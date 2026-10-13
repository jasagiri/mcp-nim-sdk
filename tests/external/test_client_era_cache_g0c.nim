## A client settles which era a server speaks when it connects and keeps
## that for the connection: it does not probe again for each request.

import std/[unittest, asyncdispatch, json]
import client/client
import client/tools
import ./client_peer

proc listing(peer: Peer, message: JsonNode) =
  if message{"method"}.getStr() == "tools/list":
    peer.reply(message["id"], %*{"tools": []})

proc listThrice(client: McpClient) =
  for _ in 1 .. 3:
    discard waitFor client.listTools()

if SpeaksModern:
  suite "the era of a server is settled once per connection (2026-07-28 client)":

    test "Given a 2026-07-28 server, when the client makes three requests after connecting, then it probed with server/discover once and never initialized":
      let peer = startPeer(listing, modern = true)
      let client = peer.connectedClient()
      listThrice(client)
      check peer.requestsFor("server/discover").len == 1
      check peer.requestsFor("initialize").len == 0
      check peer.requestsFor("tools/list").len == 3

    test "Given a legacy server, when the client makes three requests after connecting, then it probed and initialized once each and sent no further probe":
      let peer = startPeer(listing, modern = false)
      let client = peer.connectedClient()
      listThrice(client)
      check peer.requestsFor("server/discover").len == 1
      check peer.requestsFor("initialize").len == 1
      check peer.requestsFor("tools/list").len == 3
      for request in peer.requestsFor("tools/list"):
        check not request["params"].hasKey("_meta")
