## The time limit of a wait that ended is not left in the event loop
## (MCP-LIFECYCLE-29), for the two sites whose test needs the HTTP wire itself:
## a request of transport/http_wire, and an icon fetch, whose IconGet hook
## returns a WireResponse. The other sites are checked from the entries in
## tests/external/test_wait_limits.nim, which says how the timers are read.
##
## Internal (I), not external: the HTTP wire is not exported by any entry,
## and an icon fetch from the entries goes to an https server only, which a
## test on this machine does not have; the hook that points it at a plain
## local server has to build the wire's response.

import std/[unittest, asyncdispatch, asyncnet, heapqueue, httpcore, monotimes,
            nativesockets, strutils, times]
import transport/http_wire as wire
import transport/transport
import client/icons
import client/content

const
  LongMs = 600_000
    ## The limit under test: far longer than the test runs.
  FarMs = 5_000
    ## A timer due later than this is a limit that was left behind. Timers of
    ## the tests themselves (a few milliseconds) and of the watcher (at most
    ## 200 ms) fall due sooner.
  QuietWithinMs = 2_000
    ## What a test waits for the loop to let go of a limit that ended.
  Png = "\x89PNG\r\n\x1a\n" & "rest of a png"

proc timersDueAfter(ms: int): int =
  ## How many timers of this thread's event loop fall due later than ms
  ## milliseconds from now.
  let limit = getMonoTime() + initDuration(milliseconds = ms)
  let timers = getGlobalDispatcher().timers
  for i in 0 ..< timers.len:
    if timers[i].finishAt > limit:
      inc result

proc farTimers(): int =
  timersDueAfter(FarMs)

proc waitQuiet(before: int, bound: int) =
  ## Waits (against a deadline) for the loop to hold no more timers due after
  ## bound than it did at the start of the test.
  let deadline = epochTime() + QuietWithinMs / 1000
  while timersDueAfter(bound) > before and epochTime() < deadline:
    waitFor sleepAsync(5)

template untilQuiet(before: int, what: string, bound = FarMs) =
  ## Then says whether it did. (A template: check belongs to the test body.)
  waitQuiet(before, bound)
  checkpoint what
  check timersDueAfter(bound) <= before


# ---- a server that answers every connection with one fixed text ----------

type Answering = ref object
  socket: AsyncSocket
  port: int
  requests: seq[string]  ## the head of each request

proc readHead(client: AsyncSocket): Future[string] {.async.} =
  while not result.endsWith("\c\L\c\L"):
    let chunk = await client.recv(1)
    if chunk.len == 0:
      break
    result.add chunk

proc startAnswering(answer: string, delayMs = 0): Answering =
  ## Reads a request head, waits delayMs, sends answer and closes.
  let server = Answering(socket: newAsyncSocket(buffered = false))
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.bindAddr(Port(0), "127.0.0.1")
  server.socket.listen()
  server.port = server.socket.getLocalAddr()[1].int
  proc serveOne(client: AsyncSocket) {.async.} =
    try:
      server.requests.add await client.readHead()
      if delayMs > 0:
        await sleepAsync(delayMs)
      await client.send(answer)
    except OSError:
      discard  # the peer left; nothing is owed to it
    finally:
      client.close()
  proc acceptLoop() {.async.} =
    while true:
      asyncCheck serveOne(await server.socket.accept())
  asyncCheck acceptLoop()
  server

proc empty(code = "204 No Content"): string =
  "HTTP/1.1 " & code & "\c\LContent-Length: 0\c\LConnection: close\c\L\c\L"

proc url(server: Answering, path = "/"): string =
  "http://127.0.0.1:" & $server.port & path

proc png(): string =
  "HTTP/1.1 200 OK\c\LContent-Type: image/png\c\LContent-Length: " & $Png.len &
    "\c\LConnection: close\c\L\c\L" & Png

suite "the limits of a connection and of a response head (transport/http_wire)":

  test "Given a request with a 600 s limit to connect and to be answered, when the answer came, then the event loop holds no timer due at those limits":
    let server = startAnswering(empty("200 OK"))
    let before = farTimers()
    let response = waitFor wire.request(server.url, HttpGet,
      connectTimeoutMs = LongMs, headerTimeoutMs = LongMs)
    check response.code == Http200
    response.close()
    untilQuiet(before, "the connect and the head of the answer")

  test "Given a request with a 600 s limit to connect and none for the head, when the connection was made, then the event loop holds no timer due at that limit":
    let server = startAnswering(empty("200 OK"))
    let before = farTimers()
    let response = waitFor wire.request(server.url, HttpGet,
      connectTimeoutMs = LongMs, headerTimeoutMs = 0)
    response.close()
    untilQuiet(before, "the connect")

  test "Given a request with a 600 s limit for the head and none to connect, when the head came, then the event loop holds no timer due at that limit":
    let server = startAnswering(empty("200 OK"))
    let before = farTimers()
    let response = waitFor wire.request(server.url, HttpGet,
      connectTimeoutMs = 0, headerTimeoutMs = LongMs)
    response.close()
    untilQuiet(before, "the head of the answer")

  test "Given a server that never answers, when the head limit of 100 ms passes, then the request fails at that limit with McpTransportError":
    let server = startAnswering(empty("200 OK"), delayMs = 60_000)
    let began = epochTime()
    expect McpTransportError:
      discard waitFor wire.request(server.url, HttpGet, headerTimeoutMs = 100)
    check epochTime() - began < 2.0

suite "the time limit of an icon fetch (client/icons)":

  proc via(server: Answering, path = "/icon.png"): IconGet =
    ## Points the fetch at the plain local server; the rest is the real code.
    let port = server.port
    result = proc(url: string, headers: HttpHeaders): Future[WireResponse] {.closure, gcsafe.} =
      wire.request("http://127.0.0.1:" & $port & path, HttpGet, headers)

  let icon = McpIcon(src: "https://icons.example/icon.png")

  test "Given an icon fetch with a 600 s limit, when the icon was read, then the event loop holds no timer due at that limit":
    let server = startAnswering(png())
    let before = farTimers()
    let fetched = waitFor fetchIcon(icon, "https://icons.example",
      IconFetchOptions(timeoutMs: LongMs, get: server.via))
    check fetched.kind == itPng
    untilQuiet(before, "the fetch and the read of the icon")

  test "Given an icon fetch with a limit of 0, when the server answers after 400 ms, then the icon is fetched":
    let server = startAnswering(png(), delayMs = 400)
    let fetched = waitFor fetchIcon(icon, "https://icons.example",
      IconFetchOptions(timeoutMs: 0, get: server.via))
    check fetched.kind == itPng

  test "Given an icon fetch with a limit of 100 ms, when the server answers after 5 s, then McpIconError is raised at the limit":
    let server = startAnswering(png(), delayMs = 5_000)
    let began = epochTime()
    expect McpIconError:
      discard waitFor fetchIcon(icon, "https://icons.example",
        IconFetchOptions(timeoutMs: 100, get: server.via))
    check epochTime() - began < 2.0
