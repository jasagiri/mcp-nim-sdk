## Streamable HTTP over real sockets on 127.0.0.1: the server-side
## transport checked with a plain HTTP client, and the client-side transport
## checked against this SDK's server and against hand-written servers.
##
## Expectations are derived from `DefaultProtocolVersion`, so the same file
## passes on every `mcp-<version>` release branch.

import std/[unittest, asyncdispatch, asynchttpserver, httpclient, json,
            options, strutils, nativesockets]
import transport/transport
import transport/http
import transport/http_server
import transport/event_stream
import server/server
import client/client
import protocol/types
import protocol/lifecycle

const
  SpeaksModern = isModern(DefaultProtocolVersion)
  LegacyDefault = min(DefaultProtocolVersion, mpv20251125)

proc weatherServer(version: McpProtocolVersion): McpServer =
  result = newMcpServer(McpServerInfo(name: "ExampleServer", version: "1.0.0"),
    protocolVersion = version,
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      return @[%*{"name": "get_weather", "inputSchema": {"type": "object"}}]
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      if arguments{"delayMs"}.getInt() > 0:
        await sleepAsync(arguments{"delayMs"}.getInt())
      return %*{"content": [{"type": "text",
                             "text": name & ":" & arguments{"location"}.getStr()}],
                "isError": false}
  result.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))

proc startServer(version = DefaultProtocolVersion,
                 maxBodySize = DefaultMaxBodySize): tuple[transport: HttpServerTransport, url: string, server: McpServer] =
  let transport = newHttpServerTransport(port = 0, protocolVersion = version,
                                         maxBodySize = maxBodySize)
  transport.listen()
  asyncCheck transport.serve()
  let server = weatherServer(version)
  waitFor server.attachTransport(transport)
  (transport, "http://127.0.0.1:" & $transport.port & "/mcp", server)

type Reply = tuple[code: HttpCode, headers: HttpHeaders, body: string]

proc send(url: string, httpMethod: HttpMethod, body = "",
          headers: openArray[(string, string)] = []): Reply =
  let http = newAsyncHttpClient()
  defer: http.close()
  let response = waitFor http.request(url, httpMethod, body, newHttpHeaders(headers))
  (response.code, response.headers, waitFor response.body)

proc modernMeta(version = "2026-07-28"): JsonNode =
  %*{"io.modelcontextprotocol/protocolVersion": version,
     "io.modelcontextprotocol/clientInfo": {"name": "ExampleClient", "version": "1.0.0"},
     "io.modelcontextprotocol/clientCapabilities": {}}

proc toolCall(id: JsonNode, name = "get_weather"): string =
  $(%*{"jsonrpc": "2.0", "id": id, "method": "tools/call",
       "params": {"_meta": modernMeta(), "name": name,
                  "arguments": {"location": "Seattle, WA"}}})

const ToolCallHeaders = {
  "Content-Type": "application/json",
  "MCP-Protocol-Version": "2026-07-28",
  "Mcp-Method": "tools/call",
  "Mcp-Name": "get_weather"}

proc legacyInitialize(): string =
  $(%*{"jsonrpc": "2.0", "id": 1, "method": "initialize",
       "params": {"protocolVersion": $LegacyDefault, "capabilities": {},
                  "clientInfo": {"name": "peer", "version": "0"}}})

suite "HTTP endpoint (every era)":

  test "Given a path other than the endpoint, when posted to, then the answer is 404":
    let (_, url, _) = startServer()
    check send(url.replace("/mcp", "/other"), HttpPost, legacyInitialize()).code == Http404

  test "Given the endpoint, when it receives PUT, then the answer is 405 naming the allowed methods":
    let (_, url, _) = startServer()
    let reply = send(url, HttpPut)
    check reply.code == Http405
    check $reply.headers["Allow"] == (if LegacyDefault >= mpv20250326: "POST, GET, DELETE" else: "POST, DELETE")

  test "Given the endpoint, when it receives GET without a session, then the answer is 400, or 405 where there is no GET stream":
    let (_, url, _) = startServer()
    let reply = send(url, HttpGet)
    check reply.code == (if LegacyDefault >= mpv20250326: Http400 else: Http405)

  test "Given a body that is not JSON, when posted, then the answer is 400 with a parse error":
    let (_, url, _) = startServer()
    let reply = send(url, HttpPost, "{not json")
    check reply.code == Http400
    check parseJson(reply.body)["error"]["code"].getInt() == -32700
    check parseJson(reply.body)["id"].kind == JNull

  test "Given a JSON body that is not an object, when posted, then the answer is 400 invalid request":
    let (_, url, _) = startServer()
    let reply = send(url, HttpPost, "[1, 2]")
    check reply.code == Http400
    check parseJson(reply.body)["error"]["code"].getInt() == -32600

  test "Given a body larger than the limit, when posted, then the answer is 413":
    let (_, url, _) = startServer(maxBodySize = 256)
    let reply = send(url, HttpPost, $(%*{"jsonrpc": "2.0", "id": 1, "method": "ping",
                                         "params": {"pad": repeat("x", 1024)}}))
    check reply.code == Http413

  test "Given an Origin that is neither loopback nor allowed, when posted, then the answer is 403":
    let (_, url, _) = startServer()
    check send(url, HttpPost, legacyInitialize(), {"Origin": "https://evil.example"}).code == Http403

  test "Given a loopback Origin, when posted, then the request is served":
    let (_, url, _) = startServer()
    check send(url, HttpPost, legacyInitialize(), {"Origin": "http://localhost:3000"}).code == Http200

  test "Given an Origin the operator allowed, when posted, then the request is served":
    let (transport, url, _) = startServer()
    transport.allowedOrigins = @["https://app.example"]
    check send(url, HttpPost, legacyInitialize(), {"Origin": "https://app.example"}).code == Http200

  test "Given an initialized session, when a notification is posted on it, then the answer is 202 with no body":
    let (_, url, server) = startServer()
    let session = $send(url, HttpPost, legacyInitialize()).headers["Mcp-Session-Id"]
    let reply = send(url, HttpPost, $(%*{"jsonrpc": "2.0", "method": "notifications/initialized"}),
                     {"Mcp-Session-Id": session})
    check reply.code == Http202
    check reply.body == ""
    waitFor sleepAsync(1)
    check server.session(session).state == mlsOperational

  test "Given any answer, when its headers are read, then the security headers are present":
    let (_, url, _) = startServer()
    for reply in [send(url, HttpPost, legacyInitialize()), send(url, HttpGet)]:
      check $reply.headers["X-Content-Type-Options"] == "nosniff"
      check $reply.headers["X-Frame-Options"] == "DENY"
      check $reply.headers["Content-Security-Policy"] == "default-src 'self'"
      check $reply.headers["Referrer-Policy"] == "strict-origin-when-cross-origin"

  test "Given a legacy initialize with a numeric id, when posted, then the answer is 200 JSON echoing the number":
    let (_, url, _) = startServer()
    let reply = send(url, HttpPost, legacyInitialize())
    check reply.code == Http200
    check ($reply.headers["Content-Type"]).startsWith("application/json")
    let body = parseJson(reply.body)
    check body["id"].kind == JInt
    check body["id"].getInt() == 1
    check body["result"]["protocolVersion"].getStr() == $LegacyDefault

proc legacyToolCall(id: JsonNode, location: string, delayMs = 0): string =
  $(%*{"jsonrpc": "2.0", "id": id, "method": "tools/call",
       "params": {"name": "get_weather",
                  "arguments": {"location": location, "delayMs": delayMs}}})

suite "HTTP sessions (versions 2025-03-26 to 2025-11-25)":

  test "Given a legacy initialize, when answered, then the answer names an unguessable session":
    let (_, url, _) = startServer()
    let first = $send(url, HttpPost, legacyInitialize()).headers["Mcp-Session-Id"]
    let second = $send(url, HttpPost, legacyInitialize()).headers["Mcp-Session-Id"]
    check first.len >= 32
    check first != second

  test "Given a server one client has initialized, when a second client initializes, then it gets its own session":
    let (transport, url, server) = startServer()
    check send(url, HttpPost, legacyInitialize()).code == Http200
    let reply = send(url, HttpPost, legacyInitialize())
    check reply.code == Http200
    check parseJson(reply.body).hasKey("result")
    check transport.sessionCount == 2
    check server.sessionCount == 2

  test "Given a legacy request without a session id, when posted, then the answer is 400":
    let (_, url, _) = startServer()
    let reply = send(url, HttpPost, legacyToolCall(%1, "Kobe"))
    check reply.code == Http400
    check parseJson(reply.body)["id"].getInt() == 1

  test "Given a session id the server did not issue, when a request names it, then the answer is 404":
    let (_, url, _) = startServer()
    check send(url, HttpPost, legacyToolCall(%1, "Kobe"), {"Mcp-Session-Id": "made-up"}).code == Http404

  test "Given an initialized session, when a request names it, then it is served":
    let (_, url, _) = startServer()
    let session = $send(url, HttpPost, legacyInitialize()).headers["Mcp-Session-Id"]
    let reply = send(url, HttpPost, legacyToolCall(%7, "Kobe"), {"Mcp-Session-Id": session})
    check reply.code == Http200
    let body = parseJson(reply.body)
    check body["id"].getInt() == 7
    check body["result"]["content"][0]["text"].getStr() == "get_weather:Kobe"

  test "Given two clients using the same request id at the same time, when both are answered, then each gets its own result":
    let (_, url, _) = startServer()
    let sessionA = $send(url, HttpPost, legacyInitialize()).headers["Mcp-Session-Id"]
    let sessionB = $send(url, HttpPost, legacyInitialize()).headers["Mcp-Session-Id"]
    proc call(session, location: string, delayMs: int): Future[string] {.async.} =
      let http = newAsyncHttpClient()
      let response = await http.request(url, HttpPost, legacyToolCall(%1, location, delayMs),
                                        newHttpHeaders({"Mcp-Session-Id": session}))
      let body = await response.body
      http.close()
      return body
    let slow = call(sessionA, "slow-city", 60)
    let fast = call(sessionB, "fast-city", 0)
    let fastBody = parseJson(waitFor fast)
    let slowBody = parseJson(waitFor slow)
    check fastBody["id"].getInt() == 1
    check slowBody["id"].getInt() == 1
    check fastBody["result"]["content"][0]["text"].getStr() == "get_weather:fast-city"
    check slowBody["result"]["content"][0]["text"].getStr() == "get_weather:slow-city"

  test "Given a session, when the client sends DELETE, then the session ends on the transport and the server":
    let (transport, url, server) = startServer()
    let session = $send(url, HttpPost, legacyInitialize()).headers["Mcp-Session-Id"]
    check server.sessionCount == 1
    check send(url, HttpDelete, headers = {"Mcp-Session-Id": session}).code == Http200
    check transport.sessionCount == 0
    check server.sessionCount == 0
    check send(url, HttpPost, legacyToolCall(%1, "Kobe"), {"Mcp-Session-Id": session}).code == Http404

  test "Given DELETE without a session id or with an unknown one, when sent, then the answer is 400 or 404":
    let (_, url, _) = startServer()
    check send(url, HttpDelete).code == Http400
    check send(url, HttpDelete, headers = {"Mcp-Session-Id": "made-up"}).code == Http404

  test "Given the session limit is reached by a session in use, when another client initializes, then the answer is 503":
    let (transport, url, _) = startServer()
    transport.maxSessions = 1
    let first = send(url, HttpPost, legacyInitialize())
    check first.code == Http200
    # A session never used again would be dropped to make room
    # (MCP-SEC-HTTP-3); this one is in use.
    check send(url, HttpPost, """{"jsonrpc": "2.0", "id": 2, "method": "ping"}""",
               headers = {"Mcp-Session-Id": $first.headers["Mcp-Session-Id"]}).code == Http200
    check send(url, HttpPost, legacyInitialize()).code == Http503

  test "Given an initialize the server rejects, when answered, then no session is opened":
    let (transport, url, _) = startServer()
    let reply = send(url, HttpPost, $(%*{"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": {"capabilities": {}}}))
    check parseJson(reply.body).hasKey("error")
    check not reply.headers.hasKey("Mcp-Session-Id")
    check transport.sessionCount == 0

suite "a build limited to legacy versions over HTTP":

  test "Given an endpoint limited to a legacy version, when a 2026-07-28 probe is posted, then it is refused like any request outside a session, not as a 2026-07-28 error":
    # A 2026-07-28 error code would tell a dual-era client not to fall back.
    let (_, url, _) = startServer(LegacyDefault)
    let reply = send(url, HttpPost, $(%*{"jsonrpc": "2.0", "id": "d", "method": "server/discover",
                                         "params": {"_meta": modernMeta()}}),
                     {"MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "server/discover"})
    check reply.code == Http400
    let code = parseJson(reply.body)["error"]["code"].getInt()
    check code notin [-32020, -32021, -32022]

if SpeaksModern:
  suite "2026-07-28 HTTP endpoint":

    test "Given the specification's tools/call request, when posted with its headers, then the answer is 200 with a complete result":
      let (_, url, _) = startServer()
      let reply = send(url, HttpPost, toolCall(%1), ToolCallHeaders)
      check reply.code == Http200
      let body = parseJson(reply.body)
      check body["id"].getInt() == 1
      check body["result"]["resultType"].getStr() == "complete"
      check body["result"]["content"][0]["text"].getStr() == "get_weather:Seattle, WA"

    test "Given an Mcp-Name that differs from the body, when posted, then the answer is 400 header mismatch":
      let (_, url, _) = startServer()
      let reply = send(url, HttpPost, toolCall(%1, name = "bar"), ToolCallHeaders)
      check reply.code == Http400
      let body = parseJson(reply.body)
      check body["id"].getInt() == 1
      check body["error"]["code"].getInt() == -32020

    test "Given each required header missing in turn, when posted, then the answer is 400 header mismatch":
      let (_, url, _) = startServer()
      for missing in ["MCP-Protocol-Version", "Mcp-Method", "Mcp-Name"]:
        var headers: seq[(string, string)] = @[]
        for (name, value) in ToolCallHeaders:
          if name != missing:
            headers.add (name, value)
        let reply = send(url, HttpPost, toolCall(%1), headers)
        check reply.code == Http400
        check parseJson(reply.body)["error"]["code"].getInt() == -32020

    test "Given header names in another letter case, when posted, then the request is served":
      let (_, url, _) = startServer()
      let reply = send(url, HttpPost, toolCall(%1), {
        "content-type": "application/json", "mcp-protocol-version": "2026-07-28",
        "MCP-METHOD": "tools/call", "mcp-name": "get_weather"})
      check reply.code == Http200

    test "Given an unknown version in header and body, when posted, then the answer is 400 listing supported versions":
      let (_, url, _) = startServer()
      let reply = send(url, HttpPost,
        $(%*{"jsonrpc": "2.0", "id": 1, "method": "tools/list",
             "params": {"_meta": modernMeta("1900-01-01")}}),
        {"MCP-Protocol-Version": "1900-01-01", "Mcp-Method": "tools/list"})
      check reply.code == Http400
      let error = parseJson(reply.body)["error"]
      check error["code"].getInt() == -32022
      check error["data"]["supported"][0].getStr() == "2026-07-28"

    test "Given a request without client capabilities, when posted, then the answer is 400 invalid params":
      let (_, url, _) = startServer()
      let meta = modernMeta()
      meta.delete("io.modelcontextprotocol/clientCapabilities")
      let reply = send(url, HttpPost,
        $(%*{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {"_meta": meta}}),
        {"MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"})
      check reply.code == Http400
      check parseJson(reply.body)["error"]["code"].getInt() == -32602

    test "Given a version header that names 2026-07-28 and a body without _meta, when posted, then the answer is 400 invalid params":
      let (_, url, _) = startServer()
      let reply = send(url, HttpPost,
        $(%*{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}),
        {"MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"})
      check reply.code == Http400
      check parseJson(reply.body)["error"]["code"].getInt() == -32602

    test "Given a version header that names 2026-07-28 and a _meta without the version, when posted, then the answer is 400 invalid params":
      let (_, url, _) = startServer()
      let reply = send(url, HttpPost,
        $(%*{"jsonrpc": "2.0", "id": 1, "method": "tools/list",
             "params": {"_meta": {"progressToken": "p"}}}),
        {"MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"})
      check reply.code == Http400
      check parseJson(reply.body)["error"]["code"].getInt() == -32602

    test "Given a version header that names an earlier version and a body without _meta, when posted, then the request is not taken for a 2026-07-28 one":
      let (_, url, _) = startServer()
      let reply = send(url, HttpPost,
        $(%*{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}),
        {"MCP-Protocol-Version": "2025-06-18"})
      check reply.code == Http400
      check parseJson(reply.body)["error"]["code"].getInt() == -32600

    test "Given a server without the extension that defines it, when tasks/get is posted without Mcp-Name, then the answer is method not found and not a header mismatch":
      # Mcp-Name mirrors taskId for the methods of the Tasks extension; a server
      # that does not serve them has no such rule to apply.
      let (_, url, _) = startServer()
      let body = %*{"jsonrpc": "2.0", "id": 9, "method": "tasks/get",
                  "params": {"_meta": modernMeta(), "taskId": "t-1"}}
      let reply = send(url, HttpPost, $body, {
        "Content-Type": "application/json", "MCP-Protocol-Version": "2026-07-28",
        "Mcp-Method": "tasks/get"})
      check parseJson(reply.body)["error"]["code"].getInt() == -32601

    test "Given a version header that differs from a complete body, when posted, then the answer is 400 header mismatch, not invalid params":
      let (_, url, _) = startServer()
      let reply = send(url, HttpPost,
        $(%*{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {"_meta": modernMeta()}}),
        {"MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call"})
      check reply.code == Http400
      check parseJson(reply.body)["error"]["code"].getInt() == -32020

    test "Given an Mcp-Name with spaces or tabs around it, when posted, then the spaces are not part of the value and the request is served":
      let (_, url, _) = startServer()
      for padded in ["  get_weather  ", "\tget_weather\t"]:
        let reply = send(url, HttpPost, toolCall(%1), {
          "Content-Type": "application/json", "MCP-Protocol-Version": "2026-07-28",
          "Mcp-Method": "tools/call", "Mcp-Name": padded})
        check reply.code == Http200

    test "Given a Base64 Mcp-Name that decodes to a name with spaces around it, when posted, then the spaces are part of the value":
      let (_, url, _) = startServer()
      # "  get_weather  " does not equal the body's "get_weather".
      let reply = send(url, HttpPost, toolCall(%1), {
        "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call",
        "Mcp-Name": "=?base64?ICBnZXRfd2VhdGhlciAg?="})
      check reply.code == Http400
      check parseJson(reply.body)["error"]["code"].getInt() == -32020

    test "Given a method the server does not implement, when posted, then the answer is 404 method not found":
      let (_, url, _) = startServer()
      for name in ["no/such/method", "ping"]:
        let reply = send(url, HttpPost,
          $(%*{"jsonrpc": "2.0", "id": 1, "method": name, "params": {"_meta": modernMeta()}}),
          {"MCP-Protocol-Version": "2026-07-28", "Mcp-Method": name})
        check reply.code == Http404
        check parseJson(reply.body)["error"]["code"].getInt() == -32601

    test "Given a tool name that is not plain ASCII, when posted with a Base64 Mcp-Name, then the headers agree with the body":
      let (_, url, _) = startServer()
      let reply = send(url, HttpPost, toolCall(%1, name = "天気"), {
        "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/call",
        "Mcp-Name": "=?base64?5aSp5rCX?="})
      check reply.code == Http200
      check parseJson(reply.body)["result"]["content"][0]["text"].getStr().startsWith("天気:")

suite "HTTP client transport with this SDK's server":

  test "Given an HTTP server, when the client connects and calls a tool, then the call succeeds in the newest common version":
    let (_, url, _) = startServer()
    let client = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"))
    waitFor client.connect(newStreamableHttpTransport(url))
    check client.negotiatedVersion == some(DefaultProtocolVersion)
    let response = waitFor client.sendRequest("tools/call",
      %*{"name": "get_weather", "arguments": {"location": "Nara"}})
    check response.error.isNone
    check response.result.get["content"][0]["text"].getStr() == "get_weather:Nara"
    waitFor client.close()

  test "Given an HTTP server limited to a legacy version, when a newer client connects, then it falls back to initialize and calls a tool":
    let (_, url, _) = startServer(LegacyDefault)
    let client = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"))
    let transport = newStreamableHttpTransport(url)
    waitFor client.connect(transport)
    check client.negotiatedVersion == some(LegacyDefault)
    check client.state == mlsOperational
    let response = waitFor client.sendRequest("tools/list", newJObject())
    check response.result.get["tools"].len == 1
    check transport.sessionId.isSome
    check transport.protocolVersion.isSome == (LegacyDefault >= mpv20250618)
    waitFor client.close()
    waitFor sleepAsync(1)
    check client.lastTransportError.isNil

type Scripted = proc(req: Request): Future[void] {.async, gcsafe.}

proc startScripted(handler: Scripted): string =
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  let port = server.getPort.int
  proc loop() {.async.} =
    while true:
      await server.acceptRequest(handler)
  asyncCheck loop()
  "http://127.0.0.1:" & $port & "/mcp"

suite "HTTP client transport with hand-written servers":

  test "Given a server that answers with an event stream, when a request is sent, then the notification and the response both arrive in order":
    let url = startScripted(proc(req: Request) {.async, gcsafe.} =
      let id = parseJson(req.body)["id"]
      let stream =
        formatSseComment("keep-alive") &
        formatSseEvent($(%*{"jsonrpc": "2.0", "method": "notifications/progress",
                            "params": {"progressToken": "p", "progress": 1}})) &
        formatSseEvent($(%*{"jsonrpc": "2.0", "id": id, "result": {"ok": true}}))
      await req.respond(Http200, stream, newHttpHeaders({"Content-Type": "text/event-stream"})))
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
    let first = waitFor transport.receiveMessage()
    let second = waitFor transport.receiveMessage()
    check first["method"].getStr() == "notifications/progress"
    check second["id"].getStr() == "r1"
    check second["result"]["ok"].getBool()
    waitFor transport.close()

  test "Given an event stream that ends without the response, when a request is sent, then a local stream-closed error stands in for it":
    let url = startScripted(proc(req: Request) {.async, gcsafe.} =
      await req.respond(Http200,
        formatSseEvent($(%*{"jsonrpc": "2.0", "method": "notifications/progress",
                            "params": {"progressToken": "p", "progress": 1}})),
        newHttpHeaders({"Content-Type": "text/event-stream"})))
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
    discard waitFor transport.receiveMessage()
    let standIn = waitFor transport.receiveMessage()
    check standIn["id"].getStr() == "r1"
    check standIn["error"]["code"].getInt() == ErrStreamClosed
    waitFor transport.close()

  test "Given an HTTP error with a JSON-RPC error body, when a request is sent, then the error arrives as the response":
    let url = startScripted(proc(req: Request) {.async, gcsafe.} =
      await req.respond(Http400, $(%*{"jsonrpc": "2.0", "id": parseJson(req.body)["id"],
        "error": {"code": -32022, "message": "Unsupported protocol version",
                  "data": {"supported": ["2026-07-28"], "requested": "x"}}}),
        newHttpHeaders({"Content-Type": "application/json"})))
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "server/discover", newJObject()))
    let reply = waitFor transport.receiveMessage()
    check reply["id"].getStr() == "r1"
    check reply["error"]["code"].getInt() == -32022
    waitFor transport.close()

  test "Given an HTTP error whose JSON-RPC error names a placeholder id, when a request is sent, then the error arrives under the request's own id":
    let url = startScripted(proc(req: Request) {.async, gcsafe.} =
      await req.respond(Http400, $(%*{"jsonrpc": "2.0", "id": "server-error",
        "error": {"code": -32600, "message": "Bad Request: Missing session ID"}}),
        newHttpHeaders({"Content-Type": "application/json", "Mcp-Session-Id": "throwaway"})))
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "server/discover", newJObject()))
    let reply = waitFor transport.receiveMessage()
    check reply["id"].getStr() == "r1"
    check reply["error"]["code"].getInt() == -32600
    check transport.sessionId.isNone
    waitFor transport.close()

  test "Given an HTTP error whose body is not a JSON-RPC error, when a request is sent, then McpTransportError names the status":
    let url = startScripted(proc(req: Request) {.async, gcsafe.} =
      await req.respond(Http400, """{"error":"bad"}"""))
    let transport = newStreamableHttpTransport(url)
    var message = ""
    try:
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "x", newJObject()))
    except McpTransportError as e:
      message = e.msg
    check "400" in message
    waitFor transport.close()

  test "Given a 202 with no body, when a notification is sent, then nothing is queued and nothing is raised":
    let url = startScripted(proc(req: Request) {.async, gcsafe.} =
      await req.respond(Http202, ""))
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendNotification(newJsonRpcNotification("notifications/initialized", newJObject()))
    let waiting = transport.receiveMessage()
    waitFor sleepAsync(20)
    check not waiting.finished
    waitFor transport.close()
    waitFor sleepAsync(1)
    check waiting.failed

  test "Given a server that issues a session id, when later requests are sent, then they carry it":
    var seen: seq[string] = @[]
    let url = startScripted(proc(req: Request) {.async, gcsafe.} =
      {.cast(gcsafe).}:
        seen.add(if req.headers.hasKey("Mcp-Session-Id"): $req.headers["Mcp-Session-Id"] else: "")
      await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": parseJson(req.body)["id"], "result": {}}),
        newHttpHeaders({"Content-Type": "application/json", "Mcp-Session-Id": "s-123"})))
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendRequest(newJsonRpcRequest("1", "initialize", newJObject()))
    waitFor transport.sendRequest(newJsonRpcRequest("2", "tools/list", newJObject()))
    check seen == @["", "s-123"]
    waitFor transport.close()

  test "Given a 2026-07-28 request, when sent, then it carries the mirrored headers and no session id":
    var seen: seq[tuple[version, mcpMethod, name, session: string]] = @[]
    let url = startScripted(proc(req: Request) {.async, gcsafe.} =
      proc value(name: string): string =
        if req.headers.hasKey(name): $req.headers[name] else: ""
      {.cast(gcsafe).}:
        seen.add (value("MCP-Protocol-Version"), value("Mcp-Method"),
                  value("Mcp-Name"), value("Mcp-Session-Id"))
      await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": parseJson(req.body)["id"], "result": {}}),
        newHttpHeaders({"Content-Type": "application/json", "Mcp-Session-Id": "s-123"})))
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendRequest(newJsonRpcRequest("1", "initialize", newJObject()))
    waitFor transport.sendRequest(newJsonRpcRequest("2", "tools/call",
      %*{"_meta": modernMeta(), "name": "get_weather"}))
    check seen[1] == ("2026-07-28", "tools/call", "get_weather", "")
    waitFor transport.close()

  test "Given a server that rejects the probe without a JSON-RPC body, when a client connects, then it falls back to initialize":
    var methods: seq[string] = @[]
    let url = startScripted(proc(req: Request) {.async, gcsafe.} =
      let message = parseJson(req.body)
      let name = message["method"].getStr()
      {.cast(gcsafe).}:
        methods.add name
      case name
      of "initialize":
        await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": message["id"], "result": {
          "protocolVersion": "2024-11-05", "capabilities": {},
          "serverInfo": {"name": "old", "version": "0"}}}),
          newHttpHeaders({"Content-Type": "application/json"}))
      of "notifications/initialized":
        await req.respond(Http202, "")
      else:
        await req.respond(Http400, ""))
    let client = newMcpClient(McpClientInfo(name: "c", version: "1"))
    waitFor client.connect(newStreamableHttpTransport(url))
    check client.negotiatedVersion == some(mpv20241105)
    if SpeaksModern:
      check methods == @["server/discover", "initialize", "notifications/initialized"]
    else:
      check methods == @["initialize", "notifications/initialized"]
    waitFor client.close()

import std/asyncnet

proc sendWithin(url: string, httpMethod: HttpMethod, body: string,
                headers: openArray[(string, string)] = [], ms = 2000): Option[Reply] =
  ## The reply, or none when the server has not answered within `ms`: a
  ## transport that forgets to answer must fail a check, not hang the test.
  let http = newAsyncHttpClient()
  defer: http.close()
  let pending = http.request(url, httpMethod, body, newHttpHeaders(headers))
  if waitFor withTimeout(pending, ms):
    let response = pending.read()
    some((response.code, response.headers, waitFor response.body))
  else:
    none(Reply)

suite "HTTP endpoint (mutation review, g2f-hs-b)":

  test "Given a JSON body that is a single value and no object, when posted, then the answer is 400 invalid request":
    let (_, url, _) = startServer()
    for body in ["42", "\"text\"", "null", "true"]:
      let reply = sendWithin(url, HttpPost, body)
      require reply.isSome
      check reply.get.code == Http400
      check parseJson(reply.get.body)["error"]["code"].getInt() == -32600

  test "Given a notification whose method is initialize and no session, when posted, then the answer is 400 and no session is made":
    # Only an initialize request opens a session; a message without an id is not one.
    let (transport, url, _) = startServer()
    let reply = sendWithin(url, HttpPost, $(%*{"jsonrpc": "2.0", "method": "initialize",
      "params": {"protocolVersion": $LegacyDefault, "capabilities": {},
                 "clientInfo": {"name": "peer", "version": "0"}}}))
    require reply.isSome
    check reply.get.code == Http400
    check transport.sessionCount == 0

  test "Given a POST answered with a JSON body, when the answer is complete, then the server closes the connection":
    let (transport, _, _) = startServer()
    # Unbuffered: a buffered recv(4096) would wait for 4096 bytes or the close.
    let socket = newAsyncSocket(buffered = false)
    waitFor socket.connect("127.0.0.1", Port(transport.port))
    let body = legacyInitialize()
    waitFor socket.send("POST /mcp HTTP/1.1\c\LHost: 127.0.0.1:" & $transport.port &
      "\c\LContent-Type: application/json\c\LAccept: application/json, text/event-stream" &
      "\c\LContent-Length: " & $body.len & "\c\L\c\L" & body)
    var received = ""
    var closed = false
    while true:
      let read = socket.recv(4096)
      if not waitFor withTimeout(read, 2000):
        break
      let chunk = read.read()
      if chunk.len == 0:
        closed = true
        break
      received.add chunk
    socket.close()
    check received.startsWith("HTTP/1.1 200")
    check closed

suite "starting the server transport (mutation review, g2f-hs-c)":

  test "Given a transport that is not listening, when start is called, then it binds at once and serves until it is closed":
    let transport = newHttpServerTransport(port = 0)
    let running = transport.start()
    check transport.port != 0
    check not running.finished
    let http = newAsyncHttpClient()
    check (waitFor http.request("http://127.0.0.1:" & $transport.port & "/nowhere", HttpGet)).code == Http404
    http.close()
    check not running.finished
    waitFor transport.close()
    check waitFor withTimeout(running, 2000)

suite "HTTP client transport headers by version (mutation review, g2g-hc-b)":

  proc protocolHeaderSent(version: McpProtocolVersion): string =
    ## The MCP-Protocol-Version header a notification carries once `version`
    ## was negotiated ("" when it carries none).
    var seen = ""
    let url = startScripted(proc(req: Request) {.async, gcsafe.} =
      {.cast(gcsafe).}:
        seen = if req.headers.hasKey("MCP-Protocol-Version"): $req.headers["MCP-Protocol-Version"] else: ""
      await req.respond(Http202, ""))
    let transport = newStreamableHttpTransport(url)
    transport.listenForServerMessages = false
    transport.protocolVersionNegotiated(version)
    waitFor transport.sendNotification(newJsonRpcNotification("notifications/cancelled", newJObject()))
    result = seen
    waitFor transport.close()

  test "Given versions without the header, when a notification is sent, then it names no protocol version":
    # The header exists from 2025-06-18 on; a 2026-07-28 request carries its own, mirrored from its body.
    check protocolHeaderSent(mpv20241105) == ""
    check protocolHeaderSent(mpv20250326) == ""
    check protocolHeaderSent(mpv20260728) == ""

  test "Given versions with the header, when a notification is sent, then it names the negotiated version":
    check protocolHeaderSent(mpv20250618) == "2025-06-18"
    check protocolHeaderSent(mpv20251125) == "2025-11-25"
