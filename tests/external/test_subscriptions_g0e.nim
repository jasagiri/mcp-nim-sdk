## subscriptions/listen of 2026-07-28 (basic/patterns/subscriptions): messages
## of other subscriptions may come before an acknowledgment on stdio, and a
## subscription does not outlive its connection.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness
import ./client_peer
import ./loopback_transport
import client/client
import client/subscriptions as clientSubs
import protocol/subscriptions

proc acknowledge(peer: client_peer.Peer, id: JsonNode, honored: JsonNode) =
  peer.push("notifications/subscriptions/acknowledged", %*{
    "_meta": {"io.modelcontextprotocol/subscriptionId": id},
    "notifications": honored})

proc tagged(id: JsonNode): JsonNode =
  %*{"_meta": {"io.modelcontextprotocol/subscriptionId": id}}

suite "an acknowledgment that comes after messages of other subscriptions (stdio)":

  test "Given two subscriptions on one channel, when a message of the first comes before the acknowledgment of the second, then the second is acknowledged and the message stays with the first":
    for v in versionsWith(ftSubscriptionsListen):
      var ids: seq[JsonNode]
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "subscriptions/listen":
          ids.add message["id"]
          if ids.len == 2:
            peer.push("notifications/tools/list_changed", tagged(ids[0]))
          acknowledge(peer, message["id"], %*{"toolsListChanged": true}),
        modern = true)
      let client = peer.connectedClient(v)
      let first = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      var onFirst, onSecond = 0
      first.onNotification = proc(methodName: string, params: JsonNode) = inc onFirst
      let second = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      second.onNotification = proc(methodName: string, params: JsonNode) = inc onSecond
      check second.acknowledged.isSome
      check second.acknowledged.get.toolsListChanged
      untilTrue("the message of the first subscription", proc(): bool = onFirst == 1)
      check onSecond == 0
      peer.push("notifications/tools/list_changed", tagged(ids[1]))
      untilTrue("the message of the second subscription", proc(): bool = onSecond == 1)
      check onFirst == 1

suite "a subscription does not outlive its connection":

  test "Given an open subscription, when the connection ends and another is made, then the client listens again only when asked to and the first subscription was lost":
    for v in versionsWith(ftSubscriptionsListen):
      let handler = proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "subscriptions/listen":
          acknowledge(peer, message["id"], %*{"toolsListChanged": true})
      let before = startPeer(handler, modern = true)
      let oldClient = before.connectedClient(v)
      let lost = waitFor oldClient.listen(SubscriptionFilter(toolsListChanged: true))
      before.pair.client.endStream()
      waitFor lost.ended
      check lost.endedBy == some(sbLost)
      settle()
      check before.requestsFor("subscriptions/listen").len == 1
      let after = startPeer(handler, modern = true)
      let newClient = after.connectedClient(v)
      check after.requestsFor("subscriptions/listen").len == 0
      let again = waitFor newClient.listen(SubscriptionFilter(toolsListChanged: true))
      check after.requestsFor("subscriptions/listen").len == 1
      check again.acknowledged.isSome

  test "Given an open subscription on a server, when the connection is lost, then the server holds nothing of it":
    for v in versionsWith(ftSubscriptionsListen):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability(listChanged: true))))
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.send(%"l1", "subscriptions/listen", %*{"notifications": {"toolsListChanged": true}})
      untilTrue("the acknowledgment", proc(): bool =
        t.messagesOf("notifications/subscriptions/acknowledged").len > 0)
      check server.subscriptionCount == 1
      t.hangUp()
      untilTrue("the subscription to go", proc(): bool = server.subscriptionCount == 0)
