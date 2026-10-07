## Log messages: logging/setLevel and notifications/message before
## 2026-07-28, the per-request log level of 2026-07-28.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness

const LogLevelKey = "io.modelcontextprotocol/logLevel"

var
  kept: McpRequestContext
  gate: Future[void]
  started: bool

proc logServer(declare = true): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()),
    logging: if declare: some(McpLoggingCapability()) else: none(McpLoggingCapability)))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "keep":
      kept = ctx
    of "anonymous":
      await ctx.log(mllInfo, %"no logger")
    of "late":
      started = true
      gate = newFuture[void]("gate")
      await gate
      await ctx.log(mllError, %"too late")
    else:
      for level in McpLogLevel:
        await ctx.log(level, %($level & " happened"), "db")
    return %*{"content": [{"type": "text", "text": "done"}]})

proc levelsSent(t: SessionedTransport, session = ""): seq[string] =
  for s in t.messagesOf("notifications/message"):
    if s.session == session:
      result.add s.message["params"]["level"].getStr()

suite "logging before 2026-07-28":

  test "Given no setLevel, when a handler logs at every level, then the client gets every message":
    for v in versionsWith(ftLoggingSetLevel):
      let server = logServer()
      let t = server.attach()
      discard server.connect(t, v).ask("tools/call", %*{"name": "log"})
      check t.levelsSent().len == 8

  test "Given setLevel warning, when a handler logs at every level, then the client gets warning and above":
    for v in versionsWith(ftLoggingSetLevel):
      let server = logServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      check not peer.ask("logging/setLevel", %*{"level": "warning"}).hasKey("error")
      discard peer.ask("tools/call", %*{"name": "log"})
      check t.levelsSent() == @["warning", "error", "critical", "alert", "emergency"]

  test "Given a log message, when it is sent, then it carries level, logger and data and belongs to the request":
    for v in versionsWith(ftLoggingSetLevel):
      let server = logServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "log"})
      discard t.responseTo(id)
      let first = t.messagesOf("notifications/message")[0]
      check first.message["params"] == %*{"level": "debug", "logger": "db", "data": "debug happened"}
      check first.related == id

  test "Given a log message without a logger, when it is sent, then it carries no logger key":
    for v in versionsWith(ftLoggingSetLevel):
      let server = logServer()
      let t = server.attach()
      discard server.connect(t, v).ask("tools/call", %*{"name": "anonymous"})
      check t.messagesOf("notifications/message")[0].message["params"] == %*{"level": "info", "data": "no logger"}

  test "Given two clients with different levels, when the server logs, then each gets what its level allows":
    let server = logServer()
    let t = server.attach()
    let quiet = server.connect(t, DefaultProtocolVersion.min(mpv20251125), session = "quiet")
    let loud = server.connect(t, DefaultProtocolVersion.min(mpv20251125), session = "loud")
    discard quiet.ask("logging/setLevel", %*{"level": "error"})
    discard loud.ask("logging/setLevel", %*{"level": "info"})
    waitFor server.log(mllWarning, %"disk almost full")
    check t.levelsSent("quiet").len == 0
    check t.levelsSent("loud") == @["warning"]

  test "Given an unknown level, when setLevel is sent, then the answer is invalid params":
    for v in versionsWith(ftLoggingSetLevel):
      let server = logServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("logging/setLevel", %*{"level": "loud"}).errorCode == -32602
      check peer.ask("logging/setLevel", %*{}).errorCode == -32602

  test "Given a server without the logging capability, when setLevel is sent, then the method is not found":
    for v in versionsWith(ftLoggingSetLevel):
      let server = logServer(declare = false)
      check server.connect(server.attach(), v).ask("logging/setLevel", %*{"level": "info"}).errorCode == -32601

  test "Given a client that has not initialized, when it sends setLevel, then the answer is invalid request":
    let server = logServer()
    let t = server.attach()
    let id = freshId()
    t.inject("", rpcRequest(id, "logging/setLevel", %*{"level": "info"}))
    check t.responseTo(id).errorCode == -32600

  test "Given a client that ended its session, when the server logs, then nothing is sent to it":
    let server = logServer()
    let t = server.attach()
    discard server.connect(t, DefaultProtocolVersion.min(mpv20251125), session = "gone")
    server.endSession("gone")
    waitFor server.log(mllError, %"x")
    check t.levelsSent("gone").len == 0

  test "Given a request that has been answered, when its context logs afterwards, then nothing is sent":
    for v in versionsWith(ftLoggingSetLevel):
      let server = logServer()
      let t = server.attach()
      discard server.connect(t, v).ask("tools/call", %*{"name": "keep"})
      waitFor kept.log(mllError, %"after the answer")
      check t.levelsSent().len == 0

  test "Given a request the client cancelled, when its handler logs afterwards, then nothing is sent":
    for v in versionsWith(ftLoggingSetLevel):
      started = false
      let server = logServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "late"})
      untilTrue("the handler to start", proc(): bool = started)
      peer.notify("notifications/cancelled", %*{"requestId": id})
      settle()
      gate.complete()
      settle()
      check t.levelsSent().len == 0

  test "Given a server that did not declare logging, when a handler logs, then it is an internal error and nothing is sent":
    let server = logServer(declare = false)
    let t = server.attach()
    let reply = server.connect(t, DefaultProtocolVersion).ask("tools/call", %*{"name": "log"})
    check reply.errorCode == -32603
    check t.levelsSent().len == 0

if isModern(DefaultProtocolVersion):
  suite "logging in 2026-07-28":

    test "Given a request without a log level, when a handler logs, then no notification is sent":
      let server = logServer()
      let t = server.attach()
      discard server.connect(t, mpv20260728).ask("tools/call", %*{"name": "log"})
      check t.levelsSent().len == 0

    test "Given a request with a log level, when a handler logs, then the client gets that level and above for this request":
      let server = logServer()
      let t = server.attach()
      let peer = server.connect(t, mpv20260728)
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "log"}, meta = %*{LogLevelKey: "error"})
      discard t.responseTo(id)
      check t.levelsSent() == @["error", "critical", "alert", "emergency"]
      for s in t.messagesOf("notifications/message"):
        check s.related == id

    test "Given one request with a level and one without, when a handler logs for both, then only the first is told":
      let server = logServer()
      let t = server.attach()
      let peer = server.connect(t, mpv20260728)
      discard peer.ask("tools/call", %*{"name": "log"}, meta = %*{LogLevelKey: "emergency"})
      discard peer.ask("tools/call", %*{"name": "log"})
      check t.levelsSent() == @["emergency"]

    test "Given a log level that is not one, when a request is sent, then the answer is invalid params":
      let server = logServer()
      let peer = server.connect(server.attach(), mpv20260728)
      check peer.ask("tools/call", %*{"name": "log"}, meta = %*{LogLevelKey: "loud"}).errorCode == -32602
      check peer.ask("tools/call", %*{"name": "log"}, meta = %*{LogLevelKey: 3}).errorCode == -32602

    test "Given logging/setLevel, when a 2026-07-28 client sends it, then the method is not found":
      let server = logServer()
      let reply = server.connect(server.attach(), mpv20260728).ask("logging/setLevel", %*{"level": "info"})
      check reply.errorCode == -32601

    test "Given a 2026-07-28 client only, when the server logs outside a request, then nothing is sent":
      let server = logServer()
      let t = server.attach()
      discard server.connect(t, mpv20260728).ask("tools/list")
      waitFor server.log(mllEmergency, %"x")
      check t.levelsSent().len == 0
