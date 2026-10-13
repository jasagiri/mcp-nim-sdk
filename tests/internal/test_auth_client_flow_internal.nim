## The client side of MCP authorization, end to end: a real
## StreamableHttpTransport talking to a resource server that answers 401,
## and an authorization server that does what the RFCs say. Each version
## the build speaks is run with its own rules (docs/quality/auth-requirements.md).

import std/[unittest, asyncdispatch, httpcore, json, options, strutils, times, tables, uri]
import transport/http
import protocol/types
import protocol/version
import protocol/features
import auth/client
import auth/oauth/urls
import ../external/auth_fixtures

const RedirectUri = "http://127.0.0.1:53682/callback"

type Env = object
  authServer: FakeAs
  resourceServer: FakeRs
  config: OAuthClientConfig
  consents: ref seq[string]   ## the authorization URLs the user was sent to
  clock: ref Time
  sendIss: ref bool
  tamper: ref proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.}

proc start(v: McpProtocolVersion, issuerPath = "", metadataPaths: seq[string] = @[],
           registration = true): Env =
  ## 2025-03-26 has no resource metadata and keeps both servers on one
  ## origin; later versions use two.
  result.authServer = startFakeAs(issuerPath, metadataPaths, registration)
  result.resourceServer = startFakeRs(result.authServer, sharedOrigin = v == mpv20250326)
  if v == mpv20250326:
    result.resourceServer.advertiseInChallenge = false
  result.consents = new(seq[string])
  result.clock = new(Time)
  result.clock[] = getTime()
  result.sendIss = new(bool)
  result.sendIss[] = true
  result.tamper = new(proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.})
  let (authServer, consents, sendIss, tamper) = (result.authServer, result.consents,
                                                 result.sendIss, result.tamper)
  let authorize: UserAuthorizer = proc(url: string): Future[seq[(string, string)]] {.async.} =
    consents[].add url
    var params = authServer.consent(url, sendIss[])
    if not tamper[].isNil:
      params = tamper[](params)
    return params
  let clock = result.clock
  result.config = newOAuthClientConfig(result.resourceServer.url, RedirectUri, authorize, v)
  result.config.now = proc(): Time {.closure, gcsafe, raises: [].} = clock[]

proc stop(e: Env) =
  e.resourceServer.stop()
  e.authServer.stop()

proc transportFor(client: OAuthClient, url: string): StreamableHttpTransport =
  result = newStreamableHttpTransport(url)
  result.auth = client.asHttpAuth()

proc ping(t: StreamableHttpTransport): JsonNode =
  waitFor t.sendRequest(newJsonRpcRequest("1", "ping", newJObject()))
  waitFor t.receiveMessage()

func queryPairs(url: string): seq[(string, string)] =
  ## The query of an authorization URL as the user agent receives it.
  for (k, v) in decodeQuery(parseUri(url).query):
    result.add (k, v)

func scopeOf(url: string): string =
  for (k, v) in queryPairs(url):
    if k == "scope":
      return v

func queryValue(url, name: string): Option[string] =
  for (k, v) in queryPairs(url):
    if k == name:
      return some(v)

proc bearerOf(l: Logged): string = $l.headers.getOrDefault("Authorization")

const authVersions = block:
  var vs: seq[McpProtocolVersion]
  for v in SupportedProtocolVersions:
    if v.has(ftAuthorization):
      vs.add v
  vs

suite "Authorization flow, every version of the build":
  for v in authVersions:


    test "Given version " & $v & ", when the user is sent to the authorization endpoint, then PKCE S256 and state are in the request":
      var env = start(v)
      defer: env.stop()
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      let url = env.consents[][0]
      check url.queryValue("code_challenge_method") == some("S256")
      check url.queryValue("response_type") == some("code")
      check url.queryValue("redirect_uri") == some(RedirectUri)
      check url.queryValue("state").get.len >= 43


suite "Authorization flow, scopes":
  if mpv20251125 in authVersions:


    test "Given a 403 insufficient_scope, when the client steps up, then it asks for the challenged scope and the request succeeds":
      var env = start(mpv20251125)
      defer: env.stop()
      env.resourceServer.challengeScope = "files:read"
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      env.resourceServer.requiredScope = "files:write"
      env.resourceServer.challengeScope = "files:read"
      check transport.ping(){"result", "served"}.getBool()
      check env.consents[].len == 2
      # 2025-11-25: the challenge is authoritative; 2026-07-28 keeps earlier scopes
      check env.consents[][1].scopeOf == "files:write"


  if mpv20260728 in authVersions:
    test "Given a 403 and version 2026-07-28, when the client steps up, then it asks for the union of earlier and challenged scopes":
      var env = start(mpv20260728)
      defer: env.stop()
      env.resourceServer.challengeScope = "files:read"
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      env.resourceServer.requiredScope = "files:write"
      env.resourceServer.challengeScope = "files:read"
      check transport.ping(){"result", "served"}.getBool()
      check env.consents[][1].scopeOf == "files:read files:write"

suite "Authorization flow, client registration":
  if mpv20251125 in authVersions:
    test "Given an authorization server that supports Client ID Metadata Documents, when the client has such a URL, then it uses it and does not register":
      var env = start(mpv20251125)
      defer: env.stop()
      env.authServer.metadata["client_id_metadata_document_supported"] = %true
      env.config.clientIdMetadataUrl = some("https://app.example.com/oauth/client-metadata.json")
      env.authServer.registered.setLen(0)
      let seen = new(seq[string])
      env.config.authorize = authorizerFor(env.authServer, seen)
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      # the fake server issues codes for any client_id, so the exchange completes
      check transport.ping(){"result", "served"}.getBool()
      check seen[].len == 1
      check seen[][0].queryValue("client_id") == some("https://app.example.com/oauth/client-metadata.json")
      check env.authServer.log.requestsTo("/register").len == 0


  for v in authVersions:
    test "Given pre-registered credentials and version " & $v & ", when the client authorizes, then it uses them and does not register":
      var env = start(v)
      defer: env.stop()
      env.config.preRegistered = some(PreRegisteredClient(
        clientId: "preregistered", clientSecret: none(string),
        issuer: some(env.authServer.issuer)))
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      check transport.ping(){"result", "served"}.getBool()
      check env.authServer.log.requestsTo("/register").len == 0
      check env.consents[][0].queryValue("client_id") == some("preregistered")


proc silentAuthorizer(): UserAuthorizer =
  result = proc(url: string): Future[seq[(string, string)]] {.async.} =
    return @[]

proc denyingAuthorizer(): UserAuthorizer =
  result = proc(url: string): Future[seq[(string, string)]] {.async.} =
    raise newException(OAuthError, "the user closed the consent page")

proc resourceChallenge(env: Env): seq[string] =
  @["Bearer resource_metadata=\"http://127.0.0.1:" & $env.resourceServer.port &
    "/.well-known/oauth-protected-resource/mcp\""]

proc tokenRequests(env: Env): int = env.authServer.log.requestsTo("/token").len


suite "Authorization flow, when a stored token cannot be refreshed":
  for v in authVersions:
    test "Given an expired access token without a refresh token and version " & $v &
         ", when the header is asked for, then there is none and nothing is sent":
      var env = start(v)
      defer: env.stop()
      env.authServer.accessTokenLifetime = 60
      let client = newOAuthClient(env.config)
      discard transportFor(client, env.resourceServer.url).ping()
      let key = canonicalResource(env.config.serverUrl)
      var stored = env.config.tokenStore.load(key).get
      stored.refreshToken = none(string)
      env.config.tokenStore.save(key, stored)
      env.clock[] = env.clock[] + initDuration(minutes = 5)
      let sent = env.tokenRequests
      check waitFor(client.authorizationHeader()).isNone
      check env.tokenRequests == sent


    test "Given credentials whose issuer is not the one that issued the token and version " & $v &
         ", when the token has expired, then the refresh token is not sent":
      var env = start(v)
      defer: env.stop()
      env.authServer.accessTokenLifetime = 60
      let client = newOAuthClient(env.config)
      discard transportFor(client, env.resourceServer.url).ping()
      let issuer = env.config.tokenStore.load(canonicalResource(env.config.serverUrl)).get.issuer
      var creds = env.config.credentialStore.load(issuer).get
      creds.issuer = "https://other-as.example.com"
      env.config.credentialStore.save(issuer, creds)
      env.clock[] = env.clock[] + initDuration(minutes = 5)
      let sent = env.tokenRequests
      check waitFor(client.authorizationHeader()).isNone
      check env.tokenRequests == sent

    test "Given a refresh that succeeded and version " & $v &
         ", when the next request is sent, then the refreshed token is the stored one and is not refreshed again":
      var env = start(v)
      defer: env.stop()
      env.authServer.accessTokenLifetime = 3600
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      env.clock[] = env.clock[] + initDuration(hours = 2)
      discard transport.ping()
      discard transport.ping()
      check env.tokenRequests == 2
      let posts = env.resourceServer.log.requestsTo("/mcp")
      let key = canonicalResource(env.config.serverUrl)
      check "Bearer " & env.config.tokenStore.load(key).get.accessToken == posts[^1].bearerOf

    test "Given a refresh token the server rejects and version " & $v &
         ", when the header is asked for, then there is none and the spent token is forgotten":
      var env = start(v)
      defer: env.stop()
      env.authServer.accessTokenLifetime = 60
      let client = newOAuthClient(env.config)
      discard transportFor(client, env.resourceServer.url).ping()
      env.authServer.refreshTokens.clear()
      env.clock[] = env.clock[] + initDuration(minutes = 5)
      check waitFor(client.authorizationHeader()).isNone
      check env.config.tokenStore.load(canonicalResource(env.config.serverUrl)).isNone

    test "Given a refresh token the server rejects and a user who then refuses and version " & $v &
         ", when the server answers 401, then the spent token is forgotten":
      var env = start(v)
      defer: env.stop()
      let client = newOAuthClient(env.config)
      discard transportFor(client, env.resourceServer.url).ping()
      env.authServer.refreshTokens.clear()
      var refusing = env.config
      refusing.authorize = denyingAuthorizer()
      expect CatchableError:
        discard waitFor newOAuthClient(refusing).handleChallenge(401, env.resourceChallenge)
      check env.config.tokenStore.load(canonicalResource(env.config.serverUrl)).isNone

