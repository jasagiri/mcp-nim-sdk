## Which failures are JSON-RPC errors and which are results: unknown tool,
## failing tool, unknown resource, unknown prompt, a handler's own defect.

import std/[unittest, asyncdispatch, json, options, strutils]
import ./server_harness

proc errorServer(): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()),
    resources: some(McpResourcesCapability()),
    prompts: some(McpPromptsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "ok":
      return %*{"content": [{"type": "text", "text": "fine"}]}
    of "fails":
      raise newToolFailure("the date must be in the future")
    of "breaks":
      raise newException(ValueError, "secret internal detail")
    of "not-an-object":
      return %"just text"
    else:
      raise newUnknownTool(name))
  result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    if uri != "file:///known":
      raise newResourceNotFound(uri)
    return @[%*{"uri": uri, "text": "a"}, %*{"uri": uri & "#2", "text": "b"}])
  result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    if name != "greet":
      raise newInvalidParams("Invalid prompt name: " & name)
    return %*{"messages": []})

suite "tools/call failures (every version)":

  test "Given tool handlers but no tools capability, when a tool is listed or called, then the method is not found":
    for v in SupportedProtocolVersions:
      let server = newServer(McpServerCapabilities(prompts: some(McpPromptsCapability())))
      server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
        return McpPage(items: @[%*{"name": "ok", "inputSchema": {"type": "object"}}]))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        return %*{"content": [{"type": "text", "text": "fine"}]})
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/list").errorCode == -32601
      check peer.ask("tools/call", %*{"name": "ok"}).errorCode == -32601

  test "Given the tools capability but no call handler, when a tool is called, then the method is not found":
    for v in SupportedProtocolVersions:
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/list").errorCode == -32601
      check peer.ask("tools/call", %*{"name": "ok"}).errorCode == -32601

  test "Given a tool that does not exist, when it is called, then the answer is a JSON-RPC error and not a result":
    for v in SupportedProtocolVersions:
      let server = errorServer()
      let reply = server.connect(server.attach(), v).ask("tools/call", %*{"name": "nope"})
      check reply.errorCode == -32602
      check "nope" in reply["error"]["message"].getStr()
      check not reply.hasKey("result")

  test "Given a tool that ran and failed, when it is called, then the answer is a result with isError true and the message as text":
    for v in SupportedProtocolVersions:
      let server = errorServer()
      let reply = server.connect(server.attach(), v).ask("tools/call", %*{"name": "fails"})
      check not reply.hasKey("error")
      check reply["result"]["isError"].getBool() == true
      check textOf(reply) == "the date must be in the future"
      check "traceback" notin $reply

  test "Given a tool that succeeds, when it is called, then its result is passed on unchanged":
    for v in SupportedProtocolVersions:
      let server = errorServer()
      let reply = server.connect(server.attach(), v).ask("tools/call", %*{"name": "ok"})
      check textOf(reply) == "fine"
      check not reply["result"].hasKey("isError")

  test "Given a handler that breaks, when the tool is called, then the peer gets an internal error without the cause":
    for v in SupportedProtocolVersions:
      let server = errorServer()
      let reply = server.connect(server.attach(), v).ask("tools/call", %*{"name": "breaks"})
      check reply.errorCode == -32603
      check "secret" notin $reply

  test "Given a handler whose result is not an object, when the tool is called, then the answer is an internal error":
    for v in SupportedProtocolVersions:
      let server = errorServer()
      let reply = server.connect(server.attach(), v).ask("tools/call", %*{"name": "not-an-object"})
      check reply.errorCode == -32603

  test "Given arguments that are not an object, when a tool is called, then the answer is invalid params":
    for v in SupportedProtocolVersions:
      let server = errorServer()
      let reply = server.connect(server.attach(), v).ask("tools/call",
        %*{"name": "ok", "arguments": "text"})
      check reply.errorCode == -32602

suite "resources/read and prompts/get failures (every version)":

  test "Given a resource with two contents, when it is read, then both are returned":
    for v in SupportedProtocolVersions:
      let server = errorServer()
      let reply = server.connect(server.attach(), v).ask("resources/read", %*{"uri": "file:///known"})
      check reply["result"]["contents"].len == 2

  test "Given an unknown resource, when it is read, then the code is -32002 before 2026-07-28 and -32602 from it":
    for v in SupportedProtocolVersions:
      let server = errorServer()
      let reply = server.connect(server.attach(), v).ask("resources/read", %*{"uri": "file:///gone"})
      check reply.errorCode == (if v.has(ftResourceNotFoundInvalidParams): -32602 else: -32002)
      check reply["error"]["data"]["uri"].getStr() == "file:///gone"

  test "Given an unknown prompt, when it is requested, then the answer is invalid params":
    for v in SupportedProtocolVersions:
      let server = errorServer()
      let reply = server.connect(server.attach(), v).ask("prompts/get", %*{"name": "other"})
      check reply.errorCode == -32602

  test "Given the earlier API's read handler, when a resource is read, then its one content is wrapped in contents":
    let server = newServer(McpServerCapabilities(resources: some(McpResourcesCapability())))
    let read: typeof(McpResourceHandlers().readHandler.get) =
      proc(uri: string): Future[JsonNode] {.async.} = return %*{"uri": uri, "text": "x"}
    server.setResourceHandlers(McpResourceHandlers(readHandler: some(read)))
    let reply = server.connect(server.attach(), DefaultProtocolVersion).ask(
      "resources/read", %*{"uri": "file:///a"})
    check reply["result"]["contents"][0]["text"].getStr() == "x"

  test "Given the earlier API's subscribe and unsubscribe handlers, when a client subscribes and unsubscribes, then each handler is called with the uri":
    for v in versionsWith(ftResourceSubscribe):
      let server = newServer(McpServerCapabilities(
        resources: some(McpResourcesCapability(subscribe: true))))
      var calls: seq[string]
      let subscribe: typeof(McpResourceHandlers().subscribeHandler.get) =
        proc(uri: string): Future[void] {.async.} = calls.add "subscribe " & uri
      let unsubscribe: typeof(McpResourceHandlers().unsubscribeHandler.get) =
        proc(uri: string): Future[void] {.async.} = calls.add "unsubscribe " & uri
      server.setResourceHandlers(McpResourceHandlers(
        subscribeHandler: some(subscribe), unsubscribeHandler: some(unsubscribe)))
      let peer = server.connect(server.attach(), v)
      check not peer.ask("resources/subscribe", %*{"uri": "file:///a"}).hasKey("error")
      check not peer.ask("resources/unsubscribe", %*{"uri": "file:///a"}).hasKey("error")
      check calls == @["subscribe file:///a", "unsubscribe file:///a"]

  test "Given the earlier API's get handler, when a prompt is requested, then the messages it built come back":
    for v in SupportedProtocolVersions:
      let server = newServer(McpServerCapabilities(prompts: some(McpPromptsCapability())))
      let get: typeof(McpPromptHandlers().getHandler.get) =
        proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
          return %*{"messages": [{"role": "user", "content": {"type": "text", "text": name}}]}
      server.setPromptHandlers(McpPromptHandlers(getHandler: some(get)))
      let reply = server.connect(server.attach(), v).ask("prompts/get", %*{"name": "greet"})
      check reply["result"]["messages"][0]["content"]["text"].getStr() == "greet"
