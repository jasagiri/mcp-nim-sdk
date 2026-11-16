## A client that was closed leaves nothing for the event loop to wait on
## (basic/utilities/ping: the pings stop with the connection). This file holds
## one test, so that no other client or timer shares the loop with it.

import std/[unittest, asyncdispatch, json]
import client/client
import protocol/types
import protocol/features
import ./client_peer

proc legacyVersions(): seq[McpProtocolVersion] =
  for v in SupportedProtocolVersions:
    if v.has(ftPing) and not isModern(v):
      result.add v

suite "a closed client":

  test "Given a client that pings and was closed, when the event loop is run, then it has no pending operation left":
    for v in legacyVersions():
      let peer = startPeer(proc(peer: Peer, message: JsonNode) =
        if message{"method"}.getStr() == "ping":
          peer.reply(message["id"], newJObject()))
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      client.pingIntervalMs = 50
      client.pingTimeoutMs = 100
      waitFor client.connect(peer.pair.client)
      var waited = 0
      while peer.requestsFor("ping").len < 1 and waited < 20_000:
        waitFor sleepAsync(10)
        waited += 10
      require peer.requestsFor("ping").len >= 1
      waitFor client.close()
      # Whatever was left is the client's own timers (the check of the
      # connection, the watcher of the time limits); they end by themselves.
      # The count only keeps a loop that never ends from hanging the test.
      var turns = 0
      while hasPendingOperations() and turns < 2_000:
        poll(10)
        inc turns
      check not hasPendingOperations()
