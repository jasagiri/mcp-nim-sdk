## The client answers sampling/createMessage with tools (2025-11-25): it
## declares sampling.tools, refuses what it did not declare or what breaks the
## message rules, and checks the handler's answer before the server sees it.

import std/[unittest, asyncdispatch, json, options]
import client/client
import client/content
import client/sampling
import protocol/types
import protocol/sampling_tools
import ./client_peer

proc responseTo(peer: Peer, id: string): JsonNode =
  waitFor sleepAsync(5)
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
      return message
  nil

let
  weather = %*{"name": "get_weather", "inputSchema": {"type": "object"}}
  question = %*{"role": "user", "content": {"type": "text", "text": "Weather in Paris?"}}
  toolUse = toolUseBlock("call_1", "get_weather", %*{"city": "Paris"})
  toolUseMessage = %*{"role": "assistant", "content": [toolUse]}
  toolResultMessage = %*{"role": "user", "content": [
    toolResultBlock("call_1", @[%*{"type": "text", "text": "18C"}])]}

proc withTools(messages: seq[JsonNode], extra: JsonNode = nil): JsonNode =
  result = %*{"messages": messages, "tools": [weather], "maxTokens": 100}
  if not extra.isNil:
    for key, value in extra.pairs: result[key] = value

proc toolUser(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
  return McpSamplingResult(role: "assistant", model: "m", stopReason: some("toolUse"),
    blocks: @[toolUseContent("call_1", "get_weather", %*{"city": "Paris"})])

if LegacyDefault >= mpv20251125:
  suite "sampling with tools answered by the client (2025-11-25)":

    test "Given a handler that supports tools, when the client connects, then initialize declares sampling.tools; by default it does not":
      let peer = startPeer(nil)
      discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
        client.setSamplingHandler(toolUser, tools = true))
      check peer.requestsFor("initialize")[0]["params"]["capabilities"]["sampling"] == %*{"tools": {}}
      let plain = startPeer(nil)
      discard plain.connectedClient(mpv20251125, proc(client: McpClient) =
        client.setSamplingHandler(toolUser))
      check plain.requestsFor("initialize")[0]["params"]["capabilities"]["sampling"] == newJObject()

    test "Given a request with tools, when the handler answers with tool uses, then the handler sees tools and toolChoice and the result carries a content array and toolUse":
      var seen: McpSamplingRequest
      let peer = startPeer(nil)
      discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
        client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] =
          seen = request
          toolUser(request), tools = true))
      peer.ask(%"s1", "sampling/createMessage",
               withTools(@[question], %*{"toolChoice": {"mode": "required"}}))
      let reply = peer.responseTo("s1")["result"]
      check reply["content"] == %*[toolUse]
      check reply["stopReason"].getStr() == "toolUse"
      check reply["model"].getStr() == "m"
      check seen.tools == @[weather]
      check seen.toolChoice == some("required")

    test "Given messages with tool uses and results, when the request arrives, then the handler sees every block":
      var seen: McpSamplingRequest
      let peer = startPeer(nil)
      discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
        client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
          seen = request
          return McpSamplingResult(role: "assistant", model: "m", stopReason: some("endTurn"),
            content: McpContentItem(kind: mckText, text: "18C")), tools = true))
      peer.ask(%"s1", "sampling/createMessage",
               withTools(@[question, toolUseMessage, toolResultMessage]))
      check peer.responseTo("s1")["result"]["content"] == %*{"type": "text", "text": "18C"}
      check seen.messages.len == 3
      check seen.messages[1].blocks.len == 1
      check seen.messages[1].blocks[0].kind == mckUnknown
      check seen.messages[1].blocks[0].raw == toolUse
      check seen.messages[2].blocks[0].raw["toolUseId"].getStr() == "call_1"

    test "Given a client that did not declare sampling.tools, when a request with tools arrives, then the client answers invalid params and the handler is not called":
      var called = false
      let peer = startPeer(nil)
      discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
        client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
          called = true))
      peer.ask(%"s1", "sampling/createMessage", withTools(@[question]))
      check peer.responseTo("s1")["error"]["code"].getInt() == -32602
      check not called

    test "Given a connection of 2025-06-18, when a request with tools arrives, then the client answers invalid params":
      let peer = startPeer(nil)
      discard peer.connectedClient(mpv20250618, proc(client: McpClient) =
        client.setSamplingHandler(toolUser, tools = true))
      peer.ask(%"s1", "sampling/createMessage", withTools(@[question]))
      check peer.responseTo("s1")["error"]["code"].getInt() == -32602

    test "Given a tool result mixed with other content or missing, when the request arrives, then the client answers invalid params":
      let mixed = %*{"role": "user", "content": [
        {"type": "text", "text": "results:"}, toolResultBlock("call_1", @[])]}
      for messages in [@[question, toolUseMessage, mixed], @[question, toolUseMessage]]:
        var called = false
        let peer = startPeer(nil)
        discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
          client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
            called = true, tools = true))
        peer.ask(%"s1", "sampling/createMessage", withTools(messages))
        check peer.responseTo("s1")["error"]["code"].getInt() == -32602
        check not called

    test "Given a handler that answers toolUse without a tool_use block, when the server asks, then the server gets an internal error and not the answer":
      let peer = startPeer(nil)
      discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
        client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
          return McpSamplingResult(role: "assistant", model: "m", stopReason: some("toolUse"),
            content: McpContentItem(kind: mckText, text: "x")), tools = true))
      peer.ask(%"s1", "sampling/createMessage", withTools(@[question]))
      let reply = peer.responseTo("s1")
      check reply["error"]["code"].getInt() == -32603
      check not reply.hasKey("result")

    test "Given a request without tools, when the handler answers as before, then the result is the plain content object":
      let peer = startPeer(nil)
      discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
        client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
          return McpSamplingResult(role: "assistant", model: "m",
            content: McpContentItem(kind: mckText, text: "hi"))))
      peer.ask(%"s1", "sampling/createMessage",
               %*{"messages": [question], "maxTokens": 10})
      check peer.responseTo("s1")["result"]["content"] == %*{"type": "text", "text": "hi"}
