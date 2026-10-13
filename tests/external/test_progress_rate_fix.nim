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
