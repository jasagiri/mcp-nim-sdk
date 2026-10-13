## The client side of Streamable HTTP as the transport pages of the
## specification describe it: what the client posts, how it spells the
## headers it mirrors, what it takes for noise in an event stream, how it holds
## several streams at once, and where it sends its session id.
##
## The servers here are written byte by byte on 127.0.0.1, so that each test
## sees exactly what the client put on the wire.

import std/[unittest, algorithm, asyncdispatch, asyncnet, httpcore, json, options, strutils,
            sequtils, unicode]
import mcp

const Speaks = min(DefaultProtocolVersion, mpv20251125)
  ## The newest version of the era that has a GET stream and sessions.

type
  RawRequest = object
    httpMethod: string
    headers: HttpHeaders
    body: string

  RawHandler = proc(request: RawRequest, socket: AsyncSocket): Future[void]

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

proc jsonReply(socket: AsyncSocket, body: string, extraHeaders = ""): Future[void] =
  socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" & extraHeaders &
              "Content-Length: " & $body.len & "\c\L\c\L" & body)

proc acceptedReply(socket: AsyncSocket): Future[void] =
  socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L")

proc streamHead(socket: AsyncSocket, extraHeaders = ""): Future[void] =
  socket.send("HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" & extraHeaders &
              "Connection: close\c\L\c\L")

proc received(transport: StreamableHttpTransport, timeoutMs = 3000): JsonNode =
  let next = transport.receiveMessage()
  doAssert waitFor withTimeout(next, timeoutMs), "no message within " & $timeoutMs & " ms"
  next.read()

proc modernParams(extra: JsonNode): JsonNode =
  result = %*{"_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientInfo": {"name": "peer", "version": "0"},
    "io.modelcontextprotocol/clientCapabilities": {}}}
  for key, value in extra.pairs:
    result[key] = value

proc answerOrAccept(request: RawRequest, socket: AsyncSocket) {.async.} =
  let message = parseJson(request.body)
  if message.hasKey("id") and message.hasKey("method"):
    await socket.jsonReply($(%*{"jsonrpc": "2.0", "id": message["id"], "result": {}}))
  else:
    await socket.acceptedReply()

suite "client: what is posted":

  for modern in [false, true]:
    test "Given a request, a notification, a response and a second request with the params of " &
         (if modern: "2026-07-28" else: "the earlier versions") &
         ", when the client sends them, then each is a POST of its own holding one message":
      var posts: seq[RawRequest] = @[]
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        posts.add request
        await answerOrAccept(request, socket))
      let transport = newStreamableHttpTransport(url)
      let params = if modern: modernParams(%*{"name": "t"}) else: %*{"name": "t"}
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", params))
      discard transport.received()
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/cancelled", %*{"requestId": "r1"}))
      waitFor transport.sendResponse(newJsonRpcResponse("s1", newJObject()))
      waitFor transport.sendRequest(newJsonRpcRequest("r2", "tools/call", params))
      discard transport.received()
      check posts.len == 4
      for post in posts:
        check post.httpMethod == "POST"
        let message = parseJson(post.body)
        check message.kind == JObject
        check message{"jsonrpc"}.getStr() == "2.0"
      check posts.mapIt(parseJson(it.body){"id"}.getStr()) == @["r1", "", "s1", "r2"]
      waitFor transport.close()

suite "client: UTF-8 on the wire":

  test "Given strings of every script, when a request carrying one is posted, then the body is valid UTF-8 and the server reads the same string":
    for text in ["", "plain ascii", "日本語", "é", "😀", "mixed 日本 é 😀 end",
                 "a b", "tab\tand\nnewline"]:
      var posted = ""
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        posted = request.body
        let id = parseJson(request.body)["id"]
        await socket.jsonReply($(%*{"jsonrpc": "2.0", "id": id,
                                    "result": {"text": parseJson(request.body)["params"]["text"]}})))
      let transport = newStreamableHttpTransport(url)
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "echo", %*{"text": text}))
      let answer = transport.received()
      checkpoint "text: " & text.escape
      check validateUtf8(posted) == -1
      check parseJson(posted)["params"]["text"].getStr() == text
      check answer["result"]["text"].getStr() == text
      waitFor transport.close()

suite "client: Mcp-Name in the Base64 form":

  proc nameSentFor(methodName: string, params: JsonNode): string =
    ## The Mcp-Name header the client sent with the request, "" when none.
    var sent = ""
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      sent = request.headers.getOrDefault("Mcp-Name")
      await answerOrAccept(request, socket))
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendRequest(newJsonRpcRequest("r1", methodName, modernParams(params)))
    discard transport.received()
    waitFor transport.close()
    sent

  test "Given names the specification tabulates, when tools/call is sent, then Mcp-Name is plain for plain ASCII and in the lowercase Base64 form for the rest":
    check nameSentFor("tools/call", %*{"name": "get_weather"}) == "get_weather"
    check nameSentFor("tools/call", %*{"name": "us-west1"}) == "us-west1"
    check nameSentFor("tools/call", %*{"name": "Hello, 世界"}) == "=?base64?SGVsbG8sIOS4lueVjA==?="
    check nameSentFor("tools/call", %*{"name": "天気"}) == "=?base64?5aSp5rCX?="
    check nameSentFor("tools/call", %*{"name": "line1\nline2"}) == "=?base64?bGluZTEKbGluZTI=?="
    check nameSentFor("tools/call", %*{"name": "=?base64?literal?="}) ==
      "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="

  test "Given a name with spaces round it, when tools/call is sent, then Mcp-Name is in the Base64 form":
    check nameSentFor("tools/call", %*{"name": " padded "}) == "=?base64?IHBhZGRlZCA=?="

  test "Given a resource URI that is not plain ASCII and a prompt name that is, when resources/read and prompts/get are sent, then only the URI is in the Base64 form":
    check nameSentFor("resources/read", %*{"uri": "file:///projects/myapp/config.json"}) ==
      "file:///projects/myapp/config.json"
    check nameSentFor("resources/read", %*{"uri": "file:///日本語.txt"}) ==
      "=?base64?ZmlsZTovLy/ml6XmnKzoqp4udHh0?="
    check nameSentFor("prompts/get", %*{"name": "summarize"}) == "summarize"

suite "client: header names are compared without regard to case":

  test "Given an answer whose header names are spelt in other cases, when the client reads it, then the session id and the event stream are recognised":
    if Speaks < mpv20250326:
      skip()
    else:
      for spelling in [("mcp-session-id", "content-type"), ("MCP-SESSION-ID", "CONTENT-TYPE"),
                       ("Mcp-Session-Id", "Content-Type"), ("mCp-SeSsIoN-iD", "cOnTeNt-TyPe")]:
        let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
          let id = parseJson(request.body)["id"]
          await socket.send("HTTP/1.1 200 OK\c\L" & spelling[1] & ": TEXT/EVENT-STREAM\c\L" &
                            spelling[0] & ": s-1\c\LConnection: close\c\L\c\L" &
                            formatSseEvent($(%*{"jsonrpc": "2.0", "id": id, "result": {}}))))
        let transport = newStreamableHttpTransport(url)
        waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
        checkpoint "spelling: " & spelling[0] & " " & spelling[1]
        check transport.received()["id"].getStr() == "r1"
        check transport.sessionId == some("s-1")
        waitFor transport.close()

suite "client: comment lines of an event stream":

  test "Given comment lines before, between and inside events, when the stream is read, then they are ignored and only the two messages arrive":
    let notification = $(%*{"jsonrpc": "2.0", "method": "notifications/progress",
                            "params": {"progressToken": "p", "progress": 1}})
    let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
      await socket.streamHead()
      await socket.send(":\c\L")
      await socket.send("data: " & notification & "\c\L\c\L")
      await socket.send(": keep-alive\c\L\c\L")
      await socket.send(":no space after the colon\c\L")
      await socket.send("data: {\"jsonrpc\":\"2.0\",\c\L: a comment inside an event\c\L" &
                        "data: \"id\":\"r1\",\"result\":{}}\c\L\c\L")
      await socket.send(":\c\L"))
    let transport = newStreamableHttpTransport(url)
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
    check transport.received()["method"].getStr() == "notifications/progress"
    let second = transport.received()
    check second["id"].getStr() == "r1"
    check second["result"].kind == JObject
    let waiting = transport.receiveMessage()
    waitFor sleepAsync(100)
    check not waiting.finished
    waitFor transport.close()

suite "client: several streams at once":

  test "Given a GET stream and two request streams open together, when the server speaks on each, then all three deliver and were open at the same time":
    if Speaks < mpv20250326:
      skip()
    else:
      var open = 0
      var mostOpen = 0
      let gate = newFuture[void]("gate")
      proc note(delta: int) =
        open += delta
        mostOpen = max(mostOpen, open)
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod != "GET" and not parseJson(request.body).hasKey("id"):
          await socket.acceptedReply()
          return
        note(1)
        try:
          await socket.streamHead()
          if request.httpMethod == "GET":
            await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0",
              "method": "notifications/tools/list_changed"}), "", "g-1"))
            await gate
          else:
            let message = parseJson(request.body)
            await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0",
              "method": "notifications/progress",
              "params": {"progressToken": message["id"], "progress": 1}}), "",
              "p-" & message["id"].getStr()))
            await gate
            await socket.send(formatSseEvent($(%*{"jsonrpc": "2.0", "id": message["id"],
                                                  "result": {}})))
        finally:
          note(-1))
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(Speaks)
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/initialized", newJObject()))
      check transport.received()["method"].getStr() == "notifications/tools/list_changed"
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
      waitFor transport.sendRequest(newJsonRpcRequest("r2", "tools/call", newJObject()))
      for _ in 1 .. 2:
        check transport.received()["method"].getStr() == "notifications/progress"
      check mostOpen == 3
      gate.complete()
      var answered: seq[string] = @[]
      for _ in 1 .. 2:
        answered.add transport.received()["id"].getStr()
      check answered.sorted == @["r1", "r2"]
      waitFor transport.close()

suite "client: the session id stays with the endpoint":

  test "Given a session id and a server that redirects the next POST to another origin, when the client sends it, then it raises and the other origin sees nothing":
    if Speaks < mpv20250326:
      skip()
    else:
      var strangerSaw: seq[RawRequest] = @[]
      let strangerUrl = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        strangerSaw.add request
        await socket.jsonReply("{}"))
      var posts = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        inc posts
        if posts == 1:
          let id = parseJson(request.body)["id"]
          await socket.jsonReply($(%*{"jsonrpc": "2.0", "id": id, "result": {}}),
                                "Mcp-Session-Id: s-1\c\L")
        else:
          await socket.send("HTTP/1.1 307 Temporary Redirect\c\LLocation: " & strangerUrl &
                            "\c\LContent-Length: 0\c\L\c\L"))
      let transport = newStreamableHttpTransport(url)
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "ping", newJObject()))
      discard transport.received()
      check transport.sessionId == some("s-1")
      expect McpTransportError:
        waitFor transport.sendRequest(newJsonRpcRequest("r2", "ping", newJObject()))
      waitFor sleepAsync(50)
      check strangerSaw.len == 0
      waitFor transport.close()
