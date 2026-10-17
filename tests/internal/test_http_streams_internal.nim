## What a Streamable HTTP endpoint sends besides a single JSON answer: SSE
## responses that carry what the server says while it works, the GET stream,
## resumption, JSON-RPC batches, the protocol version header and session
## expiry. The transport is driven directly, without McpServer, so that each
## test states exactly what the server side does.
##
## Versions are named in the tests that need a particular one; a test runs
## only when the build speaks that version.

import std/[unittest, asyncdispatch, asyncnet, uri, httpclient, json, options, strutils]
import transport/transport
import transport/http_server
import ../external/sse_reader
import transport/sse_stream
import protocol/types
import protocol/version

const SpeaksModern = isModern(DefaultProtocolVersion)

type
  Script = ref object
    ## What the fake server side has seen and is told to do.
    version: McpProtocolVersion
    release: Future[void]
      ## `wait` requests answer once this completes
    notifications: seq[string]
    answered: seq[JsonNode]
    cancelled: seq[string]
    ended: seq[string]

proc progress(n: int): JsonRpcNotification =
  newJsonRpcNotification("notifications/progress",
                         %*{"progressToken": "t", "progress": n})

proc runScript(t: HttpServerTransport, s: Script) {.async.} =
  ## Methods: `initialize` answers with the script's version; `work` sends
  ## two progress notifications related to the request, then answers; `wait`
  ## sends one, waits for `release`, sends another and answers; `ping`
  ## answers at once; `silent` is never answered; `paced` sends three
  ## progress notifications 20 ms apart and answers as soon as the third has
  ## gone out.
  while true:
    let incoming = await t.receive()
    let message = incoming.message
    if not isRequest(message):
      s.notifications.add message{"method"}.getStr()
      s.answered.add message
      continue
    let id = message["id"].getStr()
    let route = MessageRoute(session: incoming.session, requestId: id)
    case message["method"].getStr()
    of "initialize":
      await t.sendResponse(newJsonRpcResponse(id, %*{
        "protocolVersion": $s.version, "capabilities": {},
        "serverInfo": {"name": "script", "version": "0"}}))
    of "work":
      await t.sendNotification(progress(1), route)
      await t.sendNotification(progress(2), route)
      await t.sendResponse(newJsonRpcResponse(id, %*{"done": true}))
    of "wait":
      await t.sendNotification(progress(1), route)
      await s.release
      await t.sendNotification(progress(2), route)
      await t.sendResponse(newJsonRpcResponse(id, %*{"done": true}))
    of "paced":
      for n in 1 .. 3:
        await t.sendNotification(progress(n), route)
        if n < 3:
          await sleepAsync(20)
      await sleepAsync(0)
      await t.sendResponse(newJsonRpcResponse(id, %*{"done": true}))
    of "silent":
      discard  # never answered; the client gives up
    else:
      await t.sendResponse(newJsonRpcResponse(id, %*{}))

proc startRaw(version: McpProtocolVersion,
              maxStreamEvents = DefaultMaxStreamEvents): tuple[
    transport: HttpServerTransport, url: string, script: Script] =
  let transport = newHttpServerTransport(port = 0, protocolVersion = version)
  transport.maxStreamEvents = maxStreamEvents
  let script = Script(version: min(version, mpv20251125),
                      release: newFuture[void]("release"))
  transport.onRequestCancelled = proc(session, requestId: string) {.closure, gcsafe.} =
    script.cancelled.add requestId
  transport.onSessionEnd = proc(session: string) {.closure, gcsafe.} =
    script.ended.add session
  transport.listen()
  asyncCheck transport.serve()
  asyncCheck runScript(transport, script)
  (transport, "http://127.0.0.1:" & $transport.port & "/mcp", script)

proc rpc(id: int, name: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "method": name, "params": {}}

const PostLimitMs = 10_000

proc post(url: string, body: JsonNode, headers: openArray[(string, string)] = []):
    tuple[code: HttpCode, headers: HttpHeaders, body: string] =
  let http = newAsyncHttpClient()
  defer: http.close()
  let allHeaders = newHttpHeaders({"Content-Type": "application/json",
                                   "Accept": "application/json, text/event-stream"})
  for (name, value) in headers:
    allHeaders[name] = value
  # A server that never answers must fail the test, not stall the run.
  let requesting = http.request(url, HttpPost, $body, allHeaders)
  doAssert waitFor withTimeout(requesting, PostLimitMs),
    "no response to POST within " & $PostLimitMs & " ms"
  let response = requesting.read()
  let reading = response.body
  doAssert waitFor withTimeout(reading, PostLimitMs),
    "no end of the POST response body within " & $PostLimitMs & " ms"
  (response.code, response.headers, reading.read())

proc initialize(url: string, version: McpProtocolVersion): string =
  let reply = post(url, %*{"jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {"protocolVersion": $version, "capabilities": {},
               "clientInfo": {"name": "peer", "version": "0"}}})
  doAssert reply.code == Http200, reply.body
  $reply.headers["Mcp-Session-Id"]

proc legacyHeaders(session: string, version: McpProtocolVersion): seq[(string, string)] =
  result = @[("Mcp-Session-Id", session)]
  if version >= mpv20250618:
    result.add ("MCP-Protocol-Version", $version)

proc methodOf(message: JsonNode): string = message{"method"}.getStr()

suite "SSE response to a request (versions 2025-03-26 to 2025-11-25)":
  let version = min(DefaultProtocolVersion, mpv20251125)


suite "event ids and resumption (versions 2025-03-26 to 2025-11-25)":
  let version = min(DefaultProtocolVersion, mpv20251125)


suite "GET stream (versions 2025-03-26 to 2025-11-25)":
  let version = min(DefaultProtocolVersion, mpv20251125)


if SpeaksModern:
  suite "SSE response and cancellation (2026-07-28)":

    proc modernPost(url: string, id: int, name: string): Events =
      open(url, HttpPost, $(%*{"jsonrpc": "2.0", "id": id, "method": name,
        "params": {"_meta": {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "0"},
          "io.modelcontextprotocol/clientCapabilities": {}}}}),
        [("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", name)])


suite "MCP-Protocol-Version header (versions 2025-06-18 to 2025-11-25)":
  let version = min(DefaultProtocolVersion, mpv20251125)


suite "idle sessions":
  let version = min(DefaultProtocolVersion, mpv20251125)


import protocol/modern

type Ledger = ref object
  ## Everything the transport handed to the fake server side, in order.
  seen: seq[McpIncoming]

proc runLedger(t: HttpServerTransport, l: Ledger, version: McpProtocolVersion) {.async.} =
  ## `initialize` is answered at `version`; every other request is left
  ## unanswered, so that what a peer does to a request in progress is seen.
  while true:
    let incoming = await t.receive()
    l.seen.add incoming
    let message = incoming.message
    if isRequest(message) and message["method"].getStr() == "initialize":
      await t.sendResponse(newJsonRpcResponse(message["id"].getStr(), %*{
        "protocolVersion": $version, "capabilities": {},
        "serverInfo": {"name": "ledger", "version": "0"}}))

proc startLedger(version: McpProtocolVersion): tuple[
    transport: HttpServerTransport, url: string, ledger: Ledger] =
  let transport = newHttpServerTransport(port = 0, protocolVersion = version)
  transport.listen()
  asyncCheck transport.serve()
  let ledger = Ledger()
  asyncCheck runLedger(transport, ledger, min(version, mpv20251125))
  (transport, "http://127.0.0.1:" & $transport.port & "/mcp", ledger)

proc postWithoutWaiting(url: string, body: JsonNode,
                        headers: openArray[(string, string)]): AsyncHttpClient =
  ## Posts and leaves the answer pending; closing the result is the client leaving.
  let http = newAsyncHttpClient()
  let all = newHttpHeaders({"Content-Type": "application/json",
                            "Accept": "application/json, text/event-stream"})
  for (name, value) in headers:
    all[name] = value
  discard http.request(url, HttpPost, $body, all)
  waitFor sleepAsync(50)
  http

proc cancelNotice(requestId: int): JsonNode =
  %*{"jsonrpc": "2.0", "method": "notifications/cancelled",
     "params": {"requestId": requestId}}

proc modernBody(id: int, name: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "method": name, "params": {"_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "0"},
    "io.modelcontextprotocol/clientCapabilities": {}}}}

proc withSubscriptionId(named: string): JsonRpcNotification =
  let params = newJObject()
  params["_meta"] = newJObject()
  params["_meta"][MetaSubscriptionId] = %named
  newJsonRpcNotification("notifications/progress", params)

proc bareInitializeBody(version: McpProtocolVersion): JsonNode =
  %*{"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": $version, "capabilities": {},
                "clientInfo": {"name": "peer", "version": "0"}}}

suite "the HTTP server transport's own rules (mutation review, g2f-hs-a)":
  let version = min(DefaultProtocolVersion, mpv20251125)


  block sessionWithoutNamedVersion:
    let ceiling = latestLegacyVersion(spokenVersionsUpTo(version))

proc openWithin(url: string, httpMethod: HttpMethod, headers: seq[(string, string)],
                ms = 2000): Option[Events] =
  ## The response, or none when the server has not answered within `ms`: a
  ## transport that forgets to answer must fail a check, not hang the test.
  let opening = openAsync(url, httpMethod, "", headers)
  if waitFor withTimeout(opening, ms):
    some(opening.read())
  else:
    none(Events)

suite "GET stream and session lifetime (mutation review, g2f-hs-b)":
  let version = min(DefaultProtocolVersion, mpv20251125)


import std/times
import transport/asynchttpserver_compat  # the server the transport runs on, so `Request` is the type serveStream takes

type Served = tuple[port: int, ended: Future[SseEnd]]
  ## Where the server of `serveOnce` listens, and how its connection ended.

proc serveOnce(stream: SseStream, afterSeq = 0, keepAliveMs = DefaultKeepAliveMs): Served =
  ## A server that answers its first request with `stream`, as the
  ## transport does.
  let server = newAsyncHttpServer()
  server.listen(Port(0))
  let ended = newFuture[SseEnd]("serveOnce.ended")
  proc handler(req: Request) {.async, gcsafe.} =
    let gone = watchDisconnect(req.client)
    ended.complete(await serveStream(req, stream, afterSeq, newHttpHeaders(),
                                     gone, keepAliveMs))
  asyncCheck server.acceptRequest(handler)
  (port: server.getPort.int, ended: ended)

proc connectTo(port: int): AsyncSocket =
  ## A raw HTTP/1.1 client that has asked for the stream and sent no
  ## `Connection: close`.
  # Unbuffered: a buffered socket's `recv(n)` waits for all n bytes.
  result = newAsyncSocket(buffered = false)
  waitFor result.connect("127.0.0.1", Port(port))
  waitFor result.send("GET / HTTP/1.1\c\LHost: localhost\c\L\c\L")

proc receivedWithin(sock: AsyncSocket, marker: string, timeoutMs = 2000): bool =
  ## Whether `marker` arrives within `timeoutMs`.
  var seen = ""
  let deadline = epochTime() + timeoutMs.float / 1000
  while marker notin seen:
    let left = int((deadline - epochTime()) * 1000)
    if left <= 0:
      return false
    let chunk = sock.recv(1024)
    if not waitFor withTimeout(chunk, left):
      return false
    if chunk.read.len == 0:
      return false
    seen.add chunk.read
  true

proc endsWithin(sock: AsyncSocket, timeoutMs = 2000): bool =
  ## Whether the server closes the connection within `timeoutMs`.
  let deadline = epochTime() + timeoutMs.float / 1000
  while true:
    let left = int((deadline - epochTime()) * 1000)
    if left <= 0:
      return false
    let chunk = sock.recv(1024)
    if not waitFor withTimeout(chunk, left):
      return false
    if chunk.read.len == 0:
      return true

suite "the buffer behind an event stream (mutation review, g2f-hs-c)":

  test "Given a finished stream, when an event is pushed, then it is refused and not kept":
    let stream = newSseStream("s")
    check stream.push("one")
    stream.finish()
    check not stream.push("two")
    check stream.lastSeq == 1

  test "Given text that is not the id of an event, when it is parsed, then there is no id":
    # A stream id is never empty, so an id that starts with the dash names no stream.
    check parseEventId("-5").isNone
    check parseEventId("s-").isNone
    check parseEventId("s5").isNone
    check parseEventId("s-x").isNone
    check parseEventId("s-5").get == (streamId: "s", seqNo: 5)

  test "Given a stream that has sent nothing, when asked whether it can resume, then only the start is possible":
    let stream = newSseStream("s")
    check stream.canResumeAfter(0)
    check not stream.canResumeAfter(1)


suite "the loop that writes an event stream (mutation review, g2f-hs-c)":

  test "Given a stream with nothing to say, when a keep-alive period passes, then a comment goes out and the stream is still open":
    let stream = newSseStream("s")
    let served = serveOnce(stream, keepAliveMs = 50)
    let sock = connectTo(served.port)
    check sock.receivedWithin(": keep-alive\n\n")
    check not served.ended.finished
    sock.close()

  test "Given a stream with nothing to say, when two keep-alive periods pass, then a comment goes out in each":
    let stream = newSseStream("s")
    let served = serveOnce(stream, keepAliveMs = 50)
    let sock = connectTo(served.port)
    check sock.receivedWithin(": keep-alive\n\n: keep-alive\n\n")
    check not served.ended.finished
    sock.close()

  test "Given a stream that finishes, when its events are written, then the server closes the connection of a client that asked to keep it":
    let stream = newSseStream("s")
    check stream.push("hello")
    stream.finish()
    let served = serveOnce(stream)
    let sock = connectTo(served.port)
    check sock.endsWithin()
    check (waitFor served.ended) == seDrained
    sock.close()

  test "Given a client that sent a stray byte, when it then closes the connection, then the server notices":
    let stream = newSseStream("s")
    let served = serveOnce(stream)
    let sock = connectTo(served.port)
    check sock.receivedWithin("\c\L\c\L")  # the head
    waitFor sock.send("x")
    waitFor sleepAsync(50)
    sock.close()
    check waitFor withTimeout(served.ended, 1000)
    check served.ended.read == seClientGone

  test "Given events that no connection has written, when one resumes after the last of them, then the stream still reports nothing written":
    let stream = newSseStream("s")
    check stream.push("one")
    check stream.push("two")
    let served = serveOnce(stream, afterSeq = 2)
    let sock = connectTo(served.port)
    waitFor sleepAsync(100)
    check stream.writtenUpTo == 0
    stream.finish()
    check waitFor withTimeout(served.ended, 1000)
    sock.close()

when SpeaksModern:
  proc postKeepingConnection(url: string, id: int, name: string): AsyncSocket =
    ## A raw HTTP/1.1 client that has posted a request and asked to keep the
    ## connection.
    let body = $(%*{"jsonrpc": "2.0", "id": id, "method": name, "params": {"_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "0"},
      "io.modelcontextprotocol/clientCapabilities": {}}}})
    result = newAsyncSocket(buffered = false)
    waitFor result.connect("127.0.0.1", Port(parseInt(parseUri(url).port)))
    waitFor result.send("POST /mcp HTTP/1.1\c\LHost: localhost\c\LConnection: keep-alive\c\L" &
      "Content-Type: application/json\c\LAccept: application/json, text/event-stream\c\L" &
      "MCP-Protocol-Version: 2026-07-28\c\LMcp-Method: " & name & "\c\L" &
      "Content-Length: " & $body.len & "\c\L\c\L" & body)

