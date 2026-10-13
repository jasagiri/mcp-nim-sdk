## What a peer writes into a diagnostic line is made harmless
## (MCP-SEC-HTTP-7): control characters cannot forge a line or move the
## cursor, and one message cannot fill the log.

import std/[unittest, asyncdispatch, json, options, os, strutils]
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
