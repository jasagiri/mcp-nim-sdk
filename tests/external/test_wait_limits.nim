## The time limit of a wait that ended is not left in the event loop
## (MCP-LIFECYCLE-29): when a wait of the SDK ends before its limit, the event
## loop holds no timer that falls due at that limit; what is left is the
## watcher's own sleep of at most 200 ms. A wait whose limit passes ends at its
## own limit, and a limit of 0 or less is none. Every test reaches the wait
## through a public entrance of the site and reads the timers of the event
## loop afterwards (asyncdispatch exports them). No test waits for a long
## limit to pass in real time, and none uses std/withTimeout, which would put
## a timer of its own in the loop. The HTTP servers that a test of another site
## starts have no read timeout (readTimeoutMs = 0), so that only the limit of
## the site under test is counted; the server's own limit has a suite of its
## own.

import std/[unittest, asyncdispatch, asyncnet, heapqueue, httpcore, json, monotimes,
            nativesockets, options, strutils, times]
import transport/http
import transport/http_wire as wire
import transport/http_server
import transport/sse_legacy
import transport/transport
import protocol/types
import protocol/version
import protocol/features
import protocol/tasks
import protocol/task_methods
import client/icons
import auth/client
import ./server_harness

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
  Speaks = min(DefaultProtocolVersion, mpv20251125)

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

proc url(server: Answering, path = "/"): string =
  "http://127.0.0.1:" & $server.port & path

proc png(): string =
  "HTTP/1.1 200 OK\c\LContent-Type: image/png\c\LContent-Length: " & $Png.len &
    "\c\LConnection: close\c\L\c\L" & Png

proc empty(code = "204 No Content"): string =
  "HTTP/1.1 " & code & "\c\LContent-Length: 0\c\LConnection: close\c\L\c\L"

proc jsonAnswer(code, reason, body: string): string =
  "HTTP/1.1 " & code & " " & reason & "\c\LContent-Type: application/json\c\LContent-Length: " &
    $body.len & "\c\LConnection: close\c\L\c\L" & body

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

suite "the time a request has to arrive at the HTTP server (transport/http_server)":

  test "Given an HTTP server with a read timeout of 600 s, when it has read and answered requests, then the event loop holds no timer due at that limit":
    let transport = newHttpServerTransport(port = 0, readTimeoutMs = LongMs)
    transport.listen()
    asyncCheck transport.serve()
    let before = farTimers()
    for i in 1 .. 3:
      let response = waitFor wire.request("http://127.0.0.1:" & $transport.port & "/mcp",
        HttpGet, connectTimeoutMs = 0, headerTimeoutMs = 0)
      checkpoint "request " & $i & " got " & $response.code
      response.close()
    untilQuiet(before, "the read timeout of the requests")
    waitFor transport.close()

suite "the wait for the endpoint event (transport/sse_legacy)":

  test "Given a legacy SSE server and a 600 s limit for the endpoint, when the client connected, then the event loop holds no timer due at that limit":
    let transport = newHttpServerTransport(port = 0, protocolVersion = mpv20241105,
      readTimeoutMs = 0)
    transport.listen()
    asyncCheck transport.serve()
    let client = newSseLegacyTransport("http://127.0.0.1:" & $transport.port & "/sse")
    client.connectTimeoutMs = LongMs
    let before = farTimers()
    waitFor client.sendNotification(newJsonRpcNotification("x", newJObject()))
    untilQuiet(before, "the endpoint event")
    waitFor client.close()

suite "the DELETE of a session that ends (transport/http)":

  test "Given a session and a server that answers the DELETE, when the client closes, then the event loop holds no timer due at the 5 s limit of the DELETE":
    # The limit of the DELETE is 5 s, so the bound is below it; no other limit
    # is on (connect 0 is none).
    if not DefaultProtocolVersion.has(ftStreamableHttp):
      skip()  # a build whose versions have no HTTP session to end
    else:
      let server = startAnswering(empty())
      let transport = newStreamableHttpTransport(server.url("/mcp"))
      transport.listenForServerMessages = false
      transport.connectTimeoutMs = 0
      transport.sessionId = some("s-1")
      transport.protocolVersionNegotiated(Speaks)
      let before = timersDueAfter(2_000)
      waitFor transport.close()
      check server.requests.len == 1
      check server.requests[0].startsWith("DELETE ")
      untilQuiet(before, "the DELETE", bound = 2_000)

suite "the time limit of an OAuth request (auth/oauth/fetch)":

  proc discover(origin: string, timeoutMs: int): string =
    ## The message of what a challenge naming origin/x as its resource
    ## metadata ends in ("" when it ends well).
    var policy = defaultFetchPolicy()
    policy.timeoutMs = timeoutMs
    var config = newOAuthClientConfig(origin & "/mcp", "http://127.0.0.1:8080/cb",
      proc(url: string): Future[seq[(string, string)]] {.async.} =
        doAssert false, "the user was sent to " & url
      , DefaultProtocolVersion)
    config.fetchPolicy = policy
    let client = newOAuthClient(config)
    try:
      discard waitFor client.handleChallenge(401,
        @["Bearer resource_metadata=\"" & origin & "/x\""])
    except OAuthError as e:
      return e.msg.split("\nAsync traceback:")[0]

  test "Given a metadata request with a 600 s limit, when the answer came, then the event loop holds no timer due at that limit":
    if not DefaultProtocolVersion.has(ftProtectedResourceMetadata):
      skip()
    else:
      let server = startAnswering(jsonAnswer("404", "Not Found", "{}"))
      let before = farTimers()
      let message = discover("http://127.0.0.1:" & $server.port, LongMs)
      check server.requests.len >= 1
      check "timed out" notin message
      untilQuiet(before, "the request of the OAuth client")

  test "Given a metadata request with a limit of 0, when the server answers after 400 ms, then the request is answered and does not time out":
    if not DefaultProtocolVersion.has(ftProtectedResourceMetadata):
      skip()
    else:
      let server = startAnswering(jsonAnswer("404", "Not Found", "{}"), delayMs = 400)
      let message = discover("http://127.0.0.1:" & $server.port, 0)
      check server.requests.len >= 1
      check "timed out" notin message
      check "404" in message

  test "Given a metadata request with a limit of 100 ms, when the server answers after 5 s, then the request ends at its limit with a timeout":
    if not DefaultProtocolVersion.has(ftProtectedResourceMetadata):
      skip()
    else:
      let server = startAnswering(jsonAnswer("404", "Not Found", "{}"), delayMs = 5_000)
      let began = epochTime()
      let message = discover("http://127.0.0.1:" & $server.port, 100)
      check "timed out after 100 ms" in message
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

suite "the time limit of a request of the server to its client (server/server)":

  test "Given a server request with a 600 s limit, when the client answered, then the event loop holds no timer due at that limit":
    let server = newServer(McpServerCapabilities())
    let t = server.attach()
    discard server.connect(t, Speaks, session = "s")
    let before = farTimers()
    let pending = server.request("s", "ping", newJObject(), timeoutMs = LongMs)
    untilTrue("the server's ping", proc(): bool = t.messagesOf("ping").len > 0)
    let asked = t.messagesOf("ping")[0]
    t.inject("s", %*{"jsonrpc": "2.0", "id": asked.message["id"], "result": newJObject()})
    discard waitFor pending
    untilQuiet(before, "the request to the client")

suite "the wait for the result of a task (protocol/task_store)":

  type FakeTime = ref object
    nowMs: int64

  proc storeAt(time: FakeTime): TaskStore =
    newTaskStore(clock = proc(): int64 = time.nowMs, defaultTtlMs = some(3_600_000'i64),
                 maxTtlMs = none(int64), pollIntervalMs = some(250))

  test "Given a wait for a task that lives for ten minutes, when the task completed, then the event loop holds no timer due at its expiry":
    let time = FakeTime(nowMs: 1_000)
    let store = time.storeAt()
    let work = newFuture[JsonRpcResponse]("work")
    let task = runAsTask(store, "a", some(int64(LongMs)), proc(id: string): TaskWork =
      (response: work, cancel: nil))
    let before = farTimers()
    let waiting = store.awaitOutcome("a", task.taskId)
    waitFor sleepAsync(10)
    check not waiting.finished
    work.complete(JsonRpcResponse(jsonrpc: "2.0", id: "1", result: some(%*{"ok": true}),
                                  error: none(JsonRpcError)))
    let outcome = waitFor waiting
    check outcome.result.isSome
    untilQuiet(before, "the wait for the task")

  test "Given a wait for a task whose time to live is 300 ms, when the clock passes it, then the wait ends at the expiry with McpTaskError":
    let time = FakeTime(nowMs: 1_000)
    let store = time.storeAt()
    let work = newFuture[JsonRpcResponse]("work")
    let task = runAsTask(store, "a", some(300'i64), proc(id: string): TaskWork =
      (response: work, cancel: nil))
    let waiting = store.awaitOutcome("a", task.taskId)
    waitFor sleepAsync(10)
    time.nowMs += 300
    let began = epochTime()
    expect McpTaskError:
      discard waitFor waiting
    check epochTime() - began < 2.0

suite "the keep-alive period of an event stream (transport/sse_stream)":

  test "Given an event stream with a 600 s keep-alive period, when the client left, then the event loop holds no timer due at that period":
    let transport = newHttpServerTransport(port = 0, protocolVersion = mpv20241105,
      readTimeoutMs = 0)
    transport.sseKeepAliveMs = LongMs
    transport.listen()
    asyncCheck transport.serve()
    let before = farTimers()  # before the stream: its period starts when it opens
    let sock = newAsyncSocket(buffered = false)
    waitFor sock.connect("127.0.0.1", Port(transport.port))
    waitFor sock.send("GET /sse HTTP/1.1\c\LHost: localhost\c\LAccept: text/event-stream\c\L\c\L")
    var seen = ""
    let deadline = epochTime() + 5
    while "endpoint" notin seen and epochTime() < deadline:
      let chunk = waitFor sock.recv(1024)
      doAssert chunk.len > 0, "the stream ended before the endpoint event"
      seen.add chunk
    check "endpoint" in seen
    # While the stream is open the watcher holds the period; it leaves with
    # the client, and that is when the loop must be rid of it.
    sock.close()
    untilQuiet(before, "the keep-alive period of a stream whose client left")
