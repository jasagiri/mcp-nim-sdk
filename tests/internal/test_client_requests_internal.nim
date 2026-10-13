## Request lifecycle of the client: timeouts, cancellation, progress, and
## what happens to waiting requests when the connection ends.

import std/[unittest, asyncdispatch, json, options, os]
import client/client
import client/cancel_token
import transport/transport
import ../external/loopback_transport
import ../external/client_peer

proc silentPeer(): Peer = startPeer(nil)

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-client-requests-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc holdSending(peer: Peer, methodName: string): Future[void] =
  ## The client's transport does not finish sending `methodName` requests
  ## until the returned future is completed or failed, as an HTTP POST does
  ## until the server starts to answer.
  let gate = newFuture[void]("test.sendGate")
  peer.pair.client.holdSendsOf = methodName
  peer.pair.client.sendGate = gate
  gate

proc timesOut(client: McpClient) =
  ## A tools/list that gets no answer within 30 ms.
  expect McpTimeoutError:
    discard waitFor client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(30)))
  waitFor sleepAsync(5)

proc lastCancelled(peer: Peer): JsonNode =
  let all = peer.requestsFor("notifications/cancelled")
  if all.len == 0: nil else: all[^1]["params"]


suite "cancelling a request":


  # An internal-implementation test (I): nothing outside the token shows what
  # it still holds, so `heldWaiters` is the hook. The behaviour behind it is
  # that a token used for the whole life of an application does not grow by
  # one closure per request.
  test "Given one token used by many requests that end in different ways, when they are done, then the token holds nothing of them":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        peer.reply(message["id"], %*{"tools": []}))
    let client = peer.connectedClient(LegacyDefault)
    let token = newMcpCancelToken()
    for _ in 0 ..< 20:
      discard waitFor client.sendRequest("tools/list", newJObject(),
        McpRequestOptions(cancel: token))
    expect McpTimeoutError:
      discard waitFor client.sendRequest("tools/call", %*{"name": "slow"},
        McpRequestOptions(cancel: token, timeoutMs: some(20)))
    check token.heldWaiters == 0


if SpeaksModern:


  suite "a tools/call is repeated only when refused as a header mismatch":

    proc answeringWith(answer: proc(peer: Peer, id: JsonNode)): Peer =
      startPeer(proc(peer: Peer, message: JsonNode) =
        case message{"method"}.getStr()
        of "tools/call": answer(peer, message["id"])
        of "tools/list": peer.reply(message["id"], %*{"resultType": "complete", "tools": []})
        else: discard, modern = true, kind = mtkStreamable)

