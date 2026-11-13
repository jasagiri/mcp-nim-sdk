## A request whose event stream ends before its response is a local loss,
## told to the client on a path of its own. A peer's JSON-RPC error, whatever
## its code, stays the peer's error (2026-07-28 basic/index: local errors
## must not be mistaken for errors received from the peer).

import std/[unittest, asyncdispatch, asyncnet, httpcore, json, os, strutils, tables]
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

proc sendJson(socket: AsyncSocket, body: JsonNode, extra = "") {.async.} =
  let text = $body
  await socket.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L" & extra &
                    "Content-Length: " & $text.len & "\c\L\c\L" & text)

type Mode = enum
  moStreamEnds    ## tools/list is answered by a stream that ends with no response
  moPeerError     ## tools/list is answered with a JSON-RPC error of code -1000
  moNotifyThenEnd ## the stream carries a notification and then ends

proc lostServer(mode: Mode): string =
  startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
    if request.httpMethod != "POST":
      await socket.send("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L")
      return
    let message = parseJson(request.body)
    let id = message{"id"}
    case message{"method"}.getStr()
    of "initialize":
      await socket.sendJson(%*{"jsonrpc": "2.0", "id": id, "result": {
        "protocolVersion": message["params"]["protocolVersion"], "capabilities": {"tools": {}},
        "serverInfo": {"name": "raw", "version": "0"}}}, "Mcp-Session-Id: s-1\c\L")
    of "tools/list":
      case mode
      of moPeerError:
        await socket.sendJson(%*{"jsonrpc": "2.0", "id": id,
          "error": {"code": -1000, "message": "the peer's own"}})
      of moStreamEnds:
        await socket.send("HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" &
                          "Connection: close\c\L\c\L")
      of moNotifyThenEnd:
        await socket.send("HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L" &
                          "Connection: close\c\L\c\L" &
          formatSseEvent($(%*{"jsonrpc": "2.0", "method": "notifications/progress",
                              "params": {"progressToken": "p", "progress": 1}})))
    else:
      await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))

const LegacyHttp = min(DefaultProtocolVersion, mpv20251125)

proc connected(url: string): McpClient =
  result = newMcpClient(McpClientInfo(name: "c", version: "1"), LegacyHttp)
  waitFor result.connect(newStreamableHttpTransport(url))

proc loggedWhile(body: proc()): string =
  let path = getTempDir() / "mcp-lost-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

suite "a request lost with its stream is not a response":

  test "Given a stream that ends before the response, when the client sent the request, then it raises McpRequestLostError and not McpRequestError":
    let c = connected(lostServer(moStreamEnds))
    var lost = false
    var peers = false
    try:
      discard waitFor c.callMethod("tools/list", newJObject())
    except McpRequestLostError:
      lost = true
    except client.McpRequestError:
      peers = true
    check lost
    check not peers
    waitFor c.close()

  test "Given a stream that ends before the response, when a loss is raised, then it is a McpTransportError":
    let c = connected(lostServer(moStreamEnds))
    expect McpTransportError:
      discard waitFor c.callMethod("tools/list", newJObject())
    waitFor c.close()

  test "Given a peer that answers with an error of code -1000, when the client sent the request, then it raises McpRequestError with that code":
    let c = connected(lostServer(moPeerError))
    var code = 0
    var lost = false
    try:
      discard waitFor c.callMethod("tools/list", newJObject())
    except client.McpRequestError as e:
      code = e.code
    except McpRequestLostError:
      lost = true
    check code == -1000
    check not lost
    waitFor c.close()

  test "Given a client that lost a request, when it sends the next, then the connection still works":
    let c = connected(lostServer(moStreamEnds))
    for attempt in 1 .. 2:
      expect McpRequestLostError:
        discard waitFor c.callMethod("tools/list", newJObject())
    waitFor c.close()

suite "a loss the client no longer waits for":

  test "Given a request lost with its stream, when the caller was told, then the client holds no request for it any more":
    let c = connected(lostServer(moStreamEnds))
    expect McpRequestLostError:
      discard waitFor c.callMethod("tools/list", newJObject())
    check c.pendingRequests.len == 0
    waitFor c.close()

  test "Given a transport that reports the loss of a request nobody waits for, when it does, then the client goes on and answers the next request":
    let transport = newStreamableHttpTransport(lostServer(moPeerError))
    let c = newMcpClient(McpClientInfo(name: "c", version: "1"), LegacyHttp)
    waitFor c.connect(transport)
    transport.onRequestLost("nobody-waits-for-this", "the stream ended")
    var code = 0
    try:
      discard waitFor c.callMethod("tools/list", newJObject())
    except client.McpRequestError as e:
      code = e.code
    check code == -1000
    waitFor c.close()

suite "a transport tells its client about a loss on its own path":

  test "Given a transport whose stream ends before the response, when it has a loss handler, then the handler gets the id and receiveMessage gets nothing":
    let url = lostServer(moStreamEnds)
    let transport = newStreamableHttpTransport(url)
    var lostIds: seq[string]
    var reasons: seq[string]
    transport.onRequestLost = proc(requestId: string, reason: string) =
      lostIds.add requestId
      reasons.add reason
    transport.protocolVersionNegotiated(LegacyHttp)
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/list", newJObject()))
    let next = transport.receiveMessage()
    check not waitFor withTimeout(next, 300)
    check lostIds == @["r1"]
    check reasons.len == 1 and reasons[0].len > 0
    waitFor transport.close()
    if next.failed:
      discard next.readError()

  test "Given a transport with no loss handler, when a stream ends before the response, then stderr says the request was lost":
    let url = lostServer(moNotifyThenEnd)
    let transport = newStreamableHttpTransport(url)
    transport.protocolVersionNegotiated(LegacyHttp)
    let log = loggedWhile(proc() =
      waitFor transport.sendRequest(newJsonRpcRequest("r7", "tools/list", newJObject()))
      let first = waitFor transport.receiveMessage()
      check first{"method"}.getStr() == "notifications/progress"
      waitFor sleepAsync(200))
    check "r7" in log
    check "lost" in log
    waitFor transport.close()

  test "Given a peer's error response with code -1000, when a transport reads it, then it is delivered as a message":
    let url = lostServer(moPeerError)
    let transport = newStreamableHttpTransport(url)
    var lostIds: seq[string]
    transport.onRequestLost = proc(requestId: string, reason: string) = lostIds.add requestId
    transport.protocolVersionNegotiated(LegacyHttp)
    waitFor transport.sendRequest(newJsonRpcRequest("r1", "tools/list", newJObject()))
    let message = waitFor transport.receiveMessage()
    check message{"error", "code"}.getInt() == -1000
    check lostIds.len == 0
    waitFor transport.close()
