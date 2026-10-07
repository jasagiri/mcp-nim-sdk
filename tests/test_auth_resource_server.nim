## The resource-server side of MCP authorization: this SDK's
## HttpServerTransport with a token verifier, checked with a plain HTTP
## client, and then end to end with this SDK's client and an authorization
## server. Every version the build speaks is run with its own rules
## (docs/quality/auth-requirements.md).

import std/[unittest, asyncdispatch, httpclient, httpcore, json, options,
            strutils, sequtils, tables, nativesockets, os]
import transport/http
import transport/http_server
import server/server
import client/client
import protocol/types
import protocol/version
import protocol/features
import auth/resource_server
import auth/client as authclient
import auth/oauth/challenge
import auth_fixtures

const authVersions = block:
  var vs: seq[McpProtocolVersion]
  for v in SupportedProtocolVersions:
    if v.has(ftAuthorization):
      vs.add v
  vs

type
  Seen = ref object
    ## What the verifier was asked.
    calls: seq[(string, string)]

  Env = object
    transport: HttpServerTransport
    url: string
    origin: string
    seen: Seen
    config: ResourceServerConfig

proc toolsServer(version: McpProtocolVersion): McpServer =
  result = newMcpServer(McpServerInfo(name: "ExampleServer", version: "1.0.0"),
    protocolVersion = version,
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      return @[%*{"name": "get_weather", "inputSchema": {"type": "object"}}]
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      return %*{"content": [{"type": "text", "text": name}], "isError": false}
  result.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))

proc verifierFor(seen: Seen, verdicts: TableRef[string, TokenVerdict]): TokenVerifier =
  result = proc(token, resource: string): Future[TokenVerdict] {.async.} =
    seen.calls.add (token, resource)
    if token in verdicts:
      return verdicts[token]
    return TokenVerdict(kind: tvInvalid)

proc startServer(v: McpProtocolVersion, verdicts: TableRef[string, TokenVerdict],
                 authServers = @["https://auth.example.com"],
                 challengeScopes: seq[string] = @[]): Env =
  let transport = newHttpServerTransport(port = 0, protocolVersion = v)
  transport.listen()
  asyncCheck transport.serve()
  waitFor toolsServer(v).attachTransport(transport)
  result.transport = transport
  result.origin = "http://127.0.0.1:" & $transport.port
  result.url = result.origin & "/mcp"
  result.seen = Seen()
  result.config = ResourceServerConfig(
    resource: result.url, authorizationServers: authServers,
    scopesSupported: @["files:read", "files:write"], challengeScopes: challengeScopes,
    verify: verifierFor(result.seen, verdicts), version: v)
  transport.auth = newResourceServerAuth(result.config)

proc issuedByVerifier(authServer: FakeAs, seen: Seen, v: McpProtocolVersion): TokenVerifier =
  ## Accepts what the authorization server issued, and, from the version
  ## that has the resource parameter, only for this resource (the audience).
  result = proc(token, resource: string): Future[TokenVerdict] {.async.} =
    seen.calls.add (token, resource)
    if token notin authServer.accessTokens:
      return TokenVerdict(kind: tvInvalid)
    if v.has(ftResourceIndicators) and authServer.accessTokens[token].resource != resource:
      return TokenVerdict(kind: tvInvalid)
    return TokenVerdict(kind: tvValid)

type Reply = tuple[code: HttpCode, headers: HttpHeaders, body: string]

proc send(url: string, httpMethod: HttpMethod, body = "",
          headers: openArray[(string, string)] = []): Reply =
  let http = newAsyncHttpClient()
  defer: http.close()
  let response = waitFor http.request(url, httpMethod, body, newHttpHeaders(headers))
  (response.code, response.headers, waitFor response.body)

proc wwwAuthenticate(reply: Reply): seq[string] =
  seq[string](reply.headers.getOrDefault("WWW-Authenticate"))

proc validVerdicts(): TableRef[string, TokenVerdict] =
  result = newTable[string, TokenVerdict]()
  result["good"] = TokenVerdict(kind: tvValid)
  result["narrow"] = TokenVerdict(kind: tvInsufficientScope,
                                  requiredScopes: @["files:write", "files:read"])

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-auth-resource-server-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

const initializeBody = """{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}"""

suite "Resource server, every version of the build":
  for v in authVersions:
    test "Given a request without a token and version " & $v & ", when posted, then the answer is 401 with a Bearer challenge":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url, HttpPost, initializeBody)
      check reply.code == Http401
      let bearer = bearerChallenge(reply.wwwAuthenticate)
      check bearer.isSome
      check env.seen.calls.len == 0   # nothing to verify
      check (bearer.get.resourceMetadata.isSome) == v.has(ftProtectedResourceMetadata)
      if v.has(ftProtectedResourceMetadata):
        check bearer.get.resourceMetadata.get ==
          env.origin & "/.well-known/oauth-protected-resource/mcp"

    test "Given a token the verifier rejects and version " & $v & ", when posted, then the answer is 401 invalid_token":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url, HttpPost, initializeBody, {"Authorization": "Bearer bogus"})
      check reply.code == Http401
      check bearerChallenge(reply.wwwAuthenticate).get.error == some("invalid_token")
      check env.seen.calls == @[("bogus", env.url)]

    test "Given the verifier is told the resource and version " & $v & ", when a token arrives, then it gets the canonical URI of this server to check the audience against":
      let env = startServer(v, validVerdicts())
      discard send(env.url, HttpPost, initializeBody, {"Authorization": "Bearer good"})
      check env.seen.calls[0][1] == env.url

    test "Given a token the verifier accepts and version " & $v & ", when posted, then the request reaches the MCP server":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url, HttpPost, initializeBody, {"Authorization": "Bearer good"})
      check reply.code != Http401
      check reply.code != Http403

    test "Given a token that lacks scope and version " & $v & ", when posted, then the answer is 403 insufficient_scope with all needed scopes":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url, HttpPost, initializeBody, {"Authorization": "Bearer narrow"})
      check reply.code == Http403
      let bearer = bearerChallenge(reply.wwwAuthenticate).get
      check bearer.error == some("insufficient_scope")
      check bearer.scope == some("files:write files:read")

    test "Given the Bearer scheme in another case and version " & $v & ", when posted, then it is accepted":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url, HttpPost, initializeBody, {"Authorization": "bearer good"})
      check reply.code notin {Http401, Http403}

    test "Given Authorization headers that are not Bearer tokens and version " & $v & ", when posted, then each is 401 and none reaches the verifier":
      let env = startServer(v, validVerdicts())
      for value in ["Basic Zm9vOmJhcg==", "Bearer", "Bearer ", "Bearer a b", "good"]:
        let reply = send(env.url, HttpPost, initializeBody, {"Authorization": value})
        check reply.code == Http401
      # The HTTP server refuses headers this large itself; the hook's own
      # limit is asked directly.
      let answer = waitFor env.transport.auth.intercept("POST", "/mcp",
                                                         some("Bearer " & "x".repeat(9000)))
      check answer.get.code == 401
      check env.seen.calls.len == 0

    test "Given a token in the query string and version " & $v & ", when posted, then it is not looked at":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url & "?access_token=good", HttpPost, initializeBody)
      check reply.code == Http401
      check env.seen.calls.len == 0

    test "Given a verifier that fails and version " & $v & ", when posted, then the answer is 500 and the request does not go through":
      let env = startServer(v, validVerdicts())
      env.transport.auth = newResourceServerAuth(ResourceServerConfig(
        resource: env.url, authorizationServers: @["https://auth.example.com"], version: v,
        verify: proc(token, resource: string): Future[TokenVerdict] {.async.} =
          raise newException(ValueError, "introspection endpoint is down")))
      let reply = send(env.url, HttpPost, initializeBody, {"Authorization": "Bearer good"})
      check reply.code == Http500
      check "introspection" notin reply.body

    test "Given a request without a token and version " & $v & ", when posted, then the challenge names no error: there was no credential to fault":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url, HttpPost, initializeBody)
      let bearer = bearerChallenge(reply.wwwAuthenticate).get
      check bearer.error.isNone
      check bearer.errorDescription.isNone
      check "error" notin reply.wwwAuthenticate[0]

    test "Given a token the verifier rejects and version " & $v & ", when posted, then the challenge explains the refusal":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url, HttpPost, initializeBody, {"Authorization": "Bearer bogus"})
      let bearer = bearerChallenge(reply.wwwAuthenticate).get
      check bearer.errorDescription.isSome
      check bearer.errorDescription.get.len > 0

    test "Given a token that lacks scope and version " & $v & ", when posted, then the challenge carries no empty description":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url, HttpPost, initializeBody, {"Authorization": "Bearer narrow"})
      check "error_description" notin reply.wwwAuthenticate[0]

    test "Given a token of 8192 characters and one of 8193 and version " & $v & ", when each arrives, then only the longer is refused before the verifier":
      # The limit is MaxTokenLength of resource_server.nim: "longer than this".
      let env = startServer(v, validVerdicts())
      let atLimit = waitFor env.transport.auth.intercept("POST", "/mcp",
                                                          some("Bearer " & "x".repeat(8192)))
      check env.seen.calls.len == 1
      check atLimit.get.code == 401   # the verifier does not know it
      let over = waitFor env.transport.auth.intercept("POST", "/mcp",
                                                       some("Bearer " & "x".repeat(8193)))
      check over.get.code == 401
      check env.seen.calls.len == 1

    test "Given a verifier that fails and version " & $v & ", when a token arrives, then stderr names the failure and not the token":
      let env = startServer(v, validVerdicts())
      let auth = newResourceServerAuth(ResourceServerConfig(
        resource: env.url, authorizationServers: @["https://auth.example.com"], version: v,
        verify: proc(token, resource: string): Future[TokenVerdict] {.async.} =
          raise newException(ValueError, "introspection endpoint is down")))
      var code = 0
      let logged = loggedWhile(proc() =
        code = waitFor(auth.intercept("POST", "/mcp", some("Bearer secret-token"))).get.code)
      check code == 500
      check "ValueError" in logged
      check "secret-token" notin logged
      check "introspection" notin logged

    test "Given a verifier that names a scope that cannot go in a header and version " & $v & ", when a token arrives, then the answer is 500 without a challenge and stderr says why":
      let verdicts = validVerdicts()
      verdicts["odd"] = TokenVerdict(kind: tvInsufficientScope, requiredScopes: @["a\r\nX-Forged: y"])
      let env = startServer(v, verdicts)
      let reply = send(env.url, HttpPost, initializeBody, {"Authorization": "Bearer odd"})
      check reply.code == Http500
      check not reply.headers.hasKey("WWW-Authenticate")
      let logged = loggedWhile(proc() =
        check waitFor(env.transport.auth.intercept("POST", "/mcp", some("Bearer odd"))).get.code == 500)
      check "[mcp-auth]" in logged
      check "scopes" in logged

    test "Given a delete or get on the endpoint without a token and version " & $v & ", when sent, then it is 401 too":
      let env = startServer(v, validVerdicts())
      check send(env.url, HttpDelete).code == Http401
      check send(env.url, HttpGet).code == Http401

suite "Resource server, protected resource metadata":
  for v in authVersions:
    if v.has(ftProtectedResourceMetadata):
      test "Given version " & $v & ", when the well-known URI for the endpoint is requested without a token, then the document names the resource and its authorization servers":
        let env = startServer(v, validVerdicts(), authServers = @["https://auth.example.com/tenant1"])
        let reply = send(env.origin & "/.well-known/oauth-protected-resource/mcp", HttpGet)
        check reply.code == Http200
        check ($reply.headers.getOrDefault("Content-Type")).startsWith("application/json")
        let doc = parseJson(reply.body)
        check doc["resource"].getStr() == env.url
        check doc["authorization_servers"].getElems().mapIt(it.getStr()) ==
          @["https://auth.example.com/tenant1"]
        check doc["scopes_supported"].getElems().mapIt(it.getStr()) == @["files:read", "files:write"]
        check env.seen.calls.len == 0

      test "Given version " & $v & ", when the metadata is requested with POST, then it is not served":
        let env = startServer(v, validVerdicts())
        let reply = send(env.origin & "/.well-known/oauth-protected-resource/mcp", HttpPost, "{}")
        check reply.code != Http200
    else:
      test "Given version " & $v & ", when the well-known URI is requested, then it is not served: the version has no resource metadata":
        let env = startServer(v, validVerdicts())
        let reply = send(env.origin & "/.well-known/oauth-protected-resource/mcp", HttpGet)
        check reply.code == Http404

suite "Resource server, protected resource metadata without scopes":
  test "Given a configuration that lists no scopes, when the metadata document is made, then it has no scopes_supported":
    let document = resourceMetadataDocument(ResourceServerConfig(
      resource: "https://mcp.example.com/mcp",
      authorizationServers: @["https://auth.example.com"]))
    check not document.hasKey("scopes_supported")
    check document["resource"].getStr() == "https://mcp.example.com/mcp"

suite "Resource server, scopes in the challenge":
  for v in authVersions:
    test "Given challenge scopes configured and version " & $v & ", when a request has no token, then the scope appears exactly from 2025-11-25 on":
      let env = startServer(v, validVerdicts(), challengeScopes = @["files:read"])
      let bearer = bearerChallenge(send(env.url, HttpPost, initializeBody).wwwAuthenticate).get
      check bearer.scope == (if v.has(ftIncrementalScopeConsent): some("files:read") else: none(string))

suite "Resource server, configuration":
  test "Given an unusable configuration, when the hook is made, then it is refused":
    let verify: TokenVerifier = proc(token, resource: string): Future[TokenVerdict] {.async.} =
      return TokenVerdict(kind: tvValid)
    expect ValueError:
      discard newResourceServerAuth(ResourceServerConfig(
        resource: "http://127.0.0.1:1/mcp", authorizationServers: @["https://a.example"],
        version: mpv20241105, verify: verify))
    when mpv20250618 in authVersions:
      expect ValueError:   # no verifier
        discard newResourceServerAuth(ResourceServerConfig(
          resource: "http://127.0.0.1:1/mcp", authorizationServers: @["https://a.example"],
          version: mpv20250618))
      expect ValueError:   # PRM without an authorization server
        discard newResourceServerAuth(ResourceServerConfig(
          resource: "http://127.0.0.1:1/mcp", version: mpv20250618, verify: verify))
      expect ValueError:   # resource not in canonical form
        discard newResourceServerAuth(ResourceServerConfig(
          resource: "HTTP://127.0.0.1:1/mcp", authorizationServers: @["https://a.example"],
          version: mpv20250618, verify: verify))
      expect ValueError:   # a header-splitting scope
        discard newResourceServerAuth(ResourceServerConfig(
          resource: "http://127.0.0.1:1/mcp", authorizationServers: @["https://a.example"],
          challengeScopes: @["a\r\nX: y"], version: mpv20250618, verify: verify))

suite "Resource server with this SDK's client and an authorization server":
  for v in authVersions:
    # 2025-03-26 looks the authorization server up at the origin of the MCP
    # server, and this SDK's HTTP server cannot also be one. That version's
    # client is covered against a combined fixture in test_auth_client_flow.
    if v != mpv20250326:
      test "Given an authorization server and version " & $v & ", when the client connects, then it authorizes and lists tools through the protected endpoint":
        let authServer = startFakeAs()
        defer: authServer.stop()
        # The MCP server verifies against what the authorization server issued.
        let seen = Seen()
        let transport = newHttpServerTransport(port = 0, protocolVersion = v)
        transport.listen()
        asyncCheck transport.serve()
        waitFor toolsServer(v).attachTransport(transport)
        let url = "http://127.0.0.1:" & $transport.port & "/mcp"
        transport.auth = newResourceServerAuth(ResourceServerConfig(
          resource: url, authorizationServers: @[authServer.issuer],
          verify: issuedByVerifier(authServer, seen, v), version: v))
        let consents = new(seq[string])
        let config = newOAuthClientConfig(url, "http://127.0.0.1:53682/callback",
                                          authorizerFor(authServer, consents), v)
        let httpTransport = newStreamableHttpTransport(url)
        httpTransport.auth = newOAuthClient(config).asHttpAuth()
        let client = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"))
        waitFor client.connect(httpTransport)
        let response = waitFor client.sendRequest("tools/list", newJObject())
        check response.error.isNone
        check response.result.get["tools"].len == 1
        check consents[].len == 1
        check seen.calls.len > 0
        check seen.calls[0][1] == url
        waitFor client.close()
