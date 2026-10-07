## Request lifecycle of the client: timeouts, cancellation, progress, and
## what happens to waiting requests when the connection ends.

import std/[unittest, asyncdispatch, json, options, os, strutils, tables]
import client/client
import protocol/types
import protocol/lifecycle
import transport/transport
import ./loopback_transport
import ./client_peer
import ./stuck_transport

proc silentPeer(): Peer = startPeer(nil)

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-client-requests-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc holdSending(peer: Peer, methodName: string): Future[void] =
  ## The client's transport does not finish sending `methodName` requests
  ## until the returned future is completed or failed, as an HTTP POST does
  ## until the server starts to answer.
  let gate = newFuture[void]("test.sendGate")
  peer.pair.client.holdSendsOf = methodName
  peer.pair.client.sendGate = gate
  gate

proc timesOut(client: McpClient) =
  ## A tools/list that gets no answer within 30 ms.
  expect McpTimeoutError:
    discard waitFor client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(30)))
  waitFor sleepAsync(5)

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

  test "Given a token cancelled without a reason, when the request raises, then the message names no reason":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let token = newMcpCancelToken()
    let pending = client.sendRequest("tools/call", %*{"name": "slow"},
      McpRequestOptions(cancel: token))
    waitFor sleepAsync(5)
    token.cancel()
    try:
      discard waitFor pending
      check false
    except McpCancelledError as e:
      # Nim appends the async traceback to the message.
      check e.msg.startsWith("tools/call: cancelled")
      check "()" notin e.msg

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

  test "Given two requests that share one token, when it is cancelled, then both end at once with McpCancelledError":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let token = newMcpCancelToken()
    let options = McpRequestOptions(cancel: token, timeoutMs: some(1000))
    let first = client.sendRequest("tools/call", %*{"name": "slow"}, options)
    let second = client.sendRequest("tools/list", newJObject(), options)
    waitFor sleepAsync(5)
    token.cancel("stop both")
    # Well before the timeout: a request that only noticed the cancellation
    # when its timer ran out was not cancelled.
    waitFor sleepAsync(50)
    check first.finished
    check second.finished
    expect McpCancelledError:
      discard waitFor first
    expect McpCancelledError:
      discard waitFor second
    check client.pendingRequests.len == 0

  test "Given a callback of the caller on a token, when a request is made with it, then the callback runs when the token is cancelled":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let token = newMcpCancelToken()
    var told = 0
    token.whenCancelled.addCallback(proc() = inc told)
    let pending = client.sendRequest("tools/call", %*{"name": "slow"},
      McpRequestOptions(cancel: token, timeoutMs: some(400)))
    waitFor sleepAsync(5)
    token.cancel()
    expect McpCancelledError:
      discard waitFor pending
    check told == 1

  # An internal-implementation test (I): nothing outside the token shows what
  # it still holds, so `heldWaiters` is the hook. The behaviour behind it is
  # that a token used for the whole life of an application does not grow by
  # one closure per request.
  test "Given one token used by many requests that end in different ways, when they are done, then the token holds nothing of them":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        peer.reply(message["id"], %*{"tools": []}))
    let client = peer.connectedClient(LegacyDefault)
    let token = newMcpCancelToken()
    for _ in 0 ..< 20:
      discard waitFor client.sendRequest("tools/list", newJObject(),
        McpRequestOptions(cancel: token))
    expect McpTimeoutError:
      discard waitFor client.sendRequest("tools/call", %*{"name": "slow"},
        McpRequestOptions(cancel: token, timeoutMs: some(20)))
    check token.heldWaiters == 0

suite "starting a request without waiting for its response":

  test "Given a request that is started, when the server has not answered, then it returns the id on the wire and a response that completes later":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let started = waitFor client.startRequest("tools/list", newJObject())
    check started.id == peer.requestsFor("tools/list")[0]["id"].getStr()
    check not started.response.finished
    peer.reply(%started.id, %*{"tools": []})
    check (waitFor started.response).result.isSome

  test "Given a request started with an id, when it is sent, then that id is on the wire":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let started = waitFor client.startRequest("tools/list", newJObject(), "chosen-id")
    check started.id == "chosen-id"
    check peer.requestsFor("tools/list")[0]["id"].getStr() == "chosen-id"

  test "Given sending that fails, when a request is started, then startRequest raises the transport's error":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let gate = peer.holdSending("tools/list")
    let starting = client.startRequest("tools/list", newJObject())
    waitFor sleepAsync(5)
    check not starting.finished
    gate.fail(newException(McpTransportError, "the connection broke"))
    expect McpTransportError:
      discard waitFor starting
    check client.pendingRequests.len == 0

suite "giving up a request over each transport":

  test "Given a legacy connection over HTTP, when a request that was sent times out, then notifications/cancelled is sent and the transport is not asked to cancel":
    let peer = startPeer(nil, kind = mtkStreamable)
    let client = peer.connectedClient(LegacyDefault)
    client.timesOut()
    check peer.requestsFor("notifications/cancelled").len == 1
    check peer.pair.client.cancelRequested.len == 0

  test "Given a request whose sending has not finished, when it times out, then the transport is asked to give up sending and the server is told":
    let peer = startPeer(nil, kind = mtkStreamable)
    let client = peer.connectedClient(LegacyDefault)
    let gate = peer.holdSending("tools/list")
    client.timesOut()
    check peer.pair.client.cancelRequested.len == 1
    check peer.requestsFor("tools/list").len == 0
    let told = peer.lastCancelled()
    check not told.isNil
    check told["requestId"].getStr() == peer.pair.client.cancelRequested[0]
    gate.complete()

  test "Given a request given up while it was being sent, when the sending fails afterwards, then the failure is reported":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let gate = peer.holdSending("tools/list")
    let logged = loggedWhile(proc() =
      client.timesOut()
      gate.fail(newException(McpTransportError, "the connection broke"))
      waitFor sleepAsync(20))
    check "tools/list" in logged
    check "the connection broke" in logged
    check client.pendingRequests.len == 0

  test "Given sending that fails while the request waits, when it fails, then the caller gets the transport's error and nothing stays pending":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let gate = peer.holdSending("tools/list")
    let pending = client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(0)))
    waitFor sleepAsync(5)
    check client.pendingRequests.len == 1
    gate.fail(newException(McpTransportError, "the connection broke"))
    expect McpTransportError:
      discard waitFor pending
    check client.pendingRequests.len == 0

  test "Given a notification of cancellation that cannot be sent, when a request times out, then the caller still gets McpTimeoutError and the failure is reported":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    peer.pair.client.brokenNotifications = true
    let logged = loggedWhile(proc() = client.timesOut())
    check "could not cancel request" in logged
    check "loopback notifications are broken" in logged

  test "Given a closed client, when a notification is sent, then it raises McpConnectionClosedError without sending":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    waitFor client.close()
    let before = peer.received.len
    expect McpConnectionClosedError:
      waitFor client.sendNotification("notifications/roots/list_changed", newJObject())
    check peer.received.len == before

  test "Given a client that never connected, when a notification is sent, then it raises McpConnectionClosedError":
    let client = newMcpClient(McpClientInfo(name: "c", version: "0"), LegacyDefault)
    expect McpConnectionClosedError:
      waitFor client.sendNotification("notifications/roots/list_changed", newJObject())

if SpeaksModern:
  suite "giving up a request in 2026-07-28":

    test "Given a connection over HTTP, when a request times out, then the transport is asked to cancel it and no notification is sent":
      let peer = startPeer(nil, modern = true, kind = mtkStreamable)
      let client = peer.connectedClient()
      client.timesOut()
      check peer.pair.client.cancelRequested ==
        @[peer.requestsFor("tools/list")[0]["id"].getStr()]
      check peer.requestsFor("notifications/cancelled").len == 0

    test "Given a connection over stdio, when a request times out, then notifications/cancelled is sent and the transport is not asked to cancel":
      let peer = startPeer(nil, modern = true)
      let client = peer.connectedClient()
      client.timesOut()
      check peer.requestsFor("notifications/cancelled").len == 1
      check peer.pair.client.cancelRequested.len == 0

  suite "a tools/call is repeated only when refused as a header mismatch":

    proc answeringWith(answer: proc(peer: Peer, id: JsonNode)): Peer =
      startPeer(proc(peer: Peer, message: JsonNode) =
        case message{"method"}.getStr()
        of "tools/call": answer(peer, message["id"])
        of "tools/list": peer.reply(message["id"], %*{"resultType": "complete", "tools": []})
        else: discard, modern = true, kind = mtkStreamable)

    test "Given a connection over HTTP, when a call is answered with a result, then it was sent once and the tools were not listed again":
      let peer = answeringWith(proc(peer: Peer, id: JsonNode) =
        peer.reply(id, %*{"resultType": "complete", "content": []}))
      let client = peer.connectedClient()
      client.requestTimeoutMs = 500
      let response = waitFor client.sendRequest("tools/call", %*{"name": "t"})
      check response.result.isSome
      check peer.requestsFor("tools/call").len == 1
      check peer.requestsFor("tools/list").len == 0

    test "Given a connection over HTTP, when a call is refused for another reason, then the refusal is returned and nothing is repeated":
      let peer = answeringWith(proc(peer: Peer, id: JsonNode) =
        peer.replyError(id, -32602, "invalid params"))
      let client = peer.connectedClient()
      client.requestTimeoutMs = 500
      let response = waitFor client.sendRequest("tools/call", %*{"name": "t"})
      check response.error.get.code == -32602
      check peer.requestsFor("tools/call").len == 1
      check peer.requestsFor("tools/list").len == 0

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

  test "Given two requests with progress callbacks in flight, when the server reports progress for each, then each callback sees only its own":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    var first, second: seq[float]
    let a = client.sendRequest("tools/call", %*{"name": "a"},
      McpRequestOptions(timeoutMs: some(0),
        onProgress: proc(update: McpProgress) = first.add update.progress))
    let b = client.sendRequest("tools/call", %*{"name": "b"},
      McpRequestOptions(timeoutMs: some(0),
        onProgress: proc(update: McpProgress) = second.add update.progress))
    waitFor sleepAsync(5)
    let sent = peer.requestsFor("tools/call")
    check sent.len == 2
    peer.push("notifications/progress", %*{
      "progressToken": sent[0]["params"]["_meta"]["progressToken"], "progress": 1})
    peer.push("notifications/progress", %*{
      "progressToken": sent[1]["params"]["_meta"]["progressToken"], "progress": 2})
    waitFor sleepAsync(5)
    check first == @[1.0]
    check second == @[2.0]
    peer.reply(sent[0]["id"], %*{"content": []})
    peer.reply(sent[1]["id"], %*{"content": []})
    discard waitFor a
    discard waitFor b

  test "Given a request without a progress callback, when progress arrives with an empty token, then the client carries on":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let pending = client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(0)))
    waitFor sleepAsync(5)
    peer.push("notifications/progress", %*{"progressToken": "", "progress": 1})
    waitFor sleepAsync(5)
    peer.reply(peer.requestsFor("tools/list")[0]["id"], %*{"tools": []})
    check (waitFor pending).result.isSome

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

  test "Given a transport whose receive loop close() does not end, when the client is closed, then the pending request fails at once and the transport is closed":
    let transport = newStuckTransport()
    let client = newMcpClient(McpClientInfo(name: "c", version: "0"), LegacyDefault)
    client.transport = transport
    client.state = mlsOperational
    let pending = client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(0)))
    waitFor client.close()
    expect McpConnectionClosedError:
      require waitFor withTimeout(pending, 1000)
    check transport.closeCalls == 1

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

  test "Given a pending request, when the server ends the stream, then it fails with McpConnectionClosedError and nothing stays registered as pending":
    let peer = silentPeer()
    let client = peer.connectedClient(LegacyDefault)
    let pending = client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(0)))
    waitFor sleepAsync(5)
    check client.pendingRequests.len == 1
    peer.pair.client.endStream()
    expect McpConnectionClosedError:
      discard waitFor pending
    check client.pendingRequests.len == 0

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
