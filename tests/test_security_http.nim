## Security of the HTTP server transport (build/SECURITY_FINDINGS.md: C1, M1,
## M2, M6, L5, L6), checked with plain HTTP clients against a transport that
## has a token verifier. Every test names the spec id it verifies
## (specs/security.feature, MCP-SEC-HTTP-*).

import std/[unittest, asyncdispatch, httpclient, httpcore, json, options,
            strutils, sequtils, tables]
import sse_reader
import transport/transport
import transport/http_server
import protocol/types
import protocol/version
import protocol/features
import auth/resource_server
import server/server

const
  Spoken = SupportedProtocolVersions
  ServesLegacySse = Spoken.anyIt(it.has(ftHttpSse))
  ServesSessions = latestLegacyVersion(Spoken).isSome

type
  Script = ref object
    ## What the script server was handed, and the principal it came with.
    received: seq[McpIncoming]

  Env = object
    transport: HttpServerTransport
    base: string
    script: Script

proc runScript(t: HttpServerTransport, s: Script) {.async.} =
  ## `initialize` answers with the newest legacy version; `hang` is never
  ## answered; anything else answers at once.
  while true:
    let incoming = await t.receive()
    s.received.add incoming
    let message = incoming.message
    if not isRequest(message):
      continue
    let id = message["id"].getStr()
    case message["method"].getStr()
    of "initialize":
      await t.sendResponse(newJsonRpcResponse(id, %*{
        "protocolVersion": $latestLegacyVersion(Spoken).get(DefaultProtocolVersion),
        "capabilities": {}, "serverInfo": {"name": "script", "version": "0"}}))
    of "hang":
      discard
    else:
      await t.sendResponse(newJsonRpcResponse(id, %*{"principal":
        (if incoming.principal.isSome: incoming.principal.get else: "")}))

proc verdicts(): TokenVerifier =
  ## Tokens "alice" and "bob" stand for those principals; others are invalid.
  result = proc(token, resource: string): Future[TokenVerdict] {.async.} =
    if token in ["alice", "bob"]:
      return TokenVerdict(kind: tvValid, principal: some(token))
    return TokenVerdict(kind: tvInvalid)

proc startProtected(): Env =
  let version = if ServesSessions: latestLegacyVersion(Spoken).get else: DefaultProtocolVersion
  let transport = newHttpServerTransport(port = 0, protocolVersion = version)
  transport.listen()
  asyncCheck transport.serve()
  let script = Script()
  asyncCheck runScript(transport, script)
  let base = "http://127.0.0.1:" & $transport.port
  transport.auth = newResourceServerAuth(ResourceServerConfig(
    resource: base & "/mcp", authorizationServers: @["https://auth.example.com"],
    verify: verdicts(), version: version))
  Env(transport: transport, base: base, script: script)

proc bearer(token: string): seq[(string, string)] =
  @[("Authorization", "Bearer " & token)]

proc send(url: string, httpMethod: HttpMethod, body = "",
          headers: openArray[(string, string)] = []): tuple[code: HttpCode, headers: HttpHeaders, body: string] =
  let http = newAsyncHttpClient()
  defer: http.close()
  let all = newHttpHeaders({"Content-Type": "application/json",
                            "Accept": "application/json, text/event-stream"})
  for (name, value) in headers:
    all[name] = value
  let response = waitFor http.request(url, httpMethod, body, all)
  (response.code, response.headers, waitFor response.body)

proc rpc(id: int, name: string, params = newJObject()): string =
  $(%*{"jsonrpc": "2.0", "id": id, "method": name, "params": params})

proc initializeBody(): string =
  rpc(1, "initialize", %*{"protocolVersion": $latestLegacyVersion(Spoken).get(DefaultProtocolVersion),
                          "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})

proc openSession(env: Env, token: string): string =
  ## Initializes as `token` and returns the session id.
  let reply = send(env.base & "/mcp", HttpPost, initializeBody(), bearer(token))
  doAssert reply.code == Http200, "initialize answered " & $reply.code
  $reply.headers["Mcp-Session-Id"]

suite "Authorization covers every endpoint the transport serves (MCP-SEC-HTTP-1)":
  if ServesLegacySse:
    test "Given an authorized transport, when GET /sse comes without a token, then the answer is 401 and no session is made":
      let env = startProtected()
      let stream = open(env.base & "/sse", HttpGet, "", @[("Accept", "text/event-stream")])
      check stream.code == Http401
      stream.close()
      check env.transport.sessionCount == 0

    test "Given an authorized transport, when POST /messages comes without a token, then the answer is 401 and nothing reaches the server":
      let env = startProtected()
      let reply = send(env.base & "/messages?sessionId=x", HttpPost, rpc(1, "tools/list"))
      check reply.code == Http401
      waitFor sleepAsync(30)
      check env.script.received.len == 0

    test "Given a token, when a client opens /sse and posts, then the request reaches the server as that principal":
      let env = startProtected()
      let stream = open(env.base & "/sse", HttpGet, "",
                        @[("Accept", "text/event-stream")] & bearer("alice"))
      check stream.code == Http200
      let endpoint = stream.next().get.data
      let reply = send(env.base & endpoint, HttpPost, rpc(7, "tools/list"), bearer("alice"))
      check reply.code == Http202
      let answer = parseJson(stream.next().get.data)
      check answer["result"]["principal"].getStr() == "alice"
      stream.close()

    test "Given an invalid token, when GET /sse comes, then the answer is 401":
      let env = startProtected()
      let stream = open(env.base & "/sse", HttpGet, "",
                        @[("Accept", "text/event-stream")] & bearer("nobody"))
      check stream.code == Http401
      stream.close()

  test "Given an authorized transport with documents, when a document and the metadata are read without a token, then both are served":
    let env = startProtected()
    env.transport.documents["/.well-known/server-card.json"] = HttpDocument(
      contentType: "application/json", body: """{"name":"card"}""")
    check send(env.base & "/.well-known/server-card.json", HttpGet).code == Http200
    check send(env.base & "/.well-known/oauth-protected-resource/mcp", HttpGet).code == Http200

  test "Given an authorized transport, when an unknown path is asked, then it is 404":
    let env = startProtected()
    check send(env.base & "/nothing", HttpGet).code == Http404

suite "A session belongs to the principal that made it (MCP-SEC-HTTP-2)":
  if ServesSessions:
    test "Given alice's session, when bob posts with its id, then the answer is 404 and the server sees nothing":
      let env = startProtected()
      let session = env.openSession("alice")
      let before = env.script.received.len
      let reply = send(env.base & "/mcp", HttpPost, rpc(2, "tools/list"),
                       bearer("bob") & @[("Mcp-Session-Id", session)])
      check reply.code == Http404
      check env.script.received.len == before

    test "Given alice's session, when alice posts with its id, then it is served":
      let env = startProtected()
      let session = env.openSession("alice")
      let reply = send(env.base & "/mcp", HttpPost, rpc(2, "tools/list"),
                       bearer("alice") & @[("Mcp-Session-Id", session)])
      check reply.code == Http200

    test "Given alice's session, when bob opens its GET stream, then the answer is 404":
      let env = startProtected()
      let session = env.openSession("alice")
      let stream = open(env.base & "/mcp", HttpGet, "",
                        @[("Accept", "text/event-stream"), ("Mcp-Session-Id", session)] &
                        bearer("bob"))
      check stream.code == Http404
      stream.close()

    test "Given alice's session, when bob sends DELETE with its id, then the answer is 404 and the session stays":
      let env = startProtected()
      let session = env.openSession("alice")
      check send(env.base & "/mcp", HttpDelete, "",
                 bearer("bob") & @[("Mcp-Session-Id", session)]).code == Http404
      check env.transport.sessionCount == 1
      check send(env.base & "/mcp", HttpDelete, "",
                 bearer("alice") & @[("Mcp-Session-Id", session)]).code == Http200
      check env.transport.sessionCount == 0

  if ServesLegacySse:
    test "Given alice's HTTP+SSE session, when bob posts to its endpoint, then the answer is 404":
      let env = startProtected()
      let stream = open(env.base & "/sse", HttpGet, "",
                        @[("Accept", "text/event-stream")] & bearer("alice"))
      let endpoint = stream.next().get.data
      check send(env.base & endpoint, HttpPost, rpc(1, "tools/list"), bearer("bob")).code == Http404
      check send(env.base & endpoint, HttpPost, rpc(1, "tools/list"), bearer("alice")).code == Http202
      stream.close()

type Serving = object
  transport: HttpServerTransport
  base: string

proc startServing(): Serving =
  ## A real McpServer whose tool `hang` never answers, so that what the
  ## transport and the server do with a cancellation can be seen.
  let transport = newHttpServerTransport(port = 0)
  transport.listen()
  asyncCheck transport.serve()
  let server = newMcpServer(McpServerInfo(name: "S", version: "1"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      await newFuture[void]("never")
      return %*{"content": [], "isError": false}
  server.setToolHandlers(McpToolHandlers(callHandler: some(callTool)))
  waitFor server.attachTransport(transport)
  Serving(transport: transport, base: "http://127.0.0.1:" & $transport.port)

proc modernMeta(): JsonNode =
  %*{"io.modelcontextprotocol/protocolVersion": "2026-07-28",
     "io.modelcontextprotocol/clientInfo": {"name": "C", "version": "1"},
     "io.modelcontextprotocol/clientCapabilities": {}}

proc hangCall(id: JsonNode, modern: bool): string =
  var params = %*{"name": "hang", "arguments": {}}
  if modern:
    params["_meta"] = modernMeta()
  $(%*{"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": params})

proc cancelled(requestId: JsonNode): string =
  $(%*{"jsonrpc": "2.0", "method": "notifications/cancelled",
       "params": {"requestId": requestId}})

proc startHanging(base: string, id: JsonNode, modern: bool,
                  headers: openArray[(string, string)]): AsyncHttpClient =
  ## Posts the call without waiting for its answer; closing the result is
  ## the client leaving.
  let http = newAsyncHttpClient()
  let all = newHttpHeaders({"Content-Type": "application/json",
                            "Accept": "application/json, text/event-stream"})
  for (name, value) in headers:
    all[name] = value
  if modern:
    all["MCP-Protocol-Version"] = "2026-07-28"
    all["Mcp-Method"] = "tools/call"
    all["Mcp-Name"] = "hang"
  discard http.request(base & "/mcp", HttpPost, hangCall(id, modern), all)
  waitFor sleepAsync(100)
  http

proc legacySessionOf(base: string): string =
  let reply = send(base & "/mcp", HttpPost, initializeBody())
  doAssert reply.code == Http200
  let session = $reply.headers["Mcp-Session-Id"]
  discard send(base & "/mcp", HttpPost,
    $(%*{"jsonrpc": "2.0", "method": "notifications/initialized"}),
    @[("Mcp-Session-Id", session)])
  session

suite "A cancellation cancels only the sender's own request (MCP-SEC-HTTP-6)":
  if DefaultProtocolVersion.isModern:
    test "Given a 2026-07-28 request in progress, when another client posts notifications/cancelled naming the transport's exchange id or the same id, then the request is still in progress":
      let env = startServing()
      let victim = startHanging(env.base, %1, true, [])
      check env.transport.pendingExchangeCount == 1
      for named in [%"http-1", %1, %"1"]:
        discard send(env.base & "/mcp", HttpPost, cancelled(named),
                     {"MCP-Protocol-Version": "2026-07-28"})
      waitFor sleepAsync(100)
      check env.transport.pendingExchangeCount == 1
      victim.close()

    test "Given a 2026-07-28 request in progress, when its client closes the connection, then the request is cancelled":
      let env = startServing()
      let victim = startHanging(env.base, %1, true, [])
      check env.transport.pendingExchangeCount == 1
      victim.close()
      waitFor sleepAsync(200)
      check env.transport.pendingExchangeCount == 0

  if ServesSessions:
    test "Given a session with a request in progress, when it cancels the request by the id it chose, then the request is cancelled":
      let env = startServing()
      let session = legacySessionOf(env.base)
      let hanging = startHanging(env.base, %5, false, @[("Mcp-Session-Id", session)])
      check env.transport.pendingExchangeCount == 1
      check send(env.base & "/mcp", HttpPost, cancelled(%5),
                 @[("Mcp-Session-Id", session)]).code == Http202
      waitFor sleepAsync(100)
      check env.transport.pendingExchangeCount == 0
      hanging.close()

    test "Given two sessions that chose the same request id, when one cancels it, then only its own request is cancelled":
      let env = startServing()
      let a = legacySessionOf(env.base)
      let b = legacySessionOf(env.base)
      let hangA = startHanging(env.base, %5, false, @[("Mcp-Session-Id", a)])
      let hangB = startHanging(env.base, %5, false, @[("Mcp-Session-Id", b)])
      check env.transport.pendingExchangeCount == 2
      discard send(env.base & "/mcp", HttpPost, cancelled(%5), @[("Mcp-Session-Id", a)])
      waitFor sleepAsync(100)
      check env.transport.pendingExchangeCount == 1
      hangA.close()
      hangB.close()

    test "Given a request of another session, when a session cancels the exchange id the transport made for it, then that request is still in progress":
      let env = startServing()
      let a = legacySessionOf(env.base)
      let b = legacySessionOf(env.base)
      let hangA = startHanging(env.base, %5, false, @[("Mcp-Session-Id", a)])
      check env.transport.pendingExchangeCount == 1
      for named in [%"http-1", %5]:
        discard send(env.base & "/mcp", HttpPost, cancelled(named), @[("Mcp-Session-Id", b)])
      waitFor sleepAsync(100)
      check env.transport.pendingExchangeCount == 1
      hangA.close()
