## What a peer writes into a diagnostic line is made harmless
## (MCP-SEC-HTTP-7): control characters cannot forge a line or move the
## cursor, and one message cannot fill the log.

import std/[unittest, asyncdispatch, json, options, os, strutils, sequtils]
import loopback_transport
import server/server
import protocol/types
import protocol/version

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-sec-diagnostic-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc idShown(id: string): tuple[line: string, shown: string] =
  ## What the server writes about a response with this id and no request:
  ## the whole log, and the part of it that stands for the id.
  let (_, serverSide) = newLoopbackPair()
  let server = newMcpServer(McpServerInfo(name: "s", version: "1"))
  waitFor server.attachTransport(serverSide)
  let logged = loggedWhile(proc() =
    serverSide.inject(%*{"jsonrpc": "2.0", "id": id, "result": {}})
    waitFor sleepAsync(50))
  const before = "request id '"
  const after = "' ignored"
  let a = logged.find(before)
  let b = logged.rfind(after)
  doAssert a >= 0 and b > a, "no diagnostic about the response: " & logged
  (logged, logged[a + before.len ..< b])

suite "peer text in diagnostics (MCP-SEC-HTTP-7)":


  test "Given a message that is no JSON-RPC message, when the server logs it, then the log holds one line without the control characters":
    let (_, serverSide) = newLoopbackPair()
    let server = newMcpServer(McpServerInfo(name: "s", version: "1"))
    waitFor server.attachTransport(serverSide)
    let logged = loggedWhile(proc() =
      serverSide.inject(%*{"x": "a\n[mcp-server] forged \e[2J"})
      waitFor sleepAsync(50))
    check "\e" notin logged
    check logged.count('\n') == 1
    check "[mcp-server] invalid message" in logged


  test "Given a response to no request, when the server logs its id, then the id is made fit":
    let (_, serverSide) = newLoopbackPair()
    let server = newMcpServer(McpServerInfo(name: "s", version: "1"))
    waitFor server.attachTransport(serverSide)
    let logged = loggedWhile(proc() =
      serverSide.inject(%*{"jsonrpc": "2.0", "id": "a\n[mcp-server] forged \e[2J", "result": {}})
      waitFor sleepAsync(50))
    check "\e" notin logged
    check logged.count('\n') == 1
    check "a\\n[mcp-server] forged \\x1b[2J" in logged

  if isSupported(mpv20260728):
    test "Given a tool whose result names a resultType no extension defines, when the server logs it, then the name is made fit":
      # A tool may pass on what another party gave it.
      let (_, serverSide) = newLoopbackPair()
      let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
        capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        return %*{"content": [], "resultType": "x\n[mcp-server] forged \e[2J"})
      waitFor server.attachTransport(serverSide)
      let logged = loggedWhile(proc() =
        serverSide.inject(%*{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
          "name": "t", "arguments": {},
          "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "1"},
                    "io.modelcontextprotocol/clientCapabilities": {}}}})
        waitFor sleepAsync(50))
      check "\e" notin logged
      check logged.count('\n') == 1
      check "x\\n[mcp-server] forged \\x1b[2J" in logged


  test "Given an id with dangerous code points between letters, when the server logs it, then none is written raw and each is shown as an escape":
    # C1 control, line separator, bidi override, bidi isolate, direction mark, Arabic letter mark.
    let hostile = ["\u0085", "\u2028", "\u202e", "\u2066", "\u200e", "\u061c"]
    var id = ""
    for i, h in hostile: id.add $char(ord('a') + i) & h
    id.add "g"
    let (logged, shown) = idShown(id)
    check logged.count('\n') == 1
    for h in hostile:
      check h notin logged
    check shown.count('\\') == hostile.len
    var at = 0
    for c in "abcdefg":
      let found = shown.find(c, at)
      check found >= 0
      at = found + 1

  test "Given an id of valid non-ASCII characters, when the server logs it, then it is written as it came":
    # 2, 3 (lowest lead byte E0) and 4 bytes (lowest lead byte F0), ending on one.
    let id = "\xc3\xa9\xe0\xa0\x80\xf0\x9f\x98\x80\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e"
    let (_, shown) = idShown(id)
    check shown == id

  test "Given an id with bytes that are not valid UTF-8, when the server logs it, then no such byte is written raw and each is shown as an escape":
    # A lone continuation byte, a lead byte followed by ASCII, a character cut off at the end.
    let (logged, shown) = idShown("a\x80b\xc3cd\xe3\x81")
    check logged.count('\n') == 1
    for bad in ["\x80", "\xc3", "\xe3", "\x81"]:
      check bad notin logged
    check shown.count('\\') == 4
    check shown.find("a") < shown.find("b")
    check shown.find("b") < shown.find("cd")

  test "Given an id with a carriage return and a tab, when the server logs it, then neither is written raw and each is shown as an escape":
    let (logged, shown) = idShown("a\rb\tc")
    check '\r' notin logged
    check '\t' notin logged
    check logged.count('\n') == 1
    check shown.count('\\') == 2
    check shown.find("a") < shown.find("b")
    check shown.find("b") < shown.find("c")

  test "Given an id that holds a typed backslash and n, when the server logs it, then the log tells it from a line break":
    let (_, typed) = idShown("a\\nb")
    let (_, broken) = idShown("a\nb")
    check '\\' in typed
    check typed != broken

  test "Given an id of exactly the limit, when the server logs it, then it is written whole":
    let id = 'x'.repeat(200)
    let (_, shown) = idShown(id)
    check shown == id

  test "Given an id longer than the limit, when the server logs it, then it is cut at 200 bytes and the number of bytes left out is given":
    for extra in [1, 25]:
      let (logged, shown) = idShown('x'.repeat(200 + extra))
      check logged.count('\n') == 1
      check shown.startsWith('x'.repeat(200))
      let rest = shown[200 .. ^1]
      check rest.len > 0
      check 'x' notin rest
      let digits = rest.filterIt(it in Digits).join
      check digits.len > 0
      check digits.parseInt == extra
