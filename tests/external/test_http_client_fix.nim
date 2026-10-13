## What the HTTP client does with an event or a body that holds a batch
## (2025-03-26 only), and what stands in for a request whose event stream
## ended before its response (2026-07-28: no new code in -32000 to -32019,
## none of -32020 to -32099 that the specification does not define).

import std/[unittest, asyncdispatch, asyncnet, httpcore, json, options, strutils]
import mcp

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

proc received(transport: StreamableHttpTransport, timeoutMs = 3000): JsonNode =
  let next = transport.receiveMessage()
  doAssert waitFor withTimeout(next, timeoutMs), "no message within " & $timeoutMs & " ms"
  next.read()

proc progress(n: int): JsonNode =
  %*{"jsonrpc": "2.0", "method": "notifications/progress",
     "params": {"progressToken": "p", "progress": n}}

proc streamAnswering(events: proc(id: JsonNode): seq[JsonNode]): string =
  startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
    if request.httpMethod != "POST":
      await socket.send("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L")
      return
    let id = parseJson(request.body)["id"]
    var body = ""
    for event in events(id):
      body.add formatSseEvent($event)
    await socket.send("HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" &
                      "Connection: close\c\L\c\L" & body))

const SpeaksBatches = DefaultProtocolVersion >= mpv20250326

suite "a batch in an event of a stream (2025-03-26)":

  test "Given a POST answered by a stream whose one event holds a batch of a notification and the response, when the client reads it, then the two messages are delivered one by one":
    if not SpeaksBatches:
      skip()
    else:
      let url = streamAnswering(proc(id: JsonNode): seq[JsonNode] =
        @[%[progress(1), %*{"jsonrpc": "2.0", "id": id, "result": {}}]])
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(mpv20250326)
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
      let first = transport.received()
      check first.kind == JObject
      check first{"method"}.getStr() == "notifications/progress"
      let second = transport.received()
      check second.kind == JObject
      check second{"id"}.getStr() == "r1"
      waitFor transport.close()

  test "Given a batch whose response comes first and a later event, when the client reads the stream, then the stream is answered once and no stand-in follows":
    if not SpeaksBatches:
      skip()
    else:
      let url = streamAnswering(proc(id: JsonNode): seq[JsonNode] =
        @[%[%*{"jsonrpc": "2.0", "id": id, "result": {}}, progress(1)], progress(2)])
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(mpv20250326)
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
      check transport.received(){"id"}.getStr() == "r1"
      check transport.received(){"params", "progress"}.getInt() == 1
      check transport.received(){"params", "progress"}.getInt() == 2
      let more = transport.receiveMessage()
      check not waitFor withTimeout(more, 200)
      waitFor transport.close()

  test "Given a POST answered by a JSON body that is a batch, when the client reads it, then the messages are delivered one by one":
    if not SpeaksBatches:
      skip()
    else:
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        let id = parseJson(request.body)["id"]
        let body = $(%[progress(1), %*{"jsonrpc": "2.0", "id": id, "result": {}}])
        await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" &
                          "Content-Length: " & $body.len & "\c\L\c\L" & body))
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(mpv20250326)
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
      check transport.received(){"method"}.getStr() == "notifications/progress"
      check transport.received(){"id"}.getStr() == "r1"
      waitFor transport.close()

  test "Given a GET stream whose one event holds a batch of two notifications, when the client reads it, then the two notifications are delivered one by one":
    if not SpeaksBatches:
      skip()
    else:
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod != "GET":
          await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L")
          return
        await socket.send("HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" &
                          "Connection: close\c\L\c\L" &
          formatSseEvent($(%[
            %*{"jsonrpc": "2.0", "method": "notifications/tools/list_changed"},
            %*{"jsonrpc": "2.0", "method": "notifications/prompts/list_changed"}])))
        await sleepAsync(500))
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(mpv20250326)
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/initialized", newJObject()))
      check transport.received(){"method"}.getStr() == "notifications/tools/list_changed"
      check transport.received(){"method"}.getStr() == "notifications/prompts/list_changed"
      waitFor transport.close()

  test "Given a version without batches and an event that holds an array, when the client reads it, then the array is one value, as sent":
    for version in [mpv20250618, mpv20251125]:
      if version notin SupportedProtocolVersions or version.has(ftJsonRpcBatch):
        continue
      let url = streamAnswering(proc(id: JsonNode): seq[JsonNode] =
        @[%[progress(1), %*{"jsonrpc": "2.0", "id": id, "result": {}}]])
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(version)
      waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
      let first = transport.received()
      check first.kind == JArray
      check first.len == 2
      waitFor transport.close()

suite "a request whose event stream ended before its response":

  test "Given an event stream that ends before the response, when the transport stands in for it, then the code is in no range that JSON-RPC or MCP reserves":
    let url = streamAnswering(proc(id: JsonNode): seq[JsonNode] = @[])
    let transport = newStreamableHttpTransport(url)
    transport.sessionId = some("s-1")
    transport.protocolVersionNegotiated(DefaultProtocolVersion)
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
    let standIn = transport.received()
    check standIn{"id"}.getStr() == "r1"
    let code = standIn{"error", "code"}.getInt()
    check code == ErrStreamClosed
    check not (code <= -32000 and code >= -32768)
    waitFor transport.close()
