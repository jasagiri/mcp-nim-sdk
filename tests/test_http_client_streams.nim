## The client side of Streamable HTTP when the server streams: messages are
## handed over as they arrive, a broken stream is resumed from the last event
## id, the GET stream carries what the server says outside any request, and
## closing the transport ends the session.
##
## The servers here are written byte by byte, so that each test controls
## exactly when events are sent and when connections are cut.

import std/[unittest, asyncdispatch, asyncnet, httpcore, json, options, os,
            strutils, times]
import transport/transport
import transport/http
import transport/http_server
import transport/event_stream
import protocol/types
import protocol/version
import protocol/features

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

  test "Given a request, when the client posts it, then Accept lists both application/json and text/event-stream":
    var accepts: seq[string] = @[]
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      accepts.add request.header("Accept")
      let id = parseJson(request.body)["id"]
      let body = $(%*{"jsonrpc": "2.0", "id": id, "result": {}})
      await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                        "Content-Length: " & $body.len & "\c\L\c\L" & body))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    discard transport.received()
    check accepts.len == 1
    check "application/json" in accepts[0]
    check "text/event-stream" in accepts[0]
    waitFor transport.close()

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

    test "Given a client opening the GET stream, when it asks, then Accept lists text/event-stream":
      var accepts: seq[string] = @[]
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          accepts.add request.header("Accept")
          await socket.send("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L")
        else:
          await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(speaks)
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/initialized", newJObject()))
      waitFor sleepAsync(200)
      check accepts.len == 1
      check "text/event-stream" in accepts[0]
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

import std/os

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-http-client-streams-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

type Behaviour = enum
  bAnswered      ## 200 with the JSON response
  bSseAnswered   ## 200 event stream carrying the response, then the end of the stream
  bDropped       ## the connection is closed without a word
  bHold          ## says nothing until the client leaves
  bSseEnds       ## 200 event stream with one notification and no response
  bPartialHold   ## 200 JSON head, a piece of the body, then silence

proc startSequence(script: seq[Behaviour]): string =
  ## A server whose n-th POST behaves as `script[n]` (the last one repeats).
  var served = 0
  startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
    let id = parseJson(request.body)["id"]
    let step = script[min(served, script.high)]
    inc served
    case step
    of bAnswered:
      let body = $(%*{"jsonrpc": "2.0", "id": id, "result": {}})
      await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                        "Content-Length: " & $body.len & "\c\L\c\L" & body)
    of bSseAnswered:
      await eventStreamHead(socket)
      await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": id, "result": {}})))
    of bDropped:
      discard
    of bHold:
      discard await socket.recv(1)
    of bSseEnds:
      await eventStreamHead(socket)
      await socket.send(formatSseEvent($notification(1)))
    of bPartialHold:
      await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                        "Content-Length: 100\c\L\c\L{\"jsonrpc\": \"2.0\", ")
      discard await socket.recv(1))

proc requestIsForgotten(transport: StreamableHttpTransport) =
  ## The request "r1" is sent again, to a server that ends its stream without
  ## the response: the transport must say so with the local stream-closed
  ## error, as it does for any request. Nothing that was done to the earlier
  ## "r1" may keep it silent.
  transport.ask()
  check transport.received()["method"].getStr() == "notifications/progress"
  check transport.received().isLocalStreamClosed

suite "client: what an exchange leaves behind (mutation review, g2g-hc-b)":

  test "Given a request whose answer was a JSON body, when the client cancels it afterwards and sends the id again, then the new request is not taken for a cancelled one":
    let transport = newStreamableHttpTransport(startSequence(@[bAnswered, bSseEnds]))
    transport.ask()
    check transport.received()["id"].getStr() == "r1"
    transport.cancelRequest("r1")
    transport.requestIsForgotten()
    waitFor transport.close()

  test "Given a request whose answer was an event stream, when the client cancels it afterwards and sends the id again, then the new request is not taken for a cancelled one":
    let transport = newStreamableHttpTransport(startSequence(@[bSseAnswered, bSseEnds]))
    transport.ask()
    check transport.received()["id"].getStr() == "r1"
    waitFor sleepAsync(50)
    transport.cancelRequest("r1")
    transport.requestIsForgotten()
    waitFor transport.close()

  test "Given a request that failed after the connection was made, when the client cancels it afterwards and sends the id again, then the new request is not taken for a cancelled one":
    let transport = newStreamableHttpTransport(startSequence(@[bDropped, bSseEnds]))
    expect McpTransportError:
      transport.ask()
    transport.cancelRequest("r1")
    transport.requestIsForgotten()
    waitFor transport.close()

  test "Given a request cancelled while the server was silent, when the id is sent again, then the new request is not taken for a cancelled one":
    let transport = newStreamableHttpTransport(startSequence(@[bHold, bSseEnds]))
    let sending = transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
    waitFor sleepAsync(50)
    transport.cancelRequest("r1")
    check waitFor withTimeout(sending, 2000)
    transport.requestIsForgotten()
    waitFor transport.close()

  test "Given a request cancelled while its JSON body is arriving, when the client cancels, then sendRequest returns without an error and the id is free again":
    let transport = newStreamableHttpTransport(startSequence(@[bPartialHold, bSseEnds]))
    let sending = transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
    waitFor sleepAsync(50)
    transport.cancelRequest("r1")
    check waitFor withTimeout(sending, 2000)
    check not sending.failed
    transport.requestIsForgotten()
    waitFor transport.close()

  test "Given a request whose event stream is open, when the transport closes, then the server sees the client leave":
    let hangedUp = newFuture[void]("hangedUp")
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await eventStreamHead(socket)
      await socket.send(formatSseEvent($notification(1)))
      let gone = await socket.recv(1)
      if gone.len == 0:
        hangedUp.complete())
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["method"].getStr() == "notifications/progress"
    waitFor transport.close()
    check waitFor withTimeout(hangedUp, 2000)

  test "Given a server that answers a notification with 202 and an empty body, when the notification is sent, then the client closes the connection":
    let hangedUp = newFuture[void]("hangedUp")
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L")
      let gone = await socket.recv(1)
      if gone.len == 0:
        hangedUp.complete())
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendNotification(newJsonRpcNotification("notifications/cancelled", newJObject()))
    check waitFor withTimeout(hangedUp, 2000)
    waitFor transport.close()

if speaks >= mpv20250326:
  suite "client: the GET stream and DELETE (mutation review, g2g-hc-b)":

    test "Given a client that says initialized twice, when the GET stream is already open, then it does not open a second one":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
          await eventStreamHead(socket)
          discard await socket.recv(1)
        else:
          await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(speaks)
      for _ in 1 .. 2:
        waitFor transport.sendNotification(
          newJsonRpcNotification("notifications/initialized", newJObject()))
      waitFor sleepAsync(200)
      check gets == 1
      waitFor transport.close()

    proc closingWith(answer: string): string =
      ## What a transport with a session logs when it closes and the server
      ## answers DELETE with `answer` (the connection is dropped when empty).
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if answer.len > 0:
          await socket.send(answer))
      let transport = newStreamableHttpTransport(url)
      transport.listenForServerMessages = false
      transport.sessionId = some("s-1")
      transport.protocolVersionNegotiated(speaks)
      loggedWhile(proc() = waitFor transport.close())

    test "Given a server that answers DELETE with 500, when the client closes, then the refusal is logged and closing succeeds":
      let logged = closingWith("HTTP/1.1 500 Internal Server Error\c\LContent-Length: 0\c\L\c\L")
      check "[mcp-http] DELETE" in logged
      check "answered HTTP 500" in logged

    test "Given a server that answers DELETE with 204 or 405, when the client closes, then nothing is logged":
      check closingWith("HTTP/1.1 204 No Content\c\L\c\L") == ""
      check closingWith("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L") == ""

    test "Given a server that drops the connection on DELETE, when the client closes, then the failure is logged and closing succeeds":
      let logged = closingWith("")
      check "[mcp-http] DELETE" in logged
      check "failed:" in logged

    test "Given a server that answers DELETE with 204 and no body, when the client closes, then the client closes the connection":
      let hangedUp = newFuture[void]("hangedUp")
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        await socket.send("HTTP/1.1 204 No Content\c\L\c\L")
        let gone = await socket.recv(1)
        if gone.len == 0:
          hangedUp.complete())
      let transport = newStreamableHttpTransport(url)
      transport.listenForServerMessages = false
      transport.sessionId = some("s-1")
      transport.protocolVersionNegotiated(speaks)
      waitFor transport.close()
      check waitFor withTimeout(hangedUp, 2000)

proc accepted(socket: AsyncSocket): Future[void] =
  socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L")

proc initialized(transport: StreamableHttpTransport) =
  transport.protocolVersionNegotiated(speaks)
  waitFor transport.sendNotification(
    newJsonRpcNotification("notifications/initialized", newJObject()))

proc nothingMoreWithin(transport: StreamableHttpTransport, ms: int): bool =
  let waiting = transport.receiveMessage()
  waitFor sleepAsync(ms)
  not waiting.finished

proc errorStatusOf(status: string, body: string): int =
  ## The status a client reports when the server answers its request with
  ## `status` and `body`; 0 when it reports none.
  let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
    await socket.send("HTTP/1.1 " & status & "\c\LContent-Type: application/json\c\L" &
                      "Content-Length: " & $body.len & "\c\L\c\L" & body))
  let transport = newStreamableHttpTransport(url)
  try:
    transport.ask()
  except McpTransportError as e:
    result = e.code
  waitFor transport.close()

suite "client: limits, errors and the end of a stream (mutation review, g2g-hc-a)":

  test "Given a body exactly as long as the limit, when a request is sent, then the response is delivered":
    let body = $(%*{"jsonrpc": "2.0", "id": "r1", "result": {}})
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                        "Content-Length: " & $body.len & "\c\L\c\L" & body))
    let transport = newStreamableHttpTransport(url)
    transport.maxResponseSize = body.len
    transport.ask()
    check transport.received()["id"].getStr() == "r1"
    waitFor transport.close()

  test "Given an HTTP error whose JSON body has an error but no jsonrpc version, when a request is sent, then it is a transport error with the status":
    check errorStatusOf("500 Internal Server Error", $(%*{"error": {"code": -1, "message": "x"}})) == 500

  test "Given an HTTP error whose JSON body is no object, when a request is sent, then it is a transport error with the status":
    check errorStatusOf("502 Bad Gateway", "[\"upstream\"]") == 502

  test "Given a stream that carries the response and then ends, when the response was read, then nothing else is delivered":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      let id = parseJson(request.body)["id"]
      await eventStreamHead(socket)
      await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": id, "result": {}}))))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["id"].getStr() == "r1"
    check transport.nothingMoreWithin(200)
    waitFor transport.close()

  test "Given a stream that carries the response to another request, when it ends without its own, then the stream-closed error is delivered":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await eventStreamHead(socket)
      await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": "other", "result": {}}))))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["id"].getStr() == "other"
    check transport.received().isLocalStreamClosed
    waitFor transport.close()

  test "Given a stream with a request of the server that has the id of the posted request, when it ends without the response, then the stream-closed error is delivered":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await eventStreamHead(socket)
      await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": "r1", "method": "ping"}))))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["method"].getStr() == "ping"
    check transport.received().isLocalStreamClosed
    waitFor transport.close()

  test "Given a request whose event stream is open, when the client closes, then no stream-closed error is delivered":
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await eventStreamHead(socket)
      await socket.send(formatSseEvent($notification(1)))
      discard await socket.recv(1))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    discard transport.received()
    waitFor transport.close()
    waitFor sleepAsync(100)
    expect McpTransportError:
      discard waitFor transport.receiveMessage()

  test "Given an event that is no JSON, when it arrives on the stream of a request, then the client says the stream failed and closes the connection":
    let hangedUp = newFuture[void]("hangedUp")
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await eventStreamHead(socket)
      await socket.send(formatSseEvent("not json"))
      let gone = await socket.recv(1)
      if gone.len == 0:
        hangedUp.complete())
    let transport = newStreamableHttpTransport(url)
    let logged = loggedWhile(proc() =
      transport.ask()
      check waitFor withTimeout(hangedUp, 2000))
    check "[mcp-http] event stream from " & url & " failed with McpTransportError" in logged
    check logged.count('\n') == 1
    waitFor transport.close()

  test "Given an id that was cancelled while its stream was open, when the id is used again and its stream breaks, then the stream-closed error is delivered":
    var posts = 0
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      inc posts
      await eventStreamHead(socket)
      await socket.send(formatSseEvent($notification(posts)))
      if posts == 1:
        discard await socket.recv(1))
    let transport = newStreamableHttpTransport(url)
    transport.ask()
    check transport.received()["params"]["progress"].getInt() == 1
    transport.cancelRequest("r1")
    waitFor sleepAsync(100)
    transport.ask()
    check transport.received()["params"]["progress"].getInt() == 2
    check transport.received().isLocalStreamClosed
    waitFor transport.close()

if speaks >= mpv20250326:
  suite "client: resuming and the GET stream (mutation review, g2g-hc-a)":

    proc resumingTransport(url: string): StreamableHttpTransport =
      result = newStreamableHttpTransport(url)
      result.sessionId = some("s-1")
      result.reconnectDelayMs = 5
      result.protocolVersionNegotiated(speaks)

    test "Given a resumed stream whose events carry no id, when it is cut too, then the next resumption still names the last id that was sent":
      var lastIds: seq[string] = @[]
      var postedId: JsonNode = nil
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        await eventStreamHead(socket)
        if request.httpMethod == "POST":
          postedId = parseJson(request.body)["id"]
          await socket.send(formatSseEvent($notification(1), id = "a-1"))
        else:
          lastIds.add request.header("Last-Event-ID")
          if lastIds.len == 1:
            await socket.send(formatSseEvent($notification(2)))
          else:
            await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": postedId, "result": {}}))))
      let transport = resumingTransport(url)
      transport.ask()
      discard transport.received()
      discard transport.received()
      check transport.received()["id"].getStr() == "r1"
      check lastIds == @["a-1", "a-1"]
      waitFor transport.close()

    test "Given a server that says something on every resumed stream, when the stream is cut more often than the limit, then the response still arrives":
      var gets = 0
      var postedId: JsonNode = nil
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        await eventStreamHead(socket)
        if request.httpMethod == "POST":
          postedId = parseJson(request.body)["id"]
          await socket.send(formatSseEvent($notification(0), id = "a-0"))
        else:
          inc gets
          if gets < 5:
            await socket.send(formatSseEvent($notification(gets), id = "a-" & $gets))
          else:
            await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": postedId, "result": {}}))))
      let transport = resumingTransport(url)
      transport.maxReconnects = 2
      transport.ask()
      for n in 0 .. 4:
        check transport.received()["method"].getStr() == "notifications/progress"
      check transport.received()["id"].getStr() == "r1"
      check gets == 5
      waitFor transport.close()

    test "Given a resumed stream that carries the response, when it ends, then the client neither asks again nor delivers a stream-closed error":
      var gets = 0
      var postedId: JsonNode = nil
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        await eventStreamHead(socket)
        if request.httpMethod == "POST":
          postedId = parseJson(request.body)["id"]
          await socket.send(formatSseEvent($notification(1), id = "a-1"))
        else:
          inc gets
          await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": postedId, "result": {}}), id = "a-2")))
      let transport = resumingTransport(url)
      transport.ask()
      discard transport.received()
      check transport.received()["id"].getStr() == "r1"
      check transport.nothingMoreWithin(200)
      check gets == 1
      waitFor transport.close()

    test "Given a server that ends every GET stream at once, when the session is initialized, then the client asks once and as often again as it may reconnect":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
          await eventStreamHead(socket)
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      transport.reconnectDelayMs = 5
      transport.maxReconnects = 2
      transport.initialized()
      waitFor sleepAsync(400)
      check gets == 3
      waitFor transport.close()

    test "Given a GET stream cut after a message, when the client reconnects, then it waits for the reconnect delay":
      var asked: seq[float] = @[]
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          asked.add epochTime()
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($notification(asked.len), id = "g-" & $asked.len))
          if asked.len > 1:
            discard await socket.recv(1)
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      transport.reconnectDelayMs = 150
      transport.initialized()
      check transport.received()["params"]["progress"].getInt() == 1
      check transport.received()["params"]["progress"].getInt() == 2
      check (asked[1] - asked[0]) * 1000 >= 140
      waitFor transport.close()

    test "Given GET streams whose later events carry no id, when each is cut, then every reconnection names the last id that was sent":
      var lastIds: seq[string] = @[]
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          lastIds.add request.header("Last-Event-ID")
          await eventStreamHead(socket)
          case lastIds.len
          of 1:
            await socket.send(formatSseEvent($notification(1), id = "g-1"))
          of 2:
            await socket.send(formatSseEvent($notification(2)))
          else:
            discard await socket.recv(1)
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      transport.reconnectDelayMs = 5
      transport.initialized()
      discard transport.received()
      discard transport.received()
      waitFor sleepAsync(100)
      check lastIds == @["", "g-1", "g-1"]
      waitFor transport.close()

    test "Given a server that answers the GET with 200 and no event stream, when the session is initialized, then the client asks once, says so and closes the connection":
      var gets = 0
      let hangedUp = newFuture[void]("hangedUp")
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
          await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                            "Content-Length: 2\c\L\c\L{}")
          let gone = await socket.recv(1)
          if gone.len == 0:
            hangedUp.complete()
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      transport.reconnectDelayMs = 5
      let logged = loggedWhile(proc() =
        transport.initialized()
        waitFor sleepAsync(300))
      check gets == 1
      check "[mcp-http] GET " & url & " answered HTTP 200" in logged
      check "; not resuming" in logged
      check logged.count('\n') == 1
      check waitFor withTimeout(hangedUp, 2000)
      waitFor transport.close()

    test "Given a server that answers the GET with 405, when the session is initialized, then the client closes the connection and logs nothing":
      let hangedUp = newFuture[void]("hangedUp")
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          await socket.send("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L")
          let gone = await socket.recv(1)
          if gone.len == 0:
            hangedUp.complete()
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      let logged = loggedWhile(proc() =
        transport.initialized()
        waitFor sleepAsync(200))
      check logged == ""
      check waitFor withTimeout(hangedUp, 2000)
      waitFor transport.close()

    test "Given a server that hangs up on the GET, when the session is initialized, then the client logs the failure once and does not ask again":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      transport.reconnectDelayMs = 5
      let logged = loggedWhile(proc() =
        transport.initialized()
        waitFor sleepAsync(300))
      check gets == 1
      check "[mcp-http] GET " & url & " failed: " in logged
      check logged.count('\n') == 1
      waitFor transport.close()

    test "Given an event that is no JSON on the GET stream, when it arrives, then the client says the stream failed":
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          await eventStreamHead(socket)
          await socket.send(formatSseEvent("not json"))
          discard await socket.recv(1)
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      let logged = loggedWhile(proc() =
        transport.initialized()
        waitFor sleepAsync(200))
      check "[mcp-http] event stream from " & url & " failed with McpTransportError" in logged
      check logged.count('\n') == 1
      waitFor transport.close()

    test "Given a GET stream that is open, when the client closes, then the connection of the stream is closed":
      let hangedUp = newFuture[void]("hangedUp")
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($notification(1)))
          let gone = await socket.recv(1)
          if gone.len == 0:
            hangedUp.complete()
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      transport.initialized()
      discard transport.received()
      waitFor transport.close()
      check waitFor withTimeout(hangedUp, 2000)

    test "Given a GET stream still being opened, when the client closes, then the connection of that stream is closed as well":
      let hangedUp = newFuture[void]("hangedUp")
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          await sleepAsync(150)
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($notification(1)))
          let gone = await socket.recv(1)
          if gone.len == 0:
            hangedUp.complete()
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      transport.initialized()
      waitFor sleepAsync(30)
      waitFor transport.close()
      check waitFor withTimeout(hangedUp, 2000)

    test "Given a GET stream that is open, when the client is initialized again, then it does not open a second stream":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
          await eventStreamHead(socket)
          discard await socket.recv(1)
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      transport.initialized()
      waitFor sleepAsync(100)
      transport.initialized()
      waitFor sleepAsync(100)
      check gets == 1
      waitFor transport.close()

    test "Given a GET stream that ended because the server offers none, when the client is initialized again, then it asks again":
      var gets = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "GET":
          inc gets
          await socket.send("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L")
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      transport.initialized()
      waitFor sleepAsync(100)
      transport.initialized()
      waitFor sleepAsync(100)
      check gets == 2
      waitFor transport.close()

if speaks.has(ftProtocolVersionHeader):
  suite "client: the protocol version header (mutation review, g2g-hc-a)":

    test "Given a negotiated version that has the header, when the client posts, opens the GET stream and ends the session, then each request names the version":
      var seen: seq[tuple[httpMethod, version: string]] = @[]
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        seen.add (request.httpMethod, request.header("MCP-Protocol-Version"))
        case request.httpMethod
        of "GET":
          await eventStreamHead(socket)
          discard await socket.recv(1)
        of "DELETE":
          await socket.send("HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L")
        else:
          await socket.accepted())
      let transport = newStreamableHttpTransport(url)
      transport.sessionId = some("s-1")
      transport.initialized()
      waitFor sleepAsync(100)
      waitFor transport.close()
      var methods: seq[string] = @[]
      for (httpMethod, version) in seen:
        methods.add httpMethod
        check version == $speaks
      check "POST" in methods
      check "GET" in methods
      check "DELETE" in methods

suite "client: an event stream in answer to a notification":
  # The transport pages have a server answer a notification with 202. A
  # server that opens an event stream instead is not following them, and
  # what it does must not bring the client down.

  test "Given a server that answers a notification with an event stream, when the stream ends, then its messages were delivered and the client goes on":
    var posts = 0
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      inc posts
      let message = parseJson(request.body)
      if message.hasKey("id"):
        let body = $(%*{"jsonrpc": "2.0", "id": message["id"], "result": {}})
        await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                          "Content-Length: " & $body.len & "\c\L\c\L" & body)
      else:
        await eventStreamHead(socket)
        await socket.send("data: " & $notification(1) & "\n\n"))
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendNotification(
      newJsonRpcNotification("notifications/roots/list_changed", newJObject()))
    check transport.received()["params"]["progress"].getInt() == 1
    # The stream has ended by the time the next exchange completes.
    waitFor sleepAsync(100)
    transport.ask("after")
    check transport.received()["id"].getStr() == "after"
    check posts == 2
    waitFor transport.close()

if speaks >= mpv20250326:
  suite "client: a cancelled request is not resumed":

    test "Given a request whose stream already carried an event id, when the client cancels it, then the stream is not asked for again and no answer arrives":
      var gets = 0
      var postedId: JsonNode = nil
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod == "POST":
          postedId = parseJson(request.body)["id"]
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($notification(1), id = "a-1"))
          # Holds the stream open until the client hangs up.
          discard await socket.recv(1)
        else:
          inc gets
          await eventStreamHead(socket)
          await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": postedId, "result": {}}),
                                           id = "a-2")))
      let transport = newStreamableHttpTransport(url)
      transport.sessionId = some("s-1")
      transport.reconnectDelayMs = 5
      transport.protocolVersionNegotiated(speaks)
      transport.ask()
      check transport.received()["method"].getStr() == "notifications/progress"
      transport.cancelRequest("r1")
      check transport.nothingMoreWithin(300)
      check gets == 0
      waitFor transport.close()
