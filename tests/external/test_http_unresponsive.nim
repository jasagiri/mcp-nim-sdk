## A server that accepts the connection and never answers: the client's
## timeouts must still end the wait.

import std/[unittest, asyncdispatch, asyncnet, json, nativesockets, options, times]
import transport/http
import client/client
import protocol/types

type SilentServer = ref object
  socket: AsyncSocket
  port: int
  held: seq[AsyncSocket]
    ## Kept open so the peer sees no end of stream either.

proc startSilentServer(): SilentServer =
  let server = SilentServer(socket: newAsyncSocket())
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.bindAddr(Port(0), "127.0.0.1")
  server.socket.listen()
  server.port = server.socket.getLocalAddr()[1].int
  proc acceptLoop() {.async.} =
    while true:
      server.held.add(await server.socket.accept())
  asyncCheck acceptLoop()
  server

proc elapsedMs(since: float): int =
  int((epochTime() - since) * 1000)

proc outcome[T](future: Future[T], limitMs: int): string =
  ## "pending" when `future` has not ended within `limitMs`, otherwise "ok"
  ## or the name of the exception it failed with.
  let deadline = epochTime() + limitMs / 1000
  while not future.finished and epochTime() < deadline:
    poll(20)
  if not future.finished: "pending"
  elif future.failed: $future.readError().name
  else: "ok"

suite "a server that never answers":

  test "Given a server that never answers, when a client connects, then the probe and the handshake time out instead of waiting forever":
    let server = startSilentServer()
    let client = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"))
    client.probeTimeoutMs = 200
    client.requestTimeoutMs = 300
    let started = epochTime()
    let connecting = client.connect(newStreamableHttpTransport(
      "http://127.0.0.1:" & $server.port & "/mcp"))
    check connecting.outcome(5000) == "McpTimeoutError"
    check elapsedMs(started) < 3000

  test "Given a server that never answers, when a request has its own timeout, then McpTimeoutError is raised after it":
    let server = startSilentServer()
    let client = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"))
    client.probeTimeoutMs = 100
    client.requestTimeoutMs = 100
    let connecting = client.connect(newStreamableHttpTransport(
      "http://127.0.0.1:" & $server.port & "/mcp"))
    check connecting.outcome(3000) == "McpTimeoutError"
    # The handshake failed; a request sent anyway must not hang either.
    let started = epochTime()
    let asking = client.sendRequest("tools/list", newJObject(),
      McpRequestOptions(timeoutMs: some(200)))
    check asking.outcome(3000) == "McpTimeoutError"
    check elapsedMs(started) < 2000
    check server.held.len >= 2
