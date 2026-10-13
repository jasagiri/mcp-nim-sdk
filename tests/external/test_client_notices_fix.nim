## A client says on stderr why it gave up on a request, and that a ping
## failed. What a peer or a caller chose is shown in a harmless form.

import std/[unittest, asyncdispatch, json, options, os, strutils]
import client/client
import client/utilities
import protocol/types
import ./client_peer

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-client-notice-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

suite "a client says why it gave up on a request":

  test "Given a request the caller cancels with a reason, when the client abandons it, then stderr names the request and the reason":
    for v in SupportedProtocolVersions:
      let peer = startPeer(nil, modern = isModern(v))
      let client = peer.connectedClient(v)
      let token = newMcpCancelToken()
      let log = loggedWhile(proc() =
        let call = client.callMethod("tools/list", newJObject(),
          McpRequestOptions(cancel: token))
        waitFor sleepAsync(10)
        token.cancel("user pressed stop")
        try:
          discard waitFor call
        except McpCancelledError:
          discard)
      check "abandoned" in log
      check "user pressed stop" in log

  test "Given a request that times out, when the client abandons it, then stderr says no response came":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    let log = loggedWhile(proc() =
      try:
        discard waitFor client.callMethod("tools/list", newJObject(),
          McpRequestOptions(timeoutMs: some(20)))
      except McpTimeoutError:
        discard)
    check "abandoned" in log
    check "no response within 20 ms" in log

  test "Given a cancellation reason with a line break and an escape, when the client logs it, then the log holds one line of it":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    let token = newMcpCancelToken()
    let log = loggedWhile(proc() =
      let call = client.callMethod("tools/list", newJObject(),
        McpRequestOptions(cancel: token))
      waitFor sleepAsync(10)
      token.cancel("stop\n[mcp-client] forged\x1b[2J")
      try:
        discard waitFor call
      except McpCancelledError:
        discard)
    check log.strip().splitLines().len == 1
    check '\x1b' notin log

suite "a client says that a ping failed":

  test "Given a ping that times out, when it fails, then stderr says the ping failed":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    let log = loggedWhile(proc() =
      expect McpTimeoutError:
        waitFor client.ping(McpRequestOptions(timeoutMs: some(20))))
    check "ping failed" in log
    check "McpTimeoutError" in log

  test "Given a ping the server answers, when it succeeds, then stderr is silent about it":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "ping":
        peer.reply(message["id"], newJObject()), modern = false)
    let client = peer.connectedClient(LegacyDefault)
    let log = loggedWhile(proc() = waitFor client.ping())
    check "ping failed" notin log
