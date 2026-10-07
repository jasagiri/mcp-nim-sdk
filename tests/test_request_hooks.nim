## The places an extension plugs into the server's handling of a request:
## the request's own `_meta`, a filter on the answer, and a choice of list
## handler per request. None of them changes what a server without an
## extension does.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness
import server/server
import protocol/subscriptions
import protocol/version

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

  if isSupported(mpv20260728):
    test "Given a filter that turns a 2026-07-28 result into something that is not an object, when the request is answered, then it is an internal error":
      for notAnObject in [%*[1, 2], newJNull()]:
        let replacement = notAnObject
        let server = toolServer()
        server.addResponseFilter(proc(ctx: McpRequestContext, request: JsonRpcRequest,
                                      response: JsonRpcResponse): Future[JsonRpcResponse] {.async.} =
          var replaced = response
          replaced.result = some(replacement)
          return replaced)
        let peer = server.connect(server.attach(), mpv20260728)
        check peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}}).errorCode == -32603

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

suite "request interceptors":

  test "Given interceptors, when a request is served, then they run in the order added, the first answer ends the matter and none lets the server carry on":
    for v in SupportedProtocolVersions:
      let server = toolServer()
      var seen: seq[string]
      server.addRequestInterceptor(proc(ctx: McpRequestContext,
                                        request: JsonRpcRequest): Future[Option[JsonRpcResponse]] {.async.} =
        seen.add "first:" & request.`method`
        if request.`method` == "tools/list":
          return some(newJsonRpcResponse(request.id, %*{"tools": [], "by": "first"}))
        return none(JsonRpcResponse))
      server.addRequestInterceptor(proc(ctx: McpRequestContext,
                                        request: JsonRpcRequest): Future[Option[JsonRpcResponse]] {.async.} =
        seen.add "second:" & request.`method`
        return none(JsonRpcResponse))
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/list"){"result", "by"}.getStr() == "first"
      check seen == @["first:tools/list"]
      let called = peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}})
      check called{"result", "content"}[0]{"text"}.getStr() == "plain"
      check seen == @["first:tools/list", "first:tools/call", "second:tools/call"]

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

suite "list-changed notifications with params":

  test "Given a server that declares listChanged, when notifyListChanged carries params, then a legacy client receives them":
    for v in legacyVersions():
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability(listChanged: true))))
      let transport = server.attach()
      let peer = server.connect(transport, v)
      waitFor server.notifyListChanged("notifications/tools/list_changed",
        %*{"_meta": {MetaKey: "wide"}})
      untilTrue("the notification", proc(): bool =
        transport.messagesOf("notifications/tools/list_changed").len == 1)
      check transport.messagesOf("notifications/tools/list_changed")[0].message["params"] ==
        %*{"_meta": {MetaKey: "wide"}}
      discard peer

  test "Given a list the server did not declare listChanged for, when notifyListChanged is called, then nothing is sent":
    let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
    let transport = server.attach()
    discard server.connect(transport, legacyVersions()[0])
    waitFor server.notifyListChanged("notifications/tools/list_changed")
    settle()
    check transport.messagesOf("notifications/tools/list_changed").len == 0

  test "Given prompts and resources declared without listChanged, when notifyListChanged is called for them, then nothing is sent":
    let server = newServer(McpServerCapabilities(prompts: some(McpPromptsCapability()),
                                                 resources: some(McpResourcesCapability())))
    let transport = server.attach()
    discard server.connect(transport, legacyVersions()[0])
    waitFor server.notifyListChanged("notifications/prompts/list_changed")
    waitFor server.notifyListChanged("notifications/resources/list_changed")
    settle()
    check transport.messagesOf("notifications/prompts/list_changed").len == 0
    check transport.messagesOf("notifications/resources/list_changed").len == 0

  test "Given a server that declared no tools, prompts or resources, when it announces a list change or a resource update, then nothing is sent and nothing is raised":
    let server = newServer(McpServerCapabilities())
    let transport = server.attach()
    discard server.connect(transport, legacyVersions()[0])
    for methodName in ["notifications/tools/list_changed", "notifications/prompts/list_changed",
                       "notifications/resources/list_changed"]:
      waitFor server.notifyListChanged(methodName)
    waitFor server.notifyResourceUpdated("file:///a")
    settle()
    for methodName in ["notifications/tools/list_changed", "notifications/prompts/list_changed",
                       "notifications/resources/list_changed", "notifications/resources/updated"]:
      check transport.messagesOf(methodName).len == 0

  test "Given a method that is not a list-changed notification, when notifyListChanged is called, then ValueError is raised":
    let server = toolServer()
    expect ValueError:
      waitFor server.notifyListChanged("notifications/message")

suite "a server that uses none of the hooks":

  proc plainServer(): McpServer =
    result = newServer(McpServerCapabilities(
      tools: some(McpToolsCapability(listChanged: true)),
      resources: some(McpResourcesCapability()), prompts: some(McpPromptsCapability())))
    result.onToolsList(pageOf("plain"))
    result.onResourcesList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
      return McpPage(items: @[%*{"uri": "file:///a", "name": "a"}]))
    result.onPromptsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
      return McpPage(items: @[%*{"name": "p"}]))
    result.onToolCall(proc(ctx: McpRequestContext, name: string,
                           arguments: JsonNode): Future[JsonNode] {.async.} =
      return %*{"content": [{"type": "text", "text": "ran " & name}]})
    result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
      return @[%*{"uri": uri, "text": "body"}])
    result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                            arguments: JsonNode): Future[JsonNode] {.async.} =
      return %*{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}]})

  let requests = [
    ("tools/list", %*{}), ("tools/call", %*{"name": "plain", "arguments": {"n": 1}}),
    ("resources/list", %*{}), ("resources/read", %*{"uri": "file:///a"}),
    ("prompts/list", %*{}), ("prompts/get", %*{"name": "p"})]

  test "Given handlers that never read ctx.meta, when requests carry different _meta, then the results are identical":
    for v in SupportedProtocolVersions:
      let server = plainServer()
      let peer = server.connect(server.attach(), v)
      for (methodName, params) in requests:
        let bare = peer.ask(methodName, params)["result"]
        let withMeta = peer.ask(methodName, params, meta = %*{MetaKey: "wide", "x": 1})["result"]
        let other = peer.ask(methodName, params, meta = %*{"unrelated": [1, 2]})["result"]
        check bare == withMeta
        check bare == other

  test "Given no response filter, when the standard methods are answered, then each result is what the handler returned":
    for v in SupportedProtocolVersions:
      let server = plainServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/list")["result"]["tools"].len == 1
      check peer.ask("tools/list")["result"]["tools"][0]["name"].getStr() == "plain"
      check peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}})["result"]["content"] ==
        %*[{"type": "text", "text": "ran plain"}]
      check peer.ask("resources/read", %*{"uri": "file:///a"})["result"]["contents"] ==
        %*[{"uri": "file:///a", "text": "body"}]
      check peer.ask("prompts/get", %*{"name": "p"})["result"]["messages"] ==
        %*[{"role": "user", "content": {"type": "text", "text": "hi"}}]

  test "Given no list scope, or one that answers nil, when lists are asked and a tool is called, then the registered handlers serve and validate":
    for useScope in [false, true]:
      for v in SupportedProtocolVersions:
        let server = plainServer()
        if useScope:
          server.onListScope(proc(ctx: McpRequestContext, methodName: string): ListHandler = nil)
        let peer = server.connect(server.attach(), v)
        check peer.ask("tools/list")["result"]["tools"][0]["name"].getStr() == "plain"
        check peer.ask("resources/list")["result"]["resources"][0]["uri"].getStr() == "file:///a"
        check peer.ask("prompts/list")["result"]["prompts"][0]["name"].getStr() == "p"
        # the registered tool list wants an integer n
        check not peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}})["result"].hasKey("isError")
        let bad = peer.ask("tools/call", %*{"name": "plain", "arguments": {}})
        check (bad.hasKey("error") or bad["result"]{"isError"}.getBool())

  test "Given notifyListChanged is never called, when requests are served, then no list-changed notification is sent, and notifyToolListChanged still sends it with empty params":
    for v in legacyVersions():
      let server = plainServer()
      let transport = server.attach()
      let peer = server.connect(transport, v)
      discard peer.ask("tools/list")
      discard peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}})
      settle()
      check transport.messagesOf("notifications/tools/list_changed").len == 0
      waitFor server.notifyToolListChanged()
      untilTrue("the notification", proc(): bool =
        transport.messagesOf("notifications/tools/list_changed").len == 1)
      let sent = transport.messagesOf("notifications/tools/list_changed")[0].message
      check sent["method"].getStr() == "notifications/tools/list_changed"
      check sent{"params"}.isNil or sent["params"] == %*{}

proc appending(suffix: string): ToolListTransform =
  ## A transform of the description, so that the order of two shows.
  result = proc(ctx: McpRequestContext, tool: JsonNode): JsonNode =
    result = tool.copy()
    result["description"] = %(tool{"description"}.getStr() & suffix)

suite "hooks run in the order they were added":

  test "Given two request interceptors, when a request arrives, then the first that answers ends the matter and one that answers none lets the server carry on":
    for v in SupportedProtocolVersions:
      let server = toolServer()
      var seen: seq[string]
      server.addRequestInterceptor(proc(ctx: McpRequestContext,
                                        request: JsonRpcRequest): Future[Option[JsonRpcResponse]] {.async.} =
        seen.add "first " & request.`method`
        if request.`method` == "tools/call":
          return some(newJsonRpcResponse(request.id, %*{"by": "first"}))
        return none(JsonRpcResponse))
      server.addRequestInterceptor(proc(ctx: McpRequestContext,
                                        request: JsonRpcRequest): Future[Option[JsonRpcResponse]] {.async.} =
        seen.add "second " & request.`method`
        return some(newJsonRpcResponse(request.id, %*{"by": "second"})))
      let peer = server.connect(server.attach(), v)
      seen.setLen(0)
      check peer.ask("tools/call", %*{"name": "plain", "arguments": {"n": 1}})["result"]["by"].getStr() == "first"
      check seen == @["first tools/call"]
      seen.setLen(0)
      check peer.ask("tools/list")["result"]["by"].getStr() == "second"
      check seen == @["first tools/list", "second tools/list"]

  test "Given two tool list transforms, when tools/list is asked, then each tool passes through them in the order they were added":
    for v in SupportedProtocolVersions:
      let server = toolServer()
      server.addToolListTransform(appending("-a"))
      server.addToolListTransform(appending("-b"))
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/list")["result"]["tools"][0]["description"].getStr() == "-a-b"

  test "Given two listen filter hooks, when subscriptions/listen is asked, then each sees what the earlier ones agreed to and the acknowledgment carries the result":
    for v in versionsWith(ftSubscriptionsListen):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability(listChanged: true))))
      server.addListenFilterHook(proc(ctx: McpRequestContext, requested: SubscriptionFilter,
                                      honored: var SubscriptionFilter) =
        honored.taskIds.add "task-1")
      server.addListenFilterHook(proc(ctx: McpRequestContext, requested: SubscriptionFilter,
                                      honored: var SubscriptionFilter) =
        if honored.taskIds == @["task-1"]:
          honored.promptsListChanged = true)
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.send(%"listen-1", "subscriptions/listen", %*{"notifications": {"toolsListChanged": true}})
      untilTrue("the acknowledgment", proc(): bool =
        t.messagesOf("notifications/subscriptions/acknowledged").len > 0)
      let honored = t.messagesOf("notifications/subscriptions/acknowledged")[0].message["params"]["notifications"]
      check honored["toolsListChanged"].getBool()
      check honored["taskIds"] == %*["task-1"]
      check honored["promptsListChanged"].getBool()

  test "Given a listen filter hook that raises a request error, when subscriptions/listen is asked, then the client gets that error and nothing is subscribed":
    for v in versionsWith(ftSubscriptionsListen):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability(listChanged: true))))
      server.addListenFilterHook(proc(ctx: McpRequestContext, requested: SubscriptionFilter,
                                      honored: var SubscriptionFilter) =
        raise newRequestError(-32602, "no such task"))
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("subscriptions/listen", %*{"notifications": {"toolsListChanged": true}})
      check answer.errorCode == -32602
      check answer["error"]["message"].getStr() == "no such task"
      check server.subscriptionCount == 0
