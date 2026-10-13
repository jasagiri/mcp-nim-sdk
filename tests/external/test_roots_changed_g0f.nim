## A client tells the server its roots changed (notifications/roots/list_changed,
## client/roots of 2025-06-18 and 2025-11-25); "the server should then request
## an updated list of roots". What the SDK gives a server to do that: the
## notification reaches the application's handler with its session, and
## `listRoots` asks that client again.

import std/[unittest, asyncdispatch, json]
import ./server_harness

const Roots = "notifications/roots/list_changed"

let WithRoots = %*{"roots": {"listChanged": true}}

type Heard = ref object
  ## What the server's handler of the notification learned.
  lists: seq[seq[string]]
  failed: seq[string]

proc watching(heard: Heard): McpServer =
  result = newServer(McpServerCapabilities())
  let server = result
  server.registerNotificationHandler(Roots,
    proc(notification: JsonRpcNotification): Future[void] {.async.} =
      try:
        var uris: seq[string]
        for root in await server.listRoots(notification.session):
          uris.add root["uri"].getStr()
        heard.lists.add uris
      except CatchableError as e:
        heard.failed.add e.msg)

proc awaitRequests(t: SessionedTransport, session: string, count: int): seq[Sent] =
  untilTrue("the server's roots/list " & $count, proc(): bool =
    var found = 0
    for s in t.messagesOf("roots/list"):
      if s.session == session: inc found
    found >= count)
  for s in t.messagesOf("roots/list"):
    if s.session == session:
      result.add s

proc answer(t: SessionedTransport, asked: Sent, uris: openArray[string]) =
  let roots = newJArray()
  for uri in uris:
    roots.add %*{"uri": uri, "name": uri}
  t.inject(asked.session, %*{"jsonrpc": "2.0", "id": asked.message["id"],
                             "result": {"roots": roots}})

suite "The server asks again after the roots changed (before 2026-07-28)":
  test "Given a client with roots, when it says its roots changed, then the server asks that client for the list and its handler gets the new one":
    for v in versionsWith(ftRoots):
      if isModern(v): continue
      let heard = Heard()
      let server = watching(heard)
      let t = server.attach()
      discard server.connect(t, v, session = "a", clientCapabilities = WithRoots)
      discard server.connect(t, v, session = "b", clientCapabilities = WithRoots)
      t.inject("a", rpcNotification(Roots, newJObject()))
      let asked = t.awaitRequests("a", 1)
      t.answer(asked[0], ["file:///new-project"])
      untilTrue("the handler to finish", proc(): bool = heard.lists.len == 1)
      check heard.lists == @[@["file:///new-project"]]
      check t.messagesOf("roots/list").len == 1   # only the client that changed was asked
      check heard.failed.len == 0

  test "Given a client that says its roots changed twice, when each is answered, then the second answer is the list the handler gets":
    for v in versionsWith(ftRoots):
      if isModern(v): continue
      let heard = Heard()
      let server = watching(heard)
      let t = server.attach()
      discard server.connect(t, v, session = "a", clientCapabilities = WithRoots)
      t.inject("a", rpcNotification(Roots, newJObject()))
      t.answer(t.awaitRequests("a", 1)[0], ["file:///one"])
      untilTrue("the first list", proc(): bool = heard.lists.len == 1)
      t.inject("a", rpcNotification(Roots, newJObject()))
      t.answer(t.awaitRequests("a", 2)[1], ["file:///one", "file:///two"])
      untilTrue("the second list", proc(): bool = heard.lists.len == 2)
      check heard.lists == @[@["file:///one"], @["file:///one", "file:///two"]]
