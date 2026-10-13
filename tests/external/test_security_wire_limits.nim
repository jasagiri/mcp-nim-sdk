## What the client reads from a server is bounded: a line or an event of an
## event stream that grows without end is an error, and a server that takes
## the connection and never answers does not hold the caller for ever.

import std/[unittest, asyncdispatch, asyncnet, json, nativesockets, strutils]
import transport/event_stream
import transport/http
import protocol/types

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

suite "limits of the event stream parser":

  test "Given a line that does not end within the limit, when it is fed, then SseLimitError is raised before the line is complete":
    var parser = initSseParser(maxLineBytes = 100)
    discard parser.feed("data: " & repeat('x', 90))
    expect SseLimitError:
      discard parser.feed(repeat('x', 20))

  test "Given data lines that add up past the event limit, when they are fed, then SseLimitError is raised before the event is complete":
    var parser = initSseParser(maxEventBytes = 100)
    for i in 1 .. 10:
      discard parser.feed("data: " & repeat('x', 9) & "\n")
    expect SseLimitError:
      discard parser.feed("data: " & repeat('x', 9) & "\n")

  test "Given events within both limits, when they are fed, then each is delivered":
    var parser = initSseParser(maxLineBytes = 100, maxEventBytes = 100)
    var events: seq[SseEvent]
    for i in 1 .. 5:
      events.add parser.feed("data: " & repeat('y', 60) & "\n\n")
    check events.len == 5
    check events[0].data.len == 60

suite "a server that sends too much or too little":

  test "Given an event stream whose line never ends, when the line is longer than the response limit, then the request fails instead of buffering on":
    let server = startServer(streamBytes = 5000)
    let transport = newStreamableHttpTransport(server.url)
    transport.maxResponseSize = 1000
    var lost: seq[string]
    transport.onRequestLost = proc(requestId: string, reason: string) = lost.add requestId
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
    var waited = 0
    while lost.len == 0 and waited < 3000:
      waitFor sleepAsync(10)
      waited += 10
    check lost == @["r1"]

