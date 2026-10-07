## What a peer writes into a diagnostic line is made harmless
## (MCP-SEC-HTTP-7): control characters cannot forge a line or move the
## cursor, and one message cannot fill the log.

import std/[unittest, asyncdispatch, json, options, os, strutils]
import loopback_transport
import server/server
import protocol/diagnostic
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

suite "peer text in diagnostics (MCP-SEC-HTTP-7)":
  test "Given text with line breaks and escape characters, when made fit for a log, then none survives":
    let shown = peerText("ok\r\n[mcp-server] forged\e[31m\x07\x7f\u0085 ‮")
    check shown == "ok\\r\\n[mcp-server] forged\\x1b[31m\\x07\\x7f\\u{0085}\\u{2028}\\u{202e}"
    for c in shown:
      check c.ord >= 0x20 and c.ord != 0x7f

  test "Given plain text including non-ASCII letters, when made fit for a log, then it is unchanged":
    check peerText("tools/call 日本語 é") == "tools/call 日本語 é"

  test "Given bytes that are not UTF-8, when made fit for a log, then each is shown as an escape":
    check peerText("a\x9bb\xc3") == "a\\x9bb\\xc3"

  test "Given a lone continuation byte, when made fit for a log, then it is shown as an escape":
    # 0x80 is the first byte that is not ASCII; it starts no character.
    check peerText("a\x80b") == "a\\x80b"

  test "Given tab and backslash, when made fit for a log, then each is shown as an escape":
    check peerText("a\tb") == "a\\tb"
    check peerText("a\\nb") == "a\\\\nb"   # a typed backslash-n differs from a line break

  test "Given characters of three and four bytes, when made fit for a log, then they are unchanged":
    # E0 and F0 are the lowest lead bytes of three- and four-byte characters.
    check peerText("\xe0\xa0\x80") == "\xe0\xa0\x80"
    check peerText("\xf0\x9f\x98\x80") == "\xf0\x9f\x98\x80"

  test "Given an overlong encoding of a control character, when made fit for a log, then its bytes are shown as escapes":
    check peerText("\xc0\x80") == "\\xc0\\x80"
    check peerText("\xc0") == "\\xc0"

  test "Given text of exactly the limit and one byte more, when made fit for a log, then only the longer one is cut":
    check peerText("x".repeat(10), maxLen = 10) == "x".repeat(10)
    check peerText("x".repeat(11), maxLen = 10) == "x".repeat(10) & "...(1 more bytes)"
    check peerText("x".repeat(25), maxLen = 10) == "x".repeat(10) & "...(15 more bytes)"

  test "Given text longer than the limit, when made fit for a log, then it is cut at a character and the rest is counted":
    let shown = peerText("あ".repeat(100), maxLen = 10)
    check shown.startsWith("あ".repeat(4))
    check shown.endsWith("more bytes)")
    check shown.len < 40
    check peerText("x".repeat(1000)).len < DefaultPeerTextLength + 30

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

  test "Given a message that is no JSON-RPC message and very long, when the server logs it, then the log line is short":
    let (_, serverSide) = newLoopbackPair()
    let server = newMcpServer(McpServerInfo(name: "s", version: "1"))
    waitFor server.attachTransport(serverSide)
    let logged = loggedWhile(proc() =
      serverSide.inject(%*{"x": "y".repeat(100_000)})
      waitFor sleepAsync(50))
    check logged.len < 2 * DefaultPeerTextLength

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
