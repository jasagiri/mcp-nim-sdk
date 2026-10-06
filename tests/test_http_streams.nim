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

proc post(url: string, body: JsonNode, headers: openArray[(string, string)] = []):
    tuple[code: HttpCode, headers: HttpHeaders, body: string] =
  let http = newAsyncHttpClient()
  defer: http.close()
  let allHeaders = newHttpHeaders({"Content-Type": "application/json",
                                   "Accept": "application/json, text/event-stream"})
  for (name, value) in headers:
    allHeaders[name] = value
  let response = waitFor http.request(url, HttpPost, $body, allHeaders)
  (response.code, response.headers, waitFor response.body)

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
