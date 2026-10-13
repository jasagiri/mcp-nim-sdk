## The client side of MCP authorization, for what the specification leaves
## to its choice or asks in a sentence of its own: how the client registers
## (application_type, grant_types, a refusal), which scopes it asks for
## (offline_access), and what it does with the tokens it holds. Everything
## goes to authorization and resource servers on 127.0.0.1; a redirect URI
## that is not a loopback one is only ever written into a request.

import std/[unittest, asyncdispatch, json, options, strutils, sequtils, tables, uri, os]
import transport/transport
import transport/http
import protocol/types
import protocol/version
import protocol/features
import auth/client
import auth_fixtures

const RedirectUri = "http://127.0.0.1:53682/callback"

type Env = object
  authServer: FakeAs
  resourceServer: FakeRs
  config: OAuthClientConfig
  consents: ref seq[string]   ## the authorization URLs the user was sent to

proc start(v: McpProtocolVersion, registration = true): Env =
  ## 2025-03-26 keeps both servers on one origin; later versions use two.
  result.authServer = startFakeAs(registration = registration)
  result.resourceServer = startFakeRs(result.authServer, sharedOrigin = v == mpv20250326)
  if v == mpv20250326:
    result.resourceServer.advertiseInChallenge = false
  result.consents = new(seq[string])
  let (authServer, consents) = (result.authServer, result.consents)
  let authorize: UserAuthorizer = proc(url: string): Future[seq[(string, string)]] {.async.} =
    consents[].add url
    return authServer.consent(url)
  result.config = newOAuthClientConfig(result.resourceServer.url, RedirectUri, authorize, v)

proc stop(e: Env) =
  e.resourceServer.stop()
  e.authServer.stop()

proc transportFor(client: OAuthClient, url: string): StreamableHttpTransport =
  result = newStreamableHttpTransport(url)
  result.auth = client.asHttpAuth()

proc ping(t: StreamableHttpTransport): JsonNode =
  waitFor t.sendRequest(newJsonRpcRequest("1", "ping", newJObject()))
  waitFor t.receiveMessage()

func scopeOf(url: string): Option[string] =
  for (k, v) in decodeQuery(parseUri(url).query):
    if k == "scope":
      return some(v)

const authVersions = block:
  var vs: seq[McpProtocolVersion]
  for v in SupportedProtocolVersions:
    if v.has(ftAuthorization):
      vs.add v
  vs

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-auth-client-g0f-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc recordingStore(saved: ref seq[(string, TokenSet)]): TokenStore =
  ## A store of the application's own: it remembers every save.
  result.load = proc(key: string): Option[TokenSet] {.closure, gcsafe, raises: [].} =
    for (k, tokens) in saved[]:
      if k == key:
        result = some(tokens)
  result.save = proc(key: string, value: TokenSet) {.closure, gcsafe, raises: [].} =
    saved[].add (key, value)
  result.remove = proc(key: string) {.closure, gcsafe, raises: [].} =
    for i in countdown(saved[].high, 0):
      if saved[][i][0] == key:
        saved[].delete(i)

suite "Registration: the type of application":
  for v in authVersions:
    test "Given redirect URIs on a remote host and on this machine and version " & $v &
         ", when the client registers, then the first are web applications and the others native, from 2026-07-28":
      for (redirect, kind) in [("https://app.example.com/callback", "web"),
                               ("https://app.example.org:8443/oauth/cb", "web"),
                               ("http://localhost:8080/callback", "native"),
                               ("http://127.0.0.1:53682/callback", "native"),
                               ("http://[::1]:53682/callback", "native")]:
        var env = start(v)
        defer: env.stop()
        env.config.redirectUri = redirect
        discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
        check env.authServer.registered.len == 1
        let doc = env.authServer.registered[0]
        check doc["redirect_uris"][0].getStr() == redirect
        check doc.hasKey("application_type") == v.has(ftIssuerParameter)
        if doc.hasKey("application_type"):
          check doc["application_type"].getStr() == kind

suite "Registration: the grants":
  for v in authVersions:
    test "Given version " & $v & ", when the client registers, then grant_types holds authorization_code and refresh_token":
      var env = start(v)
      defer: env.stop()
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      let grants = env.authServer.registered[0]["grant_types"].getElems().mapIt(it.getStr())
      check "refresh_token" in grants
      check "authorization_code" in grants

suite "Registration: a refusal":
  for v in authVersions:
    test "Given an authorization server that refuses registration and version " & $v &
         ", when the client is made to authorize, then it fails saying registration failed, and a later try registers again":
      var env = start(v)
      defer: env.stop()
      env.authServer.registrationEnabled = false
      let client = newOAuthClient(env.config)
      let transport = transportFor(client, env.resourceServer.url)
      var message = ""
      try:
        discard transport.ping()
      except McpTransportError as e:
        message = e.msg
      check "registration" in message.toLowerAscii()
      check env.consents[].len == 0
      check env.authServer.registered.len == 0
      env.authServer.registrationEnabled = true
      check transport.ping(){"result", "served"}.getBool()
      check env.authServer.registered.len == 1
      check env.consents[].len == 1

    test "Given a refused registration and version " & $v &
         ", when the application makes a new client with another redirect URI, then that one registers with it":
      var env = start(v)
      defer: env.stop()
      env.authServer.registrationEnabled = false
      var failed = false
      try:
        discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      except McpTransportError:
        failed = true
      check failed
      env.authServer.registrationEnabled = true
      env.config.redirectUri = "http://localhost:8123/other"
      check transportFor(newOAuthClient(env.config), env.resourceServer.url).ping(){"result", "served"}.getBool()
      check env.authServer.registered.len == 1
      check env.authServer.registered[0]["redirect_uris"][0].getStr() == "http://localhost:8123/other"

suite "Scopes: offline_access":
  for v in authVersions:
    test "Given an application that chose offline_access among its scopes and version " & $v &
         ", when the client authorizes, then the authorization request asks for it as chosen and no token request carries a scope":
      var env = start(v)
      defer: env.stop()
      env.config.scopes = some(@["files:read", "offline_access"])
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      check env.consents[][0].scopeOf == some("files:read offline_access")
      for l in env.authServer.log.requestsTo("/token"):
        check l.field("scope").isNone

    test "Given an authorization server that lists offline_access and version " & $v &
         ", when the application chose no scopes, then the client does not ask for it":
      var env = start(v)
      defer: env.stop()
      env.authServer.metadata["scopes_supported"] = %["files:read", "offline_access"]
      env.resourceServer.resourceMetadata["scopes_supported"] = %["files:read"]
      env.resourceServer.challengeScope = "files:read"
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      let scope = env.consents[][0].scopeOf
      check scope.isNone or "offline_access" notin scope.get

suite "Tokens the client holds":
  for v in authVersions:
    test "Given a token store of the application and version " & $v &
         ", when the client authorizes, then both tokens are saved there and the second request presents the stored one":
      var env = start(v)
      defer: env.stop()
      let saved = new(seq[(string, TokenSet)])
      env.config.tokenStore = recordingStore(saved)
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      discard transport.ping()
      check saved[].len >= 1
      let held = saved[][^1][1]
      check env.authServer.accessTokens.hasKey(held.accessToken)
      check held.refreshToken.isSome
      check env.authServer.refreshTokens.hasKey(held.refreshToken.get)
      # the second request used what the store gave back
      check env.consents[].len == 1

    test "Given two configurations made with the defaults and version " & $v &
         ", when the first client has authorized, then the second does not present its token and authorizes itself":
      var env = start(v)
      defer: env.stop()
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      var second = newOAuthClientConfig(env.resourceServer.url, RedirectUri,
                                        authorizerFor(env.authServer, env.consents), v)
      discard transportFor(newOAuthClient(second), env.resourceServer.url).ping()
      check env.consents[].len == 2

    test "Given tokens that were issued and then a user who refuses a new authorization and version " & $v &
         ", when the request fails, then neither the error nor stderr repeats a token":
      var env = start(v)
      defer: env.stop()
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      var issued: seq[string]
      for token in env.authServer.accessTokens.keys: issued.add token
      for token in env.authServer.refreshTokens.keys: issued.add token
      check issued.len >= 2
      env.authServer.accessTokens.clear()   # revoked: the next request is answered 401
      env.authServer.refreshTokens.clear()
      var refusing = env.config
      refusing.authorize = proc(url: string): Future[seq[(string, string)]] {.async.} =
        raise newException(OAuthError, "the user closed the consent page")
      var message = ""
      let logged = loggedWhile(proc() =
        try:
          discard transportFor(newOAuthClient(refusing), env.resourceServer.url).ping()
        except McpTransportError as e:
          message = e.msg)
      check message.len > 0
      for token in issued:
        check token notin message
        check token notin logged
