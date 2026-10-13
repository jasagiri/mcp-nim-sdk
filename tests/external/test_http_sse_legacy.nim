## The HTTP+SSE transport of protocol version 2024-11-05: the client opens an
## event stream, learns from its `endpoint` event where to POST, and from
## then on sends by POST and receives on the stream. Checked on the server
## side with a plain wire client, on the client side against this SDK's
## server and a hand-written one, and through the fallback of a client that
## tries Streamable HTTP first.

import std/[unittest, asyncdispatch, asyncnet, httpclient, json, options,
            strutils, uri]
import sse_reader
import transport/transport

import transport/http_server
import transport/http_compat
import transport/event_stream
import server/server
import client/client
import protocol/types

type Script = ref object
  answered: seq[JsonNode]
  ended: seq[string]

proc runScript(t: HttpServerTransport, s: Script) {.async.} =
  ## `initialize` answers with 2024-11-05; `work` sends a progress
  ## notification related to the request, then answers; anything else
  ## answers at once.
  while true:
    let incoming = await t.receive()
    let message = incoming.message
    if not isRequest(message):
      s.answered.add message
      continue
    let id = message["id"].getStr()
    case message["method"].getStr()
    of "initialize":
      await t.sendResponse(newJsonRpcResponse(id, %*{
        "protocolVersion": "2024-11-05", "capabilities": {},
        "serverInfo": {"name": "script", "version": "0"}}))
    of "work":
      await t.sendNotification(
        newJsonRpcNotification("notifications/progress", %*{"progressToken": "t", "progress": 1}),
        MessageRoute(session: incoming.session, requestId: id))
      await t.sendResponse(newJsonRpcResponse(id, %*{"done": true}))
    else:
      await t.sendResponse(newJsonRpcResponse(id, %*{}))

proc startLegacy(): tuple[transport: HttpServerTransport, base: string, script: Script] =
  let transport = newHttpServerTransport(port = 0, protocolVersion = mpv20241105)
  let script = Script()
  transport.onSessionEnd = proc(session: string) {.closure, gcsafe.} =
    script.ended.add session
  transport.listen()
  asyncCheck transport.serve()
  asyncCheck runScript(transport, script)
  (transport, "http://127.0.0.1:" & $transport.port, script)

proc openSse(base: string, headers: openArray[(string, string)] = []): Events =
  open(base & "/sse", HttpGet, "", @[("Accept", "text/event-stream")] & @headers)

proc endpointOf(stream: Events): string =
  let first = stream.next().get
  doAssert first.event == "endpoint", "first event was " & first.event
  first.data

proc postTo(base, endpoint: string, body: JsonNode): tuple[code: HttpCode, body: string] =
  let http = newAsyncHttpClient()
  defer: http.close()
  let response = waitFor http.request(base & endpoint, HttpPost, $body,
    newHttpHeaders({"Content-Type": "application/json"}))
  (response.code, waitFor response.body)

proc rpc(id: int, name: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "method": name, "params": {}}

proc nextMessage(stream: Events): JsonNode =
  let event = stream.next().get
  doAssert event.event == "message", "event was " & event.event
  parseJson(event.data)

suite "HTTP+SSE server (2024-11-05)":

  test "Given a GET on the SSE path, when answered, then it is an event stream whose first event names the endpoint":
    let (_, base, _) = startLegacy()
    let stream = openSse(base)
    check stream.code == Http200
    check stream.contentType.startsWith("text/event-stream")
    check stream.endpointOf().startsWith("/messages?sessionId=")
    stream.close()

  test "Given two connections, when each is answered, then the endpoints differ":
    let (_, base, _) = startLegacy()
    let a = openSse(base)
    let b = openSse(base)
    check a.endpointOf() != b.endpointOf()
    a.close()
    b.close()

  test "Given a request posted to the endpoint, when the server answers, then the POST gets 202 and the answer arrives on the stream":
    let (_, base, _) = startLegacy()
    let stream = openSse(base)
    let endpoint = stream.endpointOf()
    let reply = postTo(base, endpoint, rpc(5, "ping"))
    check reply.code == Http202
    let answer = stream.nextMessage()
    check answer["id"].getInt() == 5
    check answer.hasKey("result")
    stream.close()

  test "Given a request during which the server sent a notification, when posted, then both arrive on the stream in order":
    let (_, base, _) = startLegacy()
    let stream = openSse(base)
    discard postTo(base, stream.endpointOf(), rpc(6, "work"))
    check stream.nextMessage()["method"].getStr() == "notifications/progress"
    check stream.nextMessage()["id"].getInt() == 6
    stream.close()

  test "Given two clients using the same request id, when both are answered, then each answer reaches the right stream":
    let (_, base, _) = startLegacy()
    let a = openSse(base)
    let b = openSse(base)
    let endpointA = a.endpointOf()
    let endpointB = b.endpointOf()
    discard postTo(base, endpointA, rpc(1, "work"))
    discard postTo(base, endpointB, rpc(1, "ping"))
    check a.nextMessage()["method"].getStr() == "notifications/progress"
    check a.nextMessage()["result"]["done"].getBool()
    check b.nextMessage()["id"].getInt() == 1
    a.close()
    b.close()

  test "Given a notification the server sends to every client, when two connections are open, then each hears it":
    let (transport, base, _) = startLegacy()
    let a = openSse(base)
    let b = openSse(base)
    discard a.endpointOf()
    discard b.endpointOf()
    waitFor transport.sendNotification(
      newJsonRpcNotification("notifications/tools/list_changed", newJObject()))
    check a.nextMessage()["method"].getStr() == "notifications/tools/list_changed"
    check b.nextMessage()["method"].getStr() == "notifications/tools/list_changed"
    a.close()
    b.close()

  test "Given a request the server sends, when the client answers by POST, then the server receives the answer":
    let (transport, base, script) = startLegacy()
    let stream = openSse(base)
    let endpoint = stream.endpointOf()
    waitFor transport.sendRequest(newJsonRpcRequest("srv-1", "roots/list", newJObject()))
    check stream.nextMessage()["id"].getStr() == "srv-1"
    check postTo(base, endpoint, %*{"jsonrpc": "2.0", "id": "srv-1", "result": {"roots": []}}).code == Http202
    waitFor sleepAsync(30)
    check script.answered[^1]["id"].getStr() == "srv-1"
    stream.close()

  test "Given a POST naming no session or an unknown one, when posted, then the answer is 400 or 404":
    let (_, base, _) = startLegacy()
    check postTo(base, "/messages", rpc(1, "ping")).code == Http400
    check postTo(base, "/messages?sessionId=made-up", rpc(1, "ping")).code == Http404

  test "Given a POST that is not a JSON object, when posted, then the answer is 400":
    let (_, base, _) = startLegacy()
    let stream = openSse(base)
    let endpoint = stream.endpointOf()
    check postTo(base, endpoint, %*[rpc(1, "ping")]).code == Http400
    stream.close()

  test "Given a POST whose body is not JSON, when posted, then the answer is 400":
    let (_, base, _) = startLegacy()
    let stream = openSse(base)
    let endpoint = stream.endpointOf()
    let http = newAsyncHttpClient()
    check (waitFor http.request(base & endpoint, HttpPost, "{nope")).code == Http400
    http.close()
    stream.close()

  test "Given a client that closes its stream, when the server notices, then the session ends and its endpoint is gone":
    let (transport, base, script) = startLegacy()
    let stream = openSse(base)
    let endpoint = stream.endpointOf()
    check transport.sessionCount == 1
    stream.close()
    waitFor sleepAsync(100)
    check transport.sessionCount == 0
    check script.ended.len == 1
    check postTo(base, endpoint, rpc(1, "ping")).code == Http404

  test "Given the session limit, when another client connects, then the answer is 503":
    let (transport, base, _) = startLegacy()
    transport.maxSessions = 1
    let first = openSse(base)
    discard first.endpointOf()
    let second = openSse(base)
    check second.code == Http503
    first.close()
    second.close()

  test "Given a foreign Origin, when it connects or posts, then the answer is 403":
    let (_, base, _) = startLegacy()
    let denied = openSse(base, [("Origin", "https://evil.example")])
    check denied.code == Http403
    denied.close()
    let stream = openSse(base)
    let endpoint = stream.endpointOf()
    let http = newAsyncHttpClient()
    check (waitFor http.request(base & endpoint, HttpPost, $rpc(1, "ping"),
      newHttpHeaders({"Origin": "https://evil.example"}))).code == Http403
    http.close()
    stream.close()

  test "Given the SSE endpoint switched off, when a client connects, then the answer is 404":
    let (transport, base, _) = startLegacy()
    transport.legacySsePath = ""
    let stream = openSse(base)
    check stream.code == Http404
    stream.close()

  test "Given a stream, when its head is read, then it carries the security headers":
    let (_, base, _) = startLegacy()
    let stream = openSse(base)
    check $stream.response.headers["X-Content-Type-Options"] == "nosniff"
    check $stream.response.headers["Cache-Control"] == "no-cache"
    discard stream.endpointOf()
    stream.close()

  test "Given a stream, when events are read, then they carry no ids":
    let (_, base, _) = startLegacy()
    let stream = openSse(base)
    let endpoint = stream.endpointOf()
    discard postTo(base, endpoint, rpc(1, "ping"))
    check stream.next().get.id == ""
    stream.close()

suite "HTTP+SSE client (2024-11-05)":

  test "Given this SDK's server, when the client sends a request, then the answer and the related notification arrive through receiveMessage":
    let (_, base, _) = startLegacy()
    let transport = newSseLegacyTransport(base & "/sse")
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "work", newJObject()))
    check waitFor(transport.receiveMessage())["method"].getStr() == "notifications/progress"
    check waitFor(transport.receiveMessage())["id"].getStr() == "r1"
    waitFor transport.close()

  test "Given a connected client, when the server sends a request and the client answers, then the server receives the answer":
    let (server, base, script) = startLegacy()
    let transport = newSseLegacyTransport(base & "/sse")
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    discard waitFor transport.receiveMessage()
    waitFor server.sendRequest(newJsonRpcRequest("srv-1", "roots/list", newJObject()))
    let asked = waitFor transport.receiveMessage()
    check asked["method"].getStr() == "roots/list"
    waitFor transport.sendResponse(newJsonRpcResponse("srv-1", %*{"roots": []}))
    waitFor sleepAsync(30)
    check script.answered[^1]["id"].getStr() == "srv-1"
    waitFor transport.close()

  test "Given a client that sends a notification first, when it connects, then the notification reaches the server":
    let (_, base, script) = startLegacy()
    let transport = newSseLegacyTransport(base & "/sse")
    waitFor transport.sendNotification(
      newJsonRpcNotification("notifications/initialized", newJObject()))
    waitFor sleepAsync(30)
    check script.answered[^1]["method"].getStr() == "notifications/initialized"
    waitFor transport.close()

  test "Given headers set on the transport, when it connects and posts, then both requests carry them":
    var seen: seq[string] = @[]
    let listener = newAsyncSocket()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let port = listener.getLocalAddr()[1].int
    proc serveOne(socket: AsyncSocket) {.async.} =
      var head = ""
      while true:
        let line = await socket.recvLine()
        if line.strip().len == 0:
          break
        head.add line.toLowerAscii() & "\n"
      var length = 0
      for line in head.splitLines():
        if line.startsWith("content-length:"):
          length = parseInt(line.split(':')[1].strip())
      if length > 0:
        discard await socket.recv(length)
      seen.add (if "authorization: bearer abc" in head: "auth" else: "none")
      if head.startsWith("get "):
        await socket.send("HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" &
          "Connection: close\c\L\c\L" & formatSseEvent("/post", event = "endpoint"))
        await sleepAsync(200)
      else:
        await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L")
      socket.close()
    proc acceptLoop() {.async.} =
      while true:
        asyncCheck serveOne(await listener.accept())
    asyncCheck acceptLoop()
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    transport.headers["Authorization"] = "Bearer abc"
    waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    check seen == @["auth", "auth"]
    waitFor transport.close()

  test "Given an endpoint event naming another host, when the client connects, then it refuses to post there":
    let listener = newAsyncSocket()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let port = listener.getLocalAddr()[1].int
    proc serveOne(socket: AsyncSocket) {.async.} =
      while (await socket.recvLine()).strip().len > 0:
        discard
      await socket.send("HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" &
        "Connection: close\c\L\c\L" &
        formatSseEvent("http://evil.example/steal", event = "endpoint"))
      await sleepAsync(200)
      socket.close()
    proc acceptLoop() {.async.} =
      while true:
        asyncCheck serveOne(await listener.accept())
    asyncCheck acceptLoop()
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    expect McpTransportError:
      waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    waitFor transport.close()

  test "Given a server that never sends an endpoint, when the client connects, then it gives up with McpTransportError":
    let listener = newAsyncSocket()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let port = listener.getLocalAddr()[1].int
    proc serveOne(socket: AsyncSocket) {.async.} =
      while (await socket.recvLine()).strip().len > 0:
        discard
      await socket.send("HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" &
        "Connection: close\c\L\c\L" & formatSseComment("hello"))
      await sleepAsync(2000)
      socket.close()
    proc acceptLoop() {.async.} =
      while true:
        asyncCheck serveOne(await listener.accept())
    asyncCheck acceptLoop()
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    transport.connectTimeoutMs = 100
    expect McpTransportError:
      waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    waitFor transport.close()

  test "Given a server that answers the stream request with 404, when the client connects, then McpTransportError carries the status":
    let (_, base, _) = startLegacy()
    let transport = newSseLegacyTransport(base & "/nothing-here")
    var code = 0
    try:
      waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    except McpTransportError as e:
      code = e.code
    check code == 404
    waitFor transport.close()

  test "Given a stream that ends, when the client waits for a message, then McpTransportClosedError is raised":
    let (transport, base, _) = startLegacy()
    let client = newSseLegacyTransport(base & "/sse")
    waitFor client.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    discard waitFor client.receiveMessage()
    waitFor transport.close()  # ends its sessions, and so their streams
    expect McpTransportClosedError:
      discard waitFor client.receiveMessage()
    waitFor client.close()

  test "Given a closed client, when it sends, then McpTransportError is raised":
    let (_, base, _) = startLegacy()
    let transport = newSseLegacyTransport(base & "/sse")
    waitFor transport.close()
    expect McpTransportError:
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))

suite "client that tries Streamable HTTP first (backward compatibility)":

  test "Given a server of the old transport, when a client given its SSE URL connects, then it falls back and works":
    let (_, base, _) = startLegacy()
    let transport = newAutoHttpTransport(base & "/sse")
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    check waitFor(transport.receiveMessage())["id"].getStr() == "r1"
    check transport.chosen == hcSseLegacy
    waitFor transport.close()

  test "Given a Streamable HTTP server, when a client connects, then it uses Streamable HTTP":
    let (_, base, _) = startLegacy()
    let transport = newAutoHttpTransport(base & "/mcp")
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "initialize", %*{
      "protocolVersion": "2024-11-05", "capabilities": {},
      "clientInfo": {"name": "c", "version": "0"}}))
    check waitFor(transport.receiveMessage())["id"].getStr() == "r1"
    check transport.chosen == hcStreamable
    waitFor transport.close()

  test "Given a receive started before the first request, when the client then connects, then the receive sees the answer":
    let (_, base, _) = startLegacy()
    let transport = newAutoHttpTransport(base & "/sse")
    let waiting = transport.receiveMessage()
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    check waitFor(waiting)["id"].getStr() == "r1"
    waitFor transport.close()

  test "Given headers set on the wrapper, when it falls back, then the old transport carries them too":
    let (_, base, _) = startLegacy()
    let transport = newAutoHttpTransport(base & "/sse")
    transport.headers["Authorization"] = "Bearer abc"
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    check transport.chosen == hcSseLegacy
    check $transport.legacy.headers["Authorization"] == "Bearer abc"
    waitFor transport.close()

  test "Given a server that is down, when a client connects, then the connection error is raised and no fallback is tried":
    let transport = newAutoHttpTransport("http://127.0.0.1:1/mcp")
    expect McpTransportError:
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    check transport.chosen == hcUndecided
    waitFor transport.close()

  test "Given a full client and server, when the client connects through the wrapper to the old transport, then initialize and tools/list work":
    let transport = newHttpServerTransport(port = 0, protocolVersion = mpv20241105)
    transport.listen()
    asyncCheck transport.serve()
    let server = newMcpServer(McpServerInfo(name: "S", version: "1"),
      protocolVersion = mpv20241105,
      capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
    let listTools: typeof(McpToolHandlers().listHandler.get) =
      proc(): Future[seq[JsonNode]] {.async.} =
        return @[%*{"name": "echo", "inputSchema": {"type": "object"}}]
    server.setToolHandlers(McpToolHandlers(listHandler: some(listTools)))
    waitFor server.attachTransport(transport)
    let client = newMcpClient(McpClientInfo(name: "C", version: "1"))
    waitFor client.connect(newAutoHttpTransport("http://127.0.0.1:" & $transport.port & "/sse"))
    check client.negotiatedVersion == some(mpv20241105)
    let response = waitFor client.sendRequest("tools/list", newJObject())
    check response.result.get["tools"].len == 1
    waitFor client.close()

suite "HTTP+SSE server, requests in progress together (mutation review, g2f-hs-b)":

  test "Given two requests in progress at once, when the server answers them one after the other, then each answer carries the id its own request chose":
    let transport = newHttpServerTransport(port = 0, protocolVersion = mpv20241105)
    transport.listen()
    asyncCheck transport.serve()
    let base = "http://127.0.0.1:" & $transport.port
    let stream = openSse(base)
    let endpoint = stream.endpointOf()
    check postTo(base, endpoint, rpc(5, "first")).code == Http202
    check postTo(base, endpoint, rpc(6, "second")).code == Http202
    var seen: seq[McpIncoming] = @[]
    for _ in 1 .. 2:
      seen.add waitFor transport.receive()
    for incoming in seen:
      waitFor transport.sendResponse(newJsonRpcResponse(incoming.message["id"].getStr(),
        %*{"answers": incoming.message["method"].getStr()}))
    var answers: seq[(int, string)] = @[]
    for _ in 1 .. 2:
      let answer = stream.nextMessage()
      answers.add (answer["id"].getInt(), answer["result"]["answers"].getStr())
    check answers == @[(5, "first"), (6, "second")]
    stream.close()

suite "HTTP+SSE server paths (mutation review, g2f-hs-c)":

  proc status(base, path: string, httpMethod: HttpMethod): tuple[code: HttpCode, allow: string] =
    let http = newAsyncHttpClient()
    defer: http.close()
    let response = waitFor http.request(base & path, httpMethod, "")
    (response.code, response.headers.getOrDefault("Allow"))

  test "Given the SSE endpoint switched off, when a client posts to the messages path, then the answer is 404":
    # The two paths belong together: without the stream there is nothing to post to.
    let (transport, base, _) = startLegacy()
    transport.legacySsePath = ""
    check status(base, "/messages", HttpPost).code == Http404

  test "Given the messages path, when a client sends GET, then the answer is 405 naming POST":
    let (_, base, _) = startLegacy()
    let answer = status(base, "/messages", HttpGet)
    check answer.code == Http405
    check answer.allow == "POST"

import std/[times, os]

const StreamHead = "HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" &
  "Connection: close\c\L\c\L"

proc listenLocal(): tuple[listener: AsyncSocket, port: int] =
  let listener = newAsyncSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  (listener, listener.getLocalAddr()[1].int)

proc peerClosed(socket: AsyncSocket, ms: int): Future[bool] {.async.} =
  ## True when the peer closes its end within `ms`.
  let read = socket.recv(1)
  if not await withTimeout(read, ms):
    return false
  return read.read().len == 0

proc readHead(socket: AsyncSocket): Future[string] {.async.} =
  ## The request head, lower-cased, and the body read past.
  var head = ""
  while true:
    let line = await socket.recvLine()
    if line.strip().len == 0:
      break
    head.add line.toLowerAscii() & "\n"
  var length = 0
  for line in head.splitLines():
    if line.startsWith("content-length:"):
      length = parseInt(line.split(':')[1].strip())
  if length > 0:
    discard await socket.recv(length)
  return head

proc answerFirstWith(listener: AsyncSocket, reply: string): Future[bool] =
  ## Answers the first connection with `reply`; the future says whether the
  ## client closed its end of it within two seconds.
  let observed = newFuture[bool]("answerFirstWith")
  proc serveOne(socket: AsyncSocket) {.async.} =
    discard await socket.readHead()
    await socket.send(reply)
    observed.complete(await socket.peerClosed(2000))
    socket.close()
  proc acceptOne() {.async.} =
    asyncCheck serveOne(await listener.accept())
  asyncCheck acceptOne()
  observed

type Held = ref object
  stream, post: Future[bool]
    ## Whether the client closed its end of the stream, of the POST, within
    ## two seconds of the server's answer.

proc serveHeld(listener: AsyncSocket, afterEndpoint = ""): Held =
  ## A server of the old transport that names `/post` and then sends
  ## `afterEndpoint` on the stream, answers each POST 202, and leaves
  ## closing to the client.
  let held = Held(stream: newFuture[bool]("held.stream"), post: newFuture[bool]("held.post"))
  proc serveOne(socket: AsyncSocket) {.async.} =
    let head = await socket.readHead()
    if head.startsWith("get "):
      await socket.send(StreamHead & formatSseEvent("/post", event = "endpoint") & afterEndpoint)
      held.stream.complete(await socket.peerClosed(2000))
    else:
      await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L")
      held.post.complete(await socket.peerClosed(2000))
    socket.close()
  proc acceptLoop() {.async.} =
    while true:
      asyncCheck serveOne(await listener.accept())
  asyncCheck acceptLoop()
  held

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-sse-legacy-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc refusalFor(endpointOf: proc(port: int): string): string =
  ## The message of the error the client raises when the stream names the
  ## endpoint `endpointOf` builds; empty when it raised nothing.
  let (listener, port) = listenLocal()
  discard answerFirstWith(listener,
    StreamHead & formatSseEvent(endpointOf(port), event = "endpoint"))
  let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
  proc connectError(): Future[string] {.async.} =
    try:
      await transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    except McpTransportError as e:
      return e.msg
  let outcome = connectError()
  # A client that took the endpoint posts to a server that never answers.
  if waitFor withTimeout(outcome, 5000):
    result = outcome.read()
  waitFor transport.close()

suite "HTTP+SSE client, what the stream tells it (mutation review, g2g-hc-d)":

  test "Given an endpoint on the same host and port under another scheme, when the client connects, then it refuses it as another origin":
    check "is not on the server" in refusalFor(proc(port: int): string =
      "https://127.0.0.1:" & $port & "/post")

  test "Given an endpoint on another host at the same port, when the client connects, then it refuses it as another origin":
    check "is not on the server" in refusalFor(proc(port: int): string =
      "http://localhost:" & $port & "/post")

  test "Given an endpoint on the same host at another port, when the client connects, then it refuses it as another origin":
    check "is not on the server" in refusalFor(proc(port: int): string =
      "http://127.0.0.1:" & $(port + 1) & "/post")

  test "Given an endpoint on another origin while the stream stays open, when the client connects, then it fails at once and says why":
    let (listener, port) = listenLocal()
    discard answerFirstWith(listener,
      StreamHead & formatSseEvent("http://evil.example/steal", event = "endpoint"))
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    transport.connectTimeoutMs = 10_000
    let started = epochTime()
    var message = ""
    try:
      waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    except McpTransportError as e:
      message = e.msg
    check epochTime() - started < 1.5
    check "is not on the server" in message
    waitFor transport.close()

  test "Given a stream that ends before it names an endpoint, when the client connects, then it fails at once and says so":
    let (listener, port) = listenLocal()
    proc serveOne(socket: AsyncSocket) {.async.} =
      discard await socket.readHead()
      await socket.send(StreamHead & formatSseComment("hello"))
      socket.close()
    proc acceptLoop() {.async.} =
      while true:
        asyncCheck serveOne(await listener.accept())
    asyncCheck acceptLoop()
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    transport.connectTimeoutMs = 10_000
    let started = epochTime()
    var message = ""
    try:
      waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    except McpTransportError as e:
      message = e.msg
    check epochTime() - started < 3.0
    check "ended before it named an endpoint" in message
    waitFor transport.close()

  test "Given events that are not messages, when the client reads the stream, then it skips them and delivers the next message":
    let (listener, port) = listenLocal()
    discard serveHeld(listener,
      formatSseEvent("keepalive, not JSON", event = "ping") &
      formatSseEvent("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/after-ping\"}", event = "message"))
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    check waitFor(transport.receiveMessage())["method"].getStr() == "notifications/after-ping"
    waitFor transport.close()

  test "Given message events without data, when the client reads the stream, then it skips them and delivers the next message":
    let (listener, port) = listenLocal()
    discard serveHeld(listener,
      "data:\n\n" & "event: message\ndata:\n\n" &
      formatSseEvent("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/after-empty\"}", event = "message"))
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    check waitFor(transport.receiveMessage())["method"].getStr() == "notifications/after-empty"
    waitFor transport.close()

  test "Given a stream that ended some time ago, when the client then waits for a message, then McpTransportClosedError is raised at once":
    let (server, base, _) = startLegacy()
    let client = newSseLegacyTransport(base & "/sse")
    waitFor client.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    discard waitFor client.receiveMessage()
    waitFor server.close()
    waitFor sleepAsync(300)
    let pending = client.receiveMessage()
    var closedError = false
    try:
      discard waitFor withTimeout(pending, 3000)  # false when it hangs
    except McpTransportClosedError:
      closedError = true
    check closedError
    waitFor client.close()

suite "HTTP+SSE client, what it closes and reports (mutation review, g2g-hc-d)":

  test "Given a stream that fails on a message that is not JSON, when the client reads it, then it says so on stderr":
    let (listener, port) = listenLocal()
    discard serveHeld(listener, formatSseEvent("{not json", event = "message"))
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    let logged = loggedWhile(proc() =
      waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
      waitFor sleepAsync(100))
    check "[mcp-sse] event stream from " in logged
    check "failed with" in logged
    waitFor transport.close()

  test "Given a stream that fails on a message that is not JSON, when the client has read it, then it closes its end of the connection":
    let (listener, port) = listenLocal()
    let held = serveHeld(listener, formatSseEvent("{not json", event = "message"))
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    discard loggedWhile(proc() =
      waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
      check waitFor held.stream)
    waitFor transport.close()

  test "Given a server answering the stream request with 404, when the client gives up, then it closes its end of the connection":
    let (listener, port) = listenLocal()
    let closed = answerFirstWith(listener,
      "HTTP/1.1 404 Not Found\c\LContent-Length: 0\c\L\c\L")
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    expect McpTransportError:
      waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    check waitFor closed
    waitFor transport.close()

  test "Given a server answering the stream request with something that is no event stream, when the client gives up, then it closes its end of the connection":
    let (listener, port) = listenLocal()
    let closed = answerFirstWith(listener,
      "HTTP/1.1 200 OK\c\LContent-Type: text/plain\c\LContent-Length: 2\c\L\c\Lno")
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    expect McpTransportError:
      waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    check waitFor closed
    waitFor transport.close()

  test "Given a server that names no endpoint in time, when the client gives up, then it closes its end of the stream before it is closed itself":
    let (listener, port) = listenLocal()
    let closed = answerFirstWith(listener, StreamHead & formatSseComment("hello"))
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    transport.connectTimeoutMs = 200
    expect McpTransportError:
      waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    check waitFor closed
    waitFor transport.close()

  test "Given a POST the server answered, when the client has read the answer, then it closes its end of the POST connection":
    let (listener, port) = listenLocal()
    let held = serveHeld(listener)
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    check waitFor held.post
    waitFor transport.close()

  test "Given a connected client, when it is closed, then it closes its end of the stream":
    let (listener, port) = listenLocal()
    let held = serveHeld(listener)
    let transport = newSseLegacyTransport("http://127.0.0.1:" & $port & "/sse")
    waitFor transport.sendNotification(newJsonRpcNotification("x", newJObject()))
    waitFor transport.close()
    check waitFor held.stream

import std/[asynchttpserver, nativesockets]

suite "client that tries Streamable HTTP first (mutation review, g2g-hc-b)":

  type Seen = ref object
    ## What a hand-written Streamable HTTP server saw: `(method, protocol
    ## version header, session header)` per request.
    requests: seq[(string, string, string)]

  proc startScripted(seen: Seen): string =
    let server = newAsyncHttpServer()
    server.listen(Port(0), "127.0.0.1")
    let port = server.getPort.int
    proc handler(req: Request) {.async, gcsafe.} =
      proc value(name: string): string =
        if req.headers.hasKey(name): $req.headers[name] else: ""
      {.cast(gcsafe).}:
        seen.requests.add ($req.reqMethod, value("MCP-Protocol-Version"), value("Mcp-Session-Id"))
      if req.reqMethod == HttpPost and parseJson(req.body).hasKey("id"):
        await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": parseJson(req.body)["id"], "result": {}}),
          newHttpHeaders({"Content-Type": "application/json", "Mcp-Session-Id": "s-1"}))
      else:
        await req.respond(Http202, "")
    proc loop() {.async.} =
      while true:
        await server.acceptRequest(handler)
    asyncCheck loop()
    "http://127.0.0.1:" & $port & "/mcp"

  test "Given a server of the old transport, when the client sends a notification after falling back, then the server receives it":
    let (_, base, script) = startLegacy()
    let transport = newAutoHttpTransport(base & "/sse")
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    check transport.chosen == hcSseLegacy
    waitFor transport.sendNotification(newJsonRpcNotification("notifications/initialized", newJObject()))
    waitFor sleepAsync(100)
    check script.answered.len == 1
    check script.answered[0]["method"].getStr() == "notifications/initialized"
    waitFor transport.close()

  test "Given a server of the old transport, when the client answers a request after falling back, then the server receives the response":
    let (_, base, script) = startLegacy()
    let transport = newAutoHttpTransport(base & "/sse")
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    check transport.chosen == hcSseLegacy
    waitFor transport.sendResponse(newJsonRpcResponse("srv-1", %*{"roots": []}))
    waitFor sleepAsync(100)
    check script.answered.len == 1
    check script.answered[0]["id"].getStr() == "srv-1"
    waitFor transport.close()

  test "Given a version agreed through the wrapper, when a Streamable HTTP server is used, then later requests name it":
    let seen = Seen()
    let transport = newAutoHttpTransport(startScripted(seen))
    transport.protocolVersionNegotiated(mpv20250618)
    waitFor transport.sendNotification(newJsonRpcNotification("notifications/cancelled", newJObject()))
    check seen.requests.len == 1
    check seen.requests[0][1] == "2025-06-18"
    waitFor transport.close()

  test "Given a Streamable HTTP server that issued a session, when the wrapper closes, then the session is ended with DELETE":
    let seen = Seen()
    let transport = newAutoHttpTransport(startScripted(seen))
    transport.streamable.listenForServerMessages = false
    transport.protocolVersionNegotiated(mpv20250326)
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    check transport.chosen == hcStreamable
    waitFor transport.close()
    var methods: seq[string] = @[]
    for request in seen.requests:
      methods.add request[0]
    check methods == @["POST", "DELETE"]
    check seen.requests[1][2] == "s-1"

  test "Given a server of the old transport, when the wrapper closes, then the stream ends and the server's session with it":
    let (server, base, script) = startLegacy()
    let transport = newAutoHttpTransport(base & "/sse")
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
    check transport.chosen == hcSseLegacy
    check server.sessionCount == 1
    waitFor transport.close()
    waitFor sleepAsync(100)
    check server.sessionCount == 0
    check script.ended.len == 1

  test "Given a wrapper that has not decided, when it closes while a receive waits, then the receive fails with McpTransportError":
    let transport = newAutoHttpTransport("http://127.0.0.1:1/mcp")
    let waiting = transport.receiveMessage()
    waitFor transport.close()
    waitFor sleepAsync(20)
    check waiting.failed
    expect McpTransportError:
      discard waiting.read()
