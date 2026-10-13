## What the client reads from a server is bounded: a line or an event of an
## event stream that grows without end is an error, and a server that takes
## the connection and never answers does not hold the caller for ever.

import std/[unittest, asyncdispatch, asyncnet, httpcore, nativesockets, strutils]
import transport/http_wire as wire

type Silent = ref object
  socket: AsyncSocket
  port: int
  held: seq[AsyncSocket]
  streamBytes: int
  delayMs: int

proc startServer(streamBytes = 0, delayMs = 0): Silent =
  ## Accepts connections and reads the request. With `streamBytes` it answers
  ## with an event stream of that many bytes that never end a line and then
  ## stays open; with `delayMs` it answers 200 after that long; else it says
  ## nothing.
  let server = Silent(socket: newAsyncSocket(buffered = false),
                      streamBytes: streamBytes, delayMs: delayMs)
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.bindAddr(Port(0), "127.0.0.1")
  server.socket.listen()
  server.port = server.socket.getLocalAddr()[1].int
  proc serve(client: AsyncSocket) {.async.} =
    server.held.add client
    var request = ""
    while not request.contains("\c\L\c\L"):
      let data = await client.recv(4096)
      if data.len == 0:
        return
      request.add data
    if server.streamBytes > 0:
      await client.send("HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" &
                        "Connection: close\c\L\c\L")
      await client.send("data: " & repeat('x', server.streamBytes))
    elif server.delayMs > 0:
      await sleepAsync(server.delayMs)
      await client.send("HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L")
  proc acceptLoop() {.async.} =
    while true:
      asyncCheck serve(await server.socket.accept())
  asyncCheck acceptLoop()
  server

proc url(server: Silent): string =
  "http://127.0.0.1:" & $server.port & "/mcp"

proc outcome[T](future: Future[T], limitMs = 5000): string =
  ## "pending" when `future` did not end within `limitMs`, "ok", or the
  ## message of its failure.
  var waited = 0
  while not future.finished and waited < limitMs:
    poll(20)
    waited += 20
  if not future.finished: "pending"
  elif future.failed: future.readError().msg
  else: "ok"


suite "a server that sends too much or too little":


  test "Given a server that never answers, when a header timeout is given, then the request fails after it":
    let server = startServer()
    let attempt = wire.request(server.url, HttpGet, headerTimeoutMs = 200)
    check "no response" in attempt.outcome(3000)

  test "Given no header timeout, when a server answers after a while, then the response is waited for":
    let server = startServer(delayMs = 500)
    let attempt = wire.request(server.url, HttpGet)
    check attempt.outcome == "ok"
