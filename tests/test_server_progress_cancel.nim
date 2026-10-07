## Progress notifications from a handler, and cancellation of a request in
## flight.

import std/[unittest, asyncdispatch, json, options, strutils]
import ./server_harness

var
  gate: Future[void]
  started: bool
  sawCancelled: bool
  seenReason: string
  checkRaised: bool
  lateProgressError: string
  raceWonByCancel: bool

var kept: McpRequestContext

proc progressServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "progress":
      await ctx.reportProgress(1, some(4.0), "one of four")
      await ctx.reportProgress(2.5, some(4.0))
      return %*{"content": [{"type": "text", "text": "done"}]}
    of "keep-context":
      kept = ctx
      return %*{"content": [{"type": "text", "text": "done"}]}
    of "regress":
      await ctx.reportProgress(2)
      try:
        await ctx.reportProgress(2)
      except ValueError as e:
        return %*{"content": [{"type": "text", "text": e.plainMessage}]}
      return %*{"content": [{"type": "text", "text": "no error"}]}
    of "slow":
      started = true
      gate = newFuture[void]("gate")
      await gate
      sawCancelled = ctx.cancelled
      seenReason = ctx.cancelReason
      try:
        ctx.checkCancelled()
      except McpCancelled:
        checkRaised = true
      await ctx.reportProgress(9)
      return %*{"content": [{"type": "text", "text": "slow done"}]}
    of "race":
      gate = newFuture[void]("gate")
      started = true
      let cancelled = ctx.whenCancelled
      await gate or cancelled
      raceWonByCancel = cancelled.finished
      return %*{"content": [{"type": "text", "text": "raced"}]}
    else:
      raise newUnknownTool(name))

proc reset() =
  gate = nil
  started = false
  sawCancelled = false
  seenReason = "unset"
  checkRaised = false
  raceWonByCancel = false

proc progressesOf(t: SessionedTransport): seq[Sent] =
  t.messagesOf("notifications/progress")

proc release() =
  gate.complete()
  settle()

suite "progress (every version)":

  test "Given a progress token, when a handler reports progress, then the client gets the token, progress, total and related request":
    for v in SupportedProtocolVersions:
      let server = progressServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "progress"}, meta = %*{"progressToken": "abc123"})
      discard t.responseTo(id)
      let sent = t.progressesOf()
      check sent.len == 2
      check sent[0].related == id
      check sent[0].message["params"]{"progressToken"}.getStr() == "abc123"
      check sent[0].message["params"]["progress"].getFloat() == 1.0
      check sent[0].message["params"]["total"].getFloat() == 4.0
      check sent[1].message["params"]["progress"].getFloat() == 2.5
      check not sent[1].message["params"].hasKey("message")

  test "Given a progress message, when a handler reports it, then the client gets it from 2025-03-26 on":
    for v in SupportedProtocolVersions:
      let server = progressServer()
      let t = server.attach()
      discard server.connect(t, v).ask("tools/call", %*{"name": "progress"},
        meta = %*{"progressToken": 1})
      let first = t.progressesOf()[0].message["params"]
      check first.hasKey("message") == v.has(ftProgressMessage)

  test "Given an integer progress token, when progress is reported, then the token comes back as an integer":
    for v in SupportedProtocolVersions:
      let server = progressServer()
      let t = server.attach()
      discard server.connect(t, v).ask("tools/call", %*{"name": "progress"},
        meta = %*{"progressToken": 77})
      check t.progressesOf()[0].message["params"]["progressToken"].kind == JInt
      check t.progressesOf()[0].message["params"]["progressToken"].getInt() == 77

  test "Given no progress token, when a handler reports progress, then nothing is sent":
    for v in SupportedProtocolVersions:
      let server = progressServer()
      let t = server.attach()
      discard server.connect(t, v).ask("tools/call", %*{"name": "progress"})
      check t.progressesOf().len == 0

  test "Given a progress token that is neither string nor integer, when a request arrives, then the answer is invalid params":
    for v in SupportedProtocolVersions:
      let server = progressServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/call", %*{"name": "progress"}, meta = %*{"progressToken": 1.5}).errorCode == -32602
      check peer.ask("tools/call", %*{"name": "progress"}, meta = %*{"progressToken": {}}).errorCode == -32602

  test "Given progress that does not increase, when a handler reports it again, then it is refused":
    for v in SupportedProtocolVersions:
      let server = progressServer()
      let t = server.attach()
      let reply = server.connect(t, v).ask("tools/call", %*{"name": "regress"},
        meta = %*{"progressToken": "p"})
      check "increase" in textOf(reply)
      check t.progressesOf().len == 1

  test "Given a request that has been answered, when its handler reports progress afterwards, then nothing is sent":
    reset()
    let server = progressServer()
    let t = server.attach()
    let peer = server.connect(t, DefaultProtocolVersion)
    let id = freshId()
    peer.send(%id, "tools/call", %*{"name": "slow"}, meta = %*{"progressToken": "p"})
    untilTrue("the handler to start", proc(): bool = started)
    release()
    discard t.responseTo(id)
    check t.progressesOf().len == 1  # sent before the answer, while it was in flight

suite "progress after the answer (every version)":

  test "Given a request that was answered, when its context reports progress, then no notification is sent":
    for v in SupportedProtocolVersions:
      let server = progressServer()
      let t = server.attach()
      discard server.connect(t, v).ask("tools/call", %*{"name": "keep-context"},
        meta = %*{"progressToken": "p"})
      waitFor kept.reportProgress(5)
      settle()
      check t.progressesOf().len == 0

suite "cancellation (every version)":

  test "Given a request in flight, when the client cancels it, then no response is sent and the handler sees the cancellation":
    for v in SupportedProtocolVersions:
      reset()
      let server = progressServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "slow"}, meta = %*{"progressToken": "p"})
      untilTrue("the handler to start", proc(): bool = started)
      peer.notify("notifications/cancelled", %*{"requestId": id, "reason": "user"})
      settle()
      release()
      check sawCancelled
      check checkRaised
      check t.progressesOf().len == 0
      for s in t.sent:
        check s.message{"id"}.getStr() != id

  test "Given a numeric request id, when the client cancels it, then the request is cancelled":
    reset()
    let server = progressServer()
    let t = server.attach()
    let peer = server.connect(t, DefaultProtocolVersion)
    peer.send(%4711, "tools/call", %*{"name": "slow"})
    untilTrue("the handler to start", proc(): bool = started)
    peer.notify("notifications/cancelled", %*{"requestId": 4711})
    settle()
    release()
    check sawCancelled
    for s in t.sent:
      check not (s.message.hasKey("result") and s.message{"id"}.getInt() == 4711)

  test "Given a cancellation with a reason, when the handler looks, then ctx.cancelReason is that reason, and empty when the reason is missing or no string":
    for reason in [%"user", newJNull(), %42]:
      reset()
      let server = progressServer()
      let peer = server.connect(server.attach(), DefaultProtocolVersion)
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "slow"})
      untilTrue("the handler to start", proc(): bool = started)
      var params = %*{"requestId": id}
      if reason.kind != JNull:
        params["reason"] = reason
      peer.notify("notifications/cancelled", params)
      settle()
      release()
      check sawCancelled
      check seenReason == (if reason.kind == JString: "user" else: "")

  test "Given a handler waiting on whenCancelled, when the client cancels, then the wait ends":
    reset()
    let server = progressServer()
    let t = server.attach()
    let peer = server.connect(t, DefaultProtocolVersion)
    let id = freshId()
    peer.send(%id, "tools/call", %*{"name": "race"})
    untilTrue("the handler to start", proc(): bool = started)
    peer.notify("notifications/cancelled", %*{"requestId": id})
    untilTrue("the handler to see the cancellation", proc(): bool = raceWonByCancel)
    check raceWonByCancel

  test "Given a request id nobody sent, when the client cancels it, then it is ignored and the server goes on":
    for v in SupportedProtocolVersions:
      let server = progressServer()
      let peer = server.connect(server.attach(), v)
      peer.notify("notifications/cancelled", %*{"requestId": "never-sent"})
      peer.notify("notifications/cancelled", %*{"reason": "no id"})
      peer.notify("notifications/cancelled", %*{"requestId": [1]})
      check peer.ask("tools/call", %*{"name": "progress"})["result"]["content"][0]["text"].getStr() == "done"

  test "Given a request already answered, when the client cancels it, then the answer stands":
    for v in SupportedProtocolVersions:
      let server = progressServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "progress"})
      discard t.responseTo(id)
      peer.notify("notifications/cancelled", %*{"requestId": id})
      settle()
      var answers = 0
      for s in t.sent:
        if s.message{"id"}.getStr() == id:
          inc answers
      check answers == 1

  test "Given the same request id on two sessions, when one client cancels it, then the other's request goes on":
    reset()
    let server = progressServer()
    let t = server.attach()
    let legacy = DefaultProtocolVersion.min(mpv20251125)
    let a = server.connect(t, legacy, session = "a")
    let b = server.connect(t, legacy, session = "b")
    a.send(%"same", "tools/call", %*{"name": "slow"})
    untilTrue("the handler to start", proc(): bool = started)
    b.notify("notifications/cancelled", %*{"requestId": "same"})
    settle()
    release()
    check not sawCancelled
    untilTrue("the answer", proc(): bool =
      for s in t.sent:
        if s.session == "a" and s.message{"id"}.getStr() == "same":
          return true
      false)

  test "Given the initialize request in flight, when the client cancels it, then it is answered anyway":
    let server = progressServer()
    let slowInit = newFuture[void]("slowInit")
    server.registerRequestHandler("initialize",
      proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
        await slowInit
        return newJsonRpcResponse(request.id, newJObject()))
    let t = server.attach()
    t.inject("", rpcRequest("init-1", "initialize", %*{}))
    settle()
    t.inject("", rpcNotification("notifications/cancelled", %*{"requestId": "init-1"}))
    settle()
    slowInit.complete()
    check not t.responseTo("init-1").hasKey("error")

  test "Given a session that ends, when a request of it is in flight, then it is cancelled":
    reset()
    let server = progressServer()
    let t = server.attach()
    let peer = server.connect(t, DefaultProtocolVersion.min(mpv20251125), session = "s")
    peer.send(%"x", "tools/call", %*{"name": "slow"})
    untilTrue("the handler to start", proc(): bool = started)
    server.endSession("s")
    release()
    check sawCancelled

  test "Given cancelRequest called directly, when the request is live, unknown, cancelled already or initialize, then it says whether it stopped waiting":
    reset()
    let server = progressServer()
    let t = server.attach()
    let peer = server.connect(t, DefaultProtocolVersion.min(mpv20251125), session = "s")
    check not server.cancelRequest("s", "never-sent")
    peer.send(%"x", "tools/call", %*{"name": "slow"})
    untilTrue("the handler to start", proc(): bool = started)
    check not server.cancelRequest("other-session", "x")
    check server.cancelRequest("s", "x", "enough")
    check not server.cancelRequest("s", "x")
    release()
    check sawCancelled
    let slowInit = newFuture[void]("slowInit")
    server.registerRequestHandler("initialize",
      proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
        await slowInit
        return newJsonRpcResponse(request.id, newJObject()))
    t.inject("i", rpcRequest("init-1", "initialize", %*{}))
    settle()
    check not server.cancelRequest("i", "init-1")
    slowInit.complete()
