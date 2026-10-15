## OAuth Client Credentials, the MCP authorization extension
## `io.modelcontextprotocol/oauth-client-credentials`: an MCP client that
## authenticates with its own credentials, no user and no browser.
##
## Based on a draft: modelcontextprotocol/ext-auth
## specification/draft/oauth-client-credentials.mdx at
## fb374c7db2b34f18ca9183882e0beecdf661892b, and the identifier and the
## `extensions` declaration from docs/extensions/auth/ of the specification
## repository at 75db1e987cbbba6d170315dc99d0dfc440754aef. The draft changes
## upstream; docs/quality/ext-auth.md lists what was and was not settled.
##
## Off unless used. Nothing here runs because the module is imported: the
## application makes a `ClientCredentialsAuth` and hands it to the transport
## (`asHttpAuth`), or calls `enableClientCredentials`, which also declares the
## extension.
##
##   var config = newClientCredentialsConfig("https://mcp.example/mcp", "my-client",
##                                           "https://as.example")  # who issued the credential
##   config.signer = some(mySigner)            # private_key_jwt (recommended)
##   # config.secret = some("...")             # or a client secret
##   let auth = enableClientCredentials(client, transport, config)
##
## The SDK does not sign: `signer` is a `JwtSigner` around the application's
## RSA / ECDSA / EdDSA implementation or KMS.
##
## The declaration targets protocol version 2026-07-28
## (`officialClientCredentials` in the table of `ext/official_common`): a
## server or client limited to an older version refuses
## `advertiseClientCredentials`, `declareClientCredentials` and
## `enableClientCredentials` with ValueError naming the extension and that
## version.

import std/[asyncdispatch, options, strutils, times]
import ../protocol/version
import ../transport/auth_hook
import ../transport/http
import ../client/client
import ../client/extensions as client_extensions
import ../server/server
import ../server/extensions as server_extensions
import ../auth/policy
import ../auth/oauth/[errors, grants, jwt, metadata, metadata_fields, tokens, urls]
import bearer_challenge  # foundation/nim-bearer-challenge
import ./auth_shared
import ./official_common
export OfficialExtension, targetVersion, displayName

export grants.ClientAuthMethod, jwt.JwtSigner, jwt.newJwtSigner
export urls.FetchPolicy, urls.defaultFetchPolicy  # the type of the config's `fetchPolicy`

const
  ClientCredentialsExtensionId* = "io.modelcontextprotocol/oauth-client-credentials"

type
  AssertionAudience* = enum
    aaIssuer        ## the authorization server's issuer identifier
    aaTokenEndpoint ## the token endpoint URL

  ClientCredentialsConfig* = object
    serverUrl*: string
      ## The MCP endpoint. Its canonical form is the `resource` of the request.
    clientId*: string
      ## Pre-registered at the authorization server; this flow does no
      ## dynamic client registration.
    issuer*: string
      ## The authorization server the credential (`secret` or `signer`)
      ## belongs to, as its metadata names it. The MCP server names the
      ## authorization server the client meets; a credential is sent only to
      ## this one, so a malicious MCP server cannot collect it by naming its
      ## own.
    secret*: Option[string]
      ## Authenticate with a client secret. Exactly one of `secret` and
      ## `signer` is set.
    signer*: Option[JwtSigner]
      ## Authenticate with a signed assertion (`private_key_jwt`, RFC 7523 2.2).
    assertionAudience*: AssertionAudience
    assertionLifetime*: Duration
    version*: McpProtocolVersion
      ## The version whose authorization rules apply (the extension builds on
      ## Protected Resource Metadata, which is 2025-06-18 and later).
    scopes*: Option[seq[string]]
      ## Replaces the scope selection strategy when set.
    selectAuthorizationServer*: AuthorizationServerChooser
    fetchPolicy*: FetchPolicy
    tokenStore*: TokenStore
    now*: proc(): Time {.closure, gcsafe, raises: [].}

  ClientCredentialsAuth* = ref object
    config: ClientCredentialsConfig
    policy: AuthPolicy
    resource: string
    requestedScopes: seq[string]
    last: Option[ResourceAuthorization]
      ## From the last 401; what getting a new token before the next one
      ## needs.

proc newClientCredentialsConfig*(serverUrl, clientId, issuer: string,
                                 version = DefaultProtocolVersion): ClientCredentialsConfig =
  ClientCredentialsConfig(
    serverUrl: serverUrl, clientId: clientId, issuer: issuer, version: version,
    assertionAudience: aaIssuer, assertionLifetime: initDuration(minutes = 1),
    selectAuthorizationServer: firstAuthorizationServer,
    fetchPolicy: defaultFetchPolicy(),
    tokenStore: newMemoryStore[TokenSet](),
    now: proc(): Time {.closure, gcsafe, raises: [].} = getTime())

proc newClientCredentialsAuth*(config: ClientCredentialsConfig): ClientCredentialsAuth
                              {.raises: [ValueError, OAuthError].} =
  ## Raises for a configuration that could never succeed: no credential or
  ## two, no client id, no issuer the credential belongs to, a version
  ## without Protected Resource Metadata, a server URL that is not absolute.
  if config.clientId.len == 0:
    raise newException(ValueError, "a client id is required")
  if config.issuer.len == 0:
    raise newException(ValueError,
      "the credential has to name the authorization server it belongs to: set " &
      "ClientCredentialsConfig.issuer (the third argument of newClientCredentialsConfig) " &
      "to that server's issuer identifier. Without it a resource server could name an " &
      "authorization server of its own and receive the credential.")
  if config.secret.isSome == config.signer.isSome:
    raise newException(ValueError,
      "exactly one of a client secret and a JWT signer is required")
  if config.secret.isSome and config.secret.get.len == 0:
    raise newException(ValueError, "the client secret is empty")
  let policy = authPolicy(config.version)
  if not policy.protectedResourceMetadata:
    raise newException(ValueError,
      "client credentials needs Protected Resource Metadata, which protocol version " &
      $config.version & " does not have")
  ClientCredentialsAuth(config: config, policy: policy,
                        resource: canonicalResource(config.serverUrl))

proc authenticationFor(c: ClientCredentialsAuth, found: ResourceAuthorization
                      ): ClientAuthentication {.raises: [OAuthError].} =
  ## The client authentication the server's metadata allows. The draft
  ## requires `token_endpoint_auth_methods_supported` to list
  ## `private_key_jwt` or `client_secret_basic`, and the signing algorithms
  ## for JWT authentication. A server that does not say is not sent a secret.
  let md = found.metadata
  let methods = md.metadataStrings("token_endpoint_auth_methods_supported")
  if methods.isNone or ("private_key_jwt" notin methods.get and
                        "client_secret_basic" notin methods.get):
    raise newException(OAuthError,
      "authorization server " & found.issuer & " does not advertise private_key_jwt or " &
      "client_secret_basic in token_endpoint_auth_methods_supported; refusing to send credentials")
  let grants = md.metadataStrings("grant_types_supported")
  if grants.isSome and GrantTypeClientCredentials notin grants.get:
    raise newException(OAuthError,
      "authorization server " & found.issuer & " does not list the client_credentials grant")
  if c.config.signer.isSome:
    let signer = c.config.signer.get
    if "private_key_jwt" notin methods.get:
      raise newException(OAuthError,
        "authorization server " & found.issuer & " does not support private_key_jwt")
    let algs = md.metadataStrings("token_endpoint_auth_signing_alg_values_supported")
    if algs.isNone or signer.alg notin algs.get:
      raise newException(OAuthError,
        "authorization server " & found.issuer & " does not list " & signer.alg &
        " in token_endpoint_auth_signing_alg_values_supported")
    return privateKeyJwt(
      c.config.clientId, signer,
      (if c.config.assertionAudience == aaIssuer: found.issuer else: md.tokenEndpoint),
      c.config.assertionLifetime)
  if "client_secret_basic" in methods.get:
    return secretBasic(c.config.clientId, c.config.secret.get)
  if "client_secret_post" in methods.get:
    return secretPost(c.config.clientId, c.config.secret.get)
  raise newException(OAuthError,
    "authorization server " & found.issuer & " does not support client_secret_basic " &
    "or client_secret_post for a client secret")

proc acquire(c: ClientCredentialsAuth, found: ResourceAuthorization,
             scopes: seq[string]): Future[TokenSet] {.async.} =
  let auth = c.authenticationFor(found)
  let issued = await clientCredentialsGrant(
    found.metadata.tokenEndpoint, found.issuer, auth, scopes, some(found.resource),
    c.config.fetchPolicy, c.config.now())
  c.config.tokenStore.save(c.resource, issued)
  c.requestedScopes = scopes
  return issued

proc authorizationHeader*(c: ClientCredentialsAuth): Future[Option[string]] {.async.} =
  ## The stored access token. An expired one is replaced by a new request
  ## (there is no refresh token: the credentials are the renewal), as long as
  ## a 401 has told the client where to ask.
  let stored = c.config.tokenStore.load(c.resource)
  if stored.isNone:
    return none(string)
  var token = stored.get
  if token.isExpired(c.config.now()):
    if c.last.isNone:
      return none(string)
    try:
      token = await c.acquire(c.last.get, c.requestedScopes)
    except OAuthServerError:
      # Refused now (rotated secret, revoked client): the server's 401
      # starts the full exchange, which reports the refusal.
      c.config.tokenStore.remove(c.resource)
      return none(string)
  return some("Bearer " & token.accessToken)

proc handleChallenge*(c: ClientCredentialsAuth, status: int,
                      wwwAuthenticate: seq[string]): Future[bool] {.async.} =
  ## The server answered 401, or 403 with `insufficient_scope`. True when a
  ## new access token is stored and the request is worth repeating.
  let bearer = bearerChallenge(wwwAuthenticate)
  if status == 403:
    if not c.policy.stepUp or bearer.isNone or bearer.get.error != some("insufficient_scope"):
      return false
  elif status != 401:
    return false
  let advertised = if bearer.isSome: bearer.get.resourceMetadata else: none(string)
  let found = await discoverResourceAuthorization(
    c.config.serverUrl, advertised, c.policy, c.config.selectAuthorizationServer,
    c.config.fetchPolicy, c.config.issuer, "the client credentials")
  c.last = some(found)
  var scopes: seq[string]
  if c.config.scopes.isSome:
    scopes = c.config.scopes.get
  else:
    let challenged =
      if c.policy.scopeFromChallenge and bearer.isSome and bearer.get.scope.isSome:
        bearer.get.scope.get.splitWhitespace()
      else: @[]
    scopes = if challenged.len > 0: challenged else: found.resourceScopes
  if status == 403:
    let wanted = unionOf(c.requestedScopes, scopes)
    if wanted.len == c.requestedScopes.len:
      return false  # nothing the client has not asked for already
    scopes = wanted
  discard await c.acquire(found, scopes)
  return true

proc asHttpAuth*(c: ClientCredentialsAuth): HttpClientAuth =
  ## What `StreamableHttpTransport.auth` takes.
  HttpClientAuth(
    authorization: proc(): Future[Option[string]] {.closure, gcsafe.} =
      c.authorizationHeader(),
    onChallenge: proc(status: int, wwwAuthenticate: seq[string]): Future[bool]
                     {.closure, gcsafe.} =
      c.handleChallenge(status, wwwAuthenticate))

proc declareClientCredentials*(client: McpClient) =
  ## Declares the extension in the capabilities of every 2026-07-28 request.
  ## Call before connect(). Raises ValueError, naming the extension and its
  ## target version, when this client is limited to a version older than the
  ## target (`officialClientCredentials`).
  requireTargetSpoken(client.protocolVersion, officialClientCredentials)
  client.declareExtension(ClientCredentialsExtensionId)

proc advertiseClientCredentials*(server: McpServer) =
  ## Lists the extension in the server's capabilities (the extension's page
  ## calls this optional but recommended for discovery). Accepting tokens is
  ## the resource server's job (`auth/resource_server`); this declares
  ## nothing but the fact. Raises ValueError, naming the extension and its
  ## target version, when this server is limited to a version older than the
  ## target (`officialClientCredentials`).
  requireTargetSpoken(server.protocolVersion, officialClientCredentials)
  server.registerExtension(ClientCredentialsExtensionId)

proc enableClientCredentials*(client: McpClient, transport: StreamableHttpTransport,
                              config: ClientCredentialsConfig): ClientCredentialsAuth =
  ## Declares the extension and makes `transport` authorize with it.
  result = newClientCredentialsAuth(config)
  client.declareClientCredentials()
  transport.auth = result.asHttpAuth()
