## A ping that gets no answer (basic/utilities/ping, before 2026-07-28): the
## caller is told, may ping again, and may then give up the connection.

import std/[unittest, asyncdispatch, options]
import client/client
import client/utilities
import protocol/types
import protocol/features
import ./client_peer

suite "a ping without an answer":

  test "Given a peer that never answers, when pings time out one after another, then each raises McpTimeoutError and the caller can close the connection":
    for v in SupportedProtocolVersions:
      if not v.has(ftPing):
        continue
      let peer = startPeer(nil)
      let client = peer.connectedClient(v)
      for attempt in 1 .. 3:
        expect McpTimeoutError:
          waitFor client.ping(McpRequestOptions(timeoutMs: some(30)))
      check peer.requestsFor("ping").len == 3
      waitFor client.close()
      expect McpError:
        waitFor client.ping(McpRequestOptions(timeoutMs: some(30)))
      check peer.requestsFor("ping").len == 3
