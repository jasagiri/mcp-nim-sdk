## Authorization for an MCP client of an HTTP server (versions 2025-03-26
## and later).
##
## `newOAuthClient` makes an `OAuthClient`; `asHttpAuth` turns it into the
## hook `StreamableHttpTransport.auth` takes. The transport then sends the
## stored access token with every request and, on a 401 or 403, calls
## `handleChallenge`: discovery, registration, the user's consent through the
## application's `authorize` callback, the token request, and one more try of
## the request.
##
## The SDK never opens a browser. `authorize` receives the URL to open and
## returns the parameters of the redirect that came back (`code`, `state`,
## and `iss` where the server sends it).
##
## What is checked at each step, per protocol version, is in
## docs/quality/auth-requirements.md.

import std/[asyncdispatch, options, strutils, tables, times, uri]
import ../protocol/version
import ../transport/auth_hook
import ./policy
import ./oauth/[authcode, challenge, discovery, errors, metadata, registration, tokens, urls]

import ../transport/address_policy
export errors, tokens, urls.FetchPolicy, urls.defaultFetchPolicy
export address_policy.HostResolver  # the type of `FetchPolicy.resolver`

const
  StepUpWindow = initDuration(seconds = 60)

type
  UserAuthorizer* = proc(authorizationUrl: string): Future[seq[(string, string)]]
                        {.closure, gcsafe.}
    ## Sends the user to `authorizationUrl` and returns the query parameters
    ## of the redirect to the client's redirect URI. Raise to abort.

  PreRegisteredClient* = object
    ## Credentials obtained out of band, for one authorization server.
    clientId*: string
    clientSecret*: Option[string]
    issuer*: Option[string]
      ## The authorization server these belong to, as its metadata names it.
      ## Required whenever there is a `clientSecret`, in every version: the
      ## MCP server decides which authorization server the client meets, and
      ## without this a malicious one could name its own and receive the
      ## secret. Required from version 2026-07-28 on for every pre-registered
      ## client, since that version binds credentials to an issuer.

  OAuthClientConfig* = object
    serverUrl*: string
      ## The MCP endpoint. Its canonical form is the `resource` of every
      ## authorization and token request.
    redirectUri*: string
      ## Where the user agent returns: https or a localhost URL.
    authorize*: UserAuthorizer
    version*: McpProtocolVersion
      ## The version whose rules apply. A 401 comes before `initialize`, so
      ## this is the version the client intends to speak.
    clientName*: string
    preRegistered*: Option[PreRegisteredClient]
    clientIdMetadataUrl*: Option[string]
      ## The https URL of the application's Client ID Metadata Document
      ## (2025-11-25 on). The application hosts the document; it has to
      ## contain `client_id` equal to this URL, `client_name` and
      ## `redirect_uris` containing `redirectUri`.
    scopes*: Option[seq[string]]
      ## Replaces the scope selection strategy when set.
    selectAuthorizationServer*: proc(servers: seq[string]): string {.closure, gcsafe.}
      ## Which of several authorization servers to use (RFC 9728 7.6).
      ## Default: the first.
    fetchPolicy*: FetchPolicy
    tokenStore*: TokenStore
    credentialStore*: CredentialStore
    maxAuthorizationAttempts*: int
      ## Interactive authorizations for the same requirement within a minute
      ## before the failure is treated as permanent.
    now*: proc(): Time {.closure, gcsafe, raises: [].}

  OAuthClient* = ref object
    config: OAuthClientConfig
    policy: AuthPolicy
    resource: string
    indicator: string
      ## The `resource` of authorization and token requests: the identifier the
      ## protected resource metadata published, once it has been read; the MCP
      ## URL before that and where there is no such metadata.
    requestedScopes: seq[string]
    attempts: Table[string, (int, Time)]
    metadata: Option[AuthorizationServerMetadata]
      ## From the last discovery; what refreshing before a 401 needs.

proc newOAuthClientConfig*(serverUrl, redirectUri: string, authorize: UserAuthorizer,
                           version = DefaultProtocolVersion,
                           clientName = "mcp-nim-sdk"): OAuthClientConfig =
  OAuthClientConfig(
    serverUrl: serverUrl, redirectUri: redirectUri, authorize: authorize,
    version: version, clientName: clientName,
    selectAuthorizationServer: proc(servers: seq[string]): string {.closure, gcsafe.} = servers[0],
    fetchPolicy: defaultFetchPolicy(),
    tokenStore: newMemoryStore[TokenSet](),
    credentialStore: newMemoryStore[ClientCredentials](),
    maxAuthorizationAttempts: 2,
    now: proc(): Time {.closure, gcsafe, raises: [].} = getTime())

proc newOAuthClient*(config: OAuthClientConfig): OAuthClient
                    {.raises: [ValueError, OAuthError].} =
  ## Raises for a version without authorization and for a configuration
  ## that could never succeed (a redirect URI that is neither https nor
  ## localhost, a server URL that is not absolute, a client secret that does
  ## not say which authorization server it belongs to).
  result = OAuthClient(config: config, policy: authPolicy(config.version),
                       attempts: initTable[string, (int, Time)]())
  # Loopback is reachable only if the user pointed the client at a loopback
  # server: metadata a remote server names must not lead the client to the
  # user's own localhost.
  result.config.fetchPolicy = config.fetchPolicy.narrowedTo(config.serverUrl)
  result.resource = canonicalResource(config.serverUrl)
  result.indicator = result.resource
  checkRedirectUri(config.redirectUri)
  if config.authorize.isNil:
    raise newException(ValueError, "an authorize callback is required")
  if config.preRegistered.isSome and config.preRegistered.get.clientSecret.isSome and
     config.preRegistered.get.issuer.isNone:
    raise newException(ValueError,
      "the pre-registered client secret has to name the authorization server it belongs to: " &
      "set PreRegisteredClient.issuer to that server's issuer identifier. Without it a " &
      "resource server could name an authorization server of its own and receive the secret.")

proc tokenKey(c: OAuthClient): string = c.resource

proc authorizationHeader*(c: OAuthClient): Future[Option[string]] {.async.} =
  ## The stored access token, unless it has expired; an expired one is
  ## refreshed first when the last discovery makes that possible.
  let stored = c.config.tokenStore.load(c.tokenKey)
  if stored.isNone:
    return none(string)
  var tokens = stored.get
  if tokens.isExpired(c.config.now()):
    if tokens.refreshToken.isNone or c.metadata.isNone:
      return none(string)
    let creds = c.config.credentialStore.load(tokens.issuer)
    if creds.isNone:
      return none(string)
    # The last discovery may have met another authorization server than the
    # one that issued these tokens (a challenge that failed half way). The
    # refresh token and the client's credentials go back to their own issuer
    # or nowhere; the server's 401 starts a full authorization.
    if tokens.issuer != c.metadata.get.issuer or creds.get.issuer != tokens.issuer:
      return none(string)
    try:
      tokens = await refreshTokens(
        TokenEndpointClient(tokenEndpoint: c.metadata.get.tokenEndpoint,
                            credentials: creds.get, policy: c.config.fetchPolicy),
        tokens.refreshToken.get, tokens.scopes,
        (if c.policy.resourceIndicator: some(c.indicator) else: none(string)),
        c.config.now())
    except OAuthServerError:
      # The refresh token is spent or revoked. The server's 401 starts a
      # full authorization.
      c.config.tokenStore.remove(c.tokenKey)
      return none(string)
    c.config.tokenStore.save(c.tokenKey, tokens)
  return some("Bearer " & tokens.accessToken)

type Discovered = object
  resource: string
  issuer: string
  metadata: AuthorizationServerMetadata
  resourceScopes: seq[string]

proc discover(c: OAuthClient, advertised: Option[string]): Future[Discovered] {.async.} =
  let policy = c.config.fetchPolicy
  if c.policy.defaultEndpoints:
    let md = await discoverOrDefault(c.config.serverUrl, policy,
                                     @{"MCP-Protocol-Version": $c.config.version})
    return Discovered(resource: c.resource, issuer: md.issuer, metadata: md)
  let prm = await discoverProtectedResource(c.config.serverUrl, advertised,
                                            c.policy.wellKnownResourceFallback, policy)
  let issuer = c.config.selectAuthorizationServer(prm.authorizationServers)
  if issuer notin prm.authorizationServers:
    raise newException(OAuthSecurityError,
      "the chosen authorization server " & issuer & " is not one the resource lists")
  let md = await discoverAuthorizationServer(issuer, c.policy.asDiscovery, policy)
  return Discovered(resource: prm.resource, issuer: issuer, metadata: md,
                    resourceScopes: prm.scopesSupported)

proc requirePkce(c: OAuthClient, md: AuthorizationServerMetadata) {.raises: [OAuthSecurityError].} =
  ## The server is the only source on PKCE support; without it a client
  ## that proceeds sends a code that anyone who intercepts it can redeem.
  if md.codeChallengeMethodsSupported.isNone:
    if c.policy.requirePkceMetadata:
      raise newException(OAuthSecurityError,
        "authorization server " & md.issuer & " does not advertise PKCE " &
        "(code_challenge_methods_supported); refusing to proceed")
  elif "S256" notin md.codeChallengeMethodsSupported.get:
    raise newException(OAuthSecurityError,
      "authorization server " & md.issuer & " does not support the S256 code challenge method")

proc clientIdMetadataUrlIsValid(url: string) {.raises: [OAuthSecurityError].} =
  var strict = defaultFetchPolicy()
  strict.allowLoopback = false
  strict.allowPrivateNetworks = false
  checkFetchUrl(url, strict, "client metadata document URL")
  if parseUri(url).scheme.toLowerAscii() != "https" or parseUri(url).path in ["", "/"]:
    raise newException(OAuthSecurityError,
      "a client metadata document URL must be https and have a path: " & url)

proc requirePreRegisteredIssuer(c: OAuthClient, issuer: string)
                               {.raises: [OAuthError].} =
  ## Pre-registered credentials are used only at the authorization server
  ## they belong to. Checked before anything is sent to `issuer`, and before
  ## the checks of its metadata, so that the error says what is wrong.
  if c.config.preRegistered.isNone:
    return
  let pre = c.config.preRegistered.get
  if pre.issuer.isSome and pre.issuer.get != issuer:
    raise newException(OAuthSecurityError,
      "the pre-registered client belongs to " & pre.issuer.get &
      " but the resource server names " & issuer & "; the client is not used with another " &
      "authorization server. If the resource lists several, choose the right one with " &
      "selectAuthorizationServer")
  if pre.issuer.isNone and c.policy.issuerBoundCredentials:
    raise newException(OAuthError,
      "pre-registered credentials must name the issuer they belong to")

proc obtainCredentials(c: OAuthClient, md: AuthorizationServerMetadata): Future[ClientCredentials] {.async.} =
  ## Pre-registered, then Client ID Metadata Document, then what dynamic
  ## registration made earlier, then dynamic registration.
  let issuer = md.issuer
  if c.config.preRegistered.isSome:
    let pre = c.config.preRegistered.get
    return ClientCredentials(
      issuer: issuer, clientId: pre.clientId, clientSecret: pre.clientSecret,
      authMethod: if pre.clientSecret.isSome: "client_secret_basic" else: "none",
      redirectUris: @[c.config.redirectUri])
  if c.policy.clientIdMetadataDocuments and md.clientIdMetadataDocumentSupported and
     c.config.clientIdMetadataUrl.isSome:
    clientIdMetadataUrlIsValid(c.config.clientIdMetadataUrl.get)
    return ClientCredentials(
      issuer: issuer, clientId: c.config.clientIdMetadataUrl.get, authMethod: "none",
      redirectUris: @[c.config.redirectUri])
  let stored = c.config.credentialStore.load(issuer)
  if stored.isSome and c.config.redirectUri in stored.get.redirectUris and
     stored.get.issuer == issuer:
    return stored.get
  if md.registrationEndpoint.isNone:
    raise newException(OAuthError,
      "authorization server " & issuer & " offers no client registration the client can use; " &
      "supply pre-registered credentials")
  let nativeApp = isLoopbackHost(parseUri(c.config.redirectUri).hostname)
  let creds = await registerClient(
    md.registrationEndpoint.get, issuer,
    ClientRegistrationRequest(
      clientName: c.config.clientName, redirectUris: @[c.config.redirectUri],
      applicationType:
        if c.policy.applicationType: some(if nativeApp: "native" else: "web")
        else: none(string),
      refreshTokens: true),
    c.config.fetchPolicy)
  c.config.credentialStore.save(issuer, creds)
  return creds

func unionOf(a, b: seq[string]): seq[string] {.raises: [].} =
  result = a
  for item in b:
    if item notin result:
      result.add item

proc scopesFor(c: OAuthClient, bearer: Option[BearerChallenge],
               resourceScopes: seq[string]): seq[string] =
  ## Scope selection: the application's choice; else the challenge's scope;
  ## else everything the resource lists; none otherwise. From 2026-07-28 the
  ## scopes asked for before are kept.
  if c.config.scopes.isSome:
    return c.config.scopes.get
  var challenged: seq[string]
  if c.policy.scopeFromChallenge and bearer.isSome and bearer.get.scope.isSome:
    challenged = bearer.get.scope.get.splitWhitespace()
  result = if challenged.len > 0: challenged else: resourceScopes
  if c.policy.unionScopesOnStepUp:
    result = unionOf(c.requestedScopes, result)

proc countAttempt(c: OAuthClient, requirement: string) {.raises: [OAuthError].} =
  let now = c.config.now()
  var (count, since) = c.attempts.getOrDefault(requirement, (0, now))
  if now - since > StepUpWindow:
    (count, since) = (0, now)
  inc count
  c.attempts[requirement] = (count, since)
  if count > c.config.maxAuthorizationAttempts:
    raise newException(OAuthError,
      "authorization for [" & requirement & "] was attempted " & $(count - 1) &
      " times and the server still refuses; treating it as a permanent failure")

proc handleChallenge*(c: OAuthClient, status: int,
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
  let found = await c.discover(advertised)
  let md = found.metadata
  c.indicator = found.resource
  c.requirePreRegisteredIssuer(found.issuer)
  c.metadata = some(md)
  c.requirePkce(md)
  let creds = await c.obtainCredentials(md)

  # A refresh token may already be enough to answer a 401.
  let stored = c.config.tokenStore.load(c.tokenKey)
  if status == 401 and stored.isSome and stored.get.refreshToken.isSome and
     stored.get.issuer == md.issuer:
    try:
      let refreshed = await refreshTokens(
        TokenEndpointClient(tokenEndpoint: md.tokenEndpoint, credentials: creds,
                            policy: c.config.fetchPolicy),
        stored.get.refreshToken.get, stored.get.scopes,
        (if c.policy.resourceIndicator: some(c.indicator) else: none(string)),
        c.config.now())
      c.config.tokenStore.save(c.tokenKey, refreshed)
      return true
    except OAuthServerError:
      c.config.tokenStore.remove(c.tokenKey)

  let scopes = c.scopesFor(bearer, found.resourceScopes)
  c.countAttempt($status & " " & scopes.join(" "))
  let request = newAuthorizationRequest(
    md.authorizationEndpoint, creds.clientId, c.config.redirectUri, scopes,
    (if c.policy.resourceIndicator: some(c.indicator) else: none(string)),
    expectedIssuer = md.issuer,
    issuerParameterAdvertised = md.authorizationResponseIssParameterSupported,
    checkIssuer = c.policy.validateIssuer)
  let response = await c.config.authorize(request.authorizationUrl)
  let code = authorizationCode(request, response)
  let issued = await exchangeCode(
    TokenEndpointClient(tokenEndpoint: md.tokenEndpoint, credentials: creds,
                        policy: c.config.fetchPolicy),
    request, code, c.config.now())
  c.config.tokenStore.save(c.tokenKey, issued)
  c.requestedScopes = scopes
  return true

proc asHttpAuth*(c: OAuthClient): HttpClientAuth =
  HttpClientAuth(
    authorization: proc(): Future[Option[string]] {.closure, gcsafe.} =
      c.authorizationHeader(),
    onChallenge: proc(status: int, wwwAuthenticate: seq[string]): Future[bool]
                     {.closure, gcsafe.} =
      c.handleChallenge(status, wwwAuthenticate))
