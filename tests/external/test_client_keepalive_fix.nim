## Before 2026-07-28 a client checks an idle connection with pings (ping:
## implementations SHOULD periodically issue pings, the frequency SHOULD be
## configurable, timeouts SHOULD be treated as connection failures, failures
## SHOULD be logged). pingIntervalMs says how often (0: never), pingTimeoutMs
## how long to wait for the answer.

import std/[unittest, asyncdispatch, json, options, os, strutils]
import client/client
import protocol/types
import protocol/features
import protocol/lifecycle
import ./client_peer

proc answeringPings(peer: Peer, message: JsonNode) =
  if message{"method"}.getStr() == "ping":
    peer.reply(message["id"], newJObject())

proc loggedWhile(body: proc()): string =
  let path = getTempDir() / "mcp-keepalive-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc pingsWithin(peer: Peer, atLeast: int, ms: int): int =
  ## Waits until `atLeast` pings arrived or `ms` passed.
  var waited = 0
  while peer.requestsFor("ping").len < atLeast and waited < ms:
    waitFor sleepAsync(10)
    waited += 10
  peer.requestsFor("ping").len

proc legacyVersions(): seq[McpProtocolVersion] =
  for v in SupportedProtocolVersions:
    if v.has(ftPing) and not isModern(v):
      result.add v

suite "the settings of the checks":

  test "Given a new client, when its settings are read, then it pings every 30000 ms and waits as long as for any request":
    let client = newMcpClient(McpClientInfo(name: "c", version: "1"))
    check client.pingIntervalMs == 30_000
    check client.pingIntervalMs == DefaultPingIntervalMs
    check client.pingTimeoutMs == client.requestTimeoutMs
    check client.pingTimeoutMs == DefaultRequestTimeoutMs

suite "a client pings an idle connection":

  test "Given an idle connection and an interval, when time passes, then the client pings again and again":
    for v in legacyVersions():
      let peer = startPeer(answeringPings)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      client.pingIntervalMs = 40
      waitFor client.connect(peer.pair.client)
      check peer.pingsWithin(3, 3000) >= 3
      check client.state == mlsOperational
      waitFor client.close()

  test "Given an interval of 0, when time passes, then no ping is sent":
    for v in legacyVersions():
      let peer = startPeer(answeringPings)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      client.pingIntervalMs = 0
      waitFor client.connect(peer.pair.client)
      waitFor sleepAsync(200)
      check peer.requestsFor("ping").len == 0
      waitFor client.close()

  test "Given the default interval, when the connection is new, then no ping is sent yet":
    for v in legacyVersions():
      let peer = startPeer(answeringPings)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      waitFor client.connect(peer.pair.client)
      waitFor sleepAsync(200)
      check peer.requestsFor("ping").len == 0
      waitFor client.close()

  test "Given traffic more often than the interval, when time passes, then no ping is sent":
    for v in legacyVersions():
      let peer = startPeer(proc(peer: Peer, message: JsonNode) =
        if message{"method"}.getStr() in ["ping", "tools/list"]:
          peer.reply(message["id"], %*{"tools": []}))
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      client.pingIntervalMs = 400
      waitFor client.connect(peer.pair.client)
      for n in 1 .. 20:
        discard waitFor client.callMethod("tools/list", newJObject())
        waitFor sleepAsync(30)
      check peer.requestsFor("ping").len == 0
      waitFor client.close()

  test "Given a client that is closed, when time passes, then no more pings are sent":
    for v in legacyVersions():
      let peer = startPeer(answeringPings)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      client.pingIntervalMs = 30
      waitFor client.connect(peer.pair.client)
      check peer.pingsWithin(1, 3000) >= 1
      waitFor client.close()
      let before = peer.requestsFor("ping").len
      waitFor sleepAsync(200)
      check peer.requestsFor("ping").len == before

  test "Given a 2026-07-28 connection, when time passes, then no ping is sent":
    if not SpeaksModern:
      skip()
    else:
      let peer = startPeer(answeringPings, modern = true)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"))
      client.pingIntervalMs = 20
      waitFor client.connect(peer.pair.client)
      waitFor sleepAsync(200)
      check peer.requestsFor("ping").len == 0
      waitFor client.close()

suite "a ping that fails closes the connection":

  test "Given a peer that never answers pings, when one times out, then the client closes, waiting requests end with McpConnectionClosedError and stderr says why":
    for v in legacyVersions():
      let peer = startPeer(nil)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      client.pingIntervalMs = 30
      client.pingTimeoutMs = 60
      waitFor client.connect(peer.pair.client)
      var ended = ""
      let log = loggedWhile(proc() =
        let waiting = client.sendRequest("tools/list", newJObject(),
          McpRequestOptions(timeoutMs: some(0)))
        var waited = 0
        while not waiting.finished and waited < 3000:
          waitFor sleepAsync(10)
          waited += 10
        check waiting.finished
        try:
          discard waitFor waiting
        except McpConnectionClosedError as e:
          ended = e.msg
        waitFor sleepAsync(20))
      check ended.len > 0
      check "ping" in ended
      check client.state == mlsShutdown
      check "keepalive ping failed" in log
      check "McpTimeoutError" in log
      expect McpError:
        discard waitFor client.sendRequest("tools/list", newJObject())
      waitFor client.close()

  test "Given a peer that answers a ping with an error, when it does, then the connection stays open":
    for v in legacyVersions():
      let peer = startPeer(proc(peer: Peer, message: JsonNode) =
        if message{"method"}.getStr() == "ping":
          peer.replyError(message["id"], -32601, "Method not found"))
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      client.pingIntervalMs = 30
      client.pingTimeoutMs = 60
      waitFor client.connect(peer.pair.client)
      check peer.pingsWithin(3, 3000) >= 3
      check client.state == mlsOperational
      waitFor client.close()
