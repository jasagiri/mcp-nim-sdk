## What a server may ask of the client's sampling handler is checked before
## the handler sees it: maxTokens is the number of tokens a model is asked
## for, so it is a positive integer.

import std/[unittest, asyncdispatch, json, strutils]
import client/client
import client/sampling
import client/content
import protocol/version
import protocol/types
import ./client_peer

const Speaks = min(DefaultProtocolVersion, mpv20251125)
  ## Sampling and its limits are in every version; a build speaks the
  ## versions up to its default only.

proc responseTo(peer: Peer, id: string): JsonNode =
  waitFor sleepAsync(5)
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
      return message
  nil

proc request(maxTokens: JsonNode): JsonNode =
  result = %*{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}]}
  if not maxTokens.isNil:
    result["maxTokens"] = maxTokens

suite "a sampling request names a number of tokens a model can be asked for":

  test "Given maxTokens missing, not an integer, zero or negative, when the request arrives, then the client answers invalid params and the handler is not called":
    for maxTokens in [JsonNode(nil), %"100", %1.5, %0, % -1]:
      var called = false
      let peer = startPeer(nil)
      discard peer.connectedClient(Speaks, proc(client: McpClient) =
        client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
          called = true))
      peer.ask(%"s1", "sampling/createMessage", request(maxTokens))
      checkpoint "maxTokens: " & (if maxTokens.isNil: "missing" else: $maxTokens)
      check peer.responseTo("s1")["error"]["code"].getInt() == -32602
      check not called

  test "Given a positive integer, when the request arrives, then the handler sees it as it was sent":
    var seen = -1
    let peer = startPeer(nil)
    discard peer.connectedClient(Speaks, proc(client: McpClient) =
      client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
        seen = request.maxTokens
        return McpSamplingResult(role: "assistant", model: "m",
                                 content: McpContentItem(kind: mckText, text: "ok"))))
    peer.ask(%"s1", "sampling/createMessage", request(%1))
    discard peer.responseTo("s1")
    check seen == 1

suite "a server cannot keep any number of the client's handlers busy":

  test "Given a limit of 2 and two sampling requests in progress, when a third arrives, then it is answered with an internal error and the handler is not called for it; after one ends the next is handled":
    var calls = 0
    var gate = newFuture[void]("gate")
    let peer = startPeer(nil)
    discard peer.connectedClient(Speaks, proc(client: McpClient) =
      client.maxServerRequestsInProgress = 2
      client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
        inc calls
        await gate
        return McpSamplingResult(role: "assistant", model: "m",
                                 content: McpContentItem(kind: mckText, text: "ok"))))
    for id in ["s1", "s2", "s3"]:
      peer.ask(%id, "sampling/createMessage", request(%10))
    let refused = peer.responseTo("s3")
    check refused["error"]["code"].getInt() == -32603
    check "too many requests in progress" in refused["error"]["message"].getStr().toLowerAscii()
    check calls == 2
    gate.complete()
    check not peer.responseTo("s1").hasKey("error")
    check not peer.responseTo("s2").hasKey("error")
    gate = newFuture[void]("gate2")
    gate.complete()
    peer.ask(%"s4", "sampling/createMessage", request(%10))
    check not peer.responseTo("s4").hasKey("error")
    check calls == 3

  test "Given a limit of 0, when three sampling requests are in progress at once, then none is refused and the handler is called for each":
    var calls = 0
    let gate = newFuture[void]("gate")
    let peer = startPeer(nil)
    discard peer.connectedClient(Speaks, proc(client: McpClient) =
      client.maxServerRequestsInProgress = 0
      client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
        inc calls
        await gate
        return McpSamplingResult(role: "assistant", model: "m",
                                 content: McpContentItem(kind: mckText, text: "ok"))))
    for id in ["s1", "s2", "s3"]:
      peer.ask(%id, "sampling/createMessage", request(%10))
    waitFor sleepAsync(5)
    check calls == 3
    gate.complete()
    for id in ["s1", "s2", "s3"]:
      check not peer.responseTo(id).hasKey("error")

  test "Given no limit given, when the client is made, then 64 requests may be in progress; 0 means no limit":
    check DefaultMaxServerRequestsInProgress == 64
    check newMcpClient(McpClientInfo(name: "c", version: "1")).maxServerRequestsInProgress == 64
