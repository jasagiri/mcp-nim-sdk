## The client side of MCP authorization, end to end: a real
## StreamableHttpTransport talking to a resource server that answers 401,
## and an authorization server that does what the RFCs say. Each version
## the build speaks is run with its own rules (docs/quality/auth-requirements.md).

import std/[unittest, asyncdispatch, httpcore, json, options, strutils, sequtils, times, sets, tables, uri]
import transport/transport
import transport/http
import protocol/types
import protocol/version
import protocol/features
import auth/client
import auth/oauth/urls
import auth_fixtures

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

func scopeOf(url: string): string =
  for (k, v) in queryOf(url):
    if k == "scope":
      return v

func queryValue(url, name: string): Option[string] =
  for (k, v) in queryOf(url):
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
    test "Given a server that answers 401 and version " & $v &
         ", when a request is sent, then the client authorizes once and the request succeeds":
      var env = start(v)
      defer: env.stop()
      let client = newOAuthClient(env.config)
      let transport = transportFor(client, env.resourceServer.url)
      let answer = transport.ping()
      check answer{"result", "served"}.getBool()
      check env.consents[].len == 1
      # first request without a token, the retry with the issued one
      let posts = env.resourceServer.log.requestsTo("/mcp")
      check posts.len == 2
      check posts[0].bearerOf == ""
      check posts[1].bearerOf.startsWith("Bearer at-")
      # the token goes to the resource server and nowhere else
      for l in env.authServer.log:
        if l.path in ["/token", "/register"]:
          check not l.bearerOf.startsWith("Bearer ")

    test "Given a stored token and version " & $v &
         ", when a second request is sent, then it carries the token and no new authorization happens":
      var env = start(v)
      defer: env.stop()
      let client = newOAuthClient(env.config)
      let transport = transportFor(client, env.resourceServer.url)
      discard transport.ping()
      discard transport.ping()
      check env.consents[].len == 1
      let posts = env.resourceServer.log.requestsTo("/mcp")
      check posts.len == 3
      check posts[2].bearerOf == posts[1].bearerOf

    test "Given version " & $v & ", when the client registers, then the document is a public client with the redirect URI":
      var env = start(v)
      defer: env.stop()
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      check env.authServer.registered.len == 1
      let doc = env.authServer.registered[0]
      check doc["redirect_uris"][0].getStr() == RedirectUri
      check doc["token_endpoint_auth_method"].getStr() == "none"
      check doc["grant_types"].getElems().mapIt(it.getStr()) == @["authorization_code", "refresh_token"]
      # application_type exists from 2026-07-28 (SEP-837)
      check doc.hasKey("application_type") == v.has(ftIssuerParameter)
      if doc.hasKey("application_type"):
        check doc["application_type"].getStr() == "native"

    test "Given version " & $v & ", when the user is sent to the authorization endpoint, then PKCE S256 and state are in the request":
      var env = start(v)
      defer: env.stop()
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      let url = env.consents[][0]
      check url.queryValue("code_challenge_method") == some("S256")
      check url.queryValue("response_type") == some("code")
      check url.queryValue("redirect_uri") == some(RedirectUri)
      check url.queryValue("state").get.len >= 43

    test "Given version " & $v & ", when the request goes out, then the resource parameter is present exactly from 2025-06-18 on":
      var env = start(v)
      defer: env.stop()
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      let expected = env.resourceServer.url
      let url = env.consents[][0]
      let tokenRequest = env.authServer.log.requestsTo("/token")[0]
      if v.has(ftResourceIndicators):
        check url.queryValue("resource") == some(expected)
        check tokenRequest.field("resource") == some(expected)
      else:
        check url.queryValue("resource").isNone
        check tokenRequest.field("resource").isNone

    test "Given version " & $v & ", when the token request is sent, then it carries the verifier of this request":
      var env = start(v)
      defer: env.stop()
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      let tokenRequest = env.authServer.log.requestsTo("/token")[0]
      check tokenRequest.field("grant_type") == some("authorization_code")
      check tokenRequest.field("code_verifier").get.len == 43
      check tokenRequest.field("redirect_uri") == some(RedirectUri)

    test "Given a response with another state and version " & $v &
         ", when the client receives it, then it is discarded before any token request":
      var env = start(v)
      defer: env.stop()
      env.tamper[] = proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
        for (k, val) in params:
          result.add (k, if k == "state": "attacker-state" else: val)
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()
      check env.authServer.log.requestsTo("/token").len == 0

    test "Given a response without state and version " & $v & ", when the client receives it, then it is discarded":
      var env = start(v)
      defer: env.stop()
      env.tamper[] = proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
        for (k, val) in params:
          if k != "state":
            result.add (k, val)
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()
      check env.authServer.log.requestsTo("/token").len == 0

    test "Given the user denies consent and version " & $v & ", when the redirect reports an error, then the request fails and says why":
      var env = start(v)
      defer: env.stop()
      env.tamper[] = proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
        for (k, val) in params:
          if k in ["state", "iss"]:
            result.add (k, val)
        result.add ("error", "access_denied")
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      try:
        discard transport.ping()
        fail()
      except McpTransportError as e:
        check "access_denied" in e.msg
      check env.authServer.log.requestsTo("/token").len == 0

suite "Authorization flow, 2025-03-26 discovery":
  when mpv20250326 in authVersions:
    test "Given metadata at the root of the origin, when the client discovers, then it sends MCP-Protocol-Version and asks no resource metadata":
      var env = start(mpv20250326)
      defer: env.stop()
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      let probe = env.authServer.log.requestsTo("/.well-known/oauth-authorization-server")
      check probe.len == 1
      check $probe[0].headers.getOrDefault("MCP-Protocol-Version") == "2025-03-26"
      check env.authServer.log.requestsTo("/.well-known/oauth-protected-resource/mcp").len == 0

    test "Given no metadata (404), when the client discovers, then it uses /authorize, /token and /register":
      var env = start(mpv20250326, metadataPaths = @["/never"])
      defer: env.stop()
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      check transport.ping(){"result", "served"}.getBool()
      check env.authServer.log.requestsTo("/register").len == 1
      check env.authServer.log.requestsTo("/token").len == 1
      check env.consents[][0].parseUri.path == "/authorize"

    test "Given a failure other than 404 on the metadata URL, when the client discovers, then it does not fall back":
      var env = start(mpv20250326)
      defer: env.stop()
      env.authServer.metadataPaths.clear()
      env.authServer.redirectMetadataTo = "http://127.0.0.1:1/x"
      env.authServer.metadataPaths.incl "/.well-known/oauth-authorization-server"
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()
      check env.authServer.log.requestsTo("/register").len == 0

suite "Authorization flow, discovery through resource metadata":
  when mpv20250618 in authVersions:
    test "Given a challenge without resource_metadata and version 2025-06-18, when the client discovers, then it fails: the version defines no other way":
      var env = start(mpv20250618)
      defer: env.stop()
      env.resourceServer.advertiseInChallenge = false
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()

    test "Given a resource metadata document for another resource, when the client discovers, then it is refused":
      var env = start(mpv20250618)
      defer: env.stop()
      env.resourceServer.resourceMetadata["resource"] = %"http://127.0.0.1:1/other"
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()
      check env.consents[].len == 0

    test "Given a resource_metadata URL naming the cloud metadata address, when the client discovers, then it is refused without a request":
      var env = start(mpv20250618)
      defer: env.stop()
      let client = newOAuthClient(env.config)
      expect OAuthSecurityError:
        discard waitFor client.handleChallenge(401,
          @["Bearer resource_metadata=\"https://169.254.169.254/latest/meta-data\""])

    test "Given an authorization server metadata document that is too large, when the client discovers, then it is refused":
      var env = start(mpv20250618)
      defer: env.stop()
      env.authServer.metadata["padding"] = %"x".repeat(5000)
      env.config.fetchPolicy.maxBodySize = 2048
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()

    test "Given an authorization server that redirects its metadata, when the client discovers, then the redirect is not followed":
      var env = start(mpv20250618)
      defer: env.stop()
      env.authServer.redirectMetadataTo = "http://127.0.0.1:" & $env.resourceServer.port & "/mcp"
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()

    test "Given an issuer with a path and metadata only at the OpenID path-appending URL, when version 2025-06-18 discovers, then it does not find it":
      var env = start(mpv20250618, issuerPath = "/tenant1",
                      metadataPaths = @["/tenant1/.well-known/openid-configuration"])
      defer: env.stop()
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()

  when mpv20251125 in authVersions:
    test "Given a challenge without resource_metadata and version 2025-11-25, when the client discovers, then it probes the path-specific URI first":
      var env = start(mpv20251125)
      defer: env.stop()
      env.resourceServer.advertiseInChallenge = false
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      check transport.ping(){"result", "served"}.getBool()
      check env.resourceServer.log.requestsTo("/.well-known/oauth-protected-resource/mcp").len == 1
      check env.resourceServer.log.requestsTo("/.well-known/oauth-protected-resource").len == 0

    test "Given metadata only at the root well-known URI, when the client probes, then it falls back to the root":
      var env = start(mpv20251125)
      defer: env.stop()
      env.resourceServer.advertiseInChallenge = false
      env.resourceServer.resourceMetadataPaths.clear()
      env.resourceServer.resourceMetadataPaths.incl "/.well-known/oauth-protected-resource"
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      check transport.ping(){"result", "served"}.getBool()
      check env.resourceServer.log.requestsTo("/.well-known/oauth-protected-resource/mcp").len == 1
      check env.resourceServer.log.requestsTo("/.well-known/oauth-protected-resource").len == 1

    test "Given an issuer with a path and metadata only at the OpenID path-appending URL, when version 2025-11-25 discovers, then it tries the three URLs in order and finds it":
      var env = start(mpv20251125, issuerPath = "/tenant1",
                      metadataPaths = @["/tenant1/.well-known/openid-configuration"])
      defer: env.stop()
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      check transport.ping(){"result", "served"}.getBool()
      var tried: seq[string]
      for l in env.authServer.log:
        if ".well-known" in l.path:
          tried.add l.path
      check tried == @["/.well-known/oauth-authorization-server/tenant1",
                       "/.well-known/openid-configuration/tenant1",
                       "/tenant1/.well-known/openid-configuration"]

    test "Given an authorization server that does not advertise PKCE, when version 2025-11-25 discovers, then the client refuses to proceed":
      var env = start(mpv20251125)
      defer: env.stop()
      env.authServer.metadata.delete("code_challenge_methods_supported")
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()
      check env.consents[].len == 0
      check env.authServer.log.requestsTo("/register").len == 0

  when mpv20250618 in authVersions:
    test "Given an authorization server that advertises only the plain method, when any version discovers, then the client refuses":
      var env = start(mpv20250618)
      defer: env.stop()
      env.authServer.metadata["code_challenge_methods_supported"] = %["plain"]
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()
      check env.consents[].len == 0

    test "Given no PKCE field and version 2025-06-18, when the client discovers, then it proceeds: the version has no such check":
      var env = start(mpv20250618)
      defer: env.stop()
      env.authServer.metadata.delete("code_challenge_methods_supported")
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      check transport.ping(){"result", "served"}.getBool()

    test "Given a metadata document whose issuer differs, when the client discovers, then the document is not used":
      var env = start(mpv20250618)
      defer: env.stop()
      env.authServer.metadata["issuer"] = %"https://honest.example"
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()
      check env.consents[].len == 0

suite "Authorization flow, scopes":
  when mpv20251125 in authVersions:
    test "Given a scope in the challenge, when the client authorizes, then it asks for exactly that scope":
      var env = start(mpv20251125)
      defer: env.stop()
      env.resourceServer.challengeScope = "files:read"
      env.resourceServer.resourceMetadata["scopes_supported"] = %["files:read", "files:write"]
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      check env.consents[][0].scopeOf == "files:read"

    test "Given no scope in the challenge but scopes_supported, when the client authorizes, then it asks for all of them":
      var env = start(mpv20251125)
      defer: env.stop()
      env.resourceServer.resourceMetadata["scopes_supported"] = %["files:read", "files:write"]
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      check env.consents[][0].scopeOf == "files:read files:write"

    test "Given neither, when the client authorizes, then the scope parameter is omitted":
      var env = start(mpv20251125)
      defer: env.stop()
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      check env.consents[][0].queryValue("scope").isNone

    test "Given an application that chose its scopes, when the client authorizes, then its choice wins":
      var env = start(mpv20251125)
      defer: env.stop()
      env.resourceServer.challengeScope = "files:read"
      env.config.scopes = some(@["custom"])
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      check env.consents[][0].scopeOf == "custom"

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

  when mpv20250618 in authVersions:
    test "Given a 403 and a version before 2025-11-25, when the client receives it, then it reports the error without a new authorization":
      var env = start(mpv20250618)
      defer: env.stop()
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      env.resourceServer.requiredScope = "files:write"
      expect McpTransportError:
        discard transport.ping()
      check env.consents[].len == 1

  when mpv20251125 in authVersions:
    test "Given an authorization server that never grants the scope, when the server keeps challenging, then the client stops after its attempt limit":
      var env = start(mpv20251125)
      defer: env.stop()
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      env.resourceServer.requiredScope = "files:write"
      env.authServer.grantScopes = some("files:read")
      try:
        discard transport.ping()
        fail()
      except McpTransportError as e:
        check "permanent" in e.msg
      check env.consents[].len <= 1 + 2 + 1

  when mpv20260728 in authVersions:
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
  when mpv20251125 in authVersions:
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

    test "Given a client_id URL without a path or over http, when the client is built and used, then it is refused":
      var env = start(mpv20251125)
      defer: env.stop()
      env.authServer.metadata["client_id_metadata_document_supported"] = %true
      for url in ["https://app.example.com", "https://app.example.com/", "http://app.example.com/c.json"]:
        env.config.clientIdMetadataUrl = some(url)
        let client = newOAuthClient(env.config)
        expect OAuthSecurityError:
          discard waitFor client.handleChallenge(401, @["Bearer resource_metadata=\"" &
            "http://127.0.0.1:" & $env.resourceServer.port & "/.well-known/oauth-protected-resource/mcp\""])
      check env.consents[].len == 0

    test "Given a Client ID Metadata Document URL but a server that does not advertise support, when the client authorizes, then it registers dynamically":
      var env = start(mpv20251125)
      defer: env.stop()
      env.config.clientIdMetadataUrl = some("https://app.example.com/oauth/client-metadata.json")
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      check env.authServer.log.requestsTo("/register").len == 1

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

    test "Given a pre-registered client with a secret and version " & $v & ", when the token request is sent, then the secret goes in HTTP Basic and not in the body":
      var env = start(v)
      defer: env.stop()
      env.config.preRegistered = some(PreRegisteredClient(
        clientId: "confidential", clientSecret: some("s3cr3t"),
        issuer: some(env.authServer.issuer)))
      discard transportFor(newOAuthClient(env.config), env.resourceServer.url).ping()
      let tokenRequest = env.authServer.log.requestsTo("/token")[0]
      check ($tokenRequest.headers.getOrDefault("Authorization")).startsWith("Basic ")
      check "s3cr3t" notin tokenRequest.body

    test "Given credentials from dynamic registration and version " & $v & ", when a second authorization is needed, then they are reused":
      var env = start(v)
      defer: env.stop()
      let client = newOAuthClient(env.config)
      let transport = transportFor(client, env.resourceServer.url)
      discard transport.ping()
      # the access token is revoked at the server
      env.authServer.accessTokens.clear()
      env.authServer.refreshTokens.clear()
      check transport.ping(){"result", "served"}.getBool()
      check env.consents[].len == 2
      check env.authServer.log.requestsTo("/register").len == 1

  when mpv20260728 in authVersions:
    test "Given pre-registered credentials of another issuer and version 2026-07-28, when the client authorizes, then it refuses to reuse them":
      var env = start(mpv20260728)
      defer: env.stop()
      env.config.preRegistered = some(PreRegisteredClient(
        clientId: "old", clientSecret: none(string),
        issuer: some("https://old-as.example.com")))
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()
      check env.consents[].len == 0

    test "Given pre-registered credentials without an issuer and version 2026-07-28, when the client authorizes, then it refuses: they must be bound":
      var env = start(mpv20260728)
      defer: env.stop()
      env.config.preRegistered = some(PreRegisteredClient(clientId: "x"))
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()

    test "Given credentials registered at one issuer, when the resource now names another, then the client registers again":
      var env = start(mpv20260728)
      defer: env.stop()
      let second = startFakeAs()
      defer: second.stop()
      let client = newOAuthClient(env.config)
      let transport = transportFor(client, env.resourceServer.url)
      discard transport.ping()
      check env.authServer.log.requestsTo("/register").len == 1
      # the resource moves to the second authorization server
      env.resourceServer.resourceMetadata["authorization_servers"] = %[second.issuer]
      env.authServer.accessTokens.clear()
      env.authServer.refreshTokens.clear()
      second.accessTokens = env.authServer.accessTokens
      var moved = env.config
      moved.authorize = authorizerFor(second)
      # a fresh client keeps nothing in memory, but shares the stores
      let client2 = newOAuthClient(moved)
      discard waitFor client2.handleChallenge(401, @["Bearer resource_metadata=\"http://127.0.0.1:" &
        $env.resourceServer.port & "/.well-known/oauth-protected-resource/mcp\""])
      check second.log.requestsTo("/register").len == 1

suite "Authorization flow, issuer validation (2026-07-28)":
  when mpv20260728 in authVersions:
    test "Given metadata advertising iss and a response with another iss, when the client receives it, then the code is never sent":
      var env = start(mpv20260728)
      defer: env.stop()
      env.authServer.metadata["authorization_response_iss_parameter_supported"] = %true
      env.tamper[] = proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
        for (k, val) in params:
          result.add (k, if k == "iss": "https://attacker.example" else: val)
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()
      check env.authServer.log.requestsTo("/token").len == 0

    test "Given metadata advertising iss and a response without it, when the client receives it, then it is rejected":
      var env = start(mpv20260728)
      defer: env.stop()
      env.authServer.metadata["authorization_response_iss_parameter_supported"] = %true
      env.sendIss[] = false
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()
      check env.authServer.log.requestsTo("/token").len == 0

    test "Given metadata that does not advertise iss and a response without it, when the client receives it, then it proceeds":
      var env = start(mpv20260728)
      defer: env.stop()
      env.sendIss[] = false
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      check transport.ping(){"result", "served"}.getBool()

    test "Given metadata that does not advertise iss and a response with a wrong iss, when the client receives it, then it is rejected (table row 3)":
      var env = start(mpv20260728)
      defer: env.stop()
      env.tamper[] = proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
        for (k, val) in params:
          result.add (k, if k == "iss": "https://attacker.example" else: val)
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()

    test "Given an iss that differs only by a trailing slash, when the client compares, then it does not normalize":
      var env = start(mpv20260728)
      defer: env.stop()
      env.tamper[] = proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
        for (k, val) in params:
          result.add (k, if k == "iss": val & "/" else: val)
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      expect McpTransportError:
        discard transport.ping()

    test "Given an error response with a wrong iss, when the client receives it, then the error is not acted on or shown":
      var env = start(mpv20260728)
      defer: env.stop()
      env.tamper[] = proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
        for (k, val) in params:
          if k == "state":
            result.add (k, val)
        result.add ("iss", "https://attacker.example")
        result.add ("error", "access_denied")
        result.add ("error_description", "visit https://phish.example to continue")
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      try:
        discard transport.ping()
        fail()
      except McpTransportError as e:
        check "phish.example" notin e.msg
        check "access_denied" notin e.msg

  when mpv20251125 in authVersions:
    test "Given version 2025-11-25 and a wrong iss, when the client receives the response, then iss is not part of that version and the flow completes":
      var env = start(mpv20251125)
      defer: env.stop()
      env.tamper[] = proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
        for (k, val) in params:
          result.add (k, if k == "iss": "https://elsewhere.example" else: val)
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      check transport.ping(){"result", "served"}.getBool()

suite "Authorization flow, refreshing":
  for v in authVersions:
    test "Given an expired access token and version " & $v & ", when the next request is sent, then it is refreshed without the user":
      var env = start(v)
      defer: env.stop()
      env.authServer.accessTokenLifetime = 60
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      env.clock[] = env.clock[] + initDuration(minutes = 5)
      check transport.ping(){"result", "served"}.getBool()
      check env.consents[].len == 1
      let refresh = env.authServer.log.requestsTo("/token")[1]
      check refresh.field("grant_type") == some("refresh_token")
      check (refresh.field("resource").isSome) == v.has(ftResourceIndicators)

    test "Given a revoked access token and a valid refresh token and version " & $v & ", when the server answers 401, then the refresh token answers it":
      var env = start(v)
      defer: env.stop()
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      env.authServer.accessTokens.clear()
      check transport.ping(){"result", "served"}.getBool()
      check env.consents[].len == 1
      check env.authServer.log.requestsTo("/token").len == 2

    test "Given a spent refresh token and version " & $v & ", when the server answers 401, then the client authorizes again":
      var env = start(v)
      defer: env.stop()
      env.authServer.accessTokenLifetime = 60
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      env.authServer.refreshTokens.clear()
      env.clock[] = env.clock[] + initDuration(minutes = 5)
      check transport.ping(){"result", "served"}.getBool()
      check env.consents[].len == 2

    test "Given a persisted token store and version " & $v & ", when a new client starts, then it presents the stored token first":
      var env = start(v)
      defer: env.stop()
      let transport = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      discard transport.ping()
      let second = transportFor(newOAuthClient(env.config), env.resourceServer.url)
      check second.ping(){"result", "served"}.getBool()
      check env.consents[].len == 1
