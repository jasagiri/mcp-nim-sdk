## progress: "Both parties SHOULD implement rate limiting to prevent flooding".
## `reportProgress` sends at most `maxProgressPerSecond` notifications per
## request; the ones in between are dropped, the last one is always sent, and
## the values keep growing.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness

proc progressServer(steps: int, pauseMs = 0): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"name": "t", "inputSchema": {"type": "object"}}]))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    for step in 1 .. steps:
      await ctx.reportProgress(step.float, some(steps.float), "step " & $step)
      if pauseMs > 0:
        await sleepAsync(pauseMs)
    return %*{"content": []})

proc progressOf(t: SessionedTransport): seq[float] =
  for sent in t.messagesOf("notifications/progress"):
    result.add sent.message["params"]["progress"].getFloat()

proc callWithProgress(server: McpServer, v: McpProtocolVersion): tuple[reply: JsonNode, seen: seq[float]] =
  let t = server.attach()
  let peer = server.connect(t, v)
  result.reply = peer.ask("tools/call", %*{"name": "t"}, meta = %*{"progressToken": "p1"})
  result.seen = t.progressOf()

proc scriptedServer(perSecond: int,
                    script: proc(ctx: McpRequestContext): Future[void]): McpServer =
  ## A server whose tool runs `script` and then returns.
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"name": "t", "inputSchema": {"type": "object"}}]))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    await script(ctx)
    return %*{"content": []})
  result.maxProgressPerSecond = perSecond

proc answered(t: SessionedTransport, id: string): bool =
  for s in t.sent:
    if not s.message.hasKey("method") and s.message{"id"}.getStr() == id:
      return true

proc eras(): seq[McpProtocolVersion] =
  ## One legacy and one modern era: the limit does not depend on the version.
  @[legacyVersions()[^1], SupportedProtocolVersions[^1]]

const Patience = 20000
  ## Only a bound for failing: a test that passes does not wait for it.

suite "the progress notifications of one request":

  test "Given a limit of 2 per second, when a handler reports ten steps at once, then fewer arrive, the last one among them, in growing order":
    for v in SupportedProtocolVersions:
      let server = progressServer(10)
      server.maxProgressPerSecond = 2
      let (reply, seen) = callWithProgress(server, v)
      check reply.hasKey("result")
      check seen.len >= 1
      check seen.len <= 3
      check seen[^1] == 10.0
      for i in 1 ..< seen.len:
        check seen[i] > seen[i - 1]

  test "Given a limit of 0, when a handler reports ten steps at once, then all ten arrive":
    for v in SupportedProtocolVersions:
      let server = progressServer(10)
      server.maxProgressPerSecond = 0
      let (_, seen) = callWithProgress(server, v)
      check seen.len == 10

  test "Given the default limit, when a handler reports five steps at once, then the first and the last arrive":
    for v in SupportedProtocolVersions:
      let server = progressServer(5)
      let (_, seen) = callWithProgress(server, v)
      check seen.len >= 2
      check seen[0] == 1.0
      check seen[^1] == 5.0

  test "Given a limit of 2 per second, when the handler stops reporting after the last step, then the last value arrives before the request ends":
    for v in SupportedProtocolVersions:
      let server = progressServer(3)
      server.maxProgressPerSecond = 2
      let t = server.attach()
      let peer = server.connect(t, v)
      let reply = peer.ask("tools/call", %*{"name": "t"}, meta = %*{"progressToken": "p1"})
      check reply.hasKey("result")
      var lastProgressAt = -1
      var responseAt = -1
      for i, sent in t.sent:
        if sent.message{"method"}.getStr() == "notifications/progress":
          lastProgressAt = i
        elif sent.message{"id"}.getStr().len > 0 and sent.message.hasKey("result") and
             sent.message["result"].hasKey("content"):
          responseAt = i
      check lastProgressAt >= 0
      check lastProgressAt < responseAt
      check t.progressOf()[^1] == 3.0

  test "Given a limit of 4 per second, when a handler reports steadily over a second, then about four arrive":
    for v in SupportedProtocolVersions:
      let server = progressServer(10, pauseMs = 100)
      server.maxProgressPerSecond = 4
      let (_, seen) = callWithProgress(server, v)
      check seen.len >= 3
      check seen.len <= 6
      check seen[^1] == 10.0

  test "Given a limit of 2 per second and a handler that reports in two bursts and waits after each, when the interval passes, then the last value of each burst arrives before the handler returns":
    for v in eras():
      let gateOne = newFuture[void]("gateOne")
      let gateTwo = newFuture[void]("gateTwo")
      let server = scriptedServer(2, proc(ctx: McpRequestContext): Future[void] {.async.} =
        for step in 1 .. 3:
          await ctx.reportProgress(step.float)
        await gateOne
        for step in 4 .. 5:
          await ctx.reportProgress(step.float)
        await gateTwo)
      let t = server.attach()
      let peer = server.connect(t, v)
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "t"}, meta = %*{"progressToken": "p1"})
      untilTrue("the last value of the first burst", proc(): bool =
        3.0 in t.progressOf(), Patience)
      check not t.answered(id)
      gateOne.complete()
      untilTrue("the last value of the second burst", proc(): bool =
        5.0 in t.progressOf(), Patience)
      check not t.answered(id)
      gateTwo.complete()
      check t.responseTo(id).hasKey("result")
      let seen = t.progressOf()
      check seen[^1] == 5.0
      for i in 1 ..< seen.len:
        check seen[i] > seen[i - 1]

  test "Given a limit of 2 per second, when a handler reports after the interval has passed, then the value is sent at once":
    for v in eras():
      let t = newSessionedTransport()
      var arrivedAtOnce = false
      let server = scriptedServer(2, proc(ctx: McpRequestContext): Future[void] {.async.} =
        await ctx.reportProgress(1.0)
        await sleepAsync(600)
        await ctx.reportProgress(2.0)
        arrivedAtOnce = 2.0 in t.progressOf())
      waitFor server.attachTransport(t)
      let peer = server.connect(t, v)
      check peer.ask("tools/call", %*{"name": "t"}, meta = %*{"progressToken": "p1"}).hasKey("result")
      check arrivedAtOnce

  test "Given a limit of 1 per second, when a handler reports before the interval is over, then the value arrives soon after the interval is over":
    for v in eras():
      let t = newSessionedTransport()
      var arrivedBeforeNextWake = false
      let server = scriptedServer(1, proc(ctx: McpRequestContext): Future[void] {.async.} =
        await ctx.reportProgress(1.0)
        await sleepAsync(900)
        await ctx.reportProgress(2.0)
        # The interval is over some 100 ms from now; the handler wakes only
        # after 500 ms, and timers of one loop run in the order they fall due.
        await sleepAsync(500)
        arrivedBeforeNextWake = 2.0 in t.progressOf())
      waitFor server.attachTransport(t)
      let peer = server.connect(t, v)
      check peer.ask("tools/call", %*{"name": "t"}, meta = %*{"progressToken": "p1"}).hasKey("result")
      check arrivedBeforeNextWake

  test "Given a limit above 1000 per second, when a handler reports many steps at once, then fewer arrive, the last one among them":
    for v in eras():
      let server = progressServer(3000)
      server.maxProgressPerSecond = 2000
      let (reply, seen) = callWithProgress(server, v)
      check reply.hasKey("result")
      check seen.len >= 1
      check seen.len < 3000
      check seen[^1] == 3000.0
