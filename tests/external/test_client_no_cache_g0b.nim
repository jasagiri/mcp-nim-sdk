## A 2026-07-28 client keeps no cache of results: whatever ttlMs a result
## carries, the next request is sent.

import std/[unittest, asyncdispatch, json, options]
import client/client
import client/tools
import client/resources
import ./client_peer

var served: seq[string]

proc cachingHintsPeer(): Peer =
  served = @[]
  startPeer(proc(peer: Peer, message: JsonNode) =
    case message{"method"}.getStr()
    of "tools/list":
      peer.reply(message["id"], %*{"resultType": "complete", "ttlMs": 600000,
        "cacheScope": "public", "tools": [{"name": "t", "inputSchema": {"type": "object"}}]})
    of "resources/read":
      let uri = message["params"]["uri"].getStr()
      served.add uri
      peer.reply(message["id"], %*{"resultType": "complete", "ttlMs": 600000,
        "cacheScope": "public", "contents": [{"uri": uri, "text": "body of " & uri}]})
    else: discard, modern = true, capabilities = %*{"tools": {}, "resources": {}})

if SpeaksModern:
  suite "a client and results that say how long they stay fresh":

    test "Given a list result fresh for ten minutes, when the client lists again, then the second request is sent":
      let peer = cachingHintsPeer()
      let client = peer.connectedClient()
      discard waitFor client.listTools()
      discard waitFor client.listTools()
      check peer.requestsFor("tools/list").len == 2

    test "Given a list result fresh for ten minutes, when the client lists with a cursor, then the request is sent and the first page is not served for it":
      let peer = cachingHintsPeer()
      let client = peer.connectedClient()
      discard waitFor client.listTools()
      discard waitFor client.listTools(some("next"))
      let requests = peer.requestsFor("tools/list")
      check requests.len == 2
      check not requests[0]["params"].hasKey("cursor")
      check requests[1]["params"]["cursor"].getStr() == "next"

    test "Given two resources read in turn, when the client reads another uri, then each answer is its own and each request is sent":
      let peer = cachingHintsPeer()
      let client = peer.connectedClient()
      let a = waitFor client.readResource("file:///a")
      let b = waitFor client.readResource("file:///b")
      check a[0].text == some("body of file:///a")
      check b[0].text == some("body of file:///b")
      discard waitFor client.readResource("file:///a")
      check served == @["file:///a", "file:///b", "file:///a"]

    test "Given the same request carrying requestState sent twice, when the client sends it, then both are sent":
      let peer = cachingHintsPeer()
      let client = peer.connectedClient()
      for _ in 1 .. 2:
        discard waitFor client.sendRequest("resources/read",
          %*{"uri": "file:///a", "requestState": "s1"})
      check served == @["file:///a", "file:///a"]
