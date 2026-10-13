## The message of an error a client writes is one sentence the raiser wrote
## and never the async traceback of a debug build.

import std/[unittest, asyncdispatch, json, strutils]
import client/client
import client/sampling
import client/roots
import ./client_peer

proc errorMessage(peer: Peer, id: string): string =
  waitFor sleepAsync(10)
  for m in peer.received:
    if m{"id"}.getStr() == id and m.hasKey("error"):
      return m["error"]["message"].getStr()

let params = %*{
  "messages": [{"role": "user", "content": {"type": "text", "text": "hello"}}],
  "maxTokens": 100}

suite "an error a client writes is a message and not a traceback":

  test "Given a handler that fails with an error code of its own, when the server asks, then the message is the handler's alone":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault, proc(c: McpClient) =
      c.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
        raise newException(client.McpRequestError, "User rejected sampling request")))
    peer.ask(%"s1", "sampling/createMessage", params)
    let message = peer.errorMessage("s1")
    check message == "User rejected sampling request"

  test "Given a handler that raises, when the server asks, then the message is the one the raiser wrote, on one line, without a traceback":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault, proc(c: McpClient) =
      c.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
        raise newException(ValueError, "model offline")))
    peer.ask(%"s1", "sampling/createMessage", params)
    let message = peer.errorMessage("s1")
    check message == "model offline"
    check "traceback" notin message.toLowerAscii
    check '\n' notin message
    check ".nim" notin message

  test "Given a roots handler that raises, when the server asks, then the message names no source path":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault, proc(c: McpClient) =
      c.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} =
        raise newException(IOError, "disk gone")))
    peer.ask(%"r1", "roots/list")
    let message = peer.errorMessage("r1")
    check message == "disk gone"
    check ".nim" notin message
