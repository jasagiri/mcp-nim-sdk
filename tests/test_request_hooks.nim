## The places an extension plugs into the server's handling of a request:
## the request's own `_meta`, a filter on the answer, and a choice of list
## handler per request. None of them changes what a server without an
## extension does.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness
import server/server

const MetaKey = "com.example/lens"

proc pageOf(names: varargs[string]): ListHandler =
  var items: seq[JsonNode]
  for name in names:
    items.add %*{"name": name, "inputSchema": {"type": "object", "properties": {
      "n": {"type": "integer"}}, "required": ["n"]}}
  let page = McpPage(items: items)
  return proc(cursor: Option[string]): Future[McpPage] {.async.} = return page

proc toolServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolsList(pageOf("plain"))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    let lens =
      if ctx.meta.isNil or not ctx.meta.hasKey(MetaKey): newJNull()
      else: ctx.meta[MetaKey]
    return %*{"content": [{"type": "text", "text": name}], "lens": lens})

suite "the _meta of a request":

  test "Given a request with _meta, when a handler runs, then ctx.meta carries it unchanged":
    for v in SupportedProtocolVersions:
      let server = toolServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}},
        meta = %*{MetaKey: "wide"})
      check answer["result"]["lens"].getStr() == "wide"

  test "Given a request without _meta, when a handler runs, then ctx.meta is nil in the versions that send none":
    for v in legacyVersions():
      let server = toolServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}})
      check answer["result"]["lens"].kind == JNull

suite "response filters":

  test "Given a filter that rewrites a result, when a request is answered, then the client sees the rewrite":
    for v in SupportedProtocolVersions:
      let server = toolServer()
      server.addResponseFilter(proc(ctx: McpRequestContext, request: JsonRpcRequest,
                                    response: JsonRpcResponse): Future[JsonRpcResponse] {.async.} =
        if request.`method` == "tools/call":
          response.result.get["filtered"] = %true
        return response)
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}})["result"]["filtered"].getBool()
      check not peer.ask("tools/list")["result"].hasKey("filtered")

  test "Given a filter that raises a request error, when a request is answered, then the client gets that JSON-RPC error":
    let server = toolServer()
    server.addResponseFilter(proc(ctx: McpRequestContext, request: JsonRpcRequest,
                                  response: JsonRpcResponse): Future[JsonRpcResponse] {.async.} =
      raise newRequestError(-32602, "refused by the filter"))
    let peer = server.connect(server.attach(), DefaultProtocolVersion)
    let answer = peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}})
    check answer.errorCode == -32602
    check answer["error"]["message"].getStr() == "refused by the filter"

  test "Given a filter, when the request is answered with an error, then the filter is not asked":
    let server = toolServer()
    var asked = 0
    server.addResponseFilter(proc(ctx: McpRequestContext, request: JsonRpcRequest,
                                  response: JsonRpcResponse): Future[JsonRpcResponse] {.async.} =
      inc asked
      return response)
    let peer = server.connect(server.attach(), DefaultProtocolVersion)
    check peer.ask("tools/call", %*{"arguments": {}}).errorCode == -32602
    check asked == 0

suite "list scope":

  test "Given a scope that picks another list, when tools/list is asked, then that list is served":
    for v in SupportedProtocolVersions:
      let server = toolServer()
      let other = pageOf("lensed")
      server.onListScope(proc(ctx: McpRequestContext, methodName: string): ListHandler =
        if methodName == "tools/list" and not ctx.meta.isNil and ctx.meta.hasKey(MetaKey): other else: nil)
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/list")["result"]["tools"][0]["name"].getStr() == "plain"
      check peer.ask("tools/list", meta = %*{MetaKey: "x"})["result"]["tools"][0]["name"].getStr() == "lensed"

  test "Given a scope that picks another list, when a tool is called, then its input is validated against that list":
    let server = toolServer()
    let strict = proc(cursor: Option[string]): Future[McpPage] {.async.} =
      return McpPage(items: @[%*{"name": "plain", "inputSchema": {"type": "object",
        "properties": {"s": {"type": "string"}}, "required": ["s"]}}])
    server.onListScope(proc(ctx: McpRequestContext, methodName: string): ListHandler =
      if not ctx.meta.isNil and ctx.meta.hasKey(MetaKey): strict else: nil)
    let peer = server.connect(server.attach(), DefaultProtocolVersion)
    # The registered list wants an integer n; the scoped one wants a string s.
    check not peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}})["result"].hasKey("isError")
    let scoped = peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}},
      meta = %*{MetaKey: "x"})
    check (scoped.hasKey("error") or scoped["result"]{"isError"}.getBool())
    check not peer.ask("tools/call", %*{"name": "plain", "arguments": {"s": "a"}},
      meta = %*{MetaKey: "x"})["result"].hasKey("isError")
