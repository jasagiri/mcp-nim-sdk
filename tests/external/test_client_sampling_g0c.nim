## What a client does with a sampling request: it takes only messages with a
## role of user or assistant and a content, and it passes on whatever stop
## reason its handler gives.

import std/[unittest, asyncdispatch, json, options]
import client/client
import client/content
import client/sampling
import protocol/features
import protocol/types
import ./client_peer

let Hello = %*{"type": "text", "text": "hello"}

proc modernVersions(): seq[McpProtocolVersion] =
  for v in SupportedProtocolVersions:
    if v.has(ftMultiRoundTripRequests):
      result.add v

proc responseTo(peer: Peer, id: string): JsonNode =
  waitFor sleepAsync(5)
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
      return message
  nil

proc requestOf(messages: JsonNode): JsonNode =
  %*{"messages": messages, "maxTokens": 10}

proc vendorSampler(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
  return McpSamplingResult(role: "assistant", model: "m", stopReason: some("vendorBudgetSpent"),
                           content: McpContentItem(kind: mckText, text: "ok"))

proc inputRequired(requests: JsonNode): JsonNode =
  %*{"resultType": "input_required", "inputRequests": requests}

proc askedOnce(first: JsonNode): proc(peer: Peer, message: JsonNode) =
  ## A server whose first tools/call needs input and whose retry completes.
  var seen = 0
  result = proc(peer: Peer, message: JsonNode) =
    if message{"method"}.getStr() == "tools/call":
      peer.reply(message["id"], if seen == 0: first
                                else: %*{"resultType": "complete", "content": []})
      inc seen

suite "a sampling request that reaches a client before 2026-07-28":

  test "Given a message whose role is neither user nor assistant, or is missing, or that has no content, when the server asks, then the client answers invalid params and the handler is not called":
    for message in [%*{"role": "system", "content": Hello}, %*{"content": Hello},
                    %*{"role": "user"}, %*{"role": "user", "content": "hello"}]:
      var called = 0
      let peer = startPeer(nil)
      discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
        client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
          inc called
          return await vendorSampler(request)))
      peer.ask(%"s1", "sampling/createMessage", requestOf(%*[message]))
      check peer.responseTo("s1")["error"]["code"].getInt() == -32602
      check called == 0

  test "Given a handler whose answer stops for a reason the specification does not list, when the server asks, then the answer carries that stopReason":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setSamplingHandler(vendorSampler))
    peer.ask(%"s1", "sampling/createMessage",
             requestOf(%*[{"role": "user", "content": Hello}]))
    check peer.responseTo("s1")["result"]["stopReason"].getStr() == "vendorBudgetSpent"

suite "a sampling request that reaches a client from 2026-07-28":

  test "Given an input request whose message has a role other than user or assistant, when the client reads it, then it abandons the request with invalid params, without calling the handler or retrying":
    if modernVersions().len == 0:
      skip()
    for v in modernVersions():
      var called = 0
      let peer = startPeer(askedOnce(inputRequired(%*{"ask": {
        "method": "sampling/createMessage",
        "params": requestOf(%*[{"role": "system", "content": Hello}])}})), modern = true)
      let client = peer.connectedClient(v, proc(client: McpClient) =
        client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
          inc called
          return await vendorSampler(request)))
      var refusal = 0
      try:
        discard waitFor client.callMethod("tools/call", %*{"name": "t"})
      except McpRequestError as e:
        refusal = e.code
      check refusal == -32602
      check called == 0
      check peer.requestsFor("tools/call").len == 1

  test "Given a handler whose answer stops for a reason the specification does not list, when the server asks for input, then the retry carries that stopReason":
    if modernVersions().len == 0:
      skip()
    for v in modernVersions():
      let peer = startPeer(askedOnce(inputRequired(%*{"ask": {
        "method": "sampling/createMessage",
        "params": requestOf(%*[{"role": "user", "content": Hello}])}})), modern = true)
      let client = peer.connectedClient(v, proc(client: McpClient) =
        client.setSamplingHandler(vendorSampler))
      discard waitFor client.callMethod("tools/call", %*{"name": "t"})
      let retry = peer.requestsFor("tools/call")[1]["params"]
      check retry["inputResponses"]["ask"]["stopReason"].getStr() == "vendorBudgetSpent"
