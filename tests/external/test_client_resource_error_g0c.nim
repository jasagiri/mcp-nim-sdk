## How a client reports that a server could not find a resource: with the
## code it was given and the uri in the data. 2026-07-28 servers answer
## -32602; earlier ones -32002, which a 2026-07-28 client still takes as the
## same answer.

import std/[unittest, asyncdispatch, json]
import client/client
import client/resources
import protocol/lifecycle
import ./loopback_transport
import ./client_peer

proc notFound(code: int): Peer =
  startPeer(proc(peer: Peer, message: JsonNode) =
    if message{"method"}.getStr() == "resources/read":
      peer.pair.client.inject(%*{"jsonrpc": "2.0", "id": message["id"],
        "error": {"code": code, "message": "Resource not found",
                  "data": {"uri": "file:///gone"}}}),
    modern = SpeaksModern, capabilities = %*{"resources": {}})

suite "a client reads a resource the server does not have":

  test "Given a server that answers -32002 or -32602, when the client reads, then the call fails with that code and the uri, and the client carries on":
    for code in [-32002, -32602]:
      let peer = notFound(code)
      let client = peer.connectedClient()
      var raised = false
      try:
        discard waitFor client.readResource("file:///gone")
      except McpRequestError as e:
        raised = true
        check e.code == code
        check e.data["uri"].getStr() == "file:///gone"
      check raised
      check client.state == mlsOperational
