## Before 2026-07-28 a client checks an idle connection with pings (ping:
## implementations SHOULD periodically issue pings, the frequency SHOULD be
## configurable, timeouts SHOULD be treated as connection failures, failures
## SHOULD be logged). pingIntervalMs says how often (0: never), pingTimeoutMs
## how long to wait for the answer.

import std/[unittest, asyncdispatch, json, options, os, strutils, sequtils]
import client/client
import protocol/types
import protocol/features
import protocol/lifecycle
from mcp import McpSessionExpiredError, mtkStdio
import ./client_peer
import ./stuck_transport

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

proc nonBlankLines(log: string): seq[string] =
  for line in log.splitLines():
    if line.strip().len > 0:
      result.add line

proc raw(log: string): bool =
  ## Whether the log holds a control character besides its line ends.
  for c in log:
    if c in {'\0' .. '\x09', '\x0b' .. '\x1f', '\x7f'}:
      return true

proc connectedStuck(transport: StuckTransport, version: McpProtocolVersion,
                    intervalMs, timeoutMs: int): McpClient =
  ## A client that finished its handshake over a transport that answers
  ## nothing else.
  result = newMcpClient(McpClientInfo(name: "c", version: "1"), version)
  result.pingIntervalMs = intervalMs
  result.pingTimeoutMs = timeoutMs
  let connecting = result.connect(transport)
  var waited = 0
  while "initialize" notin transport.sentMethods and waited < 20_000:
    waitFor sleepAsync(10)
    waited += 10
  require "initialize" in transport.sentMethods
  transport.inject(%*{"jsonrpc": "2.0", "id": transport.sentIds[0], "result": {
    "protocolVersion": $version, "capabilities": {},
    "serverInfo": {"name": "peer", "version": "0"}}})
  waitFor connecting

proc untilShutdown(client: McpClient) =
  ## The failsafe only keeps a broken client from hanging the test.
  var waited = 0
  while client.state != mlsShutdown and waited < 20_000:
    waitFor sleepAsync(10)
    waited += 10

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

  test "Given traffic half an interval after the connection began, when the idle time is counted, then its ping falls due an interval after that traffic, before the ping of a connection that began half an interval later":
    ## Both connections are on one loop and ping when their timers fall due,
    ## so the order of the two pings does not depend on how busy the machine
    ## is: the first is due at the traffic + interval, the second at its own
    ## start + interval, which is later.
    for v in legacyVersions():
      var order: seq[string]
      proc recorder(label: string): proc(peer: Peer, message: JsonNode) =
        result = proc(peer: Peer, message: JsonNode) =
          case message{"method"}.getStr()
          of "tools/list":
            peer.reply(message["id"], %*{"tools": []})
          of "ping":
            order.add label
            peer.reply(message["id"], newJObject())
          else:
            discard
      let first = startPeer(recorder("first"))
      let second = startPeer(recorder("second"))
      let a = newMcpClient(McpClientInfo(name: "a", version: "1"), v)
      a.pingIntervalMs = 1000
      waitFor a.connect(first.pair.client)
      waitFor sleepAsync(500)
      discard waitFor a.callMethod("tools/list", newJObject())
      waitFor sleepAsync(500)
      let b = newMcpClient(McpClientInfo(name: "b", version: "1"), v)
      b.pingIntervalMs = 1000
      waitFor b.connect(second.pair.client)
      var waited = 0
      while order.len < 2 and waited < 20_000:
        waitFor sleepAsync(10)
        waited += 10
      check order.len >= 2
      check order[0] == "first"
      waitFor a.close()
      waitFor b.close()

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

proc lastInitialize(transport: StuckTransport): int =
  for n, name in transport.sentMethods:
    if name == "initialize":
      result = n

type ExpiringTransport = ref object of StuckTransport
  ## A transport whose session the server ends on the first tools/list.
  expiredOnce: bool

method sendRequest*(t: ExpiringTransport, request: JsonRpcRequest): Future[void] {.async.} =
  t.sentMethods.add request.`method`
  t.sentIds.add request.id
  if request.`method` == "tools/list" and not t.expiredOnce:
    t.expiredOnce = true
    var expired = newException(McpSessionExpiredError, "the server ended the session")
    expired.code = 404
    expired.current = true
    raise expired

suite "a client that starts a new session":

  test "Given a session that ended and a peer that never answers pings, when a new session is started, then one ping is sent for the interval":
    for v in legacyVersions():
      let transport = ExpiringTransport(kind: mtkStdio)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      client.pingIntervalMs = 100
      client.pingTimeoutMs = 600_000
      let connecting = client.connect(transport)
      proc answerInitialize(count: int) =
        var waited = 0
        while transport.sentMethods.count("initialize") < count and waited < 20_000:
          waitFor sleepAsync(10)
          waited += 10
        require transport.sentMethods.count("initialize") == count
        transport.inject(%*{"jsonrpc": "2.0",
          "id": transport.sentIds[lastInitialize(transport)],
          "result": {"protocolVersion": $v, "capabilities": {},
                     "serverInfo": {"name": "peer", "version": "0"}}})
      answerInitialize(1)
      waitFor connecting
      let listing = client.sendRequest("tools/list", newJObject())
      answerInitialize(2)
      var expired: ref McpSessionExpiredError
      try:
        discard waitFor listing
      except McpSessionExpiredError as e:
        expired = e
      require not expired.isNil
      check expired.renewed
      var waited = 0
      while transport.sentMethods.count("ping") < 1 and waited < 20_000:
        waitFor sleepAsync(10)
        waited += 10
      # A second check of the connection would ping once more an interval
      # after the first ping; three intervals leave no doubt.
      waitFor sleepAsync(300)
      check transport.sentMethods.count("ping") == 1
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

  test "Given a peer that never answers pings, when one times out, then the transport is closed once":
    for v in legacyVersions():
      let transport = newStuckTransport()
      let client = connectedStuck(transport, v, 30, 60)
      let log = loggedWhile(proc() = client.untilShutdown())
      check client.state == mlsShutdown
      check transport.closeCalls == 1
      check log.nonBlankLines().len >= 1

  test "Given a peer that never answers pings and a transport that fails to close, when one times out, then the client is closed and one line holds why the closing failed, without control characters":
    for v in legacyVersions():
      let transport = newStuckTransport()
      transport.closeFailure = "CLOSE-BOOM\n\x1b[31mforged line"
      let client = connectedStuck(transport, v, 30, 60)
      let log = loggedWhile(proc() = client.untilShutdown())
      check client.state == mlsShutdown
      check transport.closeCalls == 1
      var said = 0
      for line in log.nonBlankLines():
        if "CLOSE-BOOM" in line:
          inc said
      check said == 1
      check not log.raw()

  test "Given a peer that answers a ping with an error, when it does, then one line holds what the peer wrote, without its control characters":
    for v in legacyVersions():
      let peer = startPeer(proc(peer: Peer, message: JsonNode) =
        if message{"method"}.getStr() == "ping":
          peer.replyError(message["id"], -32601, "PEER-WORDS\n\x1b[2Jforged"))
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      client.pingIntervalMs = 30
      client.pingTimeoutMs = 60
      let log = loggedWhile(proc() =
        waitFor client.connect(peer.pair.client)
        # The second ping goes out after the first one's answer was dealt with.
        check peer.pingsWithin(2, 20_000) >= 2
        waitFor client.close())
      let lines = log.nonBlankLines()
      check lines.len >= 1
      for line in lines:
        check "PEER-WORDS" in line
      check not log.raw()

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
