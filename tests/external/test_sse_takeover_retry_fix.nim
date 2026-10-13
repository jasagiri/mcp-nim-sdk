## 2025-11-25 (basic/transports): "If the server does close the connection
## prior to terminating the SSE stream, it SHOULD send an SSE event with a
## standard retry field before closing the connection." The only time the
## server closes the connection of a stream it keeps is when a newer
## connection takes the stream over. The server also records the takeover,
## without the session id: a second connection that names a session is a sign
## that the id has leaked.

import std/[unittest, asyncdispatch, httpclient, httpcore, json, options, os, strutils]
import mcp
import ./sse_reader

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-takeover-fix-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc startRaw(version: McpProtocolVersion, retryMs = -1): tuple[
    transport: HttpServerTransport, url: string, release: Future[void]] =
  let transport = newHttpServerTransport(port = 0, protocolVersion = version)
  if retryMs >= 0:
    transport.sseRetryMs = retryMs
  let release = newFuture[void]("release")
  transport.listen()
  asyncCheck transport.serve()
  proc script() {.async.} =
    while true:
      let incoming = await transport.receive()
      let message = incoming.message
      if not isRequest(message):
        continue
      let id = message["id"].getStr()
      let route = MessageRoute(session: incoming.session, requestId: id)
      case message["method"].getStr()
      of "initialize":
        await transport.sendResponse(newJsonRpcResponse(id, %*{
          "protocolVersion": $min(version, mpv20251125), "capabilities": {},
          "serverInfo": {"name": "script", "version": "0"}}))
      of "wait":
        await transport.sendNotification(newJsonRpcNotification("notifications/progress",
          %*{"progressToken": "t", "progress": 1}), route)
        await release
        await transport.sendResponse(newJsonRpcResponse(id, %*{"done": true}))
      else:
        await transport.sendResponse(newJsonRpcResponse(id, %*{}))
  asyncCheck script()
  (transport, "http://127.0.0.1:" & $transport.port & "/mcp", release)

proc headersFor(version: McpProtocolVersion, session: string): seq[(string, string)] =
  @[("Mcp-Session-Id", session), ("MCP-Protocol-Version", $min(version, mpv20251125))]

proc initializeSession(url: string, version: McpProtocolVersion): string =
  let http = newAsyncHttpClient()
  defer: http.close()
  let response = waitFor http.request(url, HttpPost, $(%*{"jsonrpc": "2.0", "id": 1,
    "method": "initialize", "params": {"protocolVersion": $min(version, mpv20251125),
    "capabilities": {}, "clientInfo": {"name": "peer", "version": "0"}}}),
    newHttpHeaders({"Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream"}))
  doAssert response.code == Http200
  $response.headers["Mcp-Session-Id"]

proc takenOverGet(version: McpProtocolVersion, retryMs = -1): tuple[body, log: string] =
  let (_, url, _) = startRaw(version, retryMs)
  let session = initializeSession(url, version)
  let first = open(url, HttpGet, "", headersFor(version, session))
  var second: Events
  var body = ""
  result.log = loggedWhile(proc() =
    second = open(url, HttpGet, "", headersFor(version, session))
    body = waitFor first.response.readAll(1_000_000))
  result.body = body
  first.close()
  second.close()

suite "a stream taken over by a second connection":

  test "Given a GET stream taken over by a second connection, when the server closes the first, then it sent a retry field before closing":
    if mpv20251125 > DefaultProtocolVersion:
      skip()
    else:
      let taken = takenOverGet(mpv20251125)
      checkpoint "what the first connection carried: " & taken.body.escape
      check "retry: 1000\n" in taken.body

  test "Given a stream of a request taken over by a GET with Last-Event-ID, when the server closes the first connection, then it sent a retry field before closing":
    if mpv20251125 > DefaultProtocolVersion:
      skip()
    else:
      let (_, url, release) = startRaw(mpv20251125)
      let session = initializeSession(url, mpv20251125)
      let first = open(url, HttpPost, $(%*{"jsonrpc": "2.0", "id": 7, "method": "wait",
                                           "params": {}}), headersFor(mpv20251125, session))
      var event = first.next()
      while event.isSome and event.get.data.len == 0:
        event = first.next()
      let lastId = event.get.id
      let second = open(url, HttpGet, "", headersFor(mpv20251125, session) &
                        @[("Last-Event-ID", lastId)])
      let body = waitFor first.response.readAll(1_000_000)
      checkpoint "what the first connection carried: " & body.escape
      check "retry: 1000\n" in body
      release.complete()
      first.close()
      second.close()

  test "Given sseRetryMs set to 250, when a stream is taken over, then the first connection is told 250":
    if mpv20251125 > DefaultProtocolVersion:
      skip()
    else:
      let taken = takenOverGet(mpv20251125, 250)
      check "retry: 250\n" in taken.body
      check "retry: 1000" notin taken.body

  test "Given sseRetryMs set to 0, when a stream is taken over, then no retry field is sent":
    if mpv20251125 > DefaultProtocolVersion:
      skip()
    else:
      let taken = takenOverGet(mpv20251125, 0)
      check "retry:" notin taken.body

  test "Given a session of 2025-03-26 or 2025-06-18, when a stream is taken over, then no retry field is sent because those versions do not define the polling":
    var ran = 0
    for version in [mpv20250326, mpv20250618]:
      if version > DefaultProtocolVersion:
        continue
      inc ran
      let taken = takenOverGet(version)
      check "retry:" notin taken.body
    if ran == 0:
      skip()

  test "Given a stream taken over, when the server closes the first connection, then it records the takeover on stderr without the session id":
    if mpv20251125 > DefaultProtocolVersion:
      skip()
    else:
      let (_, url, _) = startRaw(mpv20251125)
      let session = initializeSession(url, mpv20251125)
      let first = open(url, HttpGet, "", headersFor(mpv20251125, session))
      var second: Events
      var body = ""
      let log = loggedWhile(proc() =
        second = open(url, HttpGet, "", headersFor(mpv20251125, session))
        body = waitFor first.response.readAll(1_000_000))
      checkpoint "stderr: " & log.escape
      check "[mcp-http-server]" in log
      check "taken over" in log
      check "GET stream" in log
      check session notin log
      first.close()
      second.close()
