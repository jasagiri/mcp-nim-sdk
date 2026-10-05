## The client side of Streamable HTTP when the server streams: messages are
## handed over as they arrive, a broken stream is resumed from the last event
## id, the GET stream carries what the server says outside any request, and
## closing the transport ends the session.
##
## The servers here are written byte by byte, so that each test controls
## exactly when events are sent and when connections are cut.

import std/[unittest, asyncdispatch, asyncnet, httpcore, json, options,
            strutils, times]
import transport/transport
import transport/http
import transport/http_server
import transport/event_stream
import protocol/types
import protocol/version

type
  RawRequest = object
    httpMethod: string
    headers: HttpHeaders
    body: string

  RawHandler = proc(request: RawRequest, socket: AsyncSocket): Future[void]

proc header(request: RawRequest, name: string): string =
  request.headers.getOrDefault(name)

proc readRequest(socket: AsyncSocket): Future[RawRequest] {.async.} =
  let first = await socket.recvLine()
  result.httpMethod = first.split(' ')[0]
  result.headers = newHttpHeaders()
  while true:
    let line = await socket.recvLine()
    if line.strip().len == 0:
      break
    let colon = line.find(':')
    result.headers.add(line[0 ..< colon].strip(), line[colon + 1 .. ^1].strip())
  let length = result.headers.getOrDefault("Content-Length")
  if length.len > 0 and parseInt(length) > 0:
    result.body = await socket.recv(parseInt(length))

proc startRawServer(handler: RawHandler): string =
  let listener = newAsyncSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  let port = listener.getLocalAddr()[1]
  proc serveConnection(socket: AsyncSocket) {.async.} =
    try:
      let request = await readRequest(socket)
      await handler(request, socket)
    finally:
      socket.close()
  proc acceptLoop() {.async.} =
    while true:
      let socket = await listener.accept()
      asyncCheck serveConnection(socket)
  asyncCheck acceptLoop()
  "http://127.0.0.1:" & $port.int & "/mcp"

proc eventStreamHead(socket: AsyncSocket, chunked = false): Future[void] =
  socket.send("HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" &
              (if chunked: "Transfer-Encoding: chunked\c\L" else: "") &
              "Connection: close\c\L\c\L")

proc chunk(text: string): string =
  toHex(text.len).strip(chars = {'0'}, trailing = false).toLowerAscii() &
    "\c\L" & text & "\c\L"

proc notification(n: int): JsonNode =
  %*{"jsonrpc": "2.0", "method": "notifications/progress",
     "params": {"progressToken": "t", "progress": n}}

proc ask(transport: StreamableHttpTransport, id = "r1") =
  waitFor transport.sendRequest(newJsonRpcRequest(id, "tools/call", newJObject()))

proc received(transport: StreamableHttpTransport, timeoutMs = 3000): JsonNode =
  let next = transport.receiveMessage()
  doAssert waitFor withTimeout(next, timeoutMs), "no message within " & $timeoutMs & " ms"
  next.read()

proc isLocalStreamClosed(message: JsonNode): bool =
  message{"error", "code"}.getInt() == ErrStreamClosed

proc redirectTo(socket: AsyncSocket, code: int, location: string): Future[void] =
  socket.send("HTTP/1.1 " & $code & " Redirect\c\LLocation: " & location &
              "\c\LContent-Length: 0\c\L\c\L")

let speaks = min(DefaultProtocolVersion, mpv20251125)

suite "client: streams are read as they arrive":

  test "Given a server that pauses between two events, when a request is sent, then the first message is delivered before the second is sent":
    let gate = newFuture[void]("gate")
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      let id = parseJson(request.body)["id"]
      await eventStreamHead(socket)
      await socket.send(formatSseEvent($notification(1)))
      await gate
      await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": id, "result": {}}))))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["method"].getStr() == "notifications/progress"
    gate.complete()
    check transport.received()["id"].getStr() == "r1"
    waitFor transport.close()

  test "Given a chunked event stream cut in the middle of a chunk, when a request is sent, then the events still arrive whole":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      let id = parseJson(request.body)["id"]
      await eventStreamHead(socket, chunked = true)
      let body = formatSseEvent($notification(1)) &
                 formatSseEvent($(%*{"jsonrpc": "2.0", "id": id, "result": {}}))
      let encoded = chunk(body)
      await socket.send(encoded[0 ..< 7])
      await sleepAsync(10)
      await socket.send(encoded[7 .. ^1] & "0\c\L\c\L"))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["method"].getStr() == "notifications/progress"
    check transport.received()["id"].getStr() == "r1"
    waitFor transport.close()

  test "Given an event with an id and no data, when it arrives, then it is not a message and not an error":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      let id = parseJson(request.body)["id"]
      await eventStreamHead(socket)
      await socket.send(formatSseEvent("", id = "p-1"))
      await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": id, "result": {}}), id = "p-2")))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["id"].getStr() == "r1"
    waitFor transport.close()

  test "Given a JSON body sent in two pieces with a length, when a request is sent, then the response is whole":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      let id = parseJson(request.body)["id"]
      let body = $(%*{"jsonrpc": "2.0", "id": id, "result": {"pad": repeat("x", 100)}})
      await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                        "Content-Length: " & $body.len & "\c\L\c\L" & body[0 ..< 20])
      await sleepAsync(10)
      await socket.send(body[20 .. ^1]))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["result"]["pad"].getStr().len == 100
    waitFor transport.close()

  test "Given a body longer than the limit, when a request is sent, then McpTransportError is raised":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      let body = $(%*{"jsonrpc": "2.0", "id": 1, "result": {"pad": repeat("x", 500)}})
      await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                        "Content-Length: " & $body.len & "\c\L\c\L" & body))
    let transport = newStreamableHttpTransport(url)
    transport.maxResponseSize = 100
    expect McpTransportError:
      transport.ask()
    waitFor transport.close()

  test "Given an HTTP error status, when a request is sent, then McpTransportError carries the status":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await socket.send("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L"))
    let transport = newStreamableHttpTransport(url)
    var code = 0
    try:
      transport.ask()
    except McpTransportError as e:
      code = e.code
    check code == 405
    waitFor transport.close()

proc startHttpServer(): tuple[server: HttpServerTransport, url: string,
                               ended: ref seq[string], others: ref seq[JsonNode]] =
  ## A server that answers initialize and every other request with an empty
  ## result, and keeps whatever else arrives in `others`.
  let server = newHttpServerTransport(port = 0, protocolVersion = speaks)
  let ended = new(seq[string])
  let others = new(seq[JsonNode])
  server.onSessionEnd = proc(session: string) {.closure, gcsafe.} =
    ended[].add session
  server.listen()
  asyncCheck server.serve()
  proc answer() {.async.} =
    while true:
      let incoming = await server.receive()
      if not isRequest(incoming.message):
        others[].add incoming.message
      else:
        let id = incoming.message["id"].getStr()
        if incoming.message["method"].getStr() == "initialize":
          await server.sendResponse(newJsonRpcResponse(id, %*{
            "protocolVersion": $speaks, "capabilities": {},
            "serverInfo": {"name": "s", "version": "0"}}))
        else:
          await server.sendResponse(newJsonRpcResponse(id, %*{}))
  asyncCheck answer()
  (server, "http://127.0.0.1:" & $server.port & "/mcp", ended, others)

proc handshake(transport: StreamableHttpTransport) =
  waitFor transport.sendRequest(newJsonRpcRequest("init", "initialize", %*{
    "protocolVersion": $speaks, "capabilities": {},
    "clientInfo": {"name": "c", "version": "0"}}))
  discard transport.received()
  transport.protocolVersionNegotiated(speaks)
  waitFor transport.sendNotification(
    newJsonRpcNotification("notifications/initialized", newJObject()))


suite "client: cancelling a request":

  test "Given a request the server has not answered, when the client cancels it, then the connection is closed and sendRequest returns without an error":
    let hangedUp = newFuture[void]("hangedUp")
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      # Reads until the client closes the connection.
      let gone = await socket.recv(1)
      if gone.len == 0:
        hangedUp.complete())
    let transport = newStreamableHttpTransport(url)
    let sending = transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
    waitFor sleepAsync(50)
    transport.cancelRequest("r1")
    check waitFor withTimeout(sending, 2000)
    check not sending.failed
    check waitFor withTimeout(hangedUp, 2000)
    let waiting = transport.receiveMessage()
    waitFor sleepAsync(30)
    check not waiting.finished  # no answer and no error stand in for the request
    waitFor transport.close()

  test "Given a request whose event stream is open, when the client cancels it, then the stream ends and no stream-closed error is delivered":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await eventStreamHead(socket)
      await socket.send(formatSseEvent($notification(1)))
      discard await socket.recv(1))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["method"].getStr() == "notifications/progress"
    transport.cancelRequest("r1")
    let waiting = transport.receiveMessage()
    waitFor sleepAsync(50)
    check not waiting.finished
    waitFor transport.close()

  test "Given a request that was answered, when the client cancels it, then nothing happens":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      let id = parseJson(request.body)["id"]
      let body = $(%*{"jsonrpc": "2.0", "id": id, "result": {}})
      await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                        "Content-Length: " & $body.len & "\c\L\c\L" & body))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    transport.cancelRequest("r1")
    check transport.received()["id"].getStr() == "r1"
    waitFor transport.close()

suite "client: redirects":

  test "Given a server that redirects a POST with 307 to another path of its own, when a request is sent, then it is posted again there with the same body":
    var bodies: seq[string] = @[]
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      bodies.add request.body
      if bodies.len == 1:
        await socket.redirectTo(307, "/mcp/")
      else:
        let id = parseJson(request.body)["id"]
        let body = $(%*{"jsonrpc": "2.0", "id": id, "result": {}})
        await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                          "Content-Length: " & $body.len & "\c\L\c\L" & body))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["id"].getStr() == "r1"
    check bodies.len == 2
    check bodies[0] == bodies[1]
    waitFor transport.close()

  test "Given a server that redirects to another host, when a request is sent, then McpTransportError is raised and nothing is sent there":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await socket.redirectTo(307, "http://evil.example/steal"))
    let transport = newStreamableHttpTransport(url)
    transport.headers["Authorization"] = "Bearer secret"
    expect McpTransportError:
      transport.ask()
    waitFor transport.close()

  test "Given a server that redirects forever, when a request is sent, then McpTransportError is raised":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await socket.redirectTo(307, "/mcp"))
    let transport = newStreamableHttpTransport(url)
    expect McpTransportError:
      transport.ask()
    waitFor transport.close()

  test "Given a 301 answering a POST, when a request is sent, then it is not followed and the status is reported":
    var requests = 0
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      inc requests
      await socket.redirectTo(301, "/elsewhere"))
    let transport = newStreamableHttpTransport(url)
    var code = 0
    try:
      transport.ask()
    except McpTransportError as e:
      code = e.code
    check code == 301
    check requests == 1
    waitFor transport.close()

if speaks >= mpv20250326:
  suite "client: resuming a stream":

    proc resumingTransport(url: string): StreamableHttpTransport =
      result = newStreamableHttpTransport(url)
      result.sessionId = some("s-1")
      result.reconnectDelayMs = 5
      result.protocolVersionNegotiated(speaks)

    test "Given a stream cut before the response, when an event id was seen, then the client asks for the events after it and receives the response":
      var resumes: seq[tuple[lastEventId, session: string, getCount: int]] = @[]
      var postedId: JsonNode = nil
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "POST":
          postedId = parseJson(request.body)["id"]
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($notification(1), id = "a-1"))
        else:
          resumes.add (request.header("Last-Event-ID"), request.header("Mcp-Session-Id"),
                       resumes.len + 1)
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": postedId, "result": {}}),
                                           id = "a-2")))
      let transport = resumingTransport(url)
      transport.ask()
      check transport.received()["method"].getStr() == "notifications/progress"
      check transport.received()["id"].getStr() == "r1"
      check resumes.len == 1
      check resumes[0].lastEventId == "a-1"
      check resumes[0].session == "s-1"
      waitFor transport.close()

    test "Given a stream cut before any event id, when the response is missing, then a local stream-closed error stands in for it and nothing is resumed":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
        else:
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($notification(1))))
      let transport = resumingTransport(url)
      transport.ask()
      discard transport.received()
      check transport.received().isLocalStreamClosed
      check gets == 0
      waitFor transport.close()

    test "Given a server that cuts every stream before saying anything, when the client has resumed as often as it may, then the stream-closed error stands in for the response":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
        await eventStreamHead(socket)
        await socket.send(formatSseEvent("", id = "a-" & $gets)))
      let transport = resumingTransport(url)
      transport.maxReconnects = 2
      transport.ask()
      check transport.received().isLocalStreamClosed
      check gets == 2
      waitFor transport.close()

    test "Given a server that answers the resumption with 404, when the stream was cut, then the client stops resuming and reports the stream closed":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
          await socket.send("HTTP/1.1 404 Not Found\c\LContent-Length: 0\c\L\c\L")
        else:
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($notification(1), id = "a-1")))
      let transport = resumingTransport(url)
      transport.ask()
      discard transport.received()
      check transport.received().isLocalStreamClosed
      check gets == 1
      waitFor transport.close()

    test "Given a server that asked for a delay with retry, when the stream was cut, then the client waits at least that long before resuming":
      var cutAt = 0.0
      var resumedAt = 0.0
      var postedId: JsonNode = nil
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "POST":
          postedId = parseJson(request.body)["id"]
          await eventStreamHead(socket)
          await socket.send("retry: 150\nid: a-1\ndata: " & $notification(1) & "\n\n")
          cutAt = epochTime()
        else:
          resumedAt = epochTime()
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": postedId, "result": {}}))))
      let transport = resumingTransport(url)
      transport.ask()
      discard transport.received()
      check transport.received()["id"].getStr() == "r1"
      check (resumedAt - cutAt) * 1000 >= 140
      waitFor transport.close()

    test "Given a version without resumption, when the stream was cut, then nothing is resumed":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
        else:
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($notification(1), id = "a-1")))
      let transport = newStreamableHttpTransport(url)
      transport.reconnectDelayMs = 5
      transport.protocolVersionNegotiated(mpv20241105)
      transport.ask()
      discard transport.received()
      check transport.received().isLocalStreamClosed
      check gets == 0
      waitFor transport.close()

  suite "client: the GET stream":

    test "Given an initialized session, when the server says something outside any request, then the client receives it":
      let (server, url, _, _) = startHttpServer()
      let transport = newStreamableHttpTransport(url)
      transport.handshake()
      waitFor sleepAsync(100)
      waitFor server.sendNotification(
        newJsonRpcNotification("notifications/tools/list_changed", newJObject()))
      check transport.received()["method"].getStr() == "notifications/tools/list_changed"
      waitFor transport.close()

    test "Given a request the server sends on the GET stream, when the client answers it, then the server receives the answer":
      let (server, url, _, others) = startHttpServer()
      let transport = newStreamableHttpTransport(url)
      transport.handshake()
      waitFor sleepAsync(100)
      waitFor server.sendRequest(newJsonRpcRequest("srv-1", "roots/list", newJObject()))
      let asked = transport.received()
      check asked["id"].getStr() == "srv-1"
      waitFor transport.sendResponse(newJsonRpcResponse("srv-1", %*{"roots": []}))
      waitFor sleepAsync(50)
      check others[].len == 2   # notifications/initialized, then the answer
      check others[][1]["id"].getStr() == "srv-1"
      check others[][1]["result"]["roots"].len == 0
      waitFor transport.close()

    test "Given a server without a GET stream, when the session is initialized, then the client asks once and does not ask again":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
          await socket.send("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L")
        else:
          await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(speaks)
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/initialized", newJObject()))
      waitFor sleepAsync(200)
      check gets == 1
      waitFor transport.close()

    test "Given a GET stream that is cut, when the client reconnects, then it names the last event id it saw":
      var seen: seq[string] = @[]
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          seen.add request.header("Last-Event-ID")
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($notification(seen.len), id = "g-" & $seen.len))
        else:
          await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))
      let transport = newStreamableHttpTransport(url)
      transport.reconnectDelayMs = 5
      transport.protocolVersionNegotiated(speaks)
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/initialized", newJObject()))
      check transport.received()["params"]["progress"].getInt() == 1
      check transport.received()["params"]["progress"].getInt() == 2
      check seen[0] == ""
      check seen[1] == "g-1"
      waitFor transport.close()

    test "Given a version without a GET stream, when the session is initialized, then the client does not open one":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
        await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(mpv20241105)
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/initialized", newJObject()))
      waitFor sleepAsync(100)
      check gets == 0
      waitFor transport.close()

    test "Given a client told not to listen, when the session is initialized, then it does not open a GET stream":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
        await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))
      let transport = newStreamableHttpTransport(url)
      transport.listenForServerMessages = false
      transport.protocolVersionNegotiated(speaks)
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/initialized", newJObject()))
      waitFor sleepAsync(100)
      check gets == 0
      waitFor transport.close()

  suite "client: ending the session":

    test "Given a session, when the client closes, then it sends DELETE with the session id and the server forgets it":
      let (server, url, ended, _) = startHttpServer()
      let transport = newStreamableHttpTransport(url)
      transport.listenForServerMessages = false
      transport.handshake()
      check server.sessionCount == 1
      waitFor transport.close()
      check ended[].len == 1
      check server.sessionCount == 0

    test "Given a server that refuses DELETE with 405, when the client closes, then closing succeeds":
      var deletes = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "DELETE":
          inc deletes
          await socket.send("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L")
        else:
          await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))
      let transport = newStreamableHttpTransport(url)
      transport.listenForServerMessages = false
      transport.sessionId = some("s-1")
      transport.protocolVersionNegotiated(speaks)
      waitFor transport.close()
      check deletes == 1

    test "Given no session, when the client closes, then it sends no DELETE":
      var deletes = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "DELETE":
          inc deletes
        await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(speaks)
      waitFor transport.close()
      check deletes == 0

    test "Given a GET stream open, when the client closes, then the stream ends and the server sees the client leave":
      let (server, url, _, _) = startHttpServer()
      let transport = newStreamableHttpTransport(url)
      transport.handshake()
      waitFor sleepAsync(100)
      waitFor transport.close()
      waitFor sleepAsync(100)
      check server.sessionCount == 0
