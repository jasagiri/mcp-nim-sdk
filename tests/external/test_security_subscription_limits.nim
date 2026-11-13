## One session of a server cannot make it keep any number of resource
## subscriptions or subscriptions/listen streams.

import std/[unittest, json, options, strutils]
import ./server_harness

proc resourceServer(): McpServer =
  newServer(McpServerCapabilities(
    tools: some(McpToolsCapability(listChanged: true)),
    resources: some(McpResourcesCapability(subscribe: true, listChanged: true))))

proc answered(t: SessionedTransport, id: string): bool =
  ## Whether a response to `id` has been sent (responseTo waits for one).
  for sent in t.sent:
    if not sent.message.hasKey("method") and sent.message{"id"}.getStr() == id:
      return true

proc tooMany(answer: JsonNode): bool =
  answer.hasKey("error") and answer["error"]["code"].getInt() == -32603 and
    "too many" in answer["error"]["message"].getStr().toLowerAscii()

suite "one session cannot hold any number of subscriptions or listen streams":

  test "Given a limit of 2 subscriptions, when a session subscribes to a third resource, then it is refused; again to one it holds, or after giving one up, it is not":
    for v in versionsWith(ftResourceSubscribe):
      checkpoint $v
      let server = resourceServer()
      server.maxSubscriptionsPerSession = 2
      let t = server.attach()
      let a = server.connect(t, v, session = "a")
      let b = server.connect(t, v, session = "b")
      check not a.ask("resources/subscribe", %*{"uri": "file:///1"}).hasKey("error")
      check not a.ask("resources/subscribe", %*{"uri": "file:///2"}).hasKey("error")
      check a.ask("resources/subscribe", %*{"uri": "file:///3"}).tooMany
      check not a.ask("resources/subscribe", %*{"uri": "file:///1"}).hasKey("error")
      check not b.ask("resources/subscribe", %*{"uri": "file:///3"}).hasKey("error")
      check not a.ask("resources/unsubscribe", %*{"uri": "file:///1"}).hasKey("error")
      check not a.ask("resources/subscribe", %*{"uri": "file:///3"}).hasKey("error")

  test "Given a limit of 2 listen streams, when a session opens a third, then it is refused, and another session may open one":
    for v in versionsWith(ftSubscriptionsListen):
      checkpoint $v
      let server = resourceServer()
      server.maxListenStreamsPerSession = 2
      let t = server.attach()
      let a = server.connect(t, v, session = "a")
      let b = server.connect(t, v, session = "b")
      for id in ["l1", "l2", "l3"]:
        a.send(%id, "subscriptions/listen", %*{"notifications": {"toolsListChanged": true}})
      check t.responseTo("l3").tooMany
      check not t.answered("l1")
      check not t.answered("l2")
      check server.subscriptionCount == 2
      b.send(%"m1", "subscriptions/listen", %*{"notifications": {"toolsListChanged": true}})
      untilTrue("the second session's stream", proc(): bool = server.subscriptionCount == 3)
      check not t.answered("m1")

  test "Given no limits given, when the server is made, then 1024 subscriptions and 16 listen streams per session; 0 means no limit":
    check DefaultMaxSubscriptionsPerSession == 1024
    check DefaultMaxListenStreamsPerSession == 16
    let server = resourceServer()
    check server.maxSubscriptionsPerSession == 1024
    check server.maxListenStreamsPerSession == 16

  test "Given both limits set to 0, when one session opens 17 listen streams and subscribes to resources, then none is refused":
    for v in versionsWith(ftSubscriptionsListen):
      checkpoint $v
      let server = resourceServer()
      server.maxListenStreamsPerSession = 0
      server.maxSubscriptionsPerSession = 0
      let t = server.attach()
      let a = server.connect(t, v, session = "a")
      for n in 1 .. DefaultMaxListenStreamsPerSession + 1:
        a.send(%("l" & $n), "subscriptions/listen", %*{"notifications": {"toolsListChanged": true}})
      untilTrue("all the streams", proc(): bool =
        server.subscriptionCount == DefaultMaxListenStreamsPerSession + 1)
      for n in 1 .. DefaultMaxListenStreamsPerSession + 1:
        check not t.answered("l" & $n)
    for v in versionsWith(ftResourceSubscribe):
      checkpoint $v
      let server = resourceServer()
      server.maxListenStreamsPerSession = 0
      server.maxSubscriptionsPerSession = 0
      let t = server.attach()
      let a = server.connect(t, v, session = "a")
      for n in 1 .. 3:
        check not a.ask("resources/subscribe", %*{"uri": "file:///" & $n}).hasKey("error")
