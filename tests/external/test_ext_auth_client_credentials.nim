## The OAuth Client Credentials extension (ext-auth draft, specification/draft/
## oauth-client-credentials.mdx): a real StreamableHttpTransport against a
## resource server that answers 401 and an authorization server that
## authenticates clients strictly and checks `resource`, `scope` and the
## assertion. Plus what the extension is not: off unless used.

import protocol/version
import protocol/features

when DefaultProtocolVersion.has(ftProtectedResourceMetadata):
  import std/[unittest, asyncdispatch, httpcore, json, options, strutils, tables, times]
  import transport/transport
  import transport/http
  import protocol/types
  import client/client
  import server/server
  import ext/auth_client_credentials
  import auth/oauth/errors
  import ./server_harness
  import ./client_peer
  import ext_auth_fixtures

  const
    ScopeChallenges = DefaultProtocolVersion.has(ftIncrementalScopeConsent)
      ## Scope in a challenge and step-up on 403 exist from 2025-11-25.
    Secret = "s3cret-value-7Fjfp0ZB"
    JwtKey = "jwt-signing-key-do-not-leak"

  type Env = object
    authServer: FakeAs
    rs: FakeRs
    registry: ClientRegistry
    requests: ref seq[GrantRequest]
    clock: ref Time
    lifetime: ref int

  proc startEnv(authMethods = @["private_key_jwt", "client_secret_basic", "client_secret_post"],
                algs = @["HS256"], grantTypes: seq[string] = @[]): Env =
    result.requests = new(seq[GrantRequest])
    result.clock = new(Time)
    result.clock[] = fromUnix(1_800_000_000)
    result.lifetime = new(int)
    result.lifetime[] = 3600
    result.authServer = startFakeAs(registration = false)
    result.rs = startFakeRs(result.authServer)
    result.registry = newRegistry(@[])
    result.registry.secrets["svc"] = Secret
    result.registry.jwtKeys["jwt-client"] = JwtKey
    let a = result.authServer
    let rsUrl = result.rs.url
    let (registry, requests, clock, lifetime) = (result.registry, result.requests, result.clock,
                                                 result.lifetime)
    if authMethods.len > 0:
      a.metadata["token_endpoint_auth_methods_supported"] = %authMethods
    if algs.len > 0:
      a.metadata["token_endpoint_auth_signing_alg_values_supported"] = %algs
    if grantTypes.len > 0:
      a.metadata["grant_types_supported"] = %grantTypes
    serveGrants(a, proc(req: GrantRequest): GrantAnswer {.closure, gcsafe.} =
      requests[].add req
      if req.field("grant_type").get("") != "client_credentials":
        return oauthFailure("unsupported_grant_type")
      let client = registry.authenticate(req, clock[])
      if client.isNone:
        return oauthFailure("invalid_client")
      if req.field("resource").get("") != rsUrl:
        return oauthFailure("invalid_target", "resource mismatch")
      GrantAnswer(code: Http200, body: a.issueAccessToken(
        req.field("scope").get(""), rsUrl, client.get, lifetime[])))
    result.registry.audiences = @[a.issuer, a.metadata["token_endpoint"].getStr()]

  proc stop(e: Env) =
    e.rs.stop()
    e.authServer.stop()

  proc configFor(e: Env, clientId: string): ClientCredentialsConfig =
    result = newClientCredentialsConfig(e.rs.url, clientId, e.authServer.issuer)
    let clock = e.clock
    result.now = proc(): Time {.closure, gcsafe, raises: [].} = clock[]

  proc withSecret(e: Env, secret = Secret): ClientCredentialsConfig =
    result = e.configFor("svc")
    result.secret = some(secret)

  proc withKey(e: Env, key = JwtKey): ClientCredentialsConfig =
    result = e.configFor("jwt-client")
    result.signer = some(hs256Signer(key))

  proc transportFor(auth: ClientCredentialsAuth, url: string): StreamableHttpTransport =
    result = newStreamableHttpTransport(url)
    result.auth = auth.asHttpAuth()

  proc ping(t: StreamableHttpTransport): JsonNode =
    waitFor t.sendRequest(newJsonRpcRequest("1", "ping", newJObject()))
    waitFor t.receiveMessage()

  proc bearerOf(l: Logged): string = $l.headers.getOrDefault("Authorization")

  suite "client credentials: the flow":

    test "Given a 401 and a client secret, when a request is sent, then one client_credentials request carries resource and the secret in Basic, and the retry succeeds without any user step":
      let env = startEnv()
      defer: env.stop()
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      check t.ping(){"result", "served"}.getBool()
      check env.requests[].len == 1
      let r = env.requests[][0]
      check r.field("grant_type") == some("client_credentials")
      check r.field("resource") == some(env.rs.url)
      check r.authorization.startsWith("Basic ")
      check r.field("client_secret").isNone
      let posts = env.rs.log.requestsTo("/mcp")
      check posts.len == 2
      check posts[0].bearerOf == ""
      check posts[1].bearerOf.startsWith("Bearer at-ext-")


    test "Given a server that lists only client_secret_post besides private_key_jwt, when the client has a secret, then the secret goes in the body":
      let env = startEnv(authMethods = @["private_key_jwt", "client_secret_post"])
      defer: env.stop()
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      check t.ping(){"result", "served"}.getBool()
      check env.requests[][0].field("client_secret") == some(Secret)
      check env.requests[][0].authorization == ""

    test "Given a stored token, when more requests are sent, then they reuse it and no second token is requested":
      let env = startEnv()
      defer: env.stop()
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      discard t.ping()
      discard t.ping()
      check env.requests[].len == 1
      let posts = env.rs.log.requestsTo("/mcp")
      check posts.len == 3
      check posts[2].bearerOf == posts[1].bearerOf

    test "Given a token that has expired, when the next request is sent, then a new one is requested before it and the request needs no 401":
      let env = startEnv()
      defer: env.stop()
      env.lifetime[] = 100
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      discard t.ping()
      env.clock[] = env.clock[] + initDuration(seconds = 200)
      check t.ping(){"result", "served"}.getBool()
      check env.requests[].len == 2
      let posts = env.rs.log.requestsTo("/mcp")
      check posts.len == 3
      check posts[2].bearerOf.startsWith("Bearer at-ext-")
      check posts[2].bearerOf != posts[1].bearerOf

    test "Given an access token, when requests are sent, then the token is in no URL and goes to the resource server only":
      let env = startEnv()
      defer: env.stop()
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      discard t.ping()
      let token = env.rs.log.requestsTo("/mcp")[1].bearerOf["Bearer ".len .. ^1]
      for l in env.rs.log & env.authServer.log:
        check token notin l.path & "?" & l.query
      for l in env.authServer.log:
        check not l.bearerOf.startsWith("Bearer ")

  suite "client credentials: scopes":

    test "Given a challenge with a scope, when the token is requested, then it asks for that scope":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "mcp:read"
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      discard t.ping()
      # A challenge names a scope from 2025-11-25 on; before that it is ignored.
      check env.requests[][0].field("scope") ==
        (if ScopeChallenges: some("mcp:read") else: none(string))

    test "Given no scope in the challenge but scopes_supported, when the token is requested, then it asks for those":
      let env = startEnv()
      defer: env.stop()
      env.rs.resourceMetadata["scopes_supported"] = %*["mcp:read", "mcp:write"]
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      discard t.ping()
      check env.requests[][0].field("scope") == some("mcp:read mcp:write")

    test "Given scopes in the config, when the token is requested, then they replace the challenge's":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "mcp:read"
      var config = env.withSecret()
      config.scopes = some(@["other"])
      let t = transportFor(newClientCredentialsAuth(config), env.rs.url)
      discard t.ping()
      check env.requests[][0].field("scope") == some("other")

    test "Given a 403 insufficient_scope, when the request is sent, then the client asks again for the union and the request succeeds":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "mcp:read"
      env.rs.requiredScope = "mcp:write"
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      if ScopeChallenges:
        check t.ping(){"result", "served"}.getBool()
        check env.requests[].len == 2
        check env.requests[][1].field("scope") == some("mcp:read mcp:write")
      else:
        # Step-up is 2025-11-25 on: a 403 is the end of it.
        expect McpTransportError:
          discard t.ping()
        check env.requests[].len == 1

    test "Given a 403 that names a scope the client already asked for, when it repeats, then the client does not ask again and the request fails":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "mcp:read"
      env.rs.requiredScope = "mcp:admin"
      env.rs.insufficientScopeChallenge = "mcp:read"
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      expect McpTransportError:
        discard t.ping()
      check env.requests[].len == 1

  suite "client credentials: how a challenge is answered":

    test "Given a 403 that is no insufficient_scope challenge, or a status that is no challenge, when handled, then the answer is no and nothing is requested":
      let env = startEnv()
      defer: env.stop()
      let auth = newClientCredentialsAuth(env.withSecret())
      check not (waitFor auth.handleChallenge(403, @[]))
      check not (waitFor auth.handleChallenge(403, @["Bearer"]))
      check not (waitFor auth.handleChallenge(403, @["Bearer error=\"invalid_token\""]))
      check not (waitFor auth.handleChallenge(500, @["Bearer"]))
      check env.requests[].len == 0
      check env.rs.log.len == 0
      check env.authServer.log.len == 0

    test "Given a 401 without any challenge header, when handled, then the token is requested for the scopes the resource supports":
      let env = startEnv()
      defer: env.stop()
      env.rs.resourceMetadata["scopes_supported"] = %*["mcp:read"]
      let auth = newClientCredentialsAuth(env.withSecret())
      if ScopeChallenges:
        check (waitFor auth.handleChallenge(401, @[]))
        check env.requests[].len == 1
        check env.requests[][0].field("scope") == some("mcp:read")
      else:
        # Before 2025-11-25 the metadata is found only through the challenge.
        expect OAuthError:
          discard waitFor auth.handleChallenge(401, @[])
        check env.requests[].len == 0

    test "Given a 403 that names a scope already requested, when handled, then the answer is no and no second token is requested":
      let env = startEnv()
      defer: env.stop()
      let auth = newClientCredentialsAuth(env.withSecret())
      let metadata = "http://127.0.0.1:" & $env.rs.port & "/.well-known/oauth-protected-resource/mcp"
      check (waitFor auth.handleChallenge(401,
        @["Bearer resource_metadata=\"" & metadata & "\", scope=\"mcp:read\""]))
      check env.requests[].len == 1
      check not (waitFor auth.handleChallenge(403,
        @["Bearer error=\"insufficient_scope\", scope=\"mcp:read\""]))
      check env.requests[].len == 1

  suite "client credentials: the clock and a refused renewal":

    test "Given the default clock, when a signing client requests a token, then the assertion is dated now and the server accepts it":
      let env = startEnv()
      defer: env.stop()
      env.clock[] = getTime()
      var config = newClientCredentialsConfig(env.rs.url, "jwt-client", env.authServer.issuer)
      config.signer = some(hs256Signer(JwtKey))
      let t = transportFor(newClientCredentialsAuth(config), env.rs.url)
      check t.ping(){"result", "served"}.getBool()

    test "Given an expired token and an authorization server that now refuses the client, when requests fail, then the stale token is dropped and the next request asks once":
      let env = startEnv()
      defer: env.stop()
      env.lifetime[] = 100
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      discard t.ping()
      env.clock[] = env.clock[] + initDuration(seconds = 200)
      env.registry.secrets["svc"] = "rotated-" & Secret
      expect McpTransportError:
        discard t.ping()
      let asked = env.requests[].len
      expect McpTransportError:
        discard t.ping()
      check env.requests[].len == asked + 1

  suite "client credentials: what the authorization server must advertise":

    proc refused(env: Env, config: ClientCredentialsConfig): string =
      ## The message of the failure; the token endpoint must not have been called.
      let t = transportFor(newClientCredentialsAuth(config), env.rs.url)
      try:
        discard t.ping()
        fail()
      except McpTransportError as e:
        result = e.msg
      check env.requests[].len == 0

    test "Given metadata without token_endpoint_auth_methods_supported, when a request is sent, then no credential is sent":
      let env = startEnv(authMethods = @[])
      defer: env.stop()
      check "token_endpoint_auth_methods_supported" in env.refused(env.withSecret())

    test "Given metadata that lists neither private_key_jwt nor client_secret_basic, when a request is sent, then no credential is sent":
      let env = startEnv(authMethods = @["client_secret_post", "none"])
      defer: env.stop()
      check "token_endpoint_auth_methods_supported" in env.refused(env.withSecret())

    test "Given a signing client and metadata without private_key_jwt, when a request is sent, then no assertion is sent":
      let env = startEnv(authMethods = @["client_secret_basic"])
      defer: env.stop()
      check "private_key_jwt" in env.refused(env.withKey())

    test "Given a signer whose algorithm the server does not list, when a request is sent, then no assertion is sent":
      let env = startEnv(algs = @["RS256", "ES256"])
      defer: env.stop()
      check "HS256" in env.refused(env.withKey())

    test "Given metadata without token_endpoint_auth_signing_alg_values_supported, when a signing client sends a request, then no assertion is sent":
      let env = startEnv(algs = @[])
      defer: env.stop()
      check "token_endpoint_auth_signing_alg_values_supported" in env.refused(env.withKey())

    test "Given a secret client and metadata that lists only private_key_jwt, when a request is sent, then the secret is not sent":
      let env = startEnv(authMethods = @["private_key_jwt"])
      defer: env.stop()
      check "client_secret" in env.refused(env.withSecret())

    test "Given a grant_types_supported without client_credentials, when a request is sent, then nothing is sent":
      let env = startEnv(grantTypes = @["authorization_code", "refresh_token"])
      defer: env.stop()
      check "client_credentials" in env.refused(env.withSecret())

    test "Given metadata whose token_endpoint_auth_methods_supported is not an array, when a request is sent, then it is refused":
      let env = startEnv()
      defer: env.stop()
      env.authServer.metadata["token_endpoint_auth_methods_supported"] = %"client_secret_basic"
      check "not an array" in env.refused(env.withSecret())

  suite "client credentials: refusals and secrets":

    test "Given a wrong secret, when a request is sent, then the failure names the error and neither the secret nor the assertion key":
      let env = startEnv()
      defer: env.stop()
      let t = transportFor(newClientCredentialsAuth(env.withSecret("not-" & Secret)), env.rs.url)
      try:
        discard t.ping()
        fail()
      except McpTransportError as e:
        check "invalid_client" in e.msg
        check Secret notin e.msg

    test "Given an assertion signed with a wrong key, when a request is sent, then the failure does not contain the key":
      let env = startEnv()
      defer: env.stop()
      let t = transportFor(newClientCredentialsAuth(env.withKey("wrong-" & JwtKey)), env.rs.url)
      try:
        discard t.ping()
        fail()
      except McpTransportError as e:
        check "invalid_client" in e.msg
        check JwtKey notin e.msg

    test "Given a signer that fails, when a request is sent, then the failure is reported without the signer's message":
      let env = startEnv()
      defer: env.stop()
      var config = env.configFor("jwt-client")
      config.signer = some(newJwtSigner("HS256", proc(input: string): string {.closure, gcsafe.} =
        raise newException(IOError, "HSM at /dev/hsm0 said " & JwtKey)))
      let t = transportFor(newClientCredentialsAuth(config), env.rs.url)
      try:
        discard t.ping()
        fail()
      except McpTransportError as e:
        check JwtKey notin e.msg
        check "hsm0" notin e.msg
      check env.requests[].len == 0

    test "Given an authorization server that is not the one the resource lists, when the config chooses it, then the client refuses":
      let env = startEnv()
      defer: env.stop()
      var config = env.withSecret()
      config.selectAuthorizationServer = proc(servers: seq[string]): string {.closure, gcsafe.} =
        "https://evil.example"
      let t = transportFor(newClientCredentialsAuth(config), env.rs.url)
      expect McpTransportError:
        discard t.ping()
      check env.requests[].len == 0

    test "Given metadata that names another issuer, when a request is sent, then the client refuses and sends no credential":
      let env = startEnv()
      defer: env.stop()
      env.authServer.metadata["issuer"] = %"https://other.example"
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      expect McpTransportError:
        discard t.ping()
      check env.requests[].len == 0

    test "Given metadata with a token endpoint that is plain http on a public host, when a request is sent, then the client refuses and sends no credential":
      let env = startEnv()
      defer: env.stop()
      env.authServer.metadata["token_endpoint"] = %"http://auth.example.com/token"
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      expect McpTransportError:
        discard t.ping()
      check env.requests[].len == 0

    test "Given a token response that is not Bearer, when a request is sent, then the client refuses it":
      let env = startEnv()
      defer: env.stop()
      let a = env.authServer
      serveGrants(a, proc(req: GrantRequest): GrantAnswer {.closure, gcsafe.} =
        GrantAnswer(code: Http200, body: %*{"access_token": "x", "token_type": "mac"}))
      let t = transportFor(newClientCredentialsAuth(env.withSecret()), env.rs.url)
      expect McpTransportError:
        discard t.ping()

  suite "client credentials: off unless used":

    test "Given a transport without the extension's auth, when the server answers 401, then the request fails and no token is requested":
      let env = startEnv()
      defer: env.stop()
      let t = newStreamableHttpTransport(env.rs.url)
      expect McpTransportError:
        discard t.ping()
      check env.requests[].len == 0
      check env.authServer.log.len == 0

    test "Given a config that could never succeed, when the auth is made, then ValueError says why":
      let env = startEnv()
      defer: env.stop()
      var neither = env.configFor("svc")
      expect ValueError: discard newClientCredentialsAuth(neither)
      var both = env.withSecret()
      both.signer = some(hs256Signer("k"))
      expect ValueError: discard newClientCredentialsAuth(both)
      expect ValueError: discard newClientCredentialsAuth(env.withSecret(""))
      var noId = env.withSecret()
      noId.clientId = ""
      expect ValueError: discard newClientCredentialsAuth(noId)
      var old = env.withSecret()
      old.version = mpv20250326
      expect ValueError: discard newClientCredentialsAuth(old)
      var noAuthVersion = env.withSecret()
      noAuthVersion.version = mpv20241105
      expect ValueError: discard newClientCredentialsAuth(noAuthVersion)
      var relative = env.withSecret()
      relative.serverUrl = "/mcp"
      expect OAuthError: discard newClientCredentialsAuth(relative)

  suite "client credentials: the extensions capability":

    test "Given a client that declares the extension, when it sends a 2026-07-28 request, then clientCapabilities carries the identifier with empty settings":
      for v in versionsWith(ftExtensions):
        let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
          if message{"method"}.getStr() == "tools/list":
            peer.reply(message["id"], %*{"resultType": "complete", "tools": []}), modern = true)
        let client = peer.connectedClient(v, proc(c: McpClient) = c.declareClientCredentials())
        discard waitFor client.callMethod("tools/list", newJObject())
        let caps = peer.requestsFor("tools/list")[0]["params"]["_meta"][
          "io.modelcontextprotocol/clientCapabilities"]
        check caps["extensions"][ClientCredentialsExtensionId] == newJObject()

    test "Given a client that did not declare the extension, when it sends a request, then clientCapabilities has no extensions":
      for v in versionsWith(ftExtensions):
        let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
          if message{"method"}.getStr() == "tools/list":
            peer.reply(message["id"], %*{"resultType": "complete", "tools": []}), modern = true)
        let client = peer.connectedClient(v)
        discard waitFor client.callMethod("tools/list", newJObject())
        let caps = peer.requestsFor("tools/list")[0]["params"]["_meta"][
          "io.modelcontextprotocol/clientCapabilities"]
        check not caps.hasKey("extensions")

    test "Given a server that advertises the extension, when a 2026-07-28 client discovers it, then the capabilities list the identifier":
      for v in versionsWith(ftExtensions):
        let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
        server.advertiseClientCredentials()
        let peer = server.connect(server.attach(), v)
        let answer = peer.ask("server/discover")
        check answer["result"]["capabilities"]["extensions"][ClientCredentialsExtensionId] ==
              newJObject()

    test "Given a server that did not advertise it, when a client discovers it, then the capabilities do not list the identifier":
      for v in versionsWith(ftExtensions):
        let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
        let peer = server.connect(server.attach(), v)
        let answer = peer.ask("server/discover")
        check not answer["result"]["capabilities"].hasKey("extensions")

    test "Given a build that speaks no version with the extensions capability, when the extension is declared or advertised, then ValueError names the limit and nothing is registered":
      if not DefaultProtocolVersion.has(ftExtensions):
        let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
        expect ValueError: server.advertiseClientCredentials()
        check server.capabilities.extensions.isNone
        let peer = startPeer(nil)
        var client: McpClient
        expect ValueError:
          discard peer.connectedClient(DefaultProtocolVersion, proc(c: McpClient) =
            client = c
            c.declareClientCredentials())

    test "Given enableClientCredentials, when called, then the transport authorizes with it and the extension is declared":
      if DefaultProtocolVersion.has(ftExtensions):
        let env = startEnv()
        defer: env.stop()
        let client = newMcpClient(McpClientInfo(name: "test-client", version: "0"),
                                  DefaultProtocolVersion)
        let t = newStreamableHttpTransport(env.rs.url)
        let auth = enableClientCredentials(client, t, env.withSecret())
        check not auth.isNil
        check not t.auth.isNil
        check client.capabilities.extensions.get.hasKey(ClientCredentialsExtensionId)
        check t.ping(){"result", "served"}.getBool()


else:
  import std/[unittest, options]
  import ext/auth_client_credentials

  suite "client credentials: versions without Protected Resource Metadata":
    test "Given a version before Protected Resource Metadata, when the auth is made, then ValueError says the extension needs it":
      var config = newClientCredentialsConfig("https://mcp.example/mcp", "svc",
                                              "https://as.example", DefaultProtocolVersion)
      config.secret = some("a-secret")
      expect ValueError:
        discard newClientCredentialsAuth(config)
