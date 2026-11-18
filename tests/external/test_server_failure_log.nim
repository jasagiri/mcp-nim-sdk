## A failure whose cause the peer is not told (MCP-ERRORS-3): the server
## writes the cause to stderr on one line. The lines are not compared with a
## wording; what is looked for is a line, and in it what the caller gave: the
## message of a handler, a method, a tool, a request id.

import std/[unittest, asyncdispatch, json, options, os, strutils]
import ./server_harness
import ./loopback_transport
import server/mrtr

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-server-failure-log-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc linesOf(log: string): seq[string] =
  log.strip(leading = false).splitLines()

proc raw(log: string): bool =
  ## Whether the log holds a control character besides its line ends.
  for c in log:
    if c in {'\0' .. '\x09', '\x0b' .. '\x1f', '\x7f'}:
      return true

proc eras(): seq[McpProtocolVersion] =
  @[legacyVersions()[^1], SupportedProtocolVersions[^1]]

proc scripted(onTool: ToolCallHandler = nil): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()), resources: some(McpResourcesCapability())))
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[
      %*{"name": "plain", "inputSchema": {"type": "object"}},
      %*{"name": "no-schema", "inputSchema": {"type": "object", "properties": {
           "x": {"type": "no-such-type"}}}}]))
  if not onTool.isNil:
    result.onToolCall(onTool)

suite "the cause of a failure the peer is not told is written to stderr (MCP-ERRORS-3)":

  test "Given a resource handler that returns a blob that is not base64, when it is read, then the peer gets an internal error and one line names the method":
    for v in eras():
      let server = scripted()
      server.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
        return @[%*{"uri": uri, "blob": "!!not base64!!"}])
      let peer = server.connect(server.attach(), v)
      var reply: JsonNode
      let log = loggedWhile(proc() =
        reply = peer.ask("resources/read", %*{"uri": "file:///a"}))
      check reply.errorCode == -32603
      check log.linesOf().len == 1
      check "resources/read" in log
      check not log.raw()

  test "Given a filter that gives a result a negative ttlMs, when a 2026-07-28 client reads a resource, then the peer gets an internal error and one line names the method":
    if DefaultProtocolVersion < mpv20260728:
      skip()  # a build that does not speak 2026-07-28
    else:
      let server = scripted()
      server.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
        return @[%*{"uri": uri, "text": "a"}])
      server.addResponseFilter(proc(ctx: McpRequestContext, request: JsonRpcRequest,
                                    response: JsonRpcResponse): Future[JsonRpcResponse] {.async.} =
        response.result.get["ttlMs"] = %(-1)
        return response)
      let peer = server.connect(server.attach(), SupportedProtocolVersions[^1])
      var reply: JsonNode
      let log = loggedWhile(proc() =
        reply = peer.ask("resources/read", %*{"uri": "file:///a"}))
      check reply.errorCode == -32603
      check log.linesOf().len == 1
      check "resources/read" in log
      check not log.raw()

  test "Given a tool with an invalid x-mcp-header, when a 2026-07-28 client lists tools, then the tool is left out and one line names it":
    if DefaultProtocolVersion < mpv20260728:
      skip()  # a build that does not speak 2026-07-28
    else:
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
        return McpPage(items: @[
          %*{"name": "plain", "inputSchema": {"type": "object"}},
          %*{"name": "bad-header", "inputSchema": {"type": "object", "properties": {
               "r": {"type": "string", "x-mcp-header": "Bad Name"}}}}]))
      let peer = server.connect(server.attach(), SupportedProtocolVersions[^1])
      var reply: JsonNode
      let log = loggedWhile(proc() =
        reply = peer.ask("tools/list"))
      var names: seq[string]
      for tool in reply["result"]["tools"]:
        names.add tool["name"].getStr()
      check names == @["plain"]
      check log.linesOf().len == 1
      check "bad-header" in log
      check not log.raw()

  test "Given a tool handler that fails with a message of its own, when the tool is called, then the peer gets an internal error and one line holds the message, without its control characters":
    for v in eras():
      let server = scripted(proc(ctx: McpRequestContext, name: string,
                                 arguments: JsonNode): Future[JsonNode] {.async.} =
        raise newException(ValueError, "BOOM-cause\n\x1b[31mforged line"))
      let peer = server.connect(server.attach(), v)
      var reply: JsonNode
      let log = loggedWhile(proc() =
        reply = peer.ask("tools/call", %*{"name": "plain"}))
      check reply.errorCode == -32603
      check log.linesOf().len == 1
      check "BOOM-cause" in log
      check not log.raw()

  test "Given a tool handler that asks for input in a version that cannot, when the tool is called, then the peer gets an internal error and one line names the method":
    for v in legacyVersions():
      let server = scripted(proc(ctx: McpRequestContext, name: string,
                                 arguments: JsonNode): Future[JsonNode] {.async.} =
        raise newInputRequired())
      let peer = server.connect(server.attach(), v)
      var reply: JsonNode
      let log = loggedWhile(proc() =
        reply = peer.ask("tools/call", %*{"name": "plain"}))
      check reply.errorCode == -32603
      check log.linesOf().len == 1
      check "tools/call" in log
      check not log.raw()

  test "Given a tool whose inputSchema cannot be checked, when it is called, then the peer gets an internal error and one line names the tool":
    for v in eras():
      let server = scripted(proc(ctx: McpRequestContext, name: string,
                                 arguments: JsonNode): Future[JsonNode] {.async.} =
        return %*{"content": []})
      let peer = server.connect(server.attach(), v)
      var reply: JsonNode
      let log = loggedWhile(proc() =
        reply = peer.ask("tools/call", %*{"name": "no-schema", "arguments": {"x": 1}}))
      check reply.errorCode == -32603
      check log.linesOf().len == 1
      check "no-schema" in log
      check not log.raw()

  test "Given a tool list that never ends, when a tool that it does not hold is called, then one line names the tool, without its control characters":
    for v in eras():
      let server = scripted(proc(ctx: McpRequestContext, name: string,
                                 arguments: JsonNode): Future[JsonNode] {.async.} =
        return %*{"content": []})
      server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
        return McpPage(items: @[], nextCursor: some("more")))
      let peer = server.connect(server.attach(), v)
      let log = loggedWhile(proc() =
        discard peer.ask("tools/call", %*{"name": "ghost\x1b[2Jtool"}))
      check log.linesOf().len == 1
      check "ghost" in log
      check not log.raw()

  test "Given a request the client cancelled and a handler that fails afterwards, when it fails, then one line names the method and the request and one line holds its message":
    for v in eras():
      let gate = newFuture[void]("gate")
      var started = false
      let server = scripted(proc(ctx: McpRequestContext, name: string,
                                 arguments: JsonNode): Future[JsonNode] {.async.} =
        started = true
        await gate
        raise newException(ValueError, "BOOM-after-cancel"))
      let peer = server.connect(server.attach(), v)
      let id = freshId()
      let log = loggedWhile(proc() =
        peer.send(%id, "tools/call", %*{"name": "plain"})
        untilTrue("the handler to start", proc(): bool = started)
        peer.notify("notifications/cancelled", %*{"requestId": id})
        settle()
        gate.complete()
        settle())
      var named, said = 0
      for line in log.linesOf():
        if "tools/call" in line and id in line:
          inc named
        if "BOOM-after-cancel" in line:
          inc said
      check named == 1
      check said == 1
      check not log.raw()

  test "Given a held progress notification that cannot be sent, when the interval passes, then one line names the session":
    let t = newSessionedTransport()
    let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
    server.maxProgressPerSecond = 2
    server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
      return McpPage(items: @[%*{"name": "t", "inputSchema": {"type": "object"}}]))
    server.onToolCall(proc(ctx: McpRequestContext, name: string,
                           arguments: JsonNode): Future[JsonNode] {.async.} =
      await ctx.reportProgress(1.0)
      t.failFor = "s-progress"
      await ctx.reportProgress(2.0)
      # The held value is due in 500 ms; timers of one loop run in the order
      # they fall due, so the failed send is over when the handler wakes.
      await sleepAsync(800)
      return %*{"content": []})
    waitFor server.attachTransport(t)
    let peer = server.connect(t, legacyVersions()[^1], session = "s-progress")
    var reply: JsonNode
    let log = loggedWhile(proc() =
      reply = peer.ask("tools/call", %*{"name": "t"}, meta = %*{"progressToken": "p"}))
    check reply.hasKey("result")
    check log.linesOf().len == 1
    check "s-progress" in log
    check not log.raw()

  test "Given a request of the server that times out and a cancellation that cannot be sent, when the time is up, then the caller is told and one line names the method":
    let t = newSessionedTransport()
    let server = scripted()
    waitFor server.attachTransport(t)
    discard server.connect(t, legacyVersions()[^1], session = "s-timeout")
    t.failFor = "s-timeout"
    var timedOut = false
    let log = loggedWhile(proc() =
      try:
        discard waitFor server.request("s-timeout", "ping", newJObject(), timeoutMs = 50)
      except McpRequestTimeout:
        timedOut = true)
    check timedOut
    check log.linesOf().len == 1
    check "ping" in log
    check not log.raw()

  test "Given a stdio server whose notifications fail, when it ends a subscription, then one line names the request, without its control characters":
    for v in versionsWith(ftSubscriptionsListen):
      let server = scripted()
      let pair = newLoopbackPair()
      waitFor server.attachTransport(pair.server)
      pair.server.inject(%*{"jsonrpc": "2.0", "id": "listen-\x1b[2J7", "method": "subscriptions/listen",
        "params": {"_meta": modernMeta(), "notifications": {"toolsListChanged": true}}})
      untilTrue("the acknowledgment", proc(): bool =
        for message in pair.server.sent:
          if message{"method"}.getStr() == "notifications/subscriptions/acknowledged":
            return true
        false)
      pair.server.brokenNotifications = true
      let log = loggedWhile(proc() =
        waitFor server.endSubscriptions()
        settle())
      check log.linesOf().len == 1
      check "listen-" in log
      check not log.raw()
