## A request that was answered leaves no time limit of its own in the event
## loop (MCP-LIFECYCLE-28): a program that runs the loop until it is empty
## ends soon after its last answer, not when the longest limit would have
## been over. Only the client's public entrances are used. No test waits for
## a long limit to pass in real time.

import std/[unittest, asyncdispatch, json, options, times]
import client/client
import client/subscriptions as clientSubs
import protocol/subscriptions
import protocol/types
import protocol/version
import protocol/features
import ./client_peer
from ./server_harness import untilTrue

const
  LongLimitMs = 60_000
  EmptyWithinMs = 1_000
    ## The client's watcher sleeps one tick (200 ms) after the last answer;
    ## this is a tick and room to spare on a busy machine.

proc quietClient(peer: Peer, timeoutMs = LongLimitMs): McpClient =
  peer.connectedClient(configure = proc(client: McpClient) =
    client.requestTimeoutMs = timeoutMs
    client.pingIntervalMs = 0)

proc answersToolsList(): Peer =
  startPeer(proc(peer: Peer, message: JsonNode) =
    if message{"method"}.getStr() == "tools/list":
      peer.reply(message["id"], %*{"tools": []}))

proc loopEmptiesSoon(what: string) =
  untilTrue(what, proc(): bool = not hasPendingOperations(), EmptyWithinMs)

suite "the time limit of a request that was answered":

  test "Given a request with a 60 s limit, when its answer came, then the event loop has nothing pending within a short time":
    let peer = answersToolsList()
    let client = quietClient(peer)
    discard waitFor client.sendRequest("tools/list", newJObject())
    loopEmptiesSoon("the event loop to hold nothing after the answer")

  test "Given 200 requests with 60 s limits, when all were answered, then the event loop has nothing pending within a short time":
    let peer = answersToolsList()
    let client = quietClient(peer)
    var all: seq[Future[JsonRpcResponse]]
    for _ in 1 .. 200:
      all.add client.sendRequest("tools/list", newJObject())
    for response in all:
      discard waitFor response
    loopEmptiesSoon("the event loop to hold nothing after 200 answers")

  test "Given a client that has just connected, when its probe was answered, then the event loop has nothing pending within a short time":
    let peer = answersToolsList()
    discard quietClient(peer)
    loopEmptiesSoon("the event loop to hold nothing after the handshake")

  test "Given a request that is answered, when its own short limit would have passed, then it still has its answer":
    let peer = answersToolsList()
    let client = quietClient(peer)
    let response = waitFor client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(50)))
    waitFor sleepAsync(120)
    check response.result.isSome

suite "the time limit of a request that is not answered":

  test "Given a peer that never answers, when the limit passes, then the request raises McpTimeoutError":
    let peer = startPeer(nil)
    let client = quietClient(peer)
    expect McpTimeoutError:
      discard waitFor client.sendRequest("tools/list", newJObject(),
        McpRequestOptions(timeoutMs: some(40)))

  test "Given a far limit and then a nearer one, when time passes, then the nearer request times out at its own limit":
    let peer = startPeer(nil)
    let client = quietClient(peer)
    let far = client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(2_000)))
    let began = getTime()
    expect McpTimeoutError:
      discard waitFor client.sendRequest("tools/list", newJObject(),
        McpRequestOptions(timeoutMs: some(60)))
    check (getTime() - began).inMilliseconds < 1_000
    check not far.finished
    expect McpTimeoutError:
      discard waitFor far

  test "Given a limit of 0, when time passes, then the request waits on and is answered later":
    var held: JsonNode
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        held = message["id"])
    let client = quietClient(peer, timeoutMs = 0)
    let pending = client.sendRequest("tools/list", newJObject())
    untilTrue("the request to arrive", proc(): bool = not held.isNil)
    waitFor sleepAsync(400)
    check not pending.finished
    peer.reply(held, %*{"tools": []})
    check waitFor(pending).result.isSome

suite "the time limit of a subscription's acknowledgment":

  test "Given a listen with a 60 s limit, when the acknowledgment came, then the event loop has nothing pending within a short time":
    if not DefaultProtocolVersion.has(ftSubscriptionsListen):
      skip()  # a build whose default version has no subscriptions/listen
    else:
      let peer = startPeer(proc(peer: Peer, message: JsonNode) =
        if message{"method"}.getStr() == "subscriptions/listen":
          peer.push("notifications/subscriptions/acknowledged", %*{
            "_meta": {"io.modelcontextprotocol/subscriptionId": message["id"]},
            "notifications": {"toolsListChanged": true}}), modern = true)
      let client = quietClient(peer)
      let subscription = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      check subscription.acknowledged.isSome
      loopEmptiesSoon("the event loop to hold nothing after the acknowledgment")
