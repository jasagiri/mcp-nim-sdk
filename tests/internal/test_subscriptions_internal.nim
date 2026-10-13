## `subscriptions/listen` of 2026-07-28 (basic/patterns/subscriptions): the
## server acknowledges, then delivers the notifications the client opted in
## to, each tagged with the subscription id, until either side ends the
## stream. Over stdio, over Streamable HTTP (the response stream of the
## request), and on both sides of the API.
##
## Message shapes follow the examples published with the specification
## (tests/fixtures/2026-07-28).

import std/[unittest, asyncdispatch, json, options, os]
import ../external/server_harness
import ../external/client_peer
import client/client
import client/cancel_token
import client/client as clientMod
import client/subscriptions as clientSubs
import protocol/subscriptions

const
  Fixtures = currentSourcePath().parentDir.parentDir / "fixtures" / "2026-07-28"
  Config = "file:///project/config.json"

proc fixture(name: string): JsonNode =
  parseJson(readFile(Fixtures / name))

proc fullServer(): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability(listChanged: true)),
    prompts: some(McpPromptsCapability(listChanged: true)),
    resources: some(McpResourcesCapability(subscribe: true, listChanged: true))))

proc listenParams(notifications: JsonNode): JsonNode =
  %*{"notifications": notifications}

proc listenAndWait(peer: server_harness.Peer, id: JsonNode, notifications: JsonNode) =
  peer.send(id, "subscriptions/listen", listenParams(notifications))
  untilTrue("the acknowledgment", proc(): bool =
    peer.transport.messagesOf("notifications/subscriptions/acknowledged").len > 0)


suite "subscriptions on the client":

  proc listenPeer(replies: proc(peer: client_peer.Peer, message: JsonNode)): client_peer.Peer =
    startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      if message{"method"}.getStr() == "subscriptions/listen":
        replies(peer, message), modern = true)

  proc acknowledge(peer: client_peer.Peer, message: JsonNode, honored: JsonNode) =
    peer.push("notifications/subscriptions/acknowledged", %*{
      "_meta": {"io.modelcontextprotocol/subscriptionId": message["id"]},
      "notifications": honored})

  proc tagged(message: JsonNode, extra: JsonNode = nil): JsonNode =
    result = %*{"_meta": {"io.modelcontextprotocol/subscriptionId": message["id"]}}
    if not extra.isNil:
      for key, value in extra.pairs:
        result[key] = value


  # An internal-implementation test (I): see the same kind of test in
  # test_client_requests.nim.
  test "Given a token used for several listens that were acknowledged, when they are done, then the token holds nothing of them":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      let token = newMcpCancelToken()
      let options = McpRequestOptions(cancel: token)
      for _ in 0 ..< 3:
        discard waitFor client.listen(SubscriptionFilter(toolsListChanged: true), options)
      check token.heldWaiters == 0

