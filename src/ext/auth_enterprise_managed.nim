## Enterprise-Managed Authorization, the MCP authorization extension
## `io.modelcontextprotocol/enterprise-managed-authorization`: an MCP client
## whose user signed in through the enterprise identity provider (IdP)
## obtains an access token for the MCP server without sending the user to the
## server's authorization endpoint. The client exchanges the identity
## assertion it holds for an Identity Assertion JWT Authorization Grant
## (ID-JAG) at the IdP (RFC 8693), and presents that at the MCP server's
## authorization server as a JWT bearer grant (RFC 7523).
##
## Based on modelcontextprotocol/ext-auth
## specification/stable/enterprise-managed-authorization.mdx at
## fb374c7db2b34f18ca9183882e0beecdf661892b, which profiles
## draft-ietf-oauth-identity-assertion-authz-grant-04 (an Internet-Draft; the
## processing rules cited here are its sections 3.1, 4.3 and 4.4), and the
## identifier and the `extensions` declaration from docs/extensions/auth/ of
## the specification repository at 75db1e987cbbba6d170315dc99d0dfc440754aef.
## docs/quality/ext-auth.md lists what those texts leave open.
##
## Off unless used. The application makes an `EnterpriseManagedAuth` and hands
## it to the transport (`asHttpAuth`), or calls `enableEnterpriseManaged`,
## which also declares the extension.
##
## What this client does not do: single sign-on (the application's, and its
## `identityAssertion` callback returns what SSO produced), verify the ID-JAG's
## signature (it is meant for the MCP server's authorization server, and the
## client has no business with the IdP's keys: `checkIdentityAssertionGrant`
## checks the claims that decide where the grant may be sent), and the
## authorization-server side (validating an ID-JAG is that server's job).

import std/[asyncdispatch, json, math, options, strutils, times]
import ../protocol/version
import ../transport/auth_hook
import ../transport/http
import ../client/client
import ../client/extensions as client_extensions
import ../server/server
import ../server/extensions as server_extensions
import ../auth/policy
import ../auth/oauth/[challenge, discovery, errors, grants, jwt, metadata, metadata_fields,
                      tokens, urls]
import ./auth_shared

export grants.ClientAuthentication, grants.secretBasic, grants.secretPost,
       grants.privateKeyJwt, grants.publicClient

const
  EnterpriseManagedExtensionId* = "io.modelcontextprotocol/enterprise-managed-authorization"
  TokenTypeIdJag* = "urn:ietf:params:oauth:token-type:id-jag"
  GrantProfileIdJag* = "urn:ietf:params:oauth:grant-profile:id-jag"
  IdJagJwtType* = "oauth-id-jag+jwt"
  ExchangedTokenType = "N_A"
    ## `token_type` of a token exchange response whose token is not an access
    ## token (draft 4.3.4).

type
  IdentityAssertionKind* = enum
    iakIdToken       ## an OpenID Connect ID Token
    iakSaml2         ## a SAML 2.0 assertion
    iakRefreshToken  ## a refresh token the IdP issued for this user and client

  IdentityAssertion* = object
    ## What single sign-on left the application with.
    kind*: IdentityAssertionKind
    token*: string

  IdentityAssertionProvider* = proc(): Future[IdentityAssertion] {.closure, gcsafe.}
    ## The application's single sign-on: the identity assertion it holds now,
    ## renewed if it has expired. Raises when the user has to sign in again;
    ## that failure reaches the request that needed the token.

  EnterpriseManagedConfig* = object
    serverUrl*: string
      ## The MCP endpoint; its canonical form is the `resource` of the exchange.
    version*: McpProtocolVersion
      ## The version whose authorization rules apply (Protected Resource
      ## Metadata: 2025-06-18 and later).
    resourceIssuer*: string
      ## The authorization server `resourceClientAuthentication` belongs to,
      ## as its metadata names it. The MCP server names the authorization
      ## server the client meets; the client talks to it, and asks the IdP for
      ## a grant that names it, only when it is this one. Otherwise a
      ## malicious MCP server could collect the user's identity assertion
      ## and the client's credential by naming its own.
    idpIssuer*: string
      ## The enterprise IdP, as the organization configures it. Its metadata
      ## (RFC 8414 or OpenID Connect Discovery) gives the token endpoint.
    idpClientAuthentication*: ClientAuthentication
      ## The client at the IdP (the one SSO signed in with). A
      ## `privateKeyJwt` with an empty `audience` is made out to `idpIssuer`.
    resourceClientAuthentication*: ClientAuthentication
      ## The client at the MCP server's authorization server: pre-registered
      ## credentials, or `publicClient` with the URL of the client's Client ID
      ## Metadata Document as the id. A `privateKeyJwt` with an empty
      ## `audience` is made out to that server's issuer.
    identityAssertion*: IdentityAssertionProvider
    scopes*: Option[seq[string]]
      ## Replaces the scope selection strategy when set.
    omitResource*: bool
      ## The `resource` of the exchange is optional (spec 4); it is sent
      ## unless this is set, and without it the access token is not tied to
      ## the MCP server by the grant.
    selectAuthorizationServer*: AuthorizationServerChooser
    fetchPolicy*: FetchPolicy
    tokenStore*: TokenStore
    now*: proc(): Time {.closure, gcsafe, raises: [].}

  CachedGrant = object
    token: string
    scopes: seq[string]
    expiresAt: Time

  EnterpriseManagedAuth* = ref object
    config: EnterpriseManagedConfig
    policy: AuthPolicy
    resource: string
    requestedScopes: seq[string]
    last: Option[ResourceAuthorization]
    grant: Option[CachedGrant]
      ## The ID-JAG, kept in memory only, until it expires (draft 4.4.3: a
      ## client may present the same ID-JAG again for a new access token).

proc newEnterpriseManagedConfig*(serverUrl, idpIssuer, resourceIssuer: string,
                                 idpClient, resourceClient: ClientAuthentication,
                                 identityAssertion: IdentityAssertionProvider,
                                 version = DefaultProtocolVersion): EnterpriseManagedConfig =
  EnterpriseManagedConfig(
    serverUrl: serverUrl, idpIssuer: idpIssuer, resourceIssuer: resourceIssuer,
    version: version,
    idpClientAuthentication: idpClient, resourceClientAuthentication: resourceClient,
    identityAssertion: identityAssertion,
    selectAuthorizationServer: firstAuthorizationServer,
    fetchPolicy: defaultFetchPolicy(),
    tokenStore: newMemoryStore[TokenSet](),
    now: proc(): Time {.closure, gcsafe, raises: [].} = getTime())

proc newEnterpriseManagedAuth*(config: EnterpriseManagedConfig): EnterpriseManagedAuth
                              {.raises: [ValueError, OAuthError, OAuthSecurityError].} =
  ## Raises for a configuration that could never succeed.
  if config.identityAssertion.isNil:
    raise newException(ValueError, "an identityAssertion callback is required")
  if config.idpClientAuthentication.clientId.len == 0 or
     config.resourceClientAuthentication.clientId.len == 0:
    raise newException(ValueError, "a client id is required at the IdP and at the authorization server")
  if config.resourceIssuer.len == 0:
    raise newException(ValueError,
      "the resource client has to name the authorization server it belongs to: set " &
      "EnterpriseManagedConfig.resourceIssuer (the third argument of " &
      "newEnterpriseManagedConfig) to that server's issuer identifier. Without it a " &
      "resource server could name an authorization server of its own and receive the " &
      "identity assertion and the client's credential.")
  let policy = authPolicy(config.version)
  if not policy.protectedResourceMetadata:
    raise newException(ValueError,
      "enterprise-managed authorization needs Protected Resource Metadata, which " &
      "protocol version " & $config.version & " does not have")
  checkFetchUrl(config.idpIssuer, config.fetchPolicy, "IdP issuer")
  EnterpriseManagedAuth(config: config, policy: policy,
                        resource: canonicalResource(config.serverUrl))

func subjectTokenType(kind: IdentityAssertionKind): string {.raises: [].} =
  case kind
  of iakIdToken: TokenTypeIdToken
  of iakSaml2: TokenTypeSaml2
  of iakRefreshToken: TokenTypeRefreshToken

func claimStrings(claims: JsonNode, name: string): Option[seq[string]] {.raises: [OAuthError].} =
  ## A claim that is a string or an array of strings (`aud`, `resource`).
  let node = claims{name}
  if node.isNil or node.kind == JNull:
    return none(seq[string])
  case node.kind
  of JString:
    some(@[node.getStr()])
  of JArray:
    var values: seq[string]
    for item in node:
      if item.kind != JString:
        raise newException(OAuthError, "the ID-JAG claim " & name & " has a non-string entry")
      values.add item.getStr()
    some(values)
  else:
    raise newException(OAuthError, "the ID-JAG claim " & name & " is neither a string nor an array")

proc numericDate(claims: JsonNode, name: string): float {.raises: [OAuthError].} =
  ## A NumericDate (RFC 7519 2) is any JSON number, a fractional one too. The
  ## value is not converted to an integer type: that is how `getBiggestInt`
  ## turned a float into 0 and a huge value into overflow.
  let node = claims{name}
  if node.isNil or node.kind notin {JInt, JFloat}:
    raise newException(OAuthError, "the ID-JAG has no " & name)
  result = node.getFloat()
  if result != result:
    raise newException(OAuthError, "the ID-JAG's " & name & " is not a number")

proc checkIdentityAssertionGrant*(jag: string, idpIssuer, authorizationServer: string,
                                  resource: Option[string], clientId: string,
                                  now: Time): DecodedJwt
                                 {.raises: [OAuthError, OAuthSecurityError].} =
  ## What the client can and should check before it hands an ID-JAG to an
  ## authorization server (draft 3.1, 4.4.1). The signature is NOT checked:
  ## it is for that server to check against the IdP's keys.
  ##  - `typ` is `oauth-id-jag+jwt`;
  ##  - `iss` is the IdP, `aud` is the authorization server (a string, or an
  ##    array of exactly that one entry), so the grant is not sent to a server
  ##    it was not issued for;
  ##  - `client_id` is the client that will authenticate at that server;
  ##  - `resource`, when the exchange asked for one, is in the grant and names
  ##    the MCP server (string or array);
  ##  - `sub`, `jti` are present, `exp` is in the future and not further away
##    than `MaxTokenLifetimeSeconds` (a grant that lives for years is not one
##    the IdP issued for an exchange), `iat` is a number.
  result = decodeJwtUnverified(jag)
  let header = result.header
  if header{"typ"}.isNil or header{"typ"}.kind != JString or
     header{"typ"}.getStr().toLowerAscii() != IdJagJwtType:
    raise newException(OAuthSecurityError, "the ID-JAG's typ is not " & IdJagJwtType)
  let claims = result.claims
  if claims{"iss"}.isNil or claims{"iss"}.kind != JString or claims{"iss"}.getStr() != idpIssuer:
    raise newException(OAuthSecurityError, "the ID-JAG was not issued by " & idpIssuer)
  let audience = claimStrings(claims, "aud")
  if audience.isNone or audience.get.len != 1 or audience.get[0] != authorizationServer:
    raise newException(OAuthSecurityError,
      "the ID-JAG is not issued for the authorization server " & authorizationServer)
  if claims{"client_id"}.isNil or claims{"client_id"}.kind != JString or
     claims{"client_id"}.getStr() != clientId:
    raise newException(OAuthSecurityError,
      "the ID-JAG's client_id is not the client that authenticates at the authorization server")
  for required in ["sub", "jti"]:
    if claims{required}.isNil or claims{required}.kind != JString or
       claims{required}.getStr().len == 0:
      raise newException(OAuthError, "the ID-JAG has no " & required)
  discard numericDate(claims, "iat")
  let exp = numericDate(claims, "exp")
  if exp <= float(now.toUnix):
    raise newException(OAuthError, "the ID-JAG has expired")
  if exp > float(now.toUnix) + float(MaxTokenLifetimeSeconds):
    raise newException(OAuthError,
      "the ID-JAG expires more than " & $MaxTokenLifetimeSeconds & " seconds from now")
  if resource.isSome:
    let granted = claimStrings(claims, "resource")
    if granted.isNone:
      raise newException(OAuthSecurityError,
        "the exchange asked for a resource but the ID-JAG names none")
    var named = false
    for candidate in granted.get:
      let canonical =
        try: canonicalResource(candidate)
        except OAuthError: ""
      if canonical == resource.get:
        named = true
    if not named:
      raise newException(OAuthSecurityError, "the ID-JAG's resource is not " & resource.get)

func withAudience(auth: ClientAuthentication, defaultAudience: string): ClientAuthentication
                 {.raises: [].} =
  result = auth
  if auth.authMethod == camPrivateKeyJwt and auth.audience.len == 0:
    result.audience = defaultAudience

proc requireProfile(found: ResourceAuthorization) {.raises: [OAuthError].} =
  ## Spec 6: the profile is advertised in `authorization_grant_profiles_supported`;
  ## draft 7.2: a server that does must also list the jwt-bearer grant. A
  ## server that does not say is not sent an ID-JAG: it carries the user's
  ## identity.
  let md = found.metadata
  if not md.supports("authorization_grant_profiles_supported", GrantProfileIdJag):
    raise newException(OAuthError,
      "authorization server " & found.issuer & " does not list " & GrantProfileIdJag &
      " in authorization_grant_profiles_supported; no ID-JAG is sent to it")
  let grantTypes = md.metadataStrings("grant_types_supported")
  if grantTypes.isNone or GrantTypeJwtBearer notin grantTypes.get:
    raise newException(OAuthError,
      "authorization server " & found.issuer & " lists the ID-JAG profile but not the " &
      GrantTypeJwtBearer & " grant")

proc obtainGrant(c: EnterpriseManagedAuth, found: ResourceAuthorization,
                 scopes: seq[string]): Future[string] {.async.} =
  ## The ID-JAG for `scopes`: the cached one while it lasts, else a token
  ## exchange at the IdP with the identity assertion the application holds.
  let now = c.config.now()
  if c.grant.isSome and c.grant.get.scopes == scopes and
     c.grant.get.expiresAt - initDuration(seconds = 30) > now:
    return c.grant.get.token
  c.grant = none(CachedGrant)
  let idp = await discoverAuthorizationServer(c.config.idpIssuer, adsOAuthThenOidc,
                                              c.config.fetchPolicy)
  let advertised = idp.metadataStrings("identity_chaining_requested_token_types_supported")
  if advertised.isSome and TokenTypeIdJag notin advertised.get:
    raise newException(OAuthError,
      "the IdP " & c.config.idpIssuer & " does not list " & TokenTypeIdJag &
      " in identity_chaining_requested_token_types_supported")
  let assertion = await c.config.identityAssertion()
  if assertion.token.len == 0:
    raise newException(OAuthError, "the identity assertion provider returned an empty token")
  let exchanged = await exchangeToken(
    idp.tokenEndpoint,
    TokenExchangeRequest(
      subjectToken: assertion.token, subjectTokenType: subjectTokenType(assertion.kind),
      requestedTokenType: some(TokenTypeIdJag),
      audience: some(found.issuer),
      resource: if c.config.omitResource: none(string) else: some(found.resource),
      scopes: scopes),
    c.config.idpClientAuthentication.withAudience(c.config.idpIssuer),
    c.config.fetchPolicy, now)
  if exchanged.issuedTokenType != TokenTypeIdJag:
    raise newException(OAuthError,
      "the IdP issued a token of type " & exchanged.issuedTokenType & ", not " & TokenTypeIdJag)
  if exchanged.tokenType.toUpperAscii() != ExchangedTokenType:
    raise newException(OAuthError,
      "the token exchange response has token_type " & exchanged.tokenType &
      ", not " & ExchangedTokenType)
  let jag = checkIdentityAssertionGrant(
    exchanged.accessToken, idp.issuer, found.issuer,
    (if c.config.omitResource: none(string) else: some(found.resource)),
    c.config.resourceClientAuthentication.clientId, now)
  c.grant = some(CachedGrant(
    token: exchanged.accessToken, scopes: scopes,
    expiresAt: fromUnix(BiggestInt(floor(jag.claims{"exp"}.getFloat())))))
  return exchanged.accessToken

proc acquire(c: EnterpriseManagedAuth, found: ResourceAuthorization,
             scopes: seq[string]): Future[TokenSet] {.async.} =
  requireProfile(found)
  let jag = await c.obtainGrant(found, scopes)
  var issued = await jwtBearerGrant(
    found.metadata.tokenEndpoint, found.issuer, jag,
    c.config.resourceClientAuthentication.withAudience(found.issuer), @[],
    c.config.fetchPolicy, c.config.now())
  # Draft 4.4.3: the ID-JAG, not a refresh token, is what renews access.
  issued.refreshToken = none(string)
  if issued.scopes.len == 0:
    issued.scopes = scopes
  c.config.tokenStore.save(c.resource, issued)
  c.requestedScopes = scopes
  return issued

proc authorizationHeader*(c: EnterpriseManagedAuth): Future[Option[string]] {.async.} =
  ## The stored access token. An expired one is replaced by presenting the
  ## ID-JAG again, or by a new exchange when that has expired too, as long as
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
      # Refused by the IdP or the authorization server (policy changed, user
      # removed): the server's 401 starts the full exchange, which reports it.
      c.grant = none(CachedGrant)
      c.config.tokenStore.remove(c.resource)
      return none(string)
  return some("Bearer " & token.accessToken)

proc handleChallenge*(c: EnterpriseManagedAuth, status: int,
                      wwwAuthenticate: seq[string]): Future[bool] {.async.} =
  ## The server answered 401, or 403 with `insufficient_scope`. True when a
  ## new access token is stored and the request is worth repeating. The user
  ## is never sent to the authorization endpoint.
  let bearer = bearerChallenge(wwwAuthenticate)
  if status == 403:
    if not c.policy.stepUp or bearer.isNone or bearer.get.error != some("insufficient_scope"):
      return false
  elif status != 401:
    return false
  let advertised = if bearer.isSome: bearer.get.resourceMetadata else: none(string)
  let found = await discoverResourceAuthorization(
    c.config.serverUrl, advertised, c.policy, c.config.selectAuthorizationServer,
    c.config.fetchPolicy, c.config.resourceIssuer, "the resource client's credentials")
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

proc asHttpAuth*(c: EnterpriseManagedAuth): HttpClientAuth =
  ## What `StreamableHttpTransport.auth` takes.
  HttpClientAuth(
    authorization: proc(): Future[Option[string]] {.closure, gcsafe.} =
      c.authorizationHeader(),
    onChallenge: proc(status: int, wwwAuthenticate: seq[string]): Future[bool]
                     {.closure, gcsafe.} =
      c.handleChallenge(status, wwwAuthenticate))

proc declareEnterpriseManaged*(client: McpClient) =
  ## Declares the extension in the capabilities of every 2026-07-28 request.
  ## Call before connect(). Raises ValueError in a build that speaks no
  ## version with the `extensions` capability.
  requireExtensionsCapability(EnterpriseManagedExtensionId)
  client.declareExtension(EnterpriseManagedExtensionId)

proc advertiseEnterpriseManaged*(server: McpServer) =
  ## Lists the extension in the server's capabilities. The extension's own
  ## text asks an MCP server for nothing else: the profile is advertised by its
  ## authorization server (`authorization_grant_profiles_supported`), and the
  ## token's audience is checked by `auth/resource_server`. Raises ValueError
  ## in a build that speaks no version with the `extensions` capability.
  requireExtensionsCapability(EnterpriseManagedExtensionId)
  server.registerExtension(EnterpriseManagedExtensionId)

proc enableEnterpriseManaged*(client: McpClient, transport: StreamableHttpTransport,
                              config: EnterpriseManagedConfig): EnterpriseManagedAuth =
  ## Declares the extension and makes `transport` authorize with it.
  result = newEnterpriseManagedAuth(config)
  client.declareEnterpriseManaged()
  transport.auth = result.asHttpAuth()
