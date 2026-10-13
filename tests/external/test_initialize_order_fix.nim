## Before 2026-07-28 a client sends no request but ping until the server has
## answered initialize (basic/lifecycle: the client SHOULD NOT). A request it
## is asked to send meanwhile is refused to the caller, not queued.

import std/[unittest, asyncdispatch, json, options]
import client/client
import protocol/types
import ./loopback_transport

proc methodsSent(pair: tuple[client, server: LoopbackTransport]): seq[string] =
  for message in pair.client.sent:
    result.add message{"method"}.getStr()

proc initializeResult(pair: tuple[client, server: LoopbackTransport], v: McpProtocolVersion): JsonNode =
  %*{"jsonrpc": "2.0", "id": pair.client.sent[0]["id"],
     "result": {"protocolVersion": $v, "capabilities": {"tools": {}},
                "serverInfo": {"name": "s", "version": "1"}}}

suite "a client holds back requests until initialize is answered":

  test "Given a client that has sent initialize, when the caller sends tools/list before the answer, then it is refused and not on the wire":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let pair = newLoopbackPair()
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      let connecting = client.connect(pair.client)
      waitFor sleepAsync(5)
      var refused = false
      try:
        discard waitFor client.sendRequest("tools/list", newJObject(),
          McpRequestOptions(timeoutMs: some(50)))
      except McpError:
        refused = true
      check refused
      check pair.methodsSent() == @["initialize"]
      pair.client.inject(pair.initializeResult(v))
      waitFor connecting
      waitFor client.close()

  test "Given a client that has sent initialize, when the caller pings before the answer, then the ping is sent":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let pair = newLoopbackPair()
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      let connecting = client.connect(pair.client)
      waitFor sleepAsync(5)
      let ping = client.sendRequest("ping", newJObject(), McpRequestOptions(timeoutMs: some(30)))
      waitFor sleepAsync(10)
      check pair.methodsSent() == @["initialize", "ping"]
      pair.client.inject(pair.initializeResult(v))
      waitFor connecting
      waitFor sleepAsync(50)
      check ping.finished
      if ping.failed:
        discard ping.readError()
      waitFor client.close()

  test "Given a client whose initialize was answered, when the caller sends tools/list, then it is sent":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let pair = newLoopbackPair()
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      let connecting = client.connect(pair.client)
      waitFor sleepAsync(5)
      pair.client.inject(pair.initializeResult(v))
      waitFor connecting
      let listing = client.sendRequest("tools/list", newJObject(), McpRequestOptions(timeoutMs: some(30)))
      waitFor sleepAsync(10)
      check "tools/list" in pair.methodsSent()
      waitFor sleepAsync(50)
      if listing.failed:
        discard listing.readError()
      waitFor client.close()

  test "Given a client whose initialize failed, when the caller sends tools/list, then it is not refused for waiting on initialize":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let pair = newLoopbackPair()
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), v)
      let connecting = client.connect(pair.client)
      waitFor sleepAsync(5)
      pair.client.inject(%*{"jsonrpc": "2.0", "id": pair.client.sent[0]["id"],
                            "error": {"code": -32603, "message": "no"}})
      expect ValueError:
        waitFor connecting
      let listing = client.sendRequest("tools/list", newJObject(), McpRequestOptions(timeoutMs: some(30)))
      waitFor sleepAsync(10)
      check "tools/list" in pair.methodsSent()
      waitFor sleepAsync(50)
      if listing.failed:
        discard listing.readError()
      waitFor client.close()
