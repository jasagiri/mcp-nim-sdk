## What the server of a client writes into a diagnostic line is made
## harmless (MCP-SEC-HTTP-7): the client's lines hold the text of a peer
## only as escapes and cut short.

import std/[unittest, asyncdispatch, json, os, strutils]
import client/client
import protocol/types
import ./client_peer
import ./loopback_transport

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-sec-diagnostic-client-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

const Hostile = "x\n[mcp-client] forged line \e[2J"

suite "peer text in the diagnostics of the client (MCP-SEC-HTTP-7)":
  test "Given a server message that is no JSON-RPC message, when the client logs it, then the log holds one line without the control characters":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    let logged = loggedWhile(proc() =
      peer.pair.client.inject(%*{"x": Hostile})
      waitFor sleepAsync(50))
    check "\e" notin logged
    check logged.count('\n') == 1
    check "[mcp-client] invalid message" in logged
    waitFor client.close()

  test "Given a server message that is no JSON-RPC message and very long, when the client logs it, then the log line is short":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    let logged = loggedWhile(proc() =
      peer.pair.client.inject(%*{"x": "y".repeat(100_000)})
      waitFor sleepAsync(50))
    check logged.len < 1000
    check logged.count('\n') == 1
    waitFor client.close()

  test "Given a request whose method name is hostile and whose handler fails with a hostile message, when the client logs it, then both are shown as escapes":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault, proc(c: McpClient) =
      c.registerRequestHandler(Hostile, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
        raise newException(ValueError, Hostile)))
    let logged = loggedWhile(proc() =
      peer.ask(%1, Hostile)
      waitFor sleepAsync(50))
    check "\e" notin logged
    check logged.count('\n') == 1
    check logged.count("\\n[mcp-client] forged line \\x1b[2J") == 2
    waitFor client.close()
