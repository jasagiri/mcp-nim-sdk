## Parameter headers (2026-07-28) over real sockets on 127.0.0.1: a server
## whose tools carry x-mcp-header, checked with a plain HTTP client, and the
## client transport checked against this SDK's server and a scripted one.
##
## The same file passes on every `mcp-<version>` branch: the scenarios exist
## only where the default version is 2026-07-28 or later.

import std/[unittest, asyncdispatch, asynchttpserver, httpclient, json,
            options, strutils, nativesockets]
import transport/transport
import transport/http
import transport/http_server
import server/server
import client/client
import protocol/types

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
