## What a server asks of a client in sampling/createMessage: includeContext
## thisServer and allServers need the sampling.context capability, and the
## structuredContent of a tool_result conforms to the outputSchema of its
## tool. A handler that asks otherwise gets an exception from createMessage
## (nothing is sent), or, in 2026-07-28, an error answer and no input_required.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness
import server/mrtr

let
  Hello = %*{"type": "text", "text": "hello"}
  WithSampling = %*{"sampling": {}}

proc askParams(extra: JsonNode = nil): JsonNode =
  result = %*{"messages": [{"role": "user", "content": Hello}], "maxTokens": 10}
  if not extra.isNil:
    for key, value in extra.pairs:
      result[key] = value

proc caps(capabilities: JsonNode): JsonNode =
  %*{"io.modelcontextprotocol/clientCapabilities": capabilities}

proc asksForSample(params: JsonNode, capabilities: JsonNode, v: McpProtocolVersion): JsonNode =
  let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    discard ctx.requireInput("q", "sampling/createMessage", params)
    return %*{"content": []})
  server.connect(server.attach(), v).ask("tools/call", %*{"name": "t"}, meta = caps(capabilities))

suite "includeContext needs sampling.context":

  test "Given a client that declared sampling without context, when the server asks with includeContext thisServer or allServers, then it raises and sends nothing":
    for v in versionsWith(ftSamplingTools):
      if not v.has(ftServerInitiatedRequests):
        continue
      for scope in ["thisServer", "allServers"]:
        let server = newServer(McpServerCapabilities())
        let t = server.attach()
        discard server.connect(t, v, session = "s", clientCapabilities = WithSampling)
        let pending = server.createMessage("s", askParams(%*{"includeContext": scope}))
        settle()
        check pending.failed
        check t.messagesOf("sampling/createMessage").len == 0

  test "Given the same client, when the server asks with includeContext none or none at all, then the request is sent":
    for v in versionsWith(ftSamplingTools):
      if not v.has(ftServerInitiatedRequests):
        continue
      for extra in [%*{"includeContext": "none"}, newJObject()]:
        let server = newServer(McpServerCapabilities())
        let t = server.attach()
        discard server.connect(t, v, session = "s", clientCapabilities = WithSampling)
        discard server.createMessage("s", askParams(extra))
        untilTrue("the request", proc(): bool = t.messagesOf("sampling/createMessage").len == 1)

  test "Given a client that declared sampling.context, when the server asks with includeContext thisServer or allServers, then the request is sent":
    for v in versionsWith(ftSamplingTools):
      if not v.has(ftServerInitiatedRequests):
        continue
      for scope in ["thisServer", "allServers"]:
        let server = newServer(McpServerCapabilities())
        let t = server.attach()
        discard server.connect(t, v, session = "s",
                               clientCapabilities = %*{"sampling": {"context": {}}})
        discard server.createMessage("s", askParams(%*{"includeContext": scope}))
        untilTrue("the request", proc(): bool = t.messagesOf("sampling/createMessage").len == 1)

  test "Given a handler that asks with includeContext thisServer or allServers of a client without sampling.context, when the tool is called, then the answer is the missing-capability error and not input_required":
    for v in versionsWith(ftMultiRoundTripRequests):
      for scope in ["thisServer", "allServers"]:
        let reply = asksForSample(askParams(%*{"includeContext": scope}), WithSampling, v)
        check reply.hasKey("error")
        check not reply.hasKey("result")
        check reply.errorCode == -32021
        check reply["error"]["data"]["requiredCapabilities"]["sampling"].hasKey("context")

  test "Given a handler that asks with includeContext none, or with thisServer of a client with sampling.context, when the tool is called, then the answer is input_required":
    for v in versionsWith(ftMultiRoundTripRequests):
      for (extra, declared) in [(%*{"includeContext": "none"}, WithSampling),
                                (newJObject(), WithSampling),
                                (%*{"includeContext": "thisServer"}, %*{"sampling": {"context": {}}})]:
        let reply = asksForSample(askParams(extra), declared, v)
        check reply.hasKey("result")
        check reply["result"]["resultType"].getStr() == "input_required"

suite "a tool_result conforms to the outputSchema of its tool":

  let tools = %*[{"name": "weather", "inputSchema": {"type": "object"},
                  "outputSchema": {"type": "object",
                                   "properties": {"temp": {"type": "number"}},
                                   "required": ["temp"]}}]

  proc conversation(structured: JsonNode, toolList: JsonNode = tools): JsonNode =
    askParams(%*{"tools": toolList, "messages": [
      {"role": "user", "content": {"type": "text", "text": "Hi"}},
      {"role": "assistant", "content": [{"type": "tool_use", "id": "u1", "name": "weather", "input": {}}]},
      {"role": "user", "content": [{"type": "tool_result", "toolUseId": "u1",
                                    "content": [], "structuredContent": structured}]}]})

  let ToolsCapability = %*{"sampling": {"tools": {}}}

  test "Given a tool_result whose structuredContent breaks the outputSchema of its tool, when the server asks, then it is refused and nothing is sent":
    for v in versionsWith(ftSamplingTools):
      if not v.has(ftServerInitiatedRequests):
        continue
      for broken in [%*{"temp": "hot"}, %*{}, %*[1]]:
        let server = newServer(McpServerCapabilities())
        let t = server.attach()
        discard server.connect(t, v, session = "s", clientCapabilities = ToolsCapability)
        let pending = server.createMessage("s", conversation(broken))
        settle()
        check pending.failed
        check t.messagesOf("sampling/createMessage").len == 0

  test "Given a tool_result that conforms, or whose tool lists no outputSchema, when the server asks, then the request is sent":
    for v in versionsWith(ftSamplingTools):
      if not v.has(ftServerInitiatedRequests):
        continue
      let plain = %*[{"name": "weather", "inputSchema": {"type": "object"}}]
      for params in [conversation(%*{"temp": 21}), conversation(%*{"temp": 21.5, "unit": "C"}),
                     conversation(%*{"anything": "goes"}, plain)]:
        let server = newServer(McpServerCapabilities())
        let t = server.attach()
        discard server.connect(t, v, session = "s", clientCapabilities = ToolsCapability)
        discard server.createMessage("s", params)
        untilTrue("the request", proc(): bool = t.messagesOf("sampling/createMessage").len == 1)

  proc conversationWith(toolList: JsonNode, extra: JsonNode): JsonNode =
    ## The conversation above with one more user message of the one block `extra`.
    result = conversation(%*{"temp": 21}, toolList)
    result["messages"].add %*{"role": "user", "content": [extra]}

  proc requestIsSent(params: JsonNode, v: McpProtocolVersion): bool =
    let server = newServer(McpServerCapabilities())
    let t = server.attach()
    discard server.connect(t, v, session = "s", clientCapabilities = ToolsCapability)
    let pending = server.createMessage("s", params)
    settle()
    result = not pending.failed and t.messagesOf("sampling/createMessage").len == 1

  test "Given a block that is not a tool_use but carries the id of a tool_use and another name, when the server asks with a tool_result that breaks the schema of the tool_use's tool, then it is refused":
    let twoTools = %*[{"name": "weather", "inputSchema": {"type": "object"},
                       "outputSchema": {"type": "object",
                                        "properties": {"temp": {"type": "number"}},
                                        "required": ["temp"]}},
                      {"name": "plain", "inputSchema": {"type": "object"}}]
    for v in versionsWith(ftSamplingTools):
      if not v.has(ftServerInitiatedRequests):
        continue
      var params = conversation(%*{"temp": "hot"}, twoTools)
      params["messages"].add %*{"role": "user", "content": [
        {"type": "text", "text": "x", "id": "u1", "name": "plain"}]}
      check not requestIsSent(params, v)

  test "Given a block that is not a tool_result but carries a structuredContent breaking a schema, when the server asks with a tool_result that conforms, then the request is sent":
    for v in versionsWith(ftSamplingTools):
      if not v.has(ftServerInitiatedRequests):
        continue
      let params = conversationWith(tools, %*{"type": "text", "text": "x", "toolUseId": "u1",
                                              "structuredContent": {"temp": "hot"}})
      check requestIsSent(params, v)

  test "Given two tools with different outputSchemas, when the server asks with a tool_result that conforms to its own tool only, then the request is sent":
    let twoSchemas = %*[{"name": "clock", "inputSchema": {"type": "object"},
                         "outputSchema": {"type": "object",
                                          "properties": {"time": {"type": "string"}},
                                          "required": ["time"]}},
                        {"name": "weather", "inputSchema": {"type": "object"},
                         "outputSchema": {"type": "object",
                                          "properties": {"temp": {"type": "number"}},
                                          "required": ["temp"]}}]
    for v in versionsWith(ftSamplingTools):
      if not v.has(ftServerInitiatedRequests):
        continue
      check requestIsSent(conversation(%*{"temp": 21}, twoSchemas), v)

  test "Given a tool_result without a structuredContent for a tool that lists an outputSchema, when the server asks, then the request is sent":
    for v in versionsWith(ftSamplingTools):
      if not v.has(ftServerInitiatedRequests):
        continue
      var params = conversation(%*{"temp": 21})
      params["messages"][2]["content"][0].delete("structuredContent")
      check requestIsSent(params, v)

  test "Given a tool whose outputSchema cannot be used as a schema, when the server asks with a tool_result of it that has a structuredContent, then it is refused and nothing is sent":
    for v in versionsWith(ftSamplingTools):
      if not v.has(ftServerInitiatedRequests):
        continue
      for schema in [%*{"$schema": 5}, %*{"$schema": "https://example.com/no-such-dialect"}]:
        let unusable = %*[{"name": "weather", "inputSchema": {"type": "object"}, "outputSchema": schema}]
        check not requestIsSent(conversation(%*{"temp": 21}, unusable), v)

  test "Given a 2026-07-28 handler that asks with a tool_result that breaks the schema, when the request is served, then the answer is an error and not input_required":
    for v in versionsWith(ftMultiRoundTripRequests):
      let reply = asksForSample(conversation(%*{"temp": "hot"}), ToolsCapability, v)
      check reply.hasKey("error")
      check reply.errorCode == -32603

  test "Given a 2026-07-28 handler that asks with a tool_result that conforms, when the request is served, then the answer is input_required":
    for v in versionsWith(ftMultiRoundTripRequests):
      let reply = asksForSample(conversation(%*{"temp": 21}), ToolsCapability, v)
      check reply.hasKey("result")
      check reply["result"]["resultType"].getStr() == "input_required"
