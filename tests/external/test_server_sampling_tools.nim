## The server asks the client's model to use tools (sampling/createMessage
## with `tools`, 2025-11-25): what the client must have declared, what the
## server refuses to send, and what it makes of the answer.

import std/[unittest, asyncdispatch, json, options]
import protocol/sampling_tools
import ./server_harness

let
  WithTools = %*{"sampling": {"tools": {}}}
  Plain = %*{"sampling": {}}
  weather = %*{"name": "get_weather", "inputSchema": {"type": "object"}}
  question = %*{"role": "user", "content": {"type": "text", "text": "Weather in Paris?"}}
  toolUse = toolUseBlock("call_1", "get_weather", %*{"city": "Paris"})
  toolUseMessage = %*{"role": "assistant", "content": [toolUse]}
  toolResultMessage = %*{"role": "user", "content": [
    toolResultBlock("call_1", @[%*{"type": "text", "text": "18C"}])]}

proc toolsRequest(messages: seq[JsonNode], extra: JsonNode = nil): JsonNode =
  result = %*{"messages": messages, "tools": [weather], "maxTokens": 100}
  if not extra.isNil:
    for key, value in extra.pairs: result[key] = value

proc toolServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))

proc awaitRequest(t: SessionedTransport, methodName: string): Sent =
  untilTrue("the server's " & methodName, proc(): bool = t.messagesOf(methodName).len > 0)
  t.messagesOf(methodName)[0]

proc answer(t: SessionedTransport, asked: Sent, resultNode: JsonNode) =
  t.inject(asked.session, %*{"jsonrpc": "2.0", "id": asked.message["id"], "result": resultNode})

if DefaultProtocolVersion >= mpv20251125:
  suite "sampling with tools requested by the server (2025-11-25)":

    test "Given a client that declared sampling.tools, when the handshake is done, then the server knows it":
      let server = toolServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = %*{"sampling": {"tools": {}, "context": {}}})
      check server.clientCapabilities.get.sampling.get.tools
      check server.clientCapabilities.get.sampling.get.context
      let other = toolServer()
      discard other.connect(other.attach(), mpv20251125, clientCapabilities = Plain)
      check not other.clientCapabilities.get.sampling.get.tools

    test "Given a client that can use tools, when the server asks, then tools and toolChoice are sent and a toolUse answer comes back with its tool_use blocks":
      let server = toolServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = WithTools)
      let params = toolsRequest(@[question], %*{"toolChoice": {"mode": "auto"}})
      let pending = server.createMessage("", params)
      let asked = t.awaitRequest("sampling/createMessage")
      check asked.message["params"] == params
      t.answer(asked, %*{"role": "assistant", "content": [toolUse], "model": "m",
                         "stopReason": "toolUse"})
      let reply = waitFor pending
      check reply["stopReason"].getStr() == "toolUse"
      check toolUsesOf(reply) == @[toolUse]

    test "Given tool results for those uses, when the server asks again, then the follow-up is sent and the final answer comes back":
      let server = toolServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = WithTools)
      let pending = server.createMessage("",
        toolsRequest(@[question, toolUseMessage, toolResultMessage]))
      let asked = t.awaitRequest("sampling/createMessage")
      t.answer(asked, %*{"role": "assistant", "content": {"type": "text", "text": "18C"},
                         "model": "m", "stopReason": "endTurn"})
      check waitFor(pending)["content"]["text"].getStr() == "18C"

    test "Given a client without sampling.tools, when the server asks with tools, then it raises a capability error and sends nothing":
      let server = toolServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = Plain)
      expect McpCapabilityError:
        discard waitFor server.createMessage("", toolsRequest(@[question]))
      expect McpCapabilityError:
        discard waitFor server.createMessage("", %*{"messages": [question], "maxTokens": 5,
                                                    "toolChoice": {"mode": "none"}})
      check t.messagesOf("sampling/createMessage").len == 0

    test "Given a connection of 2025-06-18, when the server asks with tools, then it raises a capability error and sends nothing":
      let server = toolServer()
      let t = server.attach()
      discard server.connect(t, mpv20250618, clientCapabilities = WithTools)
      expect McpCapabilityError:
        discard waitFor server.createMessage("", toolsRequest(@[question]))
      check t.messagesOf("sampling/createMessage").len == 0

    test "Given messages that break the pairing of tool uses and results, when the server asks, then McpPayloadError names the problem and nothing is sent":
      let server = toolServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = WithTools)
      let mixed = %*{"role": "user", "content": [
        {"type": "text", "text": "results:"}, toolResultBlock("call_1", @[])]}
      expect McpPayloadError:
        discard waitFor server.createMessage("", toolsRequest(@[question, toolUseMessage, mixed]))
      expect McpPayloadError:
        discard waitFor server.createMessage("", toolsRequest(@[question, toolUseMessage]))
      check t.messagesOf("sampling/createMessage").len == 0

    test "Given an answer that stops for tool use without a tool_use block, when it arrives, then McpPayloadError is raised":
      let server = toolServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = WithTools)
      let pending = server.createMessage("", toolsRequest(@[question]))
      t.answer(t.awaitRequest("sampling/createMessage"), %*{"role": "assistant",
        "content": {"type": "text", "text": "x"}, "model": "m", "stopReason": "toolUse"})
      expect McpPayloadError:
        discard waitFor pending

    test "Given tool choice none, when the answer holds a tool_use, then McpPayloadError is raised":
      let server = toolServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = WithTools)
      let pending = server.createMessage("", toolsRequest(@[question], %*{"toolChoice": {"mode": "none"}}))
      t.answer(t.awaitRequest("sampling/createMessage"), %*{"role": "assistant",
        "content": [toolUse], "model": "m", "stopReason": "toolUse"})
      expect McpPayloadError:
        discard waitFor pending

    test "Given a handler that samples with tools, when a tool is called, then the request belongs to the tool call":
      let server = toolServer()
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        let reply = await ctx.createMessage(toolsRequest(@[question]))
        return %*{"content": [{"type": "text", "text": $toolUsesOf(reply).len}]})
      let t = server.attach()
      let peer = server.connect(t, mpv20251125, clientCapabilities = WithTools)
      let callId = freshId()
      peer.send(%callId, "tools/call", %*{"name": "agent"})
      let asked = t.awaitRequest("sampling/createMessage")
      check asked.related == callId
      t.answer(asked, %*{"role": "assistant", "content": [toolUse], "model": "m",
                         "stopReason": "toolUse"})
      check textOf(t.responseTo(callId)) == "1"
