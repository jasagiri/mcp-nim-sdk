## Parameter headers (2026-07-28) over real sockets on 127.0.0.1: a server
## whose tools carry x-mcp-header, checked with a plain HTTP client, and the
## client transport checked against this SDK's server and a scripted one.
##
## The same file passes on every `mcp-<version>` branch: the scenarios exist
## only where the default version is 2026-07-28 or later.

import std/[unittest, asyncdispatch, asynchttpserver, httpclient, json,
            options, strutils, nativesockets, os]
import transport/transport
import transport/http
import transport/http_server
import server/server
import client/client
import protocol/types
import transport/event_stream

const SpeaksModern = isModern(DefaultProtocolVersion)

proc sqlTool(): JsonNode =
  %*{"name": "execute_sql", "description": "Execute SQL",
  "inputSchema": {"type": "object", "properties": {
    "region": {"type": "string", "x-mcp-header": "Region"},
    "query": {"type": "string"}},
  "required": ["region", "query"]}}

proc badTool(): JsonNode =
  %*{"name": "bad_tool", "inputSchema": {"type": "object", "properties": {
    "ratio": {"type": "number", "x-mcp-header": "Ratio"}}}}

proc plainTool(): JsonNode =
  %*{"name": "plain_tool", "inputSchema": {"type": "object"}}

proc sqlServer(version: McpProtocolVersion, tools: seq[JsonNode]): McpServer =
  result = newMcpServer(McpServerInfo(name: "ExampleServer", version: "1.0.0"),
    protocolVersion = version,
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      return tools
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      return %*{"content": [{"type": "text", "text": name & ":" & $arguments}],
                "isError": false}
  result.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))

proc startServer(tools: seq[JsonNode]): tuple[url: string, server: McpServer] =
  let transport = newHttpServerTransport(port = 0)
  transport.listen()
  asyncCheck transport.serve()
  let server = sqlServer(DefaultProtocolVersion, tools)
  waitFor server.attachTransport(transport)
  ("http://127.0.0.1:" & $transport.port & "/mcp", server)

type ChangingTools = ref object
  ## The tool definitions of a server that changes them while it runs.
  tools: seq[JsonNode]
  listed: int
  called: int

proc startChangingServer(state: ChangingTools): string =
  let transport = newHttpServerTransport(port = 0)
  transport.listen()
  asyncCheck transport.serve()
  let server = newMcpServer(McpServerInfo(name: "ExampleServer", version: "1.0.0"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      inc state.listed
      return state.tools
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      inc state.called
      return %*{"content": [{"type": "text", "text": name}], "isError": false}
  server.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))
  waitFor server.attachTransport(transport)
  "http://127.0.0.1:" & $transport.port & "/mcp"

proc sqlToolWithoutHeader(): JsonNode =
  %*{"name": "execute_sql", "inputSchema": {"type": "object", "properties": {
    "region": {"type": "string"}, "query": {"type": "string"}}}}

type Reply = tuple[code: HttpCode, body: string]

proc post(url: string, body: JsonNode, headers: openArray[(string, string)]): Reply =
  let http = newAsyncHttpClient()
  defer: http.close()
  let response = waitFor http.request(url, HttpPost, $body, newHttpHeaders(headers))
  (response.code, waitFor response.body)

proc modernMeta(): JsonNode =
  %*{"io.modelcontextprotocol/protocolVersion": "2026-07-28",
     "io.modelcontextprotocol/clientInfo": {"name": "ExampleClient", "version": "1.0.0"},
     "io.modelcontextprotocol/clientCapabilities": {}}

proc sqlCall(arguments: JsonNode, tool = "execute_sql"): JsonNode =
  %*{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
     "params": {"_meta": modernMeta(), "name": tool, "arguments": arguments}}

proc callHeaders(extra: openArray[(string, string)], tool = "execute_sql"): seq[(string, string)] =
  result = @[("Content-Type", "application/json"),
             ("MCP-Protocol-Version", "2026-07-28"),
             ("Mcp-Method", "tools/call"), ("Mcp-Name", tool)]
  result.add extra

proc errorCode(reply: Reply): int =
  parseJson(reply.body){"error", "code"}.getInt()

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

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-param-headers-http-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

type MismatchState = ref object
  ## A scripted server that refuses every tools/call as a header mismatch.
  calls: int
  lists: int
  listReply: proc(id: JsonNode, cursor: string): JsonNode {.gcsafe.}

proc startMismatchServer(state: MismatchState): string =
  startScripted(proc(req: Request) {.async, gcsafe.} =
    let message = parseJson(req.body)
    var code = Http200
    var body: JsonNode
    {.cast(gcsafe).}:
      case message["method"].getStr()
      of "server/discover":
        body = %*{"jsonrpc": "2.0", "id": message["id"], "result": {
          "resultType": "complete", "supportedVersions": ["2026-07-28"],
          "capabilities": {"tools": {}},
          "serverInfo": {"name": "scripted", "version": "1"}}}
      of "tools/list":
        inc state.lists
        body = state.listReply(message["id"], message["params"]{"cursor"}.getStr())
      else:
        inc state.calls
        code = Http400
        body = %*{"jsonrpc": "2.0", "id": message["id"], "error": {
          "code": -32020, "message": "Header mismatch: Mcp-Param-Region is required"}}
    await req.respond(code, $body, newHttpHeaders({"Content-Type": "application/json"})))

proc listPage(id: JsonNode, tools: seq[JsonNode], next: JsonNode = nil): JsonNode =
  var res = %*{"resultType": "complete", "tools": tools, "ttlMs": 0, "cacheScope": "private"}
  if not next.isNil:
    res["nextCursor"] = next
  %*{"jsonrpc": "2.0", "id": id, "result": res}

proc callExecuteSql(client: McpClient): JsonRpcResponse =
  waitFor client.sendRequest("tools/call",
    %*{"name": "execute_sql", "arguments": {"region": "us-west1", "query": "q"}})

proc connectedTo(url: string): McpClient =
  result = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"))
  waitFor result.connect(newStreamableHttpTransport(url))

if SpeaksModern:
  suite "2026-07-28 parameter headers: server validation":

    test "Given a tool with x-mcp-header, when a call carries the matching header, then the answer is 200":
      let (url, _) = startServer(@[sqlTool()])
      let reply = post(url, sqlCall(%*{"region": "us-west1", "query": "SELECT 1"}),
                       callHeaders({"Mcp-Param-Region": "us-west1"}))
      check reply.code == Http200
      check parseJson(reply.body)["result"]["resultType"].getStr() == "complete"

    test "Given a tool with x-mcp-header, when the header differs from the body, then the answer is 400 header mismatch":
      let (url, _) = startServer(@[sqlTool()])
      let reply = post(url, sqlCall(%*{"region": "us-west1", "query": "SELECT 1"}),
                       callHeaders({"Mcp-Param-Region": "eu-north1"}))
      check reply.code == Http400
      check reply.errorCode == -32020

    test "Given a tool with x-mcp-header, when the call omits the header though the body has the value, then the answer is 400 header mismatch":
      let (url, _) = startServer(@[sqlTool()])
      let reply = post(url, sqlCall(%*{"region": "us-west1", "query": "SELECT 1"}), callHeaders([]))
      check reply.code == Http400
      check reply.errorCode == -32020

    test "Given a tool with x-mcp-header, when the argument is absent and so is the header, then the answer is 200":
      let (url, _) = startServer(@[sqlTool()])
      let reply = post(url, sqlCall(%*{"query": "SELECT 1"}), callHeaders([]))
      check reply.code == Http200

    test "Given a tool with x-mcp-header, when the argument is null and the header is absent, then the answer is 200":
      let (url, _) = startServer(@[sqlTool()])
      let reply = post(url, sqlCall(%*{"region": nil, "query": "SELECT 1"}), callHeaders([]))
      check reply.code == Http200

    test "Given a tool with x-mcp-header, when the header is sent without the argument, then the answer is 400 header mismatch":
      let (url, _) = startServer(@[sqlTool()])
      let reply = post(url, sqlCall(%*{"query": "SELECT 1"}),
                       callHeaders({"Mcp-Param-Region": "us-west1"}))
      check reply.code == Http400
      check reply.errorCode == -32020

    test "Given a Base64 header, when it decodes to the body value, then the answer is 200":
      let (url, _) = startServer(@[sqlTool()])
      let reply = post(url, sqlCall(%*{"region": "Hello, 世界", "query": "q"}),
                       callHeaders({"Mcp-Param-Region": "=?base64?SGVsbG8sIOS4lueVjA==?="}))
      check reply.code == Http200

    test "Given a Base64 header without its padding, when posted, then the answer is 400 header mismatch":
      let (url, _) = startServer(@[sqlTool()])
      let reply = post(url, sqlCall(%*{"region": "Hello", "query": "q"}),
                       callHeaders({"Mcp-Param-Region": "=?base64?SGVsbG8?=" }))
      check reply.code == Http400
      check reply.errorCode == -32020

    test "Given a header value with a control character, when posted, then the answer is 400 header mismatch":
      let (url, _) = startServer(@[sqlTool()])
      let reply = post(url, sqlCall(%*{"region": "a", "query": "q"}),
                       callHeaders({"Mcp-Param-Region": "a\x01"}))
      check reply.code == Http400
      check reply.errorCode == -32020

    test "Given a tool without x-mcp-header, when a Mcp-Param header is sent, then it is ignored":
      let (url, _) = startServer(@[plainTool()])
      let reply = post(url, sqlCall(newJObject(), "plain_tool"),
                       callHeaders({"Mcp-Param-Anything": "x"}, "plain_tool"))
      check reply.code == Http200

    test "Given a tool the server does not list, when it is called, then validation does not stand in the way of the not-found answer":
      let (url, _) = startServer(@[sqlTool()])
      let reply = post(url, sqlCall(newJObject(), "no_such_tool"),
                       callHeaders({"Mcp-Param-Region": "x"}, "no_such_tool"))
      check reply.code != Http400 or reply.errorCode != -32020

  suite "2026-07-28 parameter headers: tools/list":

    test "Given a tool whose x-mcp-header is invalid, when tools are listed, then the server does not publish it":
      let (url, _) = startServer(@[sqlTool(), badTool(), plainTool()])
      let reply = post(url, %*{"jsonrpc": "2.0", "id": 1, "method": "tools/list",
                               "params": {"_meta": modernMeta()}},
                       {"Content-Type": "application/json",
                        "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"})
      check reply.code == Http200
      var names: seq[string] = @[]
      for tool in parseJson(reply.body)["result"]["tools"]:
        names.add tool["name"].getStr()
      check names == @["execute_sql", "plain_tool"]

  suite "2026-07-28 parameter headers: client":

    test "Given a client that listed tools, when it calls one with x-mcp-header, then the request carries Mcp-Param-Region":
      let (url, _) = startServer(@[sqlTool()])
      let client = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"))
      waitFor client.connect(newStreamableHttpTransport(url))
      discard waitFor client.sendRequest("tools/list", newJObject())
      let response = waitFor client.sendRequest("tools/call",
        %*{"name": "execute_sql", "arguments": {"region": "us-west1", "query": "SELECT 1"}})
      check response.error.isNone
      check response.result.get["resultType"].getStr() == "complete"

    test "Given a tool that gained x-mcp-header after it was listed, when the call is refused as a header mismatch, then the client lists the tools again and retries with the header":
      let state = ChangingTools(tools: @[sqlToolWithoutHeader()])
      let client = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"))
      waitFor client.connect(newStreamableHttpTransport(startChangingServer(state)))
      discard waitFor client.sendRequest("tools/list", newJObject())
      state.tools = @[sqlTool()]
      let listedBefore = state.listed
      let response = waitFor client.sendRequest("tools/call",
        %*{"name": "execute_sql", "arguments": {"region": "us-west1", "query": "SELECT 1"}})
      check response.error.isNone
      check response.result.get["content"][0]["text"].getStr() == "execute_sql"
      check state.called == 1
      check state.listed > listedBefore

    test "Given a call that is refused as a header mismatch again after the tools were listed again, when it is answered, then the error is returned and the client does not retry a second time":
      # The server wants a header the client has no declaration for: the
      # list it publishes never mentions it.
      var calls = 0
      var lists = 0
      let url = startScripted(proc(req: Request) {.async, gcsafe.} =
        let message = parseJson(req.body)
        var code = Http200
        var body: JsonNode
        case message["method"].getStr()
        of "server/discover":
          body = %*{"jsonrpc": "2.0", "id": message["id"], "result": {
            "resultType": "complete", "supportedVersions": ["2026-07-28"],
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "scripted", "version": "1"}}}
        of "tools/list":
          {.cast(gcsafe).}: inc lists
          body = %*{"jsonrpc": "2.0", "id": message["id"], "result": {
            "resultType": "complete", "tools": [sqlToolWithoutHeader()],
            "ttlMs": 0, "cacheScope": "private"}}
        else:
          {.cast(gcsafe).}: inc calls
          code = Http400
          body = %*{"jsonrpc": "2.0", "id": message["id"], "error": {
            "code": -32020, "message": "Header mismatch: Mcp-Param-Region is required"}}
        await req.respond(code, $body, newHttpHeaders({"Content-Type": "application/json"})))
      let client = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"))
      waitFor client.connect(newStreamableHttpTransport(url))
      let response = waitFor client.sendRequest("tools/call",
        %*{"name": "execute_sql", "arguments": {"region": "us-west1"}})
      check response.error.get.code == -32020
      check calls == 2
      check lists == 1

    test "Given a tool call that the server answers, when it is sent over HTTP, then the client does not read the tool list again":
      let state = MismatchState(listReply: proc(id: JsonNode, cursor: string): JsonNode {.gcsafe.} =
        listPage(id, @[sqlTool()]))
      let url = startScripted(proc(req: Request) {.async, gcsafe.} =
        let message = parseJson(req.body)
        var payload: JsonNode
        {.cast(gcsafe).}:
          case message["method"].getStr()
          of "server/discover":
            payload = %*{"resultType": "complete", "supportedVersions": ["2026-07-28"],
              "capabilities": {"tools": {}}, "serverInfo": {"name": "scripted", "version": "1"}}
          of "tools/list":
            inc state.lists
            payload = %*{"resultType": "complete", "tools": [sqlTool()], "ttlMs": 0, "cacheScope": "private"}
          else:
            payload = %*{"resultType": "complete", "content": []}
        await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": message["id"], "result": payload}),
          newHttpHeaders({"Content-Type": "application/json"})))
      let client = connectedTo(url)
      let response = client.callExecuteSql()
      check response.error.isNone
      check state.lists == 0

    test "Given a header mismatch and a tool list that cannot be read, when the call is refused, then the refusal is returned without a retry":
      let state = MismatchState(listReply: proc(id: JsonNode, cursor: string): JsonNode {.gcsafe.} =
        %*{"jsonrpc": "2.0", "id": id, "error": {"code": -32603,
                                                  "message": "list failed\n[mcp-client] forged line \e[2J"}})
      let client = connectedTo(startMismatchServer(state))
      var response: JsonRpcResponse
      let logged = loggedWhile(proc() = response = client.callExecuteSql())
      check response.error.get.code == -32020
      check state.lists == 1
      check state.calls == 1
      check "tools/list after a header mismatch failed: list failed" in logged
      check "\e" notin logged
      check logged.count('\n') == 1

    test "Given a header mismatch and a tool list without the tool, when the call is refused, then the refusal is returned without a retry":
      let state = MismatchState(listReply: proc(id: JsonNode, cursor: string): JsonNode {.gcsafe.} =
        listPage(id, @[plainTool()]))
      let client = connectedTo(startMismatchServer(state))
      let response = client.callExecuteSql()
      check response.error.get.code == -32020
      check state.lists == 1
      check state.calls == 1

    test "Given a header mismatch and a tool listed on the second page, when the call is refused, then the client reads on and retries":
      let state = MismatchState(listReply: proc(id: JsonNode, cursor: string): JsonNode {.gcsafe.} =
        if cursor == "": listPage(id, @[plainTool()], %"second")
        else: listPage(id, @[sqlTool()]))
      let client = connectedTo(startMismatchServer(state))
      let response = client.callExecuteSql()
      check response.error.get.code == -32020
      check state.lists == 2
      check state.calls == 2

    test "Given a header mismatch and a tool list whose nextCursor is not a string, when the call is refused, then the client stops reading and returns the refusal":
      let state = MismatchState(listReply: proc(id: JsonNode, cursor: string): JsonNode {.gcsafe.} =
        listPage(id, @[plainTool()], %7))
      let client = connectedTo(startMismatchServer(state))
      let response = client.callExecuteSql()
      check response.error.get.code == -32020
      check state.lists == 1
      check state.calls == 1

    test "Given a header mismatch and a server whose tool list never ends, when the call is refused, then the client gives up reading and returns the refusal":
      let state = MismatchState(listReply: proc(id: JsonNode, cursor: string): JsonNode {.gcsafe.} =
        listPage(id, @[plainTool()], %"again"))
      let client = connectedTo(startMismatchServer(state))
      var response: JsonRpcResponse
      let logged = loggedWhile(proc() = response = client.callExecuteSql())
      check response.error.get.code == -32020
      check state.lists > 1
      check state.calls == 1
      check "'execute_sql' was not found" in logged
      check logged.count('\n') == 1

    test "Given a scripted server, when a client calls a tool listed with x-mcp-header, then the headers are exactly the specification's":
      var seen: seq[tuple[name, region, other: string]] = @[]
      let url = startScripted(proc(req: Request) {.async, gcsafe.} =
        let message = parseJson(req.body)
        let name = message["method"].getStr()
        proc value(header: string): string =
          if req.headers.hasKey(header): $req.headers[header] else: "<none>"
        var payload: JsonNode
        if name == "tools/list":
          payload = %*{"tools": [sqlTool(), {"name": "n", "inputSchema": {"type": "object", "properties": {
            "n": {"type": "integer", "x-mcp-header": "N"},
            "flag": {"type": "boolean", "x-mcp-header": "Flag"},
            "text": {"type": "string", "x-mcp-header": "Text"}}}}]}
        else:
          {.cast(gcsafe).}:
            seen.add (message["params"]["name"].getStr(), value("Mcp-Param-Region"), value("Mcp-Param-N") &
                      "," & value("Mcp-Param-Flag") & "," & value("Mcp-Param-Text"))
          payload = %*{"content": []}
        await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": message["id"], "result": payload}),
          newHttpHeaders({"Content-Type": "application/json"})))
      let transport = newStreamableHttpTransport(url)
      let meta = modernMeta()
      waitFor transport.sendRequest(newJsonRpcRequest("1", "tools/list", %*{"_meta": meta}))
      discard waitFor transport.receiveMessage()
      waitFor transport.sendRequest(newJsonRpcRequest("2", "tools/call", %*{"_meta": meta,
        "name": "execute_sql", "arguments": {"region": "us-west1", "query": "q"}}))
      waitFor transport.sendRequest(newJsonRpcRequest("3", "tools/call", %*{"_meta": meta,
        "name": "execute_sql", "arguments": {"query": "q"}}))
      waitFor transport.sendRequest(newJsonRpcRequest("4", "tools/call", %*{"_meta": meta,
        "name": "n", "arguments": {"n": 42, "flag": false, "text": " padded "}}))
      check seen == @[("execute_sql", "us-west1", "<none>,<none>,<none>"),
                      ("execute_sql", "<none>", "<none>,<none>,<none>"),
                      ("n", "<none>", "42,false,=?base64?IHBhZGRlZCA=?=")]
      waitFor transport.close()

    test "Given a server that lists an invalid tool, when the client lists tools, then the invalid tool is excluded and the others stay":
      let url = startScripted(proc(req: Request) {.async, gcsafe.} =
        let message = parseJson(req.body)
        await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": message["id"], "result": {
          "tools": [sqlTool(), badTool(), plainTool(),
                    {"name": "dup", "inputSchema": {"type": "object", "properties": {
                      "a": {"type": "string", "x-mcp-header": "Same"},
                      "b": {"type": "string", "x-mcp-header": "SAME"}}}}]}}),
          newHttpHeaders({"Content-Type": "application/json"})))
      let transport = newStreamableHttpTransport(url)
      waitFor transport.sendRequest(newJsonRpcRequest("1", "tools/list", %*{"_meta": modernMeta()}))
      let listed = waitFor transport.receiveMessage()
      var names: seq[string] = @[]
      for tool in listed["result"]["tools"]:
        names.add tool["name"].getStr()
      check names == @["execute_sql", "plain_tool"]
      waitFor transport.close()

    test "Given a call whose integer argument is beyond the safe range, when it is sent, then the transport refuses it before the wire":
      var posts = 0
      let url = startScripted(proc(req: Request) {.async, gcsafe.} =
        let message = parseJson(req.body)
        {.cast(gcsafe).}:
          inc posts
        let payload =
          if message["method"].getStr() == "tools/list":
            %*{"tools": [{"name": "n", "inputSchema": {"type": "object", "properties": {
              "n": {"type": "integer", "x-mcp-header": "N"}}}}]}
          else: %*{"content": []}
        await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": message["id"], "result": payload}),
          newHttpHeaders({"Content-Type": "application/json"})))
      let transport = newStreamableHttpTransport(url)
      let meta = modernMeta()
      waitFor transport.sendRequest(newJsonRpcRequest("1", "tools/list", %*{"_meta": meta}))
      discard waitFor transport.receiveMessage()
      expect McpTransportError:
        waitFor transport.sendRequest(newJsonRpcRequest("2", "tools/call", %*{"_meta": meta,
          "name": "n", "arguments": {"n": 9_007_199_254_740_992'i64}}))
      check posts == 1
      waitFor transport.close()

if SpeaksModern:
  suite "2026-07-28 parameter headers: client (mutation review, g2g-hc-b)":

    proc paramHeadersOfCalls(calls: seq[JsonNode]): seq[string] =
      ## The Mcp-Param-Region header ("<none>" when absent) of each tools/call
      ## sent, after `execute_sql` was listed the way a 2026-07-28 client lists.
      var seen: seq[string] = @[]
      let url = startScripted(proc(req: Request) {.async, gcsafe.} =
        let message = parseJson(req.body)
        var payload = %*{"content": []}
        if message["method"].getStr() == "tools/list":
          payload = %*{"tools": [sqlTool()]}
        else:
          {.cast(gcsafe).}:
            seen.add(if req.headers.hasKey("Mcp-Param-Region"): $req.headers["Mcp-Param-Region"] else: "<none>")
        await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": message["id"], "result": payload}),
          newHttpHeaders({"Content-Type": "application/json"})))
      let transport = newStreamableHttpTransport(url)
      waitFor transport.sendRequest(newJsonRpcRequest("0", "tools/list", %*{"_meta": modernMeta()}))
      discard waitFor transport.receiveMessage()
      for index, call in calls:
        waitFor transport.sendRequest(newJsonRpcRequest($(index + 1), "tools/call", call))
      waitFor transport.close()
      seen

    let arguments = %*{"region": "us-west1", "query": "q"}

    test "Given a call that does not name 2026-07-28, when it is sent after the tool was listed, then it carries no Mcp-Param header":
      # Parameter headers belong to 2026-07-28; the call of another version, or of none, has none.
      func meta(version: JsonNode): JsonNode = %*{"io.modelcontextprotocol/protocolVersion": version}
      check paramHeadersOfCalls(@[
        %*{"name": "execute_sql", "arguments": arguments},
        %*{"_meta": {}, "name": "execute_sql", "arguments": arguments},
        %*{"_meta": meta(%7), "name": "execute_sql", "arguments": arguments},
        %*{"_meta": meta(%"2025-11-25"), "name": "execute_sql", "arguments": arguments},
        %*{"_meta": meta(%"1900-01-01"), "name": "execute_sql", "arguments": arguments},
        %*{"_meta": modernMeta(), "name": "execute_sql", "arguments": arguments}]) ==
        @["<none>", "<none>", "<none>", "<none>", "<none>", "us-west1"]

    test "Given a 2026-07-28 tools/call without a tool name, when it is sent, then it is posted without Mcp-Param headers":
      check paramHeadersOfCalls(@[
        %*{"_meta": modernMeta(), "arguments": arguments},
        %*{"_meta": modernMeta(), "name": 7, "arguments": arguments}]) ==
        @["<none>", "<none>"]

    test "Given a tools/list that failed, when its id is used again by another request, then that answer is not read as a tool list":
      # Only the answer to a tools/list that was sent is checked for x-mcp-header; the invalid tool stays in any other answer.
      var posts = 0
      let url = startScripted(proc(req: Request) {.async, gcsafe.} =
        let message = parseJson(req.body)
        {.cast(gcsafe).}:
          inc posts
        if posts == 1:
          await req.respond(Http500, "")
        else:
          await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": message["id"], "result": {
            "tools": [sqlTool(), badTool()]}}), newHttpHeaders({"Content-Type": "application/json"})))
      let transport = newStreamableHttpTransport(url)
      expect McpTransportError:
        waitFor transport.sendRequest(newJsonRpcRequest("1", "tools/list", %*{"_meta": modernMeta()}))
      waitFor transport.sendRequest(newJsonRpcRequest("1", "resources/list", %*{"_meta": modernMeta()}))
      let answer = waitFor transport.receiveMessage()
      check answer["result"]["tools"].len == 2
      waitFor transport.close()

  suite "2026-07-28 parameter headers: what the client learns from tools/list (mutation review, g2g-hc-a)":

    type Listing = ref object
      ## A scripted server: the tools/list answers are whatever the test
      ## builds, and each tools/call records the Mcp-Param-Region it carried.
      lists: int
      regions: seq[string]
      answer: proc(id: JsonNode, nth: int): tuple[contentType, body: string]

    proc startListing(state: Listing): string =
      startScripted(proc(req: Request) {.async, gcsafe.} =
        let message = parseJson(req.body)
        var contentType = "application/json"
        var body: string
        {.cast(gcsafe).}:
          if message["method"].getStr() == "tools/list":
            (contentType, body) = state.answer(message["id"], state.lists)
            inc state.lists
          else:
            state.regions.add(if req.headers.hasKey("Mcp-Param-Region"):
                                $req.headers["Mcp-Param-Region"] else: "<none>")
            body = $(%*{"jsonrpc": "2.0", "id": message["id"], "result": {"content": []}})
        await req.respond(Http200, body, newHttpHeaders({"Content-Type": contentType})))

    proc listed(id: JsonNode, tools: varargs[JsonNode]): JsonNode =
      %*{"jsonrpc": "2.0", "id": id, "result": {"tools": @tools}}

    proc asJson(message: JsonNode): tuple[contentType, body: string] =
      ("application/json", $message)

    proc asEvents(messages: varargs[JsonNode]): tuple[contentType, body: string] =
      result.contentType = "text/event-stream"
      for message in messages:
        result.body.add formatSseEvent($message)

    proc regionAfterListing(state: Listing, lists: int): string =
      ## Lists the tools `lists` times, then calls execute_sql with a region.
      let transport = newStreamableHttpTransport(startListing(state))
      let meta = modernMeta()
      for n in 1 .. lists:
        waitFor transport.sendRequest(newJsonRpcRequest("l" & $n, "tools/list", %*{"_meta": meta}))
        discard waitFor transport.receiveMessage()
      waitFor transport.sendRequest(newJsonRpcRequest("call", "tools/call", %*{"_meta": meta,
        "name": "execute_sql", "arguments": {"region": "us-west1", "query": "q"}}))
      result = state.regions[^1]
      waitFor transport.close()

    proc answerOf(answer: JsonNode): JsonNode =
      ## What the client hands over when the server answers tools/list with
      ## `answer` (a result or an error).
      let state = Listing(answer: proc(id: JsonNode, nth: int): tuple[contentType, body: string] =
        var reply = %*{"jsonrpc": "2.0", "id": id}
        for key, value in answer:
          reply[key] = value
        reply.asJson)
      let transport = newStreamableHttpTransport(startListing(state))
      waitFor transport.sendRequest(newJsonRpcRequest("1", "tools/list", %*{"_meta": modernMeta()}))
      result = waitFor transport.receiveMessage()
      waitFor transport.close()

    test "Given a tools/list answer without a tools member, when the client reads it, then the answer is handed over as it is":
      let answer = answerOf(%*{"result": {"resultType": "complete"}})
      check answer["result"]["resultType"].getStr() == "complete"
      check not answer["result"].hasKey("tools")

    test "Given a tools/list answer whose tools member is no array, when the client reads it, then the answer is handed over as it is":
      check answerOf(%*{"result": {"tools": "none"}})["result"]["tools"].getStr() == "none"

    test "Given a tool listed with x-mcp-header, when the next listing declares it invalid, then a call no longer carries the header":
      let invalid = %*{"name": "execute_sql", "inputSchema": {"type": "object", "properties": {
        "region": {"type": "number", "x-mcp-header": "Region"}}}}
      let state = Listing(answer: proc(id: JsonNode, nth: int): tuple[contentType, body: string] =
        asJson(listed(id, if nth == 0: sqlTool() else: invalid)))
      check regionAfterListing(state, 2) == "<none>"

    test "Given a tool listed with x-mcp-header, when the next listing no longer declares it, then a call no longer carries the header":
      let state = Listing(answer: proc(id: JsonNode, nth: int): tuple[contentType, body: string] =
        asJson(listed(id, if nth == 0: sqlTool() else: sqlToolWithoutHeader())))
      check regionAfterListing(state, 2) == "<none>"

    test "Given a tools/list answered twice with the same id, when the second answer drops the header, then the first answer is what counts":
      let state = Listing(answer: proc(id: JsonNode, nth: int): tuple[contentType, body: string] =
        asEvents(listed(id, sqlTool()), listed(id, sqlToolWithoutHeader())))
      check regionAfterListing(state, 1) == "us-west1"

    test "Given a request of the server whose id equals that of a pending tools/list, when the answer follows, then the answer is what counts":
      let state = Listing(answer: proc(id: JsonNode, nth: int): tuple[contentType, body: string] =
        asEvents(%*{"jsonrpc": "2.0", "id": id, "method": "ping"}, listed(id, sqlTool())))
      check regionAfterListing(state, 1) == "us-west1"

    test "Given a tool listed with an invalid x-mcp-header, when the client reads the listing, then it says which tool it left out":
      let state = Listing(answer: proc(id: JsonNode, nth: int): tuple[contentType, body: string] =
        asJson(listed(id, badTool(), plainTool())))
      let logged = loggedWhile(proc() =
        let transport = newStreamableHttpTransport(startListing(state))
        waitFor transport.sendRequest(newJsonRpcRequest("1", "tools/list", %*{"_meta": modernMeta()}))
        discard waitFor transport.receiveMessage()
        waitFor transport.close())
      check "ignoring tool 'bad_tool'" in logged
      check logged.count('\n') == 1
