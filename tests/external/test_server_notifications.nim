## Notifications from the server to the right sessions: resource
## subscriptions and updates, list_changed.

import std/[unittest, asyncdispatch, json, options, algorithm]
import transport/transport
import ./server_harness

const Legacy = DefaultProtocolVersion.min(mpv20251125)

proc resourceServer(subscribe = true, listChanged = true): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability(listChanged: listChanged)),
    prompts: some(McpPromptsCapability(listChanged: listChanged)),
    resources: some(McpResourcesCapability(subscribe: subscribe, listChanged: listChanged))))

proc updatesTo(t: SessionedTransport, session: string): seq[string] =
  for s in t.messagesOf("notifications/resources/updated"):
    if s.session == session:
      result.add s.message["params"]["uri"].getStr()

suite "resource subscriptions (before 2026-07-28)":

  test "Given a subscription, when the resource is updated, then the subscriber is told with the uri":
    for v in versionsWith(ftResourceSubscribe):
      let server = resourceServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      check not peer.ask("resources/subscribe", %*{"uri": "file:///a"}).hasKey("error")
      waitFor server.notifyResourceUpdated("file:///a")
      check t.updatesTo("") == @["file:///a"]

  test "Given a subscription to one resource, when another is updated, then nothing is sent":
    let server = resourceServer()
    let t = server.attach()
    let peer = server.connect(t, Legacy)
    discard peer.ask("resources/subscribe", %*{"uri": "file:///a"})
    waitFor server.notifyResourceUpdated("file:///b")
    check t.updatesTo("").len == 0

  test "Given an unsubscribe, when the resource is updated, then nothing is sent":
    let server = resourceServer()
    let t = server.attach()
    let peer = server.connect(t, Legacy)
    discard peer.ask("resources/subscribe", %*{"uri": "file:///a"})
    check not peer.ask("resources/unsubscribe", %*{"uri": "file:///a"}).hasKey("error")
    waitFor server.notifyResourceUpdated("file:///a")
    check t.updatesTo("").len == 0

  test "Given two clients and one subscription, when the resource is updated, then only the subscriber is told":
    let server = resourceServer()
    let t = server.attach()
    let a = server.connect(t, Legacy, session = "a")
    discard server.connect(t, Legacy, session = "b")
    discard a.ask("resources/subscribe", %*{"uri": "file:///a"})
    waitFor server.notifyResourceUpdated("file:///a")
    check t.updatesTo("a") == @["file:///a"]
    check t.updatesTo("b").len == 0

  test "Given a client that ends its session, when the resource is updated, then it is not told":
    let server = resourceServer()
    let t = server.attach()
    let a = server.connect(t, Legacy, session = "a")
    discard a.ask("resources/subscribe", %*{"uri": "file:///a"})
    server.endSession("a")
    waitFor server.notifyResourceUpdated("file:///a")
    check t.updatesTo("a").len == 0

  test "Given a handler for subscriptions, when a client subscribes and unsubscribes, then the handler hears of both":
    let server = resourceServer()
    var heard: seq[string]
    server.onResourceSubscribe(proc(ctx: McpRequestContext, uri: string): Future[void] {.async.} =
      heard.add "+" & uri)
    server.onResourceUnsubscribe(proc(ctx: McpRequestContext, uri: string): Future[void] {.async.} =
      heard.add "-" & uri)
    let peer = server.connect(server.attach(), Legacy)
    discard peer.ask("resources/subscribe", %*{"uri": "file:///a"})
    discard peer.ask("resources/unsubscribe", %*{"uri": "file:///a"})
    check heard == @["+file:///a", "-file:///a"]

  test "Given a handler that refuses the resource, when a client subscribes, then it gets the error and no subscription":
    let server = resourceServer()
    server.onResourceSubscribe(proc(ctx: McpRequestContext, uri: string): Future[void] {.async.} =
      raise newResourceNotFound(uri))
    let t = server.attach()
    let peer = server.connect(t, Legacy)
    check peer.ask("resources/subscribe", %*{"uri": "file:///a"}).errorCode == -32002
    check server.subscribersOf("file:///a").len == 0

  test "Given a server without the subscribe capability, when a client subscribes, then the method is not found":
    for v in versionsWith(ftResourceSubscribe):
      let server = resourceServer(subscribe = false)
      let peer = server.connect(server.attach(), v)
      check peer.ask("resources/subscribe", %*{"uri": "file:///a"}).errorCode == -32601

  test "Given a subscribe without a uri, when it is sent, then the answer is invalid params":
    let server = resourceServer()
    let peer = server.connect(server.attach(), Legacy)
    check peer.ask("resources/subscribe", %*{}).errorCode == -32602

  test "Given a client that has not initialized, when it subscribes, then the answer is invalid request":
    let server = resourceServer()
    let t = server.attach()
    let id = freshId()
    t.inject("", rpcRequest(id, "resources/subscribe", %*{"uri": "file:///a"}))
    check t.responseTo(id).errorCode == -32600

if isModern(DefaultProtocolVersion):
  suite "resource subscriptions in 2026-07-28":

    test "Given a 2026-07-28 client, when it subscribes, then the method is not found":
      let server = resourceServer()
      let peer = server.connect(server.attach(), mpv20260728)
      check peer.ask("resources/subscribe", %*{"uri": "file:///a"}).errorCode == -32601
      check peer.ask("resources/unsubscribe", %*{"uri": "file:///a"}).errorCode == -32601

suite "list_changed":

  test "Given two initialized clients, when the tool list changes, then each is told on its own session":
    let server = resourceServer()
    let t = server.attach()
    discard server.connect(t, Legacy, session = "a")
    discard server.connect(t, Legacy, session = "b")
    waitFor server.notifyToolListChanged()
    let sent = t.messagesOf("notifications/tools/list_changed")
    check sent.len == 2
    check @[sent[0].session, sent[1].session].sorted == @["a", "b"]

  test "Given resources, prompts and tools, when each list changes, then each notification has its method":
    let server = resourceServer()
    let t = server.attach()
    discard server.connect(t, Legacy)
    waitFor server.notifyToolListChanged()
    waitFor server.notifyPromptListChanged()
    waitFor server.notifyResourceListChanged()
    check t.messagesOf("notifications/tools/list_changed").len == 1
    check t.messagesOf("notifications/prompts/list_changed").len == 1
    check t.messagesOf("notifications/resources/list_changed").len == 1

  test "Given a server that did not declare listChanged, when a list changes, then nothing is sent":
    let server = resourceServer(listChanged = false)
    let t = server.attach()
    discard server.connect(t, Legacy)
    waitFor server.notifyToolListChanged()
    waitFor server.notifyPromptListChanged()
    waitFor server.notifyResourceListChanged()
    check t.messagesOf("notifications/tools/list_changed").len == 0
    check t.messagesOf("notifications/prompts/list_changed").len == 0
    check t.messagesOf("notifications/resources/list_changed").len == 0

  test "Given a client that has not sent initialized, when a list changes, then it is not told":
    let server = resourceServer()
    let t = server.attach()
    let id = freshId()
    t.inject("a", rpcRequest(id, "initialize", %*{
      "protocolVersion": $Legacy, "capabilities": {}, "clientInfo": {"name": "c", "version": "1"}}))
    discard t.responseTo(id)
    waitFor server.notifyToolListChanged()
    check t.messagesOf("notifications/tools/list_changed").len == 0

  test "Given a client whose transport fails, when a list changes, then the others are still told and the failure is raised":
    let server = resourceServer()
    let t = server.attach()
    discard server.connect(t, Legacy, session = "a")
    discard server.connect(t, Legacy, session = "b")
    t.failFor = "a"
    var raised = false
    try:
      waitFor server.notifyToolListChanged()
    except McpTransportError:
      raised = true
    check raised
    check t.messagesOf("notifications/tools/list_changed").len == 1
    check t.messagesOf("notifications/tools/list_changed")[0].session == "b"
