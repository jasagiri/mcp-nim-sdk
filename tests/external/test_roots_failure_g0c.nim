## A client whose roots provider fails answers the server's roots/list with
## an internal error and carries on.

import std/[unittest, asyncdispatch, json]
import client/client
import client/roots
import protocol/lifecycle
import ./client_peer

proc responseTo(peer: Peer, id: string): JsonNode =
  waitFor sleepAsync(5)
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
      return message
  nil

suite "a roots provider that fails (before 2026-07-28)":

  test "Given a roots provider that raises, when the server asks for the roots, then the answer is -32603 and the client is still operational":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} =
        raise newException(IOError, "disk unreadable")))
    peer.ask(%"r1", "roots/list")
    let answer = peer.responseTo("r1")
    check answer["error"]["code"].getInt() == -32603
    check not answer.hasKey("result")
    check client.state == mlsOperational
