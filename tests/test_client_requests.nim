## Request lifecycle of the client: timeouts, cancellation, progress, and
## what happens to waiting requests when the connection ends.

import std/[unittest, asyncdispatch, json, options, strutils, tables]
import client/client
import protocol/types
import protocol/lifecycle
import ./loopback_transport
import ./client_peer

proc silentPeer(): Peer = startPeer(nil)

proc lastCancelled(peer: Peer): JsonNode =
  let all = peer.requestsFor("notifications/cancelled")
  if all.len == 0: nil else: all[^1]["params"]

suite "request timeouts":

  test "Given a server that never answers, when a request has a timeout, then it raises McpTimeoutError":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    expect McpTimeoutError:
      discard waitFor client.sendRequest("tools/list", newJObject(),
        McpRequestOptions(timeoutMs: some(30)))

  test "Given a timed-out request, when it raises, then the server is told to cancel that request id":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    try:
      discard waitFor client.sendRequest("tools/list", newJObject(),
        McpRequestOptions(timeoutMs: some(30)))
    except McpTimeoutError:
      discard
    let listed = peer.requestsFor("tools/list")
    let cancelled = peer.lastCancelled()
    check not cancelled.isNil
    check cancelled["requestId"].getStr() == listed[0]["id"].getStr()
    check "30 ms" in cancelled["reason"].getStr()
    check client.pendingRequests.len == 0

  test "Given a client default timeout, when a request sets none, then the default applies":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    client.requestTimeoutMs = 30
    expect McpTimeoutError:
      discard waitFor client.sendRequest("tools/list", newJObject())

  test "Given a zero timeout, when the server answers after the client default, then the response is returned":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        let id = message["id"]
        sleepAsync(80).addCallback(proc() = peer.reply(id, %*{"tools": []})))
    let client = peer.connectedClient(LegacyDefault)
    client.requestTimeoutMs = 20
    let response = waitFor client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(0)))
    check response.result.isSome

  test "Given a late response to a timed-out request, when it arrives, then it is ignored":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    try:
      discard waitFor client.sendRequest("tools/list", newJObject(),
        McpRequestOptions(timeoutMs: some(20)))
    except McpTimeoutError:
      discard
    peer.reply(peer.requestsFor("tools/list")[0]["id"], %*{"tools": []})
    waitFor sleepAsync(10)
    check client.pendingRequests.len == 0
    check client.state == mlsOperational

  test "Given a server that never answers initialize, when connect times out, then no cancellation is sent":
    # initialize must not be cancelled (specification, cancellation).
    let pair = newLoopbackPair()
    let client = newMcpClient(McpClientInfo(name: "c", version: "0"), LegacyDefault)
    client.requestTimeoutMs = 30
    expect McpTimeoutError:
      waitFor client.connect(pair.client)
    waitFor sleepAsync(5)
    check pair.client.sent.len == 1
    check pair.client.sent[0]["method"].getStr() == "initialize"

suite "cancelling a request":

  test "Given a pending request, when its token is cancelled, then it raises McpCancelledError and the server is told why":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let token = newMcpCancelToken()
    let pending = client.sendRequest("tools/call", %*{"name": "slow"},
      McpRequestOptions(cancel: token))
    waitFor sleepAsync(5)
    token.cancel("user stopped it")
    expect McpCancelledError:
      discard waitFor pending
    let cancelled = peer.lastCancelled()
    check cancelled["requestId"].getStr() == peer.requestsFor("tools/call")[0]["id"].getStr()
    check cancelled["reason"].getStr() == "user stopped it"
    check client.pendingRequests.len == 0

  test "Given a token cancelled before the call, when the request is made, then nothing is sent":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let token = newMcpCancelToken()
    token.cancel()
    expect McpCancelledError:
      discard waitFor client.sendRequest("tools/call", %*{"name": "slow"},
        McpRequestOptions(cancel: token))
    check peer.requestsFor("tools/call").len == 0

  test "Given a request that already finished, when its token is cancelled later, then nothing is sent":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        peer.reply(message["id"], %*{"tools": []}))
    let client = peer.connectedClient(LegacyDefault)
    let token = newMcpCancelToken()
    discard waitFor client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(cancel: token))
    token.cancel()
    waitFor sleepAsync(5)
    check peer.requestsFor("notifications/cancelled").len == 0

suite "progress":

  test "Given a progress callback, when the request is sent, then it carries a progressToken in _meta":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let pending = client.sendRequest("tools/call", %*{"name": "t"},
      McpRequestOptions(onProgress: proc(update: McpProgress) = discard,
                        timeoutMs: some(20)))
    try:
      discard waitFor pending
    except McpTimeoutError:
      discard
    let token = peer.requestsFor("tools/call")[0]["params"]["_meta"]["progressToken"]
    check token.kind == JString
    check token.getStr().len > 0

  test "Given a request with a callback, when the server sends progress, then the callback sees each update in order":
    var seen: seq[McpProgress]
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        let token = message["params"]["_meta"]["progressToken"]
        peer.push("notifications/progress", %*{"progressToken": token, "progress": 1, "total": 3, "message": "one"})
        peer.push("notifications/progress", %*{"progressToken": token, "progress": 2})
        peer.reply(message["id"], %*{"content": []}))
    let client = peer.connectedClient(LegacyDefault)
    discard waitFor client.sendRequest("tools/call", %*{"name": "t"},
      McpRequestOptions(onProgress: proc(update: McpProgress) = seen.add update))
    check seen.len == 2
    check seen[0].progress == 1.0
    check seen[0].total == some(3.0)
    check seen[0].message == "one"
    check seen[1].progress == 2.0
    check seen[1].total.isNone

  test "Given a finished request, when a late progress arrives, then the callback is not called":
    var calls = 0
    var token: JsonNode
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        token = message["params"]["_meta"]["progressToken"]
        peer.reply(message["id"], %*{"content": []}))
    let client = peer.connectedClient(LegacyDefault)
    discard waitFor client.sendRequest("tools/call", %*{"name": "t"},
      McpRequestOptions(onProgress: proc(update: McpProgress) = inc calls))
    peer.push("notifications/progress", %*{"progressToken": token, "progress": 9})
    waitFor sleepAsync(5)
    check calls == 0

  test "Given progress for an unknown token, when it arrives, then the client carries on":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    peer.push("notifications/progress", %*{"progressToken": "nobody", "progress": 1})
    waitFor sleepAsync(5)
    check client.state == mlsOperational

  test "Given a caller's own _meta, when a progress callback is set, then both keys are sent":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    try:
      discard waitFor client.sendRequest("tools/call",
        %*{"name": "t", "_meta": {"trace": "abc"}},
        McpRequestOptions(onProgress: proc(update: McpProgress) = discard,
                          timeoutMs: some(20)))
    except McpTimeoutError:
      discard
    let meta = peer.requestsFor("tools/call")[0]["params"]["_meta"]
    check meta["trace"].getStr() == "abc"
    check meta.hasKey("progressToken")

suite "the end of a connection":

  test "Given a pending request, when the client is closed, then it fails with McpConnectionClosedError":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let pending = client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(0)))
    waitFor sleepAsync(5)
    waitFor client.close()
    expect McpConnectionClosedError:
      discard waitFor pending

  test "Given a pending request, when the transport fails, then it fails with McpConnectionClosedError and the cause is recorded":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let pending = client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(0)))
    waitFor sleepAsync(5)
    waitFor peer.pair.client.close()
    expect McpConnectionClosedError:
      discard waitFor pending
    check not client.lastTransportError.isNil

  test "Given a closed client, when a request is made, then it raises McpConnectionClosedError without sending":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    waitFor client.close()
    let before = peer.received.len
    expect McpConnectionClosedError:
      discard waitFor client.sendRequest("tools/list", newJObject())
    check peer.received.len == before

  test "Given a client that never connected, when a request is made, then it raises McpConnectionClosedError":
    let client = newMcpClient(McpClientInfo(name: "c", version: "0"), LegacyDefault)
    expect McpConnectionClosedError:
      discard waitFor client.sendRequest("tools/list", newJObject())

suite "failures of an answered request":

  test "Given an error response, when callMethod is used, then McpRequestError carries code and data":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.pair.client.inject(%*{"jsonrpc": "2.0", "id": message["id"],
          "error": {"code": -32602, "message": "Unknown tool", "data": {"name": "x"}}}))
    let client = peer.connectedClient(LegacyDefault)
    try:
      discard waitFor client.callMethod("tools/call", %*{"name": "x"})
      fail()
    except McpRequestError as e:
      check e.code == -32602
      check "Unknown tool" in e.msg
      check e.data["name"].getStr() == "x"

  test "Given an error response, when sendRequest is used, then the response is returned for inspection":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.replyError(message["id"], -32602, "Unknown tool"))
    let client = peer.connectedClient(LegacyDefault)
    let response = waitFor client.sendRequest("tools/call", %*{"name": "x"})
    check response.error.get.code == -32602
