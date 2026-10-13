## The server side of Streamable HTTP as the transport pages of the
## specification describe it: where a local server listens, what its session
## ids look like, which stream carries a response, how long a stream of a
## request stays open, which notifications a request's stream carries, and how
## the server reads the names of the headers it is sent and the markers of a
## Base64 value.
##
## Versions are named in the tests that need a particular one; a test runs
## only when the build speaks that version.

import std/[unittest, asyncdispatch, asyncnet, httpclient, json, options, os, osproc,
            sequtils, strutils, uri]
import mcp
import ./sse_reader

const
  SpeaksModern = isModern(DefaultProtocolVersion)
  LegacyDefault = min(DefaultProtocolVersion, mpv20251125)
  HasGetStream = LegacyDefault >= mpv20250326

type
  Script = ref object
    ## What the fake server side is told to do.
    release: Future[void]
      ## `wait` requests answer once this completes

proc progress(n: int): JsonRpcNotification =
  newJsonRpcNotification("notifications/progress",
                         %*{"progressToken": "t", "progress": n})

proc serveOne(t: HttpServerTransport, s: Script, version: McpProtocolVersion,
              incoming: McpIncoming) {.async.} =
  let message = incoming.message
  if not isRequest(message):
    return
  let id = message["id"].getStr()
  let route = MessageRoute(session: incoming.session, requestId: id)
  case message["method"].getStr()
  of "initialize":
    await t.sendResponse(newJsonRpcResponse(id, %*{
      "protocolVersion": $version, "capabilities": {},
      "serverInfo": {"name": "script", "version": "0"}}))
  of "wait":
    await t.sendNotification(progress(1), route)
    await s.release
    await t.sendNotification(progress(2), route)
    await t.sendResponse(newJsonRpcResponse(id, %*{"done": true}))
  of "work":
    await t.sendNotification(progress(1), route)
    await t.sendNotification(progress(2), route)
    await t.sendResponse(newJsonRpcResponse(id, %*{"done": true}))
  else:
    await t.sendResponse(newJsonRpcResponse(id, %*{}))

proc runScript(t: HttpServerTransport, s: Script, version: McpProtocolVersion) {.async.} =
  ## `initialize` answers with `version`; `wait` sends one progress
  ## notification related to the request, waits for `release`, sends another
  ## and answers; `work` sends two and answers. Requests are served at once,
  ## not one after the other.
  while true:
    asyncCheck serveOne(t, s, version, await t.receive())

proc startRaw(version: McpProtocolVersion): tuple[
    transport: HttpServerTransport, url: string, script: Script] =
  let transport = newHttpServerTransport(port = 0, protocolVersion = version)
  let script = Script(release: newFuture[void]("release"))
  transport.listen()
  asyncCheck transport.serve()
  asyncCheck runScript(transport, script, min(version, mpv20251125))
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
  let requesting = http.request(url, HttpPost, $body, allHeaders)
  doAssert waitFor withTimeout(requesting, 10_000), "no response to POST within 10 s"
  let response = requesting.read()
  let reading = response.body
  doAssert waitFor withTimeout(reading, 10_000), "no end of the POST response body within 10 s"
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

proc messagesWithData(events: Events): seq[JsonNode] =
  events.messages()

suite "where a local server listens":

  test "Given a transport made with the defaults, when it is started, then its socket is bound to 127.0.0.1 and not to every interface":
    if findExe("lsof").len == 0:
      skip()
    else:
      let transport = newHttpServerTransport(port = 0)
      transport.listen()
      defer: waitFor transport.close()
      check transport.host == "127.0.0.1"
      let (listing, code) = execCmdEx("lsof -nP -a -p " & $getCurrentProcessId() &
                                      " -iTCP:" & $transport.port & " -sTCP:LISTEN -Fn")
      check code == 0
      let names = listing.splitLines.filterIt(it.startsWith("n"))
      check names.len >= 1
      for name in names:
        checkpoint "listening on " & name
        check name == "n127.0.0.1:" & $transport.port

suite "session ids":

  test "Given many clients that initialize, when the server issues their sessions, then every id is made of visible ASCII characters only":
    let (_, url, _) = startRaw(LegacyDefault)
    for _ in 1 .. 40:
      let session = initialize(url, LegacyDefault)
      check session.len > 0
      for c in session:
        check c in {'\x21' .. '\x7E'}

if HasGetStream:
  suite "which stream carries a response (versions 2025-03-26 to 2025-11-25)":

    test "Given a request in progress while a GET stream is open, when the server answers, then the response is on the stream of the request and the GET stream carries only what the server said on its own":
      let (transport, url, script) = startRaw(LegacyDefault)
      let session = initialize(url, LegacyDefault)
      let listen = open(url, HttpGet, "", legacyHeaders(session, LegacyDefault))
      let stream = open(url, HttpPost, $rpc(7, "wait"), legacyHeaders(session, LegacyDefault))
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/tools/list_changed", newJObject()),
        MessageRoute(session: session))
      script.release.complete()
      let answered = stream.messagesWithData()
      check answered.len == 3
      check answered[2]["id"].getInt() == 7
      transport.endSession(session)
      let heard = listen.messagesWithData()
      check heard.len == 1
      check heard[0].methodOf == "notifications/tools/list_changed"
      check heard.allIt(not it.hasKey("result") and not it.hasKey("error"))
      stream.close()
      listen.close()

    test "Given a request whose answer takes longer than the idle limit of sessions, when the server answers at last, then the stream stayed open and carries the response":
      let (transport, url, script) = startRaw(LegacyDefault)
      transport.sessionIdleTimeoutMs = 40
      let session = initialize(url, LegacyDefault)
      let stream = open(url, HttpPost, $rpc(7, "wait"), legacyHeaders(session, LegacyDefault))
      var first = stream.next()
      while first.isSome and first.get.data.len == 0:
        first = stream.next()
      check parseJson(first.get.data).methodOf == "notifications/progress"
      waitFor sleepAsync(700)
      check transport.sessionCount == 1
      script.release.complete()
      let rest = stream.messagesWithData()
      check rest.len == 2
      check rest[0].methodOf == "notifications/progress"
      check rest[1]["id"].getInt() == 7
      stream.close()

if SpeaksModern:
  suite "which notifications a request's stream carries (2026-07-28)":

    proc modernPost(url: string, id: int, name: string): Events =
      open(url, HttpPost, $(%*{"jsonrpc": "2.0", "id": id, "method": name,
        "params": {"_meta": {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "0"},
          "io.modelcontextprotocol/clientCapabilities": {}}}}),
        [("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", name)])

    test "Given two requests in progress, when the server sends a notification for one and another that belongs to no request, then each stream carries only the notifications of its own request":
      let (transport, url, script) = startRaw(DefaultProtocolVersion)
      let first = modernPost(url, 7, "wait")
      let second = modernPost(url, 8, "wait")
      discard first.next()
      discard second.next()
      waitFor transport.sendNotification(progress(50), MessageRoute(requestId: "http-2"))
      waitFor transport.sendNotification(progress(99))
      script.release.complete()
      let ofFirst = first.messagesWithData()
      let ofSecond = second.messagesWithData()
      check ofFirst.mapIt(it{"params", "progress"}.getInt()) == @[2, 0]
      check ofFirst[1]["id"].getInt() == 7
      check ofSecond.mapIt(it{"params", "progress"}.getInt()) == @[50, 2, 0]
      check ofSecond[2]["id"].getInt() == 8
      first.close()
      second.close()

  suite "the Base64 marker and the names of headers (2026-07-28)":

    proc weatherServer(version: McpProtocolVersion): McpServer =
      result = newMcpServer(McpServerInfo(name: "ExampleServer", version: "1.0.0"),
        protocolVersion = version,
        capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
      let listTools: typeof(McpToolHandlers().listHandler.get) =
        proc(): Future[seq[JsonNode]] {.async.} =
          return @[%*{"name": "get_weather", "inputSchema": {"type": "object"}}]
      let callTool: typeof(McpToolHandlers().callHandler.get) =
        proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
          return %*{"content": [{"type": "text", "text": name}], "isError": false}
      result.setToolHandlers(McpToolHandlers(
        listHandler: some(listTools), callHandler: some(callTool)))

    proc startServer(): string =
      let transport = newHttpServerTransport(port = 0)
      transport.listen()
      asyncCheck transport.serve()
      waitFor weatherServer(DefaultProtocolVersion).attachTransport(transport)
      "http://127.0.0.1:" & $transport.port & "/mcp"

    let toolCall = $(%*{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
      "params": {"_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "0"},
        "io.modelcontextprotocol/clientCapabilities": {}},
        "name": "get_weather", "arguments": {}}})

    proc rawPost(url: string, headerLines: string, body: string): tuple[code: int, body: string] =
      ## A POST whose header names are written exactly as given.
      let socket = waitFor asyncnet.dial("127.0.0.1", Port(parseInt(parseUri(url).port)))
      defer: socket.close()
      waitFor socket.send("POST /mcp HTTP/1.1\c\LHost: 127.0.0.1\c\L" & headerLines &
        "Content-Length: " & $body.len & "\c\LConnection: close\c\L\c\L" & body)
      var received = ""
      while true:
        let part = waitFor socket.recv(4096)
        if part.len == 0:
          break
        received.add part
      let blank = received.find("\c\L\c\L")
      (parseInt(received.split(' ')[1]), received[blank + 4 .. ^1])

    test "Given an Mcp-Name that decodes to the tool's name, when its markers are lowercase, then the request is served, and when they are in capitals, then it is not decoded and the answer is a header mismatch":
      let url = startServer()
      let common = "Content-Type: application/json\c\LMCP-Protocol-Version: 2026-07-28\c\L" &
                   "Mcp-Method: tools/call\c\L"
      check rawPost(url, common & "Mcp-Name: =?base64?Z2V0X3dlYXRoZXI=?=\c\L", toolCall).code == 200
      for marker in ["=?BASE64?Z2V0X3dlYXRoZXI=?=", "=?Base64?Z2V0X3dlYXRoZXI=?="]:
        let answer = rawPost(url, common & "Mcp-Name: " & marker & "\c\L", toolCall)
        checkpoint "marker: " & marker
        check answer.code == 400
        check parseJson(answer.body)["error"]["code"].getInt() == -32020

    test "Given the headers of a request spelt in other cases, when it is posted, then it is read as with the usual spelling, and a differing Mcp-Name is still a mismatch":
      let url = startServer()
      for names in [("content-type", "mcp-protocol-version", "mcp-method", "mcp-name"),
                    ("CONTENT-TYPE", "MCP-PROTOCOL-VERSION", "MCP-METHOD", "MCP-NAME"),
                    ("Content-TYPE", "mCp-PrOtOcOl-VeRsIoN", "mCP-mEtHoD", "Mcp-NAME")]:
        let lines = proc(name: string): string =
          names[0] & ": application/json\c\L" & names[1] & ": 2026-07-28\c\L" &
          names[2] & ": tools/call\c\L" & names[3] & ": " & name & "\c\L"
        checkpoint "spelling: " & names[3]
        check rawPost(url, lines("get_weather"), toolCall).code == 200
        check rawPost(url, lines("other_tool"), toolCall).code == 400

if HasGetStream:
  suite "the names of the headers of a session (versions 2025-03-26 to 2025-11-25)":

    test "Given a session, when a request names it with the header spelt in other cases, then the session is found, and an unknown id is not found":
      let (_, url, _) = startRaw(LegacyDefault)
      let session = initialize(url, LegacyDefault)
      let target = parseUri(url)
      for spelling in ["mcp-session-id", "MCP-SESSION-ID", "mCp-SeSsIoN-iD"]:
        for (id, expected) in [(session, 200), ("made-up", 404)]:
          let body = $rpc(2, "ping")
          let socket = waitFor asyncnet.dial("127.0.0.1", Port(parseInt(target.port)))
          waitFor socket.send("POST /mcp HTTP/1.1\c\LHost: 127.0.0.1\c\L" &
            "Content-Type: application/json\c\L" &
            (if LegacyDefault >= mpv20250618: "MCP-Protocol-Version: " & $LegacyDefault & "\c\L" else: "") &
            spelling & ": " & id & "\c\LContent-Length: " & $body.len &
            "\c\LConnection: close\c\L\c\L" & body)
          var received = ""
          while true:
            let part = waitFor socket.recv(4096)
            if part.len == 0:
              break
            received.add part
          socket.close()
          checkpoint "spelling: " & spelling & ", id: " & id
          check parseInt(received.split(' ')[1]) == expected
