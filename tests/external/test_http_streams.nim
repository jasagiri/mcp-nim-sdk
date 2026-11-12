## What a Streamable HTTP endpoint sends besides a single JSON answer: SSE
## responses that carry what the server says while it works, the GET stream,
## resumption, JSON-RPC batches, the protocol version header and session
## expiry. The transport is driven directly, without McpServer, so that each
## test states exactly what the server side does.
##
## Versions are named in the tests that need a particular one; a test runs
## only when the build speaks that version.

import std/[unittest, asyncdispatch, asyncnet, uri, httpclient, json, options, strutils,
            algorithm, sequtils]
import transport/transport
import transport/http_server
import sse_reader
import transport/event_stream
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

const UseDefaultMaxStreamEvents = -1
  ## Leaves the transport's own limit as it is.

proc startRaw(version: McpProtocolVersion,
              maxStreamEvents = UseDefaultMaxStreamEvents): tuple[
    transport: HttpServerTransport, url: string, script: Script] =
  let transport = newHttpServerTransport(port = 0, protocolVersion = version)
  if maxStreamEvents != UseDefaultMaxStreamEvents:
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
  if version >= mpv20250326:

    test "Given a request during which the server sent notifications, when posted, then the answer is an event stream with the notifications first and the response last":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "work"), legacyHeaders(session, version))
      check stream.code == Http200
      check stream.contentType.startsWith("text/event-stream")
      let got = stream.messages()
      check got.len == 3
      check got[0].methodOf == "notifications/progress"
      check got[1]["params"]["progress"].getInt() == 2
      check got[2]["id"].getInt() == 7
      check got[2]["result"]["done"].getBool()
      stream.close()

    test "Given a response that is ready while the last notification is being written, when posted, then the stream ends with the response without waiting for a keep-alive":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "paced"), legacyHeaders(session, version))
      let got = stream.messages()
      check got.len == 4
      check got[3]["id"].getInt() == 7
      stream.close()

    test "Given a request during which the server sent nothing, when posted, then the answer is a plain JSON body":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let reply = post(url, rpc(3, "ping"), legacyHeaders(session, version))
      check reply.code == Http200
      check ($reply.headers["Content-Type"]).startsWith("application/json")

    test "Given an event stream, when its head is read, then it carries the security headers and no caching":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "work"), legacyHeaders(session, version))
      check $stream.response.headers["X-Content-Type-Options"] == "nosniff"
      check $stream.response.headers["Content-Security-Policy"] == "default-src 'self'"
      check $stream.response.headers["Cache-Control"] == "no-cache"
      discard stream.messages()
      stream.close()

    test "Given a notification the server sends for a request that is not in progress, when sent, then McpTransportError is raised":
      let (transport, _, _) = startRaw(version)
      expect McpTransportError:
        waitFor transport.sendNotification(progress(1),
          MessageRoute(session: "s", requestId: "http-999"))

    test "Given two requests at once on one session, when each sends notifications, then each stream carries only its own":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let first = open(url, HttpPost, $rpc(1, "work"), legacyHeaders(session, version))
      let second = open(url, HttpPost, $rpc(2, "work"), legacyHeaders(session, version))
      for (stream, id) in [(first, 1), (second, 2)]:
        let got = stream.messages()
        check got.len == 3
        check got[2]["id"].getInt() == id
        stream.close()

suite "event ids and resumption (versions 2025-03-26 to 2025-11-25)":
  let version = min(DefaultProtocolVersion, mpv20251125)
  if version >= mpv20250326:

    test "Given an event stream, when its events are read, then every event has an id and the ids differ":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "work"), legacyHeaders(session, version))
      var ids: seq[string] = @[]
      while true:
        let event = stream.next()
        if event.isNone:
          break
        ids.add event.get.id
      check ids.len >= 3
      check "" notin ids
      check ids.len == ids.deduplicate().len
      stream.close()

    test "Given a stream cut after its first event, when the client asks for the events after that one, then it gets the rest and not the first again":
      let (_, url, script) = startRaw(version)
      let session = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "wait"), legacyHeaders(session, version))
      var first = stream.next()
      while first.isSome and first.get.data.len == 0:
        first = stream.next()
      let lastId = first.get.id
      stream.close()
      script.release.complete()
      waitFor sleepAsync(50)
      let resumed = open(url, HttpGet, "",
        legacyHeaders(session, version) & @[("Last-Event-ID", lastId)])
      check resumed.code == Http200
      let got = resumed.messages()
      check got.len == 2
      check got[0]["params"]["progress"].getInt() == 2
      check got[1]["id"].getInt() == 7
      resumed.close()

    test "Given a request whose connection was cut, when the server finishes it, then it was not treated as cancelled":
      let (_, url, script) = startRaw(version)
      let session = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "wait"), legacyHeaders(session, version))
      discard stream.next()
      stream.close()
      waitFor sleepAsync(50)
      script.release.complete()
      waitFor sleepAsync(50)
      check script.cancelled.len == 0

    test "Given a Last-Event-ID of no stream the server knows, when asked to resume, then the answer is 400":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let resumed = open(url, HttpGet, "",
        legacyHeaders(session, version) & @[("Last-Event-ID", "nothing-1")])
      check resumed.code == Http400
      resumed.close()

    test "Given a Last-Event-ID that is not an event id at all, when asked to resume, then the answer is 400":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let resumed = open(url, HttpGet, "",
        legacyHeaders(session, version) & @[("Last-Event-ID", "garbage")])
      check resumed.code == Http400
      resumed.close()

    test "Given a stream of another session, when its event id is presented, then it is not replayed":
      let (_, url, _) = startRaw(version)
      let owner = initialize(url, version)
      let intruder = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "work"), legacyHeaders(owner, version))
      let first = stream.next().get
      discard stream.messages()
      stream.close()
      let resumed = open(url, HttpGet, "",
        legacyHeaders(intruder, version) & @[("Last-Event-ID", first.id)])
      check resumed.code == Http400
      resumed.close()

    test "Given a stream that remembers one event, when more were sent after the client left, then resuming from an event it forgot is refused":
      let (_, url, script) = startRaw(version, maxStreamEvents = 1)
      let session = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "wait"), legacyHeaders(session, version))
      let seen = stream.next().get
      stream.close()
      waitFor sleepAsync(50)
      script.release.complete()
      waitFor sleepAsync(50)
      let resumed = open(url, HttpGet, "",
        legacyHeaders(session, version) & @[("Last-Event-ID", seen.id)])
      check resumed.code == Http400
      resumed.close()

  if version >= mpv20251125:
    test "Given a version that primes streams, when a stream opens, then its first event has an id and no data":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "work"), legacyHeaders(session, version))
      let first = stream.next().get
      check first.id.len > 0
      check first.data == ""
      discard stream.messages()
      stream.close()

  if version >= mpv20250326 and version < mpv20251125:
    test "Given a version that does not prime streams, when a stream opens, then its first event is a message":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "work"), legacyHeaders(session, version))
      check stream.next().get.data.len > 0
      discard stream.messages()
      stream.close()

suite "GET stream (versions 2025-03-26 to 2025-11-25)":
  let version = min(DefaultProtocolVersion, mpv20251125)
  if version >= mpv20250326:

    test "Given a session, when the client opens GET, then the server's own notifications arrive on it":
      let (transport, url, _) = startRaw(version)
      let session = initialize(url, version)
      let listen = open(url, HttpGet, "", legacyHeaders(session, version))
      check listen.code == Http200
      check listen.contentType.startsWith("text/event-stream")
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/tools/list_changed", newJObject()),
        MessageRoute(session: session))
      var event = listen.next().get
      while event.data.len == 0:
        event = listen.next().get
      check parseJson(event.data).methodOf == "notifications/tools/list_changed"
      listen.close()

    test "Given a notification sent to every client, when two sessions listen, then each hears it once":
      let (transport, url, _) = startRaw(version)
      let a = initialize(url, version)
      let b = initialize(url, version)
      let listenA = open(url, HttpGet, "", legacyHeaders(a, version))
      let listenB = open(url, HttpGet, "", legacyHeaders(b, version))
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/prompts/list_changed", newJObject()))
      for listen in [listenA, listenB]:
        var event = listen.next().get
        while event.data.len == 0:
          event = listen.next().get
        check parseJson(event.data).methodOf == "notifications/prompts/list_changed"
        listen.close()

    test "Given a notification sent before the client opened GET, when it opens, then the notification is waiting":
      let (transport, url, _) = startRaw(version)
      let session = initialize(url, version)
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/resources/list_changed", newJObject()),
        MessageRoute(session: session))
      let listen = open(url, HttpGet, "", legacyHeaders(session, version))
      var event = listen.next().get
      while event.data.len == 0:
        event = listen.next().get
      check parseJson(event.data).methodOf == "notifications/resources/list_changed"
      listen.close()

    test "Given a request the server sends on the GET stream, when the client answers by POST, then the server receives the answer":
      let (transport, url, script) = startRaw(version)
      let session = initialize(url, version)
      let listen = open(url, HttpGet, "", legacyHeaders(session, version))
      waitFor transport.sendRequest(
        newJsonRpcRequest("srv-1", "roots/list", newJObject()),
        MessageRoute(session: session))
      var event = listen.next().get
      while event.data.len == 0:
        event = listen.next().get
      let asked = parseJson(event.data)
      check asked["id"].getStr() == "srv-1"
      let reply = post(url, %*{"jsonrpc": "2.0", "id": asked["id"], "result": {"roots": []}},
                       legacyHeaders(session, version))
      check reply.code == Http202
      waitFor sleepAsync(20)
      check script.answered[^1]["id"].getStr() == "srv-1"
      listen.close()

    test "Given a second GET on a session, when the first is still open, then the second takes the stream over":
      let (transport, url, _) = startRaw(version)
      let session = initialize(url, version)
      let first = open(url, HttpGet, "", legacyHeaders(session, version))
      let second = open(url, HttpGet, "", legacyHeaders(session, version))
      check second.code == Http200
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/tools/list_changed", newJObject()),
        MessageRoute(session: session))
      var event = second.next().get
      while event.data.len == 0:
        event = second.next().get
      check parseJson(event.data).methodOf == "notifications/tools/list_changed"
      var firstEnded = false
      while true:
        if first.next().isNone:
          firstEnded = true
          break
      check firstEnded
      first.close()
      second.close()

    test "Given a second GET that took the stream over, when a notification is sent, then the first connection ends without carrying it":
      let (transport, url, _) = startRaw(version)
      let session = initialize(url, version)
      let first = open(url, HttpGet, "", legacyHeaders(session, version))
      let second = open(url, HttpGet, "", legacyHeaders(session, version))
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/tools/list_changed", newJObject()),
        MessageRoute(session: session))
      var event = second.next().get
      while event.data.len == 0:
        event = second.next().get
      check parseJson(event.data).methodOf == "notifications/tools/list_changed"
      var carriedByFirst: seq[string] = @[]
      while true:
        let left = first.next()
        if left.isNone:
          break
        if left.get.data.len > 0:
          carriedByFirst.add left.get.data
      check carriedByFirst.len == 0
      first.close()
      second.close()

    test "Given a GET without a session id, when sent, then the answer is 400":
      let (_, url, _) = startRaw(version)
      discard initialize(url, version)
      let listen = open(url, HttpGet, "", [])
      check listen.code == Http400
      listen.close()

    test "Given a GET naming an unknown session, when sent, then the answer is 404":
      let (_, url, _) = startRaw(version)
      let listen = open(url, HttpGet, "", [("Mcp-Session-Id", "made-up")])
      check listen.code == Http404
      listen.close()

    test "Given a GET that does not accept an event stream, when sent, then the answer is 406":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let http = newAsyncHttpClient()
      let response = waitFor http.request(url, HttpGet, "", newHttpHeaders({
        "Accept": "application/json", "Mcp-Session-Id": session}))
      check response.code == Http406
      http.close()

    test "Given a GET from a foreign Origin, when sent, then the answer is 403":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let listen = open(url, HttpGet, "",
        legacyHeaders(session, version) & @[("Origin", "https://evil.example")])
      check listen.code == Http403
      listen.close()

    test "Given a GET open on a session, when the client sends DELETE, then the stream ends":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let listen = open(url, HttpGet, "", legacyHeaders(session, version))
      let http = newAsyncHttpClient()
      check (waitFor http.request(url, HttpDelete, "",
        newHttpHeaders({"Mcp-Session-Id": session}))).code == Http200
      http.close()
      var ended = false
      while true:
        if listen.next().isNone:
          ended = true
          break
      check ended
      listen.close()

if SpeaksModern:
  suite "SSE response and cancellation (2026-07-28)":

    proc modernPost(url: string, id: int, name: string): Events =
      open(url, HttpPost, $(%*{"jsonrpc": "2.0", "id": id, "method": name,
        "params": {"_meta": {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "0"},
          "io.modelcontextprotocol/clientCapabilities": {}}}}),
        [("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", name)])

    test "Given a request during which the server sent notifications, when posted, then the stream carries them and ends with the response":
      let (_, url, _) = startRaw(DefaultProtocolVersion)
      let stream = modernPost(url, 7, "work")
      check stream.contentType.startsWith("text/event-stream")
      let got = stream.messages()
      check got.len == 3
      check got[0].methodOf == "notifications/progress"
      check got[2]["id"].getInt() == 7
      stream.close()

    test "Given a response that is ready while the last notification is being written, when posted, then the stream ends with the response without waiting for a keep-alive (2026-07-28)":
      let (_, url, _) = startRaw(DefaultProtocolVersion)
      let stream = modernPost(url, 7, "paced")
      let got = stream.messages()
      check got.len == 4
      check got[3]["id"].getInt() == 7
      stream.close()

    test "Given a request of 2026-07-28, when the server tries to send a request of its own on its stream, then McpTransportError is raised":
      let (transport, url, script) = startRaw(DefaultProtocolVersion)
      let stream = modernPost(url, 7, "wait")
      discard stream.next()
      expect McpTransportError:
        waitFor transport.sendRequest(newJsonRpcRequest("srv-1", "roots/list", newJObject()),
          MessageRoute(requestId: "http-1"))
      script.release.complete()
      stream.close()

    test "Given an event stream, when its head is read, then proxies are told not to buffer it":
      let (_, url, _) = startRaw(DefaultProtocolVersion)
      let stream = modernPost(url, 7, "work")
      check $stream.response.headers["X-Accel-Buffering"] == "no"
      discard stream.messages()
      stream.close()

    test "Given a stream of 2026-07-28, when its events are read, then it has no priming event":
      let (_, url, _) = startRaw(DefaultProtocolVersion)
      let stream = modernPost(url, 7, "work")
      check stream.next().get.data.len > 0
      discard stream.messages()
      stream.close()

    test "Given a request in progress, when the client closes the connection, then the server is told the request was cancelled":
      let (_, url, script) = startRaw(DefaultProtocolVersion)
      let stream = modernPost(url, 7, "wait")
      discard stream.next()
      stream.close()
      waitFor sleepAsync(100)
      check script.cancelled.len == 1
      check script.cancelled[0].startsWith("http-")

    test "Given a request in progress with nothing sent yet, when the client closes the connection, then the server is told the request was cancelled":
      let (_, url, script) = startRaw(DefaultProtocolVersion)
      let body = $(%*{"jsonrpc": "2.0", "id": 8, "method": "silent", "params": {"_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "0"},
        "io.modelcontextprotocol/clientCapabilities": {}}}})
      let socket = waitFor asyncnet.dial("127.0.0.1", Port(parseInt(parseUri(url).port)))
      waitFor socket.send("POST /mcp HTTP/1.1\c\LHost: localhost\c\L" &
        "Content-Type: application/json\c\LMCP-Protocol-Version: 2026-07-28\c\L" &
        "Mcp-Method: silent\c\LContent-Length: " & $body.len & "\c\L\c\L" & body)
      waitFor sleepAsync(50)
      socket.close()
      waitFor sleepAsync(100)
      check script.cancelled.len == 1

    test "Given a cancelled request, when the server answers it anyway, then the answer is dropped without an error":
      let (transport, url, script) = startRaw(DefaultProtocolVersion)
      let stream = modernPost(url, 7, "wait")
      discard stream.next()
      stream.close()
      waitFor sleepAsync(100)
      script.release.complete()
      waitFor sleepAsync(50)
      check script.cancelled.len == 1
      check transport.pendingExchangeCount == 0

    test "Given a 2026-07-28 endpoint, when GET is sent, then no stream opens and the answer is 400 or 405":
      let (_, url, _) = startRaw(DefaultProtocolVersion)
      let listen = open(url, HttpGet, "", [])
      check listen.code in [Http400, Http405]
      listen.close()

suite "JSON-RPC batches (version 2025-03-26 only)":

  if mpv20250326 <= DefaultProtocolVersion:
    test "Given a batch of two requests, when posted, then the answer is an array with a response for each":
      let (_, url, _) = startRaw(mpv20250326)
      let session = initialize(url, mpv20250326)
      let reply = post(url, %*[rpc(10, "ping"), rpc(11, "ping")], [("Mcp-Session-Id", session)])
      check reply.code == Http200
      let body = parseJson(reply.body)
      check body.kind == JArray
      check body.len == 2
      check @[body[0]["id"].getInt(), body[1]["id"].getInt()].sorted == @[10, 11]

    test "Given a batch of requests and notifications, when posted, then only the requests are answered":
      let (_, url, _) = startRaw(mpv20250326)
      let session = initialize(url, mpv20250326)
      let reply = post(url, %*[rpc(10, "ping"),
        {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {}}],
        [("Mcp-Session-Id", session)])
      let body = parseJson(reply.body)
      check body.kind == JArray
      check body.len == 1

    test "Given a batch of notifications only, when posted, then the answer is 202 with no body":
      let (_, url, script) = startRaw(mpv20250326)
      let session = initialize(url, mpv20250326)
      let reply = post(url, %*[
        {"jsonrpc": "2.0", "method": "notifications/a", "params": {}},
        {"jsonrpc": "2.0", "method": "notifications/b", "params": {}}],
        [("Mcp-Session-Id", session)])
      check reply.code == Http202
      check reply.body == ""
      waitFor sleepAsync(20)
      check script.notifications == @["notifications/a", "notifications/b"]

    test "Given a batch of responses, when posted, then the answer is 202":
      let (_, url, _) = startRaw(mpv20250326)
      let session = initialize(url, mpv20250326)
      let reply = post(url, %*[{"jsonrpc": "2.0", "id": "x", "result": {}}],
                       [("Mcp-Session-Id", session)])
      check reply.code == Http202

    test "Given a batch whose requests make the server send notifications, when posted, then the answer is a stream with one response per request":
      let (_, url, _) = startRaw(mpv20250326)
      let session = initialize(url, mpv20250326)
      let stream = open(url, HttpPost, $(%*[rpc(10, "work"), rpc(11, "ping")]),
                        [("Mcp-Session-Id", session)])
      check stream.contentType.startsWith("text/event-stream")
      var responses: seq[int] = @[]
      for message in stream.messages():
        if message.hasKey("result"):
          responses.add message["id"].getInt()
      check responses.sorted == @[10, 11]
      stream.close()

    test "Given a batch holding initialize, when posted, then the answer is 400":
      let (_, url, _) = startRaw(mpv20250326)
      let reply = post(url, %*[{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "p", "version": "0"}}}])
      check reply.code == Http400

    test "Given an empty batch, when posted, then the answer is 400":
      let (_, url, _) = startRaw(mpv20250326)
      let session = initialize(url, mpv20250326)
      check post(url, %*[], [("Mcp-Session-Id", session)]).code == Http400

    test "Given a batch holding something that is not an object, when posted, then the answer is 400":
      let (_, url, _) = startRaw(mpv20250326)
      let session = initialize(url, mpv20250326)
      check post(url, %*[1, 2], [("Mcp-Session-Id", session)]).code == Http400

  if mpv20250618 <= DefaultProtocolVersion:
    test "Given a session of 2025-06-18, when a batch is posted, then the answer is 400":
      let (_, url, _) = startRaw(mpv20250618)
      let session = initialize(url, mpv20250618)
      let reply = post(url, %*[rpc(10, "ping")],
                       [("Mcp-Session-Id", session), ("MCP-Protocol-Version", "2025-06-18")])
      check reply.code == Http400
      check parseJson(reply.body)["error"]["code"].getInt() == -32600

suite "MCP-Protocol-Version header (versions 2025-06-18 to 2025-11-25)":
  let version = min(DefaultProtocolVersion, mpv20251125)
  if version >= mpv20250618:

    test "Given a header naming the negotiated version, when a request is posted, then it is served":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      check post(url, rpc(2, "ping"),
        [("Mcp-Session-Id", session), ("MCP-Protocol-Version", $version)]).code == Http200

    test "Given a header naming a version nobody released, when a request is posted, then the answer is 400":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let reply = post(url, rpc(2, "ping"),
        [("Mcp-Session-Id", session), ("MCP-Protocol-Version", "1900-01-01")])
      check reply.code == Http400

    test "Given a header that is not a version, when a request is posted, then the answer is 400":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      check post(url, rpc(2, "ping"),
        [("Mcp-Session-Id", session), ("MCP-Protocol-Version", "latest")]).code == Http400

    if not SpeaksModern:
      test "Given a header naming a released version newer than the endpoint serves, when a request is posted, then the answer is 400":
        let (_, url, _) = startRaw(version)
        let session = initialize(url, version)
        check post(url, rpc(2, "ping"),
          [("Mcp-Session-Id", session), ("MCP-Protocol-Version", "2026-07-28")]).code == Http400

    test "Given no header, when a request is posted, then it is served as the earlier version":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      check post(url, rpc(2, "ping"), [("Mcp-Session-Id", session)]).code == Http200

    test "Given a header on a notification, when it names an unsupported version, then the answer is 400":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      check post(url, %*{"jsonrpc": "2.0", "method": "notifications/initialized"},
        [("Mcp-Session-Id", session), ("MCP-Protocol-Version", "1900-01-01")]).code == Http400

suite "idle sessions":
  let version = min(DefaultProtocolVersion, mpv20251125)
  if version >= mpv20250326:

    test "Given a session unused for longer than the limit, when idle sessions are expired, then it is gone and the server is told":
      let (transport, url, script) = startRaw(version)
      transport.sessionIdleTimeoutMs = 30
      let session = initialize(url, version)
      waitFor sleepAsync(80)
      transport.expireIdleSessions()
      check transport.sessionCount == 0
      check script.ended == @[session]
      check post(url, rpc(2, "ping"), legacyHeaders(session, version)).code == Http404

    test "Given a session in use, when idle sessions are expired, then it stays":
      let (transport, url, _) = startRaw(version)
      transport.sessionIdleTimeoutMs = 200
      let session = initialize(url, version)
      waitFor sleepAsync(120)
      check post(url, rpc(2, "ping"), legacyHeaders(session, version)).code == Http200
      waitFor sleepAsync(120)
      transport.expireIdleSessions()
      check transport.sessionCount == 1

    test "Given a session with a GET stream open, when it has sent nothing for longer than the limit, then it stays":
      let (transport, url, _) = startRaw(version)
      transport.sessionIdleTimeoutMs = 30
      let session = initialize(url, version)
      let listen = open(url, HttpGet, "", legacyHeaders(session, version))
      waitFor sleepAsync(80)
      transport.expireIdleSessions()
      check transport.sessionCount == 1
      listen.close()

    test "Given the session limit is reached by idle sessions, when another client initializes, then an idle one is dropped to make room":
      let (transport, url, _) = startRaw(version)
      transport.maxSessions = 1
      transport.sessionIdleTimeoutMs = 30
      discard initialize(url, version)
      waitFor sleepAsync(80)
      discard initialize(url, version)
      check transport.sessionCount == 1

    test "Given the transport is serving, when a session stays idle, then it expires without anyone asking":
      let (transport, url, _) = startRaw(version)
      transport.sessionIdleTimeoutMs = 40
      discard initialize(url, version)
      var waited = 0
      while transport.sessionCount > 0 and waited < 3000:
        waitFor sleepAsync(20)
        waited += 20
      check transport.sessionCount == 0

    test "Given a session that expires, when a GET stream is open on it, then the stream ends":
      let (transport, url, _) = startRaw(version)
      let session = initialize(url, version)
      let listen = open(url, HttpGet, "", legacyHeaders(session, version))
      transport.endSession(session)
      var ended = false
      while true:
        if listen.next().isNone:
          ended = true
          break
      check ended
      listen.close()

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

  test "Given a transport that was never started, when it is asked, then it is not accepting; listening starts it and close stops it and frees the port":
    let transport = newHttpServerTransport(port = 0, protocolVersion = version)
    check not transport.started
    transport.listen()
    check transport.started
    let port = transport.port
    waitFor transport.close()
    check not transport.started
    expect OSError:
      let socket = waitFor asyncnet.dial("127.0.0.1", Port(port))
      socket.close()

  test "Given a posted request, when the server takes it with receiveMessage, then it gets the message":
    let transport = newHttpServerTransport(port = 0, protocolVersion = version)
    transport.listen()
    asyncCheck transport.serve()
    let http = newAsyncHttpClient()
    let all = newHttpHeaders({"Content-Type": "application/json",
                              "Accept": "application/json, text/event-stream"})
    discard http.request("http://127.0.0.1:" & $transport.port & "/mcp", HttpPost,
                         $bareInitializeBody(version), all)
    # A transport that drops the request must fail a check, not hang the test.
    let taking = transport.receiveMessage()
    let taken = waitFor withTimeout(taking, 2000)
    check taken
    if taken:
      let message = taking.read()
      check message{"method"}.getStr() == "initialize"
      check message{"id"}.getStr().startsWith("http-")
    http.close()
    waitFor transport.close()

  if version >= mpv20250326:

    test "Given an initialized session, when a notification is posted on it, then the empty answer carries no Content-Type":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let reply = post(url, %*{"jsonrpc": "2.0", "method": "notifications/initialized"},
                       legacyHeaders(session, version))
      check reply.code == Http202
      check not reply.headers.hasKey("Content-Type")

    test "Given a response stream still open, when its session ends, then the stream ends":
      let (transport, url, _) = startRaw(version)
      let session = initialize(url, version)
      let stream = open(url, HttpPost, $rpc(7, "wait"), legacyHeaders(session, version))
      discard stream.next()
      transport.endSession(session)
      while stream.next().isSome:
        discard
      stream.close()

    test "Given a session timeout of 0, when idle sessions are expired long after the last request, then the session stays":
      let (transport, url, _) = startRaw(version)
      transport.sessionIdleTimeoutMs = 0
      discard initialize(url, version)
      waitFor sleepAsync(40)
      transport.expireIdleSessions()
      check transport.sessionCount == 1

    test "Given the session limit is reached by sessions that were used and then went idle, when another client initializes, then an idle one is dropped to make room":
      let (transport, url, _) = startRaw(version)
      transport.maxSessions = 1
      transport.sessionIdleTimeoutMs = 30
      let first = initialize(url, version)
      check post(url, rpc(2, "ping"), legacyHeaders(first, version)).code == Http200
      waitFor sleepAsync(80)
      discard initialize(url, version)
      check transport.sessionCount == 1
      check post(url, rpc(3, "ping"), legacyHeaders(first, version)).code == Http404

    test "Given no limit on sessions per address (0), when a client initializes, then it gets a session":
      let (transport, url, _) = startRaw(version)
      transport.maxSessionsPerPeer = 0
      discard initialize(url, version)
      check transport.sessionCount == 1

    test "Given a limit of two queued messages and nobody receiving, when two requests are posted, then both are taken and a third is refused":
      let transport = newHttpServerTransport(port = 0, protocolVersion = version)
      transport.listen()
      asyncCheck transport.serve()
      transport.maxQueuedMessages = 2
      let url = "http://127.0.0.1:" & $transport.port & "/mcp"
      let first = postWithoutWaiting(url, bareInitializeBody(version), [])
      let second = postWithoutWaiting(url, bareInitializeBody(version), [])
      check transport.pendingExchangeCount == 2
      check post(url, bareInitializeBody(version)).code == Http503
      first.close()
      second.close()
      waitFor transport.close()

    test "Given a session that keeps one finished stream, when a second request ends, then the first stream can no longer be resumed and the second can":
      let (transport, url, _) = startRaw(version)
      transport.maxStoredStreams = 1
      let session = initialize(url, version)
      let first = open(url, HttpPost, $rpc(7, "work"), legacyHeaders(session, version))
      let firstId = first.next().get.id
      discard first.messages()
      first.close()
      let second = open(url, HttpPost, $rpc(8, "work"), legacyHeaders(session, version))
      let secondId = second.next().get.id
      discard second.messages()
      second.close()
      let tooOld = open(url, HttpGet, "",
        legacyHeaders(session, version) & @[("Last-Event-ID", firstId)])
      check tooOld.code == Http400
      tooOld.close()
      let kept = open(url, HttpGet, "",
        legacyHeaders(session, version) & @[("Last-Event-ID", secondId)])
      check kept.code == Http200
      kept.close()

    test "Given a session that keeps two finished streams, when a second request ends, then both can be resumed":
      let (transport, url, _) = startRaw(version)
      transport.maxStoredStreams = 2
      let session = initialize(url, version)
      let first = open(url, HttpPost, $rpc(7, "work"), legacyHeaders(session, version))
      let firstId = first.next().get.id
      discard first.messages()
      first.close()
      let second = open(url, HttpPost, $rpc(8, "work"), legacyHeaders(session, version))
      discard second.messages()
      second.close()
      let resumed = open(url, HttpGet, "",
        legacyHeaders(session, version) & @[("Last-Event-ID", firstId)])
      check resumed.code == Http200
      resumed.close()

    test "Given two sessions that chose the same request ids, when one cancels its requests, then each notification names that session's own request":
      let (_, url, ledger) = startLedger(version)
      let a = initialize(url, version)
      let b = initialize(url, version)
      let held = @[
        postWithoutWaiting(url, rpc(5, "silent"), legacyHeaders(a, version)),
        postWithoutWaiting(url, rpc(5, "silent"), legacyHeaders(b, version)),
        postWithoutWaiting(url, rpc(6, "silent"), legacyHeaders(a, version))]
      let silent = ledger.seen.filterIt(it.message{"method"}.getStr() == "silent")
      check silent.len == 3
      # (session, the id the client chose, which of the three requests it is)
      for (session, chosen, which) in [(a, 6, 2), (a, 5, 0), (b, 5, 1)]:
        check post(url, cancelNotice(chosen), legacyHeaders(session, version)).code == Http202
        waitFor sleepAsync(30)
        let notice = ledger.seen[^1].message
        check notice{"method"}.getStr() == "notifications/cancelled"
        check notice{"params"}{"requestId"}.getStr() == silent[which].message["id"].getStr()
      for http in held:
        http.close()

    test "Given a notification whose params is an array, when the server sends it on a request's stream, then it arrives as it was sent":
      let (transport, url, ledger) = startLedger(version)
      let session = initialize(url, version)
      let pending = openAsync(url, HttpPost, $rpc(5, "silent"), legacyHeaders(session, version))
      waitFor sleepAsync(50)
      let silent = ledger.seen.filterIt(it.message{"method"}.getStr() == "silent")
      check silent.len == 1
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/progress", %*[1, 2]),
        MessageRoute(requestId: silent[0].message["id"].getStr()))
      let stream = waitFor pending
      var event = stream.next().get
      while event.data.len == 0:
        event = stream.next().get
      check parseJson(event.data)["params"] == %*[1, 2]
      stream.close()

  if DefaultProtocolVersion.isModern:

    test "Given a subscription stream, when the server sends a notification that names another subscription, then the id is left as it is, and one that names this stream's request is given the client's id":
      let (transport, url, ledger) = startLedger(DefaultProtocolVersion)
      let pending = openAsync(url, HttpPost, $modernBody(7, "silent"),
        @[("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", "silent")])
      waitFor sleepAsync(50)
      check ledger.seen.len == 1
      let exchangeId = ledger.seen[0].message["id"].getStr()
      let route = MessageRoute(requestId: exchangeId)
      waitFor transport.sendNotification(withSubscriptionId("other"), route)
      waitFor transport.sendNotification(withSubscriptionId(exchangeId), route)
      let stream = waitFor pending
      var named: seq[JsonNode] = @[]
      while named.len < 2:
        let event = stream.next().get
        if event.data.len > 0:
          named.add parseJson(event.data){"params"}{"_meta"}{MetaSubscriptionId}
      check named[0] == %"other"
      check named[1] == %7
      stream.close()

  block sessionWithoutNamedVersion:
    let ceiling = latestLegacyVersion(spokenVersionsUpTo(version))
    if ceiling.isSome and ceiling.get >= mpv20250618:
      test "Given an initialize answer that names no version, when the session is used, then it is held to the newest version the build speaks and a version header it does not speak is refused":
        let transport = newHttpServerTransport(port = 0, protocolVersion = version)
        transport.listen()
        asyncCheck transport.serve()
        proc answerAll() {.async.} =
          while true:
            let incoming = await transport.receive()
            if isRequest(incoming.message):
              await transport.sendResponse(newJsonRpcResponse(
                incoming.message["id"].getStr(), newJObject()))
        asyncCheck answerAll()
        let url = "http://127.0.0.1:" & $transport.port & "/mcp"
        let session = initialize(url, ceiling.get)
        check post(url, rpc(2, "ping"), @[("Mcp-Session-Id", session),
          ("MCP-Protocol-Version", "1999-01-01")]).code == Http400
        check post(url, rpc(3, "ping"), legacyHeaders(session, ceiling.get)).code == Http200

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

  if isSupported(mpv20241105) and mpv20250326 <= DefaultProtocolVersion:
    test "Given a session negotiated at 2024-11-05, when it opens GET, then the answer is 405 naming POST and DELETE":
      let (_, url, script) = startRaw(version)
      script.version = mpv20241105
      let session = initialize(url, mpv20241105)
      let opened = openWithin(url, HttpGet, @[("Mcp-Session-Id", session)])
      require opened.isSome
      check opened.get.code == Http405
      check $opened.get.response.headers["Allow"] == "POST, DELETE"
      opened.get.close()

  if version >= mpv20250618:
    test "Given a GET that names a version the server does not speak, when it arrives, then the answer is 400":
      let (_, url, _) = startRaw(version)
      let session = initialize(url, version)
      let opened = openWithin(url, HttpGet,
        @[("Mcp-Session-Id", session), ("MCP-Protocol-Version", "1900-01-01")])
      require opened.isSome
      check opened.get.code == Http400
      opened.get.close()

  if version >= mpv20250326:
    test "Given the GET stream of a session, when the client left after an event and asks for the rest by that event's id, then it gets the later events":
      let (transport, url, _) = startRaw(version)
      let session = initialize(url, version)
      let listen = open(url, HttpGet, "", legacyHeaders(session, version))
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/tools/list_changed", newJObject()),
        MessageRoute(session: session))
      var seen = listen.next().get
      while seen.data.len == 0:
        seen = listen.next().get
      listen.close()
      waitFor sleepAsync(50)
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/prompts/list_changed", newJObject()),
        MessageRoute(session: session))
      let resumed = open(url, HttpGet, "",
        legacyHeaders(session, version) & @[("Last-Event-ID", seen.id)])
      check resumed.code == Http200
      var event = resumed.next().get
      while event.data.len == 0:
        event = resumed.next().get
      check parseJson(event.data).methodOf == "notifications/prompts/list_changed"
      resumed.close()

    test "Given events no connection wrote, when a connection resumes after the last of them, then a later connection without Last-Event-ID still gets them":
      let (transport, url, _) = startRaw(version)
      let session = initialize(url, version)
      let first = open(url, HttpGet, "", legacyHeaders(session, version))
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/a", newJObject()),
        MessageRoute(session: session))
      var seen = first.next().get
      while seen.data.len == 0:
        seen = first.next().get
      first.close()
      waitFor sleepAsync(50)   # the server notices the departure
      for name in ["notifications/b", "notifications/c"]:
        waitFor transport.sendNotification(newJsonRpcNotification(name, newJObject()),
                                           MessageRoute(session: session))
      # `seen.id` is stream-number; the event after the unwritten two is the number two on.
      let dash = seen.id.rfind('-')
      let lastUnwritten = seen.id[0 ..< dash] & "-" & $(parseInt(seen.id[dash + 1 .. ^1]) + 2)
      let skipping = open(url, HttpGet, "",
        legacyHeaders(session, version) & @[("Last-Event-ID", lastUnwritten)])
      check skipping.code == Http200
      skipping.close()
      let later = open(url, HttpGet, "", legacyHeaders(session, version))
      check later.code == Http200
      var got: seq[string] = @[]
      while got.len < 2:
        let event = later.next().get
        if event.data.len > 0:
          got.add parseJson(event.data).methodOf
      check got == @["notifications/b", "notifications/c"]
      later.close()

    test "Given a GET stream that has sent events, when an event id of a stream the session never had is presented, then the answer is 400":
      let (transport, url, _) = startRaw(version)
      let session = initialize(url, version)
      let listen = open(url, HttpGet, "", legacyHeaders(session, version))
      for name in ["notifications/a", "notifications/b"]:
        waitFor transport.sendNotification(newJsonRpcNotification(name, newJObject()),
                                           MessageRoute(session: session))
      let resumed = openWithin(url, HttpGet,
        legacyHeaders(session, version) & @[("Last-Event-ID", "nothing-1")])
      require resumed.isSome
      check resumed.get.code == Http400
      resumed.get.close()
      listen.close()

    test "Given a session whose GET stream has ended, when it then stays unused, then it stays only for the limit counted from the end of the stream, and then expires":
      let (transport, url, _) = startRaw(version)
      transport.sessionIdleTimeoutMs = 300
      let session = initialize(url, version)
      let listen = open(url, HttpGet, "", legacyHeaders(session, version))
      waitFor sleepAsync(350)
      listen.close()
      waitFor sleepAsync(60)
      transport.expireIdleSessions()
      check transport.sessionCount == 1
      waitFor sleepAsync(350)
      transport.expireIdleSessions()
      check transport.sessionCount == 0

    test "Given a session that has served a request, when it then stays unused beyond the limit, then it expires":
      let (transport, url, _) = startRaw(version)
      transport.sessionIdleTimeoutMs = 100
      let session = initialize(url, version)
      check post(url, rpc(2, "ping"), legacyHeaders(session, version)).code == Http200
      waitFor sleepAsync(200)
      transport.expireIdleSessions()
      check transport.sessionCount == 0

  if mpv20250326 <= DefaultProtocolVersion:
    test "Given a batch of a request and a notification, when posted, then the server receives the notification":
      let (_, url, script) = startRaw(mpv20250326)
      let session = initialize(url, mpv20250326)
      let reply = post(url, %*[rpc(10, "ping"),
        {"jsonrpc": "2.0", "method": "notifications/a", "params": {}}],
        [("Mcp-Session-Id", session)])
      check reply.code == Http200
      waitFor sleepAsync(20)
      check script.notifications == @["notifications/a"]

import std/times

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


  test "Given a stream that remembers its last two of three events, when asked where it can resume, then from the last forgotten event on and no further":
    when mpv20250326 <= DefaultProtocolVersion:
      let version = min(DefaultProtocolVersion, mpv20251125)
      let (transport, url, _) = startRaw(version, maxStreamEvents = 2)
      let session = initialize(url, version)
      let listen = open(url, HttpGet, "", legacyHeaders(session, version))
      for name in ["notifications/a", "notifications/b", "notifications/c"]:
        waitFor transport.sendNotification(newJsonRpcNotification(name, newJObject()),
                                           MessageRoute(session: session))
      var seen = listen.next().get
      while seen.data.len == 0:
        seen = listen.next().get
      listen.close()
      waitFor sleepAsync(50)
      let streamId = seen.id.rsplit('-', 1)[0]
      proc resumeAfter(n: int): HttpCode =
        let resumed = open(url, HttpGet, "",
          legacyHeaders(session, version) & @[("Last-Event-ID", streamId & "-" & $n)])
        result = resumed.code
        resumed.close()
      check resumeAfter(0) == Http400
      check resumeAfter(1) == Http200   # the next one, 2, is the oldest remembered
      check resumeAfter(2) == Http200
      check resumeAfter(3) == Http200   # everything was seen; wait for the next
      check resumeAfter(4) == Http400
    else:
      skip()


proc openGetStream(port: int, session: string, version: McpProtocolVersion): AsyncSocket =
  ## A raw HTTP/1.1 client that has asked for the GET stream of `session`.
  result = newAsyncSocket(buffered = false)
  waitFor result.connect("127.0.0.1", Port(port))
  var request = "GET /mcp HTTP/1.1\c\LHost: localhost\c\LAccept: text/event-stream\c\L"
  for (name, value) in legacyHeaders(session, version):
    request.add name & ": " & value & "\c\L"
  waitFor result.send(request & "\c\L")

suite "the keep-alive of a GET stream":

  test "Given a keep-alive period set on the transport, when a GET stream is open and nothing is sent, then a keep-alive comment arrives in every period and the stream stays open":
    when mpv20250326 <= DefaultProtocolVersion:
      let version = min(DefaultProtocolVersion, mpv20251125)
      let (transport, url, _) = startRaw(version)
      transport.sseKeepAliveMs = 50
      let session = initialize(url, version)
      let sock = openGetStream(transport.port, session, version)
      check sock.receivedWithin(": keep-alive\n\n: keep-alive\n\n")
      sock.close()
    else:
      skip()

  test "Given a keep-alive period of 0 on the transport, when a GET stream is open and nothing is sent, then no keep-alive comment arrives":
    when mpv20250326 <= DefaultProtocolVersion:
      let version = min(DefaultProtocolVersion, mpv20251125)
      let (transport, url, _) = startRaw(version)
      transport.sseKeepAliveMs = 0
      let session = initialize(url, version)
      let sock = openGetStream(transport.port, session, version)
      check sock.receivedWithin("\c\L\c\L")  # the head
      check not sock.receivedWithin(": keep-alive", timeoutMs = 300)
      sock.close()
    else:
      skip()

  test "Given a client that reads nothing for longer than a keep-alive period, when it reads on, then a keep-alive comment follows the event that was blocked":
    when mpv20250326 <= DefaultProtocolVersion:
      let version = min(DefaultProtocolVersion, mpv20251125)
      let (transport, url, _) = startRaw(version)
      transport.sseKeepAliveMs = 50
      let session = initialize(url, version)
      # An event too large for the socket buffers: the server's write stays
      # blocked for as long as the client does not read.
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/message",
          %*{"pad": 'x'.repeat(16 * 1024 * 1024), "end": "END-OF-EVENT"}),
        MessageRoute(session: session))
      let sock = openGetStream(transport.port, session, version)
      waitFor sleepAsync(300)  # several periods, a lower bound only
      # First the event is read to its end (each read may stall for a while
      # on a loaded machine, the total is not bounded); only what follows
      # it is waited for against a deadline. Only a tail is searched, so that
      # the 16 MB are not scanned again for every chunk.
      var tail = ""
      var eventRead = false
      var deadline = 0.0
      while true:
        if eventRead:
          let at = tail.find("END-OF-EVENT")
          if tail.find(": keep-alive\n\n", at) >= 0:
            break
          doAssert epochTime() < deadline, "no keep-alive after the event"
        let chunk = sock.recv(65536)
        doAssert waitFor withTimeout(chunk, 5000), "the stream stalled"
        doAssert chunk.read.len > 0, "the stream ended"
        tail.add chunk.read
        if not eventRead:
          if tail.find("END-OF-EVENT") >= 0:
            eventRead = true
            deadline = epochTime() + 5
          elif tail.len > 64:
            tail = tail[tail.len - 64 .. ^1]
      check eventRead
      sock.close()
    else:
      skip()


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

  suite "the connection of an event stream, seen from the client":

    test "Given a client that asked to keep its connection, when the event stream of its request ends, then the server closes the connection":
      let (_, url, _) = startRaw(DefaultProtocolVersion)
      let sock = postKeepingConnection(url, 7, "work")
      check sock.receivedWithin("text/event-stream")
      check sock.endsWithin()
      sock.close()

    test "Given a client that sent a stray byte into its event stream, when it then closes the connection, then the server is told the request was cancelled":
      let (_, url, script) = startRaw(DefaultProtocolVersion)
      let sock = postKeepingConnection(url, 8, "wait")
      check sock.receivedWithin("\c\L\c\L")  # the head
      waitFor sock.send("x")
      waitFor sleepAsync(50)
      check script.cancelled.len == 0
      sock.close()
      waitFor sleepAsync(100)
      check script.cancelled.len == 1
