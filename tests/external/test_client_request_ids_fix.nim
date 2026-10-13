## A request id is not used twice: not while its request is in flight (every
## version) and, before 2026-07-28, not at all in the session. The set of
## ids the client remembers for that is bounded.

import std/[unittest, asyncdispatch, json, strutils]
import client/client
import protocol/types
import ./client_peer

proc refused(client: McpClient, id: string): bool =
  try:
    discard waitFor client.startRequest("tools/list", newJObject(), id)
  except ValueError:
    return true

proc idsOnWire(peer: Peer, id: string): int =
  for request in peer.requestsFor("tools/list"):
    if request["id"].getStr() == id:
      inc result

suite "a client does not reuse a request id":

  test "Given a request in flight under a chosen id, when another is started under the same id, then the second is refused and only one is on the wire":
    for v in SupportedProtocolVersions:
      let peer = startPeer(nil, modern = isModern(v))
      let client = peer.connectedClient(v)
      discard waitFor client.startRequest("tools/list", newJObject(), "same-id")
      check client.refused("same-id")
      check peer.idsOnWire("same-id") == 1

  test "Given a request answered under a chosen id, when another is started under it in a version before 2026-07-28, then it is refused and not sent":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let peer = startPeer(nil)
      let client = peer.connectedClient(v)
      let first = waitFor client.startRequest("tools/list", newJObject(), "once")
      peer.reply(%"once", %*{"tools": []})
      discard waitFor first.response
      check client.refused("once")
      check peer.idsOnWire("once") == 1

  test "Given a request answered under a chosen id, when another is started under it in 2026-07-28, then it is sent":
    for v in SupportedProtocolVersions:
      if not isModern(v): continue
      let peer = startPeer(nil, modern = true)
      let client = peer.connectedClient(v)
      let first = waitFor client.startRequest("tools/list", newJObject(), "once")
      peer.reply(%"once", %*{"resultType": "complete", "tools": []})
      discard waitFor first.response
      discard waitFor client.startRequest("tools/list", newJObject(), "once")
      check peer.idsOnWire("once") == 2

  test "Given ids the client makes, when many requests are started, then none is refused and none repeats":
    for v in SupportedProtocolVersions:
      let peer = startPeer(nil, modern = isModern(v))
      let client = peer.connectedClient(v)
      var seen: seq[string]
      for n in 1 .. 20:
        let started = waitFor client.startRequest("tools/list", newJObject())
        check started.id notin seen
        seen.add started.id

  test "Given a session that chose MaxChosenRequestIds ids, when it chooses another, then it is refused and the ids before it still are":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let peer = startPeer(nil)
      let client = peer.connectedClient(v)
      for n in 1 .. MaxChosenRequestIds:
        discard waitFor client.startRequest("tools/list", newJObject(), "id-" & $n)
      check client.refused("one-too-many")
      check client.refused("id-1")
      check peer.idsOnWire("one-too-many") == 0

  test "Given an id longer than the limit, when a request is started under it before 2026-07-28, then it is refused":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let peer = startPeer(nil)
      let client = peer.connectedClient(v)
      check client.refused('x'.repeat(MaxChosenRequestIdBytes + 1))
      discard waitFor client.startRequest("tools/list", newJObject(), 'x'.repeat(MaxChosenRequestIdBytes))
