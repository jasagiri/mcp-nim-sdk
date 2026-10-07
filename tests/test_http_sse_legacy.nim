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
import transport/sse_legacy
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
