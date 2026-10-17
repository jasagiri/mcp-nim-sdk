## A client of the HTTP transport has a limited time to send its request: one
## that connects and sends nothing, or stops halfway, loses the connection
## instead of holding it (and a file descriptor) for as long as it likes.

import std/[unittest, asyncdispatch, asyncnet, net, strutils, times]
import mcp

proc started(readTimeoutMs: int): HttpServerTransport =
  result = newHttpServerTransport(port = 0, readTimeoutMs = readTimeoutMs)
  result.listen()
  asyncCheck result.serve()

proc connected(transport: HttpServerTransport): AsyncSocket =
  result = newAsyncSocket(buffered = false)
  waitFor result.connect("127.0.0.1", Port(transport.port))

proc everythingUntilClosed(socket: AsyncSocket, limitMs: int): tuple[data: string, closed: bool] =
  ## What the server sends until it closes the connection, waiting at most
  ## `limitMs` in all.
  let deadline = epochTime() + limitMs / 1000
  while epochTime() < deadline:
    let chunk = socket.recv(4096)
    if not waitFor withTimeout(chunk, max(1, int((deadline - epochTime()) * 1000))):
      return (result.data, false)
    let data = chunk.read()
    if data.len == 0:
      return (result.data, true)
    result.data.add data

suite "a client that does not finish sending its request does not keep the connection":

  test "Given a limit of 300 ms, when a client connects and sends nothing, then the connection is closed without an answer":
    let transport = started(readTimeoutMs = 300)
    let socket = transport.connected()
    let began = epochTime()
    let (data, closed) = socket.everythingUntilClosed(3000)
    check closed
    check data == ""
    check epochTime() - began >= 0.25
    socket.close()
    waitFor transport.close()

  test "Given a limit of 300 ms, when a client sends the request line and stops, then it is answered 408 and the connection is closed":
    let transport = started(readTimeoutMs = 300)
    let socket = transport.connected()
    waitFor socket.send("POST /mcp HTTP/1.1\c\LHost: 127.0.0.1\c\L")
    let (data, closed) = socket.everythingUntilClosed(3000)
    check closed
    check data.startsWith("HTTP/1.1 408")
    socket.close()
    waitFor transport.close()

  test "Given a limit of 300 ms, when a whole request arrives in time, then it is answered":
    let transport = started(readTimeoutMs = 300)
    let socket = transport.connected()
    waitFor socket.send("GET /mcp HTTP/1.1\c\LHost: 127.0.0.1:" & $transport.port &
                        "\c\LAccept: text/event-stream\c\LConnection: close\c\L\c\L")
    let (data, _) = socket.everythingUntilClosed(3000)
    check data.startsWith("HTTP/1.1 ")
    check not data.startsWith("HTTP/1.1 408")
    socket.close()
    waitFor transport.close()

  test "Given no limit given, when the transport is made, then a request has 30 seconds; 0 means no limit":
    check newHttpServerTransport(port = 0).readTimeoutMs == 30_000
    check DefaultReadTimeoutMs == 30_000
    check newHttpServerTransport(port = 0, readTimeoutMs = 0).readTimeoutMs == 0
