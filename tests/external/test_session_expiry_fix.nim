## 2025-03-26 to 2025-11-25, Streamable HTTP: a request that carries a
## session id and gets 404 means the server ended the session. The client
## drops the id, starts a new session with ONE initialize that has no id, and
## does not send the request again: it tells the caller with
## McpSessionExpiredError, so a request with side effects is never done twice.

import std/[unittest, asyncdispatch, asyncnet, httpcore, json, options, os, strutils]
import mcp

const LegacyHttp = min(DefaultProtocolVersion, mpv20251125)
const SpeaksSessions = LegacyHttp >= mpv20250326

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

proc initializeResult(message: JsonNode, id: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "result": {
    "protocolVersion": message["params"]["protocolVersion"], "capabilities": {"tools": {}},
    "serverInfo": {"name": "raw", "version": "0"}}}

type Counts = ref object
  initializes: int
  sessionless: int      ## initializes that carried no session id
  lists: int            ## tools/list requests that reached the server
  sessionsOpened: int
  pingsInNewSession: int  ## pings that reached the server in a session after the first

proc expiringServer(counts: Counts, secondInitializeFails = false): string =
  ## Every request with a session id is answered 404, as if the session had
  ## ended. initialize opens session "s-<n>".
  startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
    if request.httpMethod != "POST":
      await socket.send("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L")
      return
    let message = parseJson(request.body)
    let id = message{"id"}
    let session = request.headers.getOrDefault("Mcp-Session-Id")
    case message{"method"}.getStr()
    of "initialize":
      inc counts.initializes
      if session.len == 0:
        inc counts.sessionless
      if secondInitializeFails and counts.initializes > 1:
        await socket.send("HTTP/1.1 500 Internal Server Error\c\LContent-Length: 0\c\L\c\L")
        return
      inc counts.sessionsOpened
      await socket.sendJson(initializeResult(message, id),
        "Mcp-Session-Id: s-" & $counts.sessionsOpened & "\c\L")
    of "tools/list":
      inc counts.lists
      if session == "s-1":
        await socket.send("HTTP/1.1 404 Not Found\c\LContent-Length: 0\c\L\c\L")
      else:
        await socket.sendJson(%*{"jsonrpc": "2.0", "id": id, "result": {"tools": []}})
    of "ping":
      if session == "s-1":
        await socket.send("HTTP/1.1 404 Not Found\c\LContent-Length: 0\c\L\c\L")
      else:
        inc counts.pingsInNewSession
        await socket.sendJson(%*{"jsonrpc": "2.0", "id": id, "result": {}})
    else:
      await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-session-expiry-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc connected(url: string): tuple[client: McpClient, transport: StreamableHttpTransport] =
  let client = newMcpClient(McpClientInfo(name: "c", version: "1"), LegacyHttp)
  let transport = newStreamableHttpTransport(url)
  transport.listenForServerMessages = false
  waitFor client.connect(transport)
  (client: client, transport: transport)

suite "a client whose session the server ended (2025-03-26 to 2025-11-25)":

  test "Given a session that got 404, when the client sends a request, then it raises McpSessionExpiredError after starting a new session with one initialize and does not send the request again":
    if not SpeaksSessions:
      skip()
    else:
      let counts = Counts()
      let (client, transport) = connected(expiringServer(counts))
      check transport.sessionId == some("s-1")
      var expired: ref McpSessionExpiredError
      try:
        discard waitFor client.sendRequest("tools/list", newJObject())
      except McpSessionExpiredError as e:
        expired = e
      check not expired.isNil
      check expired.renewed
      check expired.current
      check expired.code == 404
      check counts.initializes == 2
      check counts.sessionless == 2
      check counts.lists == 1
      check transport.sessionId == some("s-2")
      check client.state == mlsOperational
      waitFor client.close()

  test "Given a keepalive ping that gets 404 in an ended session, when it does, then a new session is started and one line holds the address the caller gave":
    if not SpeaksSessions:
      skip()
    else:
      let counts = Counts()
      let url = expiringServer(counts)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), LegacyHttp)
      client.pingIntervalMs = 50
      let transport = newStreamableHttpTransport(url)
      transport.listenForServerMessages = false
      let log = loggedWhile(proc() =
        waitFor client.connect(transport)
        # A ping in the new session comes after the failed one was dealt with.
        var waited = 0
        while counts.pingsInNewSession < 1 and waited < 20_000:
          waitFor sleepAsync(10)
          waited += 10
        waitFor client.close())
      check counts.initializes == 2
      check counts.pingsInNewSession >= 1
      var named = 0
      for line in log.splitLines():
        if url in line:
          inc named
          for c in line:
            check c notin {'\0' .. '\x1f', '\x7f'}
      check named == 1

  test "Given a client that started a new session, when the caller sends the request anew, then it is answered in the new session":
    if not SpeaksSessions:
      skip()
    else:
      let counts = Counts()
      let (client, transport) = connected(expiringServer(counts))
      expect McpSessionExpiredError:
        discard waitFor client.sendRequest("tools/list", newJObject())
      let answer = waitFor client.callMethod("tools/list", newJObject())
      check answer["tools"].len == 0
      check counts.lists == 2
      check counts.initializes == 2
      waitFor client.close()

  test "Given a session that got 404 and a server that refuses the new initialize, when the client tries, then it raises, tries no more and the client is closed":
    if not SpeaksSessions:
      skip()
    else:
      let counts = Counts()
      let (client, transport) = connected(expiringServer(counts, secondInitializeFails = true))
      var expired: ref McpSessionExpiredError
      try:
        discard waitFor client.sendRequest("tools/list", newJObject())
      except McpSessionExpiredError as e:
        expired = e
      check not expired.isNil
      check not expired.renewed
      check expired.current
      check not expired.parent.isNil
      check counts.initializes == 2
      expect McpError:
        discard waitFor client.sendRequest("tools/list", newJObject())
      check counts.initializes == 2
      check counts.lists == 1
      check transport.sessionId.isNone
      waitFor client.close()

  test "Given two requests in flight in the ended session, when both get 404, then one new session is started":
    if not SpeaksSessions:
      skip()
    else:
      let counts = Counts()
      let (client, transport) = connected(expiringServer(counts))
      let first = client.sendRequest("tools/list", newJObject())
      let second = client.sendRequest("tools/list", newJObject())
      waitFor sleepAsync(300)
      check first.finished and second.finished
      check first.failed and second.failed
      check first.readError() of McpSessionExpiredError
      check second.readError() of McpSessionExpiredError
      check counts.initializes == 2
      check counts.sessionsOpened == 2
      check transport.sessionId == some("s-2")
      waitFor client.close()

  test "Given a 404 for a request without a session id, when the client sends it, then it is an ordinary HTTP error and no initialize follows":
    if not SpeaksSessions:
      skip()
    else:
      var initializes = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        let message = parseJson(request.body)
        if message{"method"}.getStr() == "initialize":
          inc initializes
        await socket.send("HTTP/1.1 404 Not Found\c\LContent-Length: 0\c\L\c\L"))
      let transport = newStreamableHttpTransport(url)
      transport.protocolVersionNegotiated(LegacyHttp)
      var expired = false
      var ordinary = false
      try:
        waitFor transport.sendRequest(newJsonRpcRequest("r1", "initialize", newJObject()))
      except McpSessionExpiredError:
        expired = true
      except McpTransportError as e:
        ordinary = e.code == 404
      check ordinary
      check not expired
      check initializes == 1
      waitFor transport.close()

  test "Given a notification that gets 404 in an ended session, when the client sends it, then it raises McpSessionExpiredError and starts a new session":
    if not SpeaksSessions:
      skip()
    else:
      let counts = Counts()
      var notifications = 0
      let url = startRawServer(proc(request: RawRequest, socket: AsyncSocket) {.async.} =
        if request.httpMethod != "POST":
          await socket.send("HTTP/1.1 405 Method Not Allowed\c\LContent-Length: 0\c\L\c\L")
          return
        let message = parseJson(request.body)
        let session = request.headers.getOrDefault("Mcp-Session-Id")
        case message{"method"}.getStr()
        of "initialize":
          inc counts.initializes
          await socket.sendJson(initializeResult(message, message{"id"}),
            "Mcp-Session-Id: s-" & $counts.initializes & "\c\L")
        of "notifications/roots/list_changed":
          inc notifications
          await socket.send("HTTP/1.1 404 Not Found\c\LContent-Length: 0\c\L\c\L")
        else:
          await socket.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"))
      let (client, transport) = connected(url)
      expect McpSessionExpiredError:
        waitFor client.sendNotification("notifications/roots/list_changed", newJObject())
      check notifications == 1
      check counts.initializes == 2
      check transport.sessionId == some("s-2")
      waitFor client.close()

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

suite "a client whose session an SDK server ended":

  test "Given a session the server ended, when the client sends a request and gets 404, then it holds a new session and the next request is answered":
    if not SpeaksSessions:
      skip()
    else:
      let server = newHttpServerTransport(port = 0, protocolVersion = LegacyHttp)
      server.listen()
      asyncCheck server.serve()
      waitFor weatherServer(LegacyHttp).attachTransport(server)
      let client = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"), LegacyHttp)
      let transport = newStreamableHttpTransport("http://127.0.0.1:" & $server.port & "/mcp")
      waitFor client.connect(transport)
      let oldSession = transport.sessionId.get
      server.endSession(oldSession)
      expect McpSessionExpiredError:
        discard waitFor client.sendRequest("tools/list", newJObject())
      check server.sessionCount == 1
      check transport.sessionId.isSome
      check transport.sessionId != some(oldSession)
      let tools = waitFor client.callMethod("tools/list", newJObject())
      check tools["tools"].len == 1
      waitFor client.close()
