## `subscriptions/listen` of 2026-07-28 (basic/patterns/subscriptions): the
## server acknowledges, then delivers the notifications the client opted in
## to, each tagged with the subscription id, until either side ends the
## stream. Over stdio, over Streamable HTTP (the response stream of the
## request), and on both sides of the API.
##
## Message shapes follow the examples published with the specification
## (tests/fixtures/2026-07-28).

import std/[unittest, asyncdispatch, json, options, os, tables]
import ./server_harness
import ./client_peer
import ./loopback_transport
import client/client
import client/cancel_token
import client/client as clientMod
import client/subscriptions as clientSubs
import protocol/subscriptions
import transport/http
import transport/transport
import transport/http_server

const
  Fixtures = currentSourcePath().parentDir / "fixtures" / "2026-07-28"
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

proc idText(id: JsonNode): string =
  if id.kind == JString: id.getStr() else: $id

suite "subscriptions: the filter and the messages of the specification":

  test "Given the specification's listen request, when its filter is parsed, then the types and uris are read":
    let request = fixture("SubscriptionsListenRequest_listen-for-list-changes.json")
    let (filter, problem) = parseSubscriptionFilter(request["params"]["notifications"])
    check problem.isNone
    check filter.toolsListChanged
    check not filter.promptsListChanged
    check filter.resourceSubscriptions == @[Config]
    check filter.toJson() == request["params"]["notifications"]

  test "Given filters of the wrong shape, when parsed, then each is rejected":
    check parseSubscriptionFilter(nil).problem.isSome
    check parseSubscriptionFilter(%*[]).problem.isSome
    check parseSubscriptionFilter(%*{"toolsListChanged": "yes"}).problem.isSome
    check parseSubscriptionFilter(%*{"resourceSubscriptions": "file:///x"}).problem.isSome
    check parseSubscriptionFilter(%*{"resourceSubscriptions": [1]}).problem.isSome
    check parseSubscriptionFilter(%*{}).problem.isNone

  test "Given the specification's acknowledgment and graceful-closure examples, when built, then they are equal":
    let ack = fixture("SubscriptionsAcknowledgedNotification_listen-acknowledged.json")
    let honored = parseSubscriptionFilter(ack["params"]["notifications"]).filter
    check acknowledgementParams(%"listen-1", honored) == ack["params"]
    let closed = fixture("SubscriptionsListenResultResponse_listen-closed-response.json")
    check listenResult(%"listen-1") == closed["result"]

  test "Given a filter, when asked about notifications, then only the subscribed types and uris are wanted":
    let filter = SubscriptionFilter(toolsListChanged: true, resourceSubscriptions: @[Config])
    check filter.wants("notifications/tools/list_changed", nil)
    check not filter.wants("notifications/prompts/list_changed", nil)
    check filter.wants("notifications/resources/updated", %*{"uri": Config})
    check not filter.wants("notifications/resources/updated", %*{"uri": "file:///other"})
    check not filter.wants("notifications/message", nil)

  test "Given notification params, when the subscription id is read, then a string or an integer id is returned as text":
    check subscriptionIdOf(withSubscriptionId(nil, %"listen-1")) == some("listen-1")
    check subscriptionIdOf(withSubscriptionId(newJObject(), %7)) == some("7")
    check subscriptionIdOf(%*{"uri": "x"}).isNone

suite "subscriptions on the server (2026-07-28 only)":

  test "Given a listen request, when the server accepts it, then the acknowledgment is the first message and carries the subscription id":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%"listen-1", %*{"toolsListChanged": true, "resourceSubscriptions": [Config]})
      check t.sent[0].message["method"].getStr() == "notifications/subscriptions/acknowledged"
      check t.sent[0].related == "listen-1"
      let params = t.sent[0].message["params"]
      check params["_meta"]["io.modelcontextprotocol/subscriptionId"].getStr() == "listen-1"
      check params["notifications"]["toolsListChanged"].getBool()
      check params["notifications"]["resourceSubscriptions"][0].getStr() == Config
      check server.subscriptionCount == 1

  test "Given a type the server does not support, when it acknowledges, then that type is omitted":
    for v in versionsWith(ftSubscriptionsListen):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%1, %*{"toolsListChanged": true, "promptsListChanged": true,
                                "resourceSubscriptions": [Config]})
      check t.sent[0].message["params"]["notifications"] == newJObject()

  test "Given a numeric request id, when the server acknowledges, then the subscription id is that number":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%42, %*{"toolsListChanged": true})
      let id = t.sent[0].message["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"]
      check id.kind == JInt
      check id.getInt() == 42

  test "Given an open subscription, when the tool list changes, then the notification arrives on that stream tagged with its id":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%"l1", %*{"toolsListChanged": true})
      waitFor server.notifyToolListChanged()
      let sent = t.messagesOf("notifications/tools/list_changed")
      check sent.len == 1
      check sent[0].related == "l1"
      check sent[0].message["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].getStr() == "l1"

  test "Given an open subscription, when an extension notifies the subscribers, then the stream that wants it gets it tagged with its id":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%"l1", %*{"resourceSubscriptions": [Config]})
      waitFor server.notifySubscribers("notifications/resources/updated", %*{"uri": "file:///other"})
      waitFor server.notifySubscribers("notifications/resources/updated", %*{"uri": Config})
      let sent = t.messagesOf("notifications/resources/updated")
      check sent.len == 1
      check sent[0].related == "l1"
      check sent[0].message["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].getStr() == "l1"

  test "Given a subscription that did not ask for a type, when that type changes, then nothing is sent":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%"l1", %*{"toolsListChanged": true})
      waitFor server.notifyPromptListChanged()
      waitFor server.notifyResourceListChanged()
      waitFor server.notifyResourceUpdated(Config)
      check t.sent.len == 1

  test "Given a subscription to a resource uri, when that resource and another change, then only the named one is delivered":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%"l1", %*{"resourceSubscriptions": [Config]})
      waitFor server.notifyResourceUpdated("file:///other")
      waitFor server.notifyResourceUpdated(Config)
      let sent = t.messagesOf("notifications/resources/updated")
      check sent.len == 1
      check sent[0].message["params"]["uri"].getStr() == Config
      check sent[0].message["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].getStr() == "l1"

  test "Given two subscriptions, when a resource changes, then each stream gets its own notification with its own id":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.send(%"a", "subscriptions/listen", listenParams(%*{"resourceSubscriptions": [Config]}))
      peer.send(%"b", "subscriptions/listen", listenParams(%*{"resourceSubscriptions": [Config],
                                                              "toolsListChanged": true}))
      untilTrue("both acknowledgments", proc(): bool =
        t.messagesOf("notifications/subscriptions/acknowledged").len == 2)
      waitFor server.notifyResourceUpdated(Config)
      waitFor server.notifyToolListChanged()
      let updates = t.messagesOf("notifications/resources/updated")
      check updates.len == 2
      check updates[0].related != updates[1].related
      check t.messagesOf("notifications/tools/list_changed").len == 1
      check t.messagesOf("notifications/tools/list_changed")[0].related == "b"

  test "Given a tool call with progress, when it reports, then the notification belongs to the call and not to the subscription":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        await ctx.reportProgress(1)
        return %*{"content": []})
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%"l1", %*{"toolsListChanged": true})
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "t"}, meta = %*{"progressToken": "p"})
      discard t.responseTo(id)
      let progress = t.messagesOf("notifications/progress")
      check progress.len == 1
      check progress[0].related == id

  test "Given a client that cancels, when the cancellation arrives, then the subscription is gone and no response is sent":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%"l1", %*{"toolsListChanged": true})
      peer.notify("notifications/cancelled", %*{"requestId": "l1"})
      untilTrue("the subscription to end", proc(): bool = server.subscriptionCount == 0)
      waitFor server.notifyToolListChanged()
      settle()
      check t.messagesOf("notifications/tools/list_changed").len == 0
      for sent in t.sent:
        check not (sent.message.hasKey("id") and not sent.message.hasKey("method"))

  test "Given the transport reports the request abandoned, when the connection closes, then the subscription is gone":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%"l1", %*{"toolsListChanged": true})
      t.onRequestCancelled(peer.session, "l1")
      untilTrue("the subscription to end", proc(): bool = server.subscriptionCount == 0)

  test "Given open subscriptions, when the server ends them, then each request is answered with a graceful result and nothing more is sent":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      peer.listenAndWait(%"l1", %*{"toolsListChanged": true})
      waitFor server.endSubscriptions()
      let answer = t.responseTo("l1")
      check answer["result"]["resultType"].getStr() == "complete"
      check answer["result"]["_meta"]["io.modelcontextprotocol/subscriptionId"].getStr() == "l1"
      check t.messagesOf("notifications/cancelled").len == 0
      check server.subscriptionCount == 0
      waitFor server.notifyToolListChanged()
      check t.messagesOf("notifications/tools/list_changed").len == 0

  test "Given a stdio server, when it ends a subscription, then it sends notifications/cancelled for the request and then the graceful result":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let pair = newLoopbackPair()
      waitFor server.attachTransport(pair.server)
      pair.server.inject(%*{"jsonrpc": "2.0", "id": 5, "method": "subscriptions/listen",
        "params": {"_meta": modernMeta(), "notifications": {"toolsListChanged": true}}})
      untilTrue("the acknowledgment", proc(): bool = pair.server.sent.len == 1)
      waitFor server.endSubscriptions()
      untilTrue("the answer", proc(): bool = pair.server.sent.len == 3)
      check pair.server.sent[0]["method"].getStr() == "notifications/subscriptions/acknowledged"
      check pair.server.sent[1]["method"].getStr() == "notifications/cancelled"
      check pair.server.sent[1]["params"]["requestId"].getInt() == 5
      check pair.server.sent[2]["id"].getInt() == 5
      check pair.server.sent[2]["result"]["_meta"]["io.modelcontextprotocol/subscriptionId"].getInt() == 5

  test "Given a stdio server that ends its subscriptions twice in a row, when both calls return, then the stream was cancelled and answered once":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let pair = newLoopbackPair()
      waitFor server.attachTransport(pair.server)
      pair.server.inject(%*{"jsonrpc": "2.0", "id": 5, "method": "subscriptions/listen",
        "params": {"_meta": modernMeta(), "notifications": {"toolsListChanged": true}}})
      untilTrue("the acknowledgment", proc(): bool = pair.server.sent.len == 1)
      waitFor server.endSubscriptions()
      waitFor server.endSubscriptions()
      untilTrue("the answer", proc(): bool = pair.server.sent.len >= 3)
      settle()
      check pair.server.sent.len == 3
      check pair.server.sent[1]["method"].getStr() == "notifications/cancelled"
      check pair.server.sent[2]["id"].getInt() == 5

  test "Given a request without a usable notifications filter, when it arrives, then it is invalid params":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("subscriptions/listen").errorCode == -32602
      check peer.ask("subscriptions/listen", %*{"notifications": 5}).errorCode == -32602
      check peer.ask("subscriptions/listen",
        %*{"notifications": {"toolsListChanged": "yes"}}).errorCode == -32602
      check server.subscriptionCount == 0

  test "Given a version without subscriptions/listen, when it is requested, then it is method not found":
    for v in versionsWithout(ftSubscriptionsListen):
      let server = fullServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("subscriptions/listen", %*{"notifications": {"toolsListChanged": true}}).errorCode == -32601

  test "Given a legacy client subscribed to a resource, when the server notifies, then it gets the notification untagged":
    for v in versionsWithout(ftSubscriptionsListen):
      if not v.has(ftResourceSubscribe):
        continue
      let server = fullServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      discard peer.ask("resources/subscribe", %*{"uri": Config})
      waitFor server.notifyResourceUpdated(Config)
      let sent = t.messagesOf("notifications/resources/updated")
      check sent.len == 1
      check not sent[0].message["params"].hasKey("_meta")

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

  test "Given a modern server, when the client listens, then it sends the filter with the request metadata and returns after the acknowledgment":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      let sub = waitFor client.listen(SubscriptionFilter(
        toolsListChanged: true, promptsListChanged: true, resourceSubscriptions: @[Config]))
      let sent = peer.requestsFor("subscriptions/listen")[0]["params"]
      check sent["notifications"]["toolsListChanged"].getBool()
      check sent["notifications"]["resourceSubscriptions"][0].getStr() == Config
      check sent["_meta"].hasKey("io.modelcontextprotocol/protocolVersion")
      check sub.acknowledged.get.toolsListChanged
      check sub.unsupported().promptsListChanged
      check sub.unsupported().resourceSubscriptions == @[Config]
      check not sub.ended.finished
      check client.subscriptions.len == 1

  test "Given an open subscription, when notifications arrive, then the client's callbacks and the stream's callback see them":
    for v in versionsWith(ftSubscriptionsListen):
      var listenMessage: JsonNode
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        listenMessage = message
        acknowledge(peer, message, %*{"toolsListChanged": true, "resourceSubscriptions": [Config]}))
      let client = peer.connectedClient(v)
      var toolsChanged = 0
      var updated: seq[string]
      var onStream: seq[string]
      client.onToolsListChanged = proc() = inc toolsChanged
      client.onResourceUpdated = proc(uri: string) = updated.add uri
      let sub = waitFor client.listen(SubscriptionFilter(
        toolsListChanged: true, resourceSubscriptions: @[Config]))
      sub.onNotification = proc(methodName: string, params: JsonNode) = onStream.add methodName
      peer.push("notifications/tools/list_changed", tagged(listenMessage))
      peer.push("notifications/resources/updated", tagged(listenMessage, %*{"uri": Config}))
      untilTrue("the notifications", proc(): bool = onStream.len == 2)
      check toolsChanged == 1
      check updated == @[Config]
      check onStream == @["notifications/tools/list_changed", "notifications/resources/updated"]

  test "Given an open subscription without a callback of its own, when a notification arrives on it, then the client's callback still runs":
    for v in versionsWith(ftSubscriptionsListen):
      var listenMessage: JsonNode
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        listenMessage = message
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      var toolsChanged = 0
      client.onToolsListChanged = proc() = inc toolsChanged
      let sub = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      check sub.onNotification.isNil
      peer.push("notifications/tools/list_changed", tagged(listenMessage))
      untilTrue("the notification", proc(): bool = toolsChanged == 1)

  test "Given an acknowledged subscription, when a second acknowledgment arrives, then the first counts and the stream's callback does not see it":
    for v in versionsWith(ftSubscriptionsListen):
      var listenMessage: JsonNode
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        listenMessage = message
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      let sub = waitFor client.listen(SubscriptionFilter(
        toolsListChanged: true, promptsListChanged: true))
      var onStream: seq[string]
      sub.onNotification = proc(methodName: string, params: JsonNode) = onStream.add methodName
      acknowledge(peer, listenMessage, %*{"promptsListChanged": true})
      settle()
      check onStream.len == 0
      check sub.acknowledged.get.toolsListChanged
      check not sub.acknowledged.get.promptsListChanged

  test "Given a notification tagged with an unknown subscription id, when it arrives, then it is ignored":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      var toolsChanged = 0
      client.onToolsListChanged = proc() = inc toolsChanged
      discard waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      peer.push("notifications/tools/list_changed", %*{
        "_meta": {"io.modelcontextprotocol/subscriptionId": "nobody"}})
      settle()
      check toolsChanged == 0

  test "Given two subscriptions, when notifications arrive on each, then each stream's callback sees only its own":
    for v in versionsWith(ftSubscriptionsListen):
      var messages: seq[JsonNode]
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        messages.add message
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      var first, second = 0
      let a = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      let b = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      a.onNotification = proc(methodName: string, params: JsonNode) = inc first
      b.onNotification = proc(methodName: string, params: JsonNode) = inc second
      peer.push("notifications/tools/list_changed", tagged(messages[1]))
      untilTrue("the notification", proc(): bool = second == 1)
      check first == 0

  test "Given the server answers the listen request, when the response arrives, then the stream ended gracefully":
    for v in versionsWith(ftSubscriptionsListen):
      var listenMessage: JsonNode
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        listenMessage = message
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      let sub = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      peer.reply(listenMessage["id"], listenResult(listenMessage["id"]))
      waitFor sub.ended
      check sub.endedBy == some(sbGraceful)
      check client.subscriptions.len == 0

  test "Given a stdio server that cancels the stream, when notifications/cancelled arrives, then the stream ended by the server":
    for v in versionsWith(ftSubscriptionsListen):
      var listenMessage: JsonNode
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        listenMessage = message
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      let sub = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      peer.push("notifications/cancelled", %*{"requestId": listenMessage["id"]})
      waitFor sub.ended
      check sub.endedBy == some(sbServerCancelled)

  test "Given an open subscription, when notifications/cancelled arrives without a request id or with one that names nothing, then the stream stays open":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      let sub = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      peer.push("notifications/cancelled", newJObject())
      peer.push("notifications/cancelled", %*{"requestId": true})
      peer.push("notifications/cancelled", %*{"requestId": 0})
      settle()
      check not sub.ended.finished
      check client.subscriptions.len == 1

  test "Given an open subscription on stdio, when the client cancels it, then notifications/cancelled names the request and the stream ends":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      let sub = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      waitFor sub.cancel("not needed")
      check sub.endedBy == some(sbCancelled)
      check sub.ended.finished
      settle()
      let cancelled = peer.requestsFor("notifications/cancelled")
      check cancelled.len == 1
      check cancelled[0]["params"]["requestId"].getStr() == sub.id
      check client.subscriptions.len == 0

  test "Given an open subscription over HTTP, when the client cancels it, then the transport is asked once to close the stream and no notification is sent":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "subscriptions/listen":
          acknowledge(peer, message, %*{"toolsListChanged": true}),
        modern = true, kind = mtkStreamable)
      let client = peer.connectedClient(v)
      let sub = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      waitFor sub.cancel("not needed")
      settle()
      check sub.endedBy == some(sbCancelled)
      check peer.pair.client.cancelRequested == @[sub.id]
      check peer.requestsFor("notifications/cancelled").len == 0

  test "Given a listen and a request that share one token, when it is cancelled, then both end at once with McpCancelledError":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) = discard)
      let client = peer.connectedClient(v)
      let token = newMcpCancelToken()
      let options = McpRequestOptions(cancel: token, timeoutMs: some(1000))
      let listening = client.listen(SubscriptionFilter(toolsListChanged: true), options)
      let request = client.sendRequest("tools/list", newJObject(), options)
      waitFor sleepAsync(5)
      token.cancel("stop both")
      # Well before the timeout: see the same test for two requests.
      waitFor sleepAsync(50)
      check listening.finished
      check request.finished
      expect McpCancelledError:
        discard waitFor listening
      expect McpCancelledError:
        discard waitFor request
      check client.subscriptions.len == 0

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

  test "Given a server that rejects the listen request, when the client listens, then it raises McpRequestError":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        peer.replyError(message["id"], -32602, "bad filter"))
      let client = peer.connectedClient(v)
      expect clientMod.McpRequestError:
        discard waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      check client.subscriptions.len == 0

  test "Given a server that never acknowledges, when the timeout passes, then the client raises McpTimeoutError and cancels":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) = discard)
      let client = peer.connectedClient(v)
      expect McpTimeoutError:
        discard waitFor client.listen(SubscriptionFilter(toolsListChanged: true),
          McpRequestOptions(timeoutMs: some(40)))
      check client.subscriptions.len == 0
      check peer.requestsFor("notifications/cancelled").len == 1

  test "Given an acknowledgment that is malformed, when it arrives, then the client raises McpProtocolError and cancels":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        acknowledge(peer, message, %*{"toolsListChanged": "yes"}))
      let client = peer.connectedClient(v)
      expect McpProtocolError:
        discard waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      check client.subscriptions.len == 0

  test "Given the transport fails while listening, when the stream breaks, then it ended lost":
    for v in versionsWith(ftSubscriptionsListen):
      let peer = listenPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        acknowledge(peer, message, %*{"toolsListChanged": true}))
      let client = peer.connectedClient(v)
      let sub = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      waitFor peer.pair.client.close()
      waitFor sub.ended
      check sub.endedBy == some(sbLost)

  test "Given a version without subscriptions/listen, when the client listens, then it raises McpUnsupportedError and sends nothing":
    for v in versionsWithout(ftSubscriptionsListen):
      let peer = startPeer(nil)
      let client = peer.connectedClient(v)
      expect McpUnsupportedError:
        discard waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      check peer.requestsFor("subscriptions/listen").len == 0

suite "subscriptions end to end":

  test "Given a client and a server over stdio-style transport, when the tool list changes and the server shuts down, then the client is told and the stream ends gracefully":
    for v in versionsWith(ftSubscriptionsListen):
      let server = fullServer()
      let pair = newLoopbackPair()
      waitFor server.attachTransport(pair.server)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      waitFor client.connect(pair.client)
      var changed = 0
      client.onToolsListChanged = proc() = inc changed
      let sub = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      waitFor server.notifyToolListChanged()
      untilTrue("the notification", proc(): bool = changed == 1)
      waitFor server.endSubscriptions()
      waitFor sub.ended
      check sub.endedBy.isSome
      check sub.endedBy.get in {sbGraceful, sbServerCancelled}
      check server.subscriptionCount == 0

  test "Given a client and a server over Streamable HTTP, when the tool list changes, then it arrives on the response stream, and cancelling closes the subscription":
    for v in versionsWith(ftSubscriptionsListen):
      let transport = newHttpServerTransport(port = 0, protocolVersion = v)
      transport.listen()
      asyncCheck transport.serve()
      let server = fullServer()
      waitFor server.attachTransport(transport)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      waitFor client.connect(newStreamableHttpTransport(
        "http://127.0.0.1:" & $transport.port & "/mcp"))
      var changed = 0
      var updatedUris: seq[string]
      client.onToolsListChanged = proc() = inc changed
      client.onResourceUpdated = proc(uri: string) = updatedUris.add uri
      let sub = waitFor client.listen(SubscriptionFilter(
        toolsListChanged: true, resourceSubscriptions: @[Config]))
      check server.subscriptionCount == 1
      waitFor server.notifyToolListChanged()
      waitFor server.notifyResourceUpdated(Config)
      untilTrue("the notifications", proc(): bool = changed == 1 and updatedUris.len == 1)
      check updatedUris == @[Config]
      waitFor sub.cancel()
      untilTrue("the server to drop the subscription", proc(): bool = server.subscriptionCount == 0)
      check transport.pendingExchangeCount == 0
      waitFor client.close()
      waitFor transport.close()

  test "Given a client over Streamable HTTP, when the server ends the subscription, then the client sees a graceful end":
    for v in versionsWith(ftSubscriptionsListen):
      let transport = newHttpServerTransport(port = 0, protocolVersion = v)
      transport.listen()
      asyncCheck transport.serve()
      let server = fullServer()
      waitFor server.attachTransport(transport)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      waitFor client.connect(newStreamableHttpTransport(
        "http://127.0.0.1:" & $transport.port & "/mcp"))
      let sub = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      waitFor server.endSubscriptions()
      waitFor sub.ended
      check sub.endedBy == some(sbGraceful)
      waitFor client.close()
      waitFor transport.close()
