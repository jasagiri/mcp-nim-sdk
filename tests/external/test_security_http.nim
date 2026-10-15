## Security of the HTTP server transport (build/SECURITY_FINDINGS.md: C1, M1,
## M2, M6, L5, L6), checked with plain HTTP clients against a transport that
## has a token verifier. Every test names the spec id it verifies
## (specs/security.feature, MCP-SEC-HTTP-*).

import std/[unittest, asyncdispatch, httpclient, httpcore, json, options,
            strutils, sequtils, tables]
import sse_reader
import transport/transport
import transport/http_server
import protocol/types
import protocol/version
import protocol/features
import auth/resource_server
import server/server

const
  Spoken = SupportedProtocolVersions
  ServesLegacySse = Spoken.anyIt(it.has(ftHttpSse))
  ServesSessions = latestLegacyVersion(Spoken).isSome
  ServesAuth = Spoken.anyIt(it.has(ftAuthorization))
    ## 2024-11-05 has no authorization: a build that speaks nothing newer has
    ## no token to check.
  ServesResourceMetadata = Spoken.anyIt(it.has(ftProtectedResourceMetadata))

type
  Script = ref object
    ## What the script server was handed, and the principal it came with.
    received: seq[McpIncoming]

  Env = object
    transport: HttpServerTransport
    base: string
    script: Script

proc runScript(t: HttpServerTransport, s: Script) {.async.} =
  ## `initialize` answers with the version asked for; `hang` is never
  ## answered; anything else answers at once.
  while true:
    let incoming = await t.receive()
    s.received.add incoming
    let message = incoming.message
    if not isRequest(message):
      continue
    let id = message["id"].getStr()
    case message["method"].getStr()
    of "initialize":
      await t.sendResponse(newJsonRpcResponse(id, %*{
        "protocolVersion": message{"params"}{"protocolVersion"}.getStr(
          $latestLegacyVersion(Spoken).get(DefaultProtocolVersion)),
        "capabilities": {}, "serverInfo": {"name": "script", "version": "0"}}))
    of "hang":
      discard
    else:
      await t.sendResponse(newJsonRpcResponse(id, %*{"principal":
        (if incoming.principal.isSome: incoming.principal.get else: "")}))

proc verdicts(): TokenVerifier =
  ## Tokens "alice" and "bob" stand for those principals; others are invalid.
  result = proc(token, resource: string): Future[TokenVerdict] {.async.} =
    if token in ["alice", "bob"]:
      return TokenVerdict(kind: tvValid, principal: some(token))
    return TokenVerdict(kind: tvInvalid)

proc startProtected(): Env =
  let version = if ServesSessions: latestLegacyVersion(Spoken).get else: DefaultProtocolVersion
  let transport = newHttpServerTransport(port = 0, protocolVersion = version)
  transport.listen()
  asyncCheck transport.serve()
  let script = Script()
  asyncCheck runScript(transport, script)
  let base = "http://127.0.0.1:" & $transport.port
  transport.auth = newResourceServerAuth(ResourceServerConfig(
    resource: base & "/mcp", authorizationServers: @["https://auth.example.com"],
    verify: verdicts(), version: version))
  Env(transport: transport, base: base, script: script)

proc bearer(token: string): seq[(string, string)] =
  @[("Authorization", "Bearer " & token)]

proc send(url: string, httpMethod: HttpMethod, body = "",
          headers: openArray[(string, string)] = []): tuple[code: HttpCode, headers: HttpHeaders, body: string] =
  let http = newAsyncHttpClient()
  defer: http.close()
  let all = newHttpHeaders({"Content-Type": "application/json",
                            "Accept": "application/json, text/event-stream"})
  for (name, value) in headers:
    all[name] = value
  let response = waitFor http.request(url, httpMethod, body, all)
  (response.code, response.headers, waitFor response.body)

proc rpc(id: int, name: string, params = newJObject()): string =
  $(%*{"jsonrpc": "2.0", "id": id, "method": name, "params": params})

proc initializeBody(): string =
  rpc(1, "initialize", %*{"protocolVersion": $latestLegacyVersion(Spoken).get(DefaultProtocolVersion),
                          "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})

proc openSession(env: Env, token: string): string =
  ## Initializes as `token` and returns the session id.
  let reply = send(env.base & "/mcp", HttpPost, initializeBody(), bearer(token))
  doAssert reply.code == Http200, "initialize answered " & $reply.code
  $reply.headers["Mcp-Session-Id"]

if ServesAuth:
  suite "Authorization covers every endpoint the transport serves (MCP-SEC-HTTP-1)":
    if ServesLegacySse:
      test "Given an authorized transport, when GET /sse comes without a token, then the answer is 401 and no session is made":
        let env = startProtected()
        let stream = open(env.base & "/sse", HttpGet, "", @[("Accept", "text/event-stream")])
        check stream.code == Http401
        stream.close()
        check env.transport.sessionCount == 0

      test "Given an authorized transport, when POST /messages comes without a token, then the answer is 401 and nothing reaches the server":
        let env = startProtected()
        let reply = send(env.base & "/messages?sessionId=x", HttpPost, rpc(1, "tools/list"))
        check reply.code == Http401
        waitFor sleepAsync(30)
        check env.script.received.len == 0

      test "Given a token, when a client opens /sse and posts, then the request reaches the server as that principal":
        let env = startProtected()
        let stream = open(env.base & "/sse", HttpGet, "",
                          @[("Accept", "text/event-stream")] & bearer("alice"))
        check stream.code == Http200
        let endpoint = stream.next().get.data
        let reply = send(env.base & endpoint, HttpPost, rpc(7, "tools/list"), bearer("alice"))
        check reply.code == Http202
        let answer = parseJson(stream.next().get.data)
        check answer["result"]["principal"].getStr() == "alice"
        stream.close()

      test "Given an invalid token, when GET /sse comes, then the answer is 401":
        let env = startProtected()
        let stream = open(env.base & "/sse", HttpGet, "",
                          @[("Accept", "text/event-stream")] & bearer("nobody"))
        check stream.code == Http401
        stream.close()

    test "Given an authorized transport with documents, when a document and the metadata are read without a token, then both are served":
      let env = startProtected()
      env.transport.documents["/.well-known/server-card.json"] = HttpDocument(
        contentType: "application/json", body: """{"name":"card"}""")
      check send(env.base & "/.well-known/server-card.json", HttpGet).code == Http200
      # The metadata document exists from 2025-06-18 on.
      if ServesResourceMetadata:
        check send(env.base & "/.well-known/oauth-protected-resource/mcp", HttpGet).code == Http200

    test "Given an authorized transport, when an unknown path is asked, then it is 404":
      let env = startProtected()
      check send(env.base & "/nothing", HttpGet).code == Http404

  suite "A session belongs to the principal that made it (MCP-SEC-HTTP-2)":
    if ServesSessions:
      test "Given alice's session, when bob posts with its id, then the answer is 404 and the server sees nothing":
        let env = startProtected()
        let session = env.openSession("alice")
        let before = env.script.received.len
        let reply = send(env.base & "/mcp", HttpPost, rpc(2, "tools/list"),
                         bearer("bob") & @[("Mcp-Session-Id", session)])
        check reply.code == Http404
        check env.script.received.len == before

      test "Given alice's session, when alice posts with its id, then it is served":
        let env = startProtected()
        let session = env.openSession("alice")
        let reply = send(env.base & "/mcp", HttpPost, rpc(2, "tools/list"),
                         bearer("alice") & @[("Mcp-Session-Id", session)])
        check reply.code == Http200

      test "Given alice's session, when bob opens its GET stream, then the answer is 404":
        let env = startProtected()
        let session = env.openSession("alice")
        let stream = open(env.base & "/mcp", HttpGet, "",
                          @[("Accept", "text/event-stream"), ("Mcp-Session-Id", session)] &
                          bearer("bob"))
        check stream.code == Http404
        stream.close()

      test "Given alice's session, when bob sends DELETE with its id, then the answer is 404 and the session stays":
        let env = startProtected()
        let session = env.openSession("alice")
        check send(env.base & "/mcp", HttpDelete, "",
                   bearer("bob") & @[("Mcp-Session-Id", session)]).code == Http404
        check env.transport.sessionCount == 1
        check send(env.base & "/mcp", HttpDelete, "",
                   bearer("alice") & @[("Mcp-Session-Id", session)]).code == Http200
        check env.transport.sessionCount == 0

    if ServesLegacySse:
      test "Given alice's HTTP+SSE session, when bob posts to its endpoint, then the answer is 404":
        let env = startProtected()
        let stream = open(env.base & "/sse", HttpGet, "",
                          @[("Accept", "text/event-stream")] & bearer("alice"))
        let endpoint = stream.next().get.data
        check send(env.base & endpoint, HttpPost, rpc(1, "tools/list"), bearer("bob")).code == Http404
        check send(env.base & endpoint, HttpPost, rpc(1, "tools/list"), bearer("alice")).code == Http202
        stream.close()

type Serving = object
  transport: HttpServerTransport
  base: string

proc startServing(): Serving =
  ## A real McpServer whose tool `hang` never answers, so that what the
  ## transport and the server do with a cancellation can be seen.
  let transport = newHttpServerTransport(port = 0)
  transport.listen()
  asyncCheck transport.serve()
  let server = newMcpServer(McpServerInfo(name: "S", version: "1"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      await newFuture[void]("never")
      return %*{"content": [], "isError": false}
  server.setToolHandlers(McpToolHandlers(callHandler: some(callTool)))
  waitFor server.attachTransport(transport)
  Serving(transport: transport, base: "http://127.0.0.1:" & $transport.port)

proc modernMeta(): JsonNode =
  %*{"io.modelcontextprotocol/protocolVersion": "2026-07-28",
     "io.modelcontextprotocol/clientInfo": {"name": "C", "version": "1"},
     "io.modelcontextprotocol/clientCapabilities": {}}

proc hangCall(id: JsonNode, modern: bool): string =
  var params = %*{"name": "hang", "arguments": {}}
  if modern:
    params["_meta"] = modernMeta()
  $(%*{"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": params})

proc cancelled(requestId: JsonNode): string =
  $(%*{"jsonrpc": "2.0", "method": "notifications/cancelled",
       "params": {"requestId": requestId}})

proc startHanging(base: string, id: JsonNode, modern: bool,
                  headers: openArray[(string, string)]): AsyncHttpClient =
  ## Posts the call without waiting for its answer; closing the result is
  ## the client leaving.
  let http = newAsyncHttpClient()
  let all = newHttpHeaders({"Content-Type": "application/json",
                            "Accept": "application/json, text/event-stream"})
  for (name, value) in headers:
    all[name] = value
  if modern:
    all["MCP-Protocol-Version"] = "2026-07-28"
    all["Mcp-Method"] = "tools/call"
    all["Mcp-Name"] = "hang"
  discard http.request(base & "/mcp", HttpPost, hangCall(id, modern), all)
  waitFor sleepAsync(100)
  http

proc legacySessionOf(base: string): string =
  let reply = send(base & "/mcp", HttpPost, initializeBody())
  doAssert reply.code == Http200
  let session = $reply.headers["Mcp-Session-Id"]
  discard send(base & "/mcp", HttpPost,
    $(%*{"jsonrpc": "2.0", "method": "notifications/initialized"}),
    @[("Mcp-Session-Id", session)])
  session

suite "A cancellation cancels only the sender's own request (MCP-SEC-HTTP-6)":
  if DefaultProtocolVersion.isModern:
    test "Given a 2026-07-28 request in progress, when another client posts notifications/cancelled naming the transport's exchange id or the same id, then the request is still in progress":
      let env = startServing()
      let victim = startHanging(env.base, %1, true, [])
      check env.transport.pendingExchangeCount == 1
      for named in [%"http-1", %1, %"1"]:
        discard send(env.base & "/mcp", HttpPost, cancelled(named),
                     {"MCP-Protocol-Version": "2026-07-28"})
      waitFor sleepAsync(100)
      check env.transport.pendingExchangeCount == 1
      victim.close()

    test "Given a 2026-07-28 request in progress, when its client closes the connection, then the request is cancelled":
      let env = startServing()
      let victim = startHanging(env.base, %1, true, [])
      check env.transport.pendingExchangeCount == 1
      victim.close()
      waitFor sleepAsync(200)
      check env.transport.pendingExchangeCount == 0

  if ServesSessions:
    test "Given a session with a request in progress, when it cancels the request by the id it chose, then the request is cancelled":
      let env = startServing()
      let session = legacySessionOf(env.base)
      let hanging = startHanging(env.base, %5, false, @[("Mcp-Session-Id", session)])
      check env.transport.pendingExchangeCount == 1
      check send(env.base & "/mcp", HttpPost, cancelled(%5),
                 @[("Mcp-Session-Id", session)]).code == Http202
      waitFor sleepAsync(100)
      check env.transport.pendingExchangeCount == 0
      hanging.close()

    test "Given two sessions that chose the same request id, when one cancels it, then only its own request is cancelled":
      let env = startServing()
      let a = legacySessionOf(env.base)
      let b = legacySessionOf(env.base)
      let hangA = startHanging(env.base, %5, false, @[("Mcp-Session-Id", a)])
      let hangB = startHanging(env.base, %5, false, @[("Mcp-Session-Id", b)])
      check env.transport.pendingExchangeCount == 2
      discard send(env.base & "/mcp", HttpPost, cancelled(%5), @[("Mcp-Session-Id", a)])
      waitFor sleepAsync(100)
      check env.transport.pendingExchangeCount == 1
      hangA.close()
      hangB.close()

    test "Given a request of another session, when a session cancels the exchange id the transport made for it, then that request is still in progress":
      let env = startServing()
      let a = legacySessionOf(env.base)
      let b = legacySessionOf(env.base)
      let hangA = startHanging(env.base, %5, false, @[("Mcp-Session-Id", a)])
      check env.transport.pendingExchangeCount == 1
      for named in [%"http-1", %5]:
        discard send(env.base & "/mcp", HttpPost, cancelled(named), @[("Mcp-Session-Id", b)])
      waitFor sleepAsync(100)
      check env.transport.pendingExchangeCount == 1
      hangA.close()

proc startOpen(version = DefaultProtocolVersion): Env =
  ## A transport without authorization, answered by the script.
  let transport = newHttpServerTransport(port = 0, protocolVersion = version)
  transport.listen()
  asyncCheck transport.serve()
  let script = Script()
  asyncCheck runScript(transport, script)
  Env(transport: transport, base: "http://127.0.0.1:" & $transport.port, script: script)

proc initializeAs(version: string): string =
  rpc(1, "initialize", %*{"protocolVersion": version, "capabilities": {},
                          "clientInfo": {"name": "t", "version": "0"}})

proc touch(env: Env, session: string): HttpCode =
  ## Names the session in a request: the session counts as used.
  send(env.base & "/mcp", HttpPost, rpc(9, "ping"), @[("Mcp-Session-Id", session)]).code

proc initialize(env: Env): tuple[code: HttpCode, session: string] =
  let reply = send(env.base & "/mcp", HttpPost, initializeBody())
  (reply.code, if reply.headers.hasKey("Mcp-Session-Id"): $reply.headers["Mcp-Session-Id"] else: "")

suite "The transport does not let one caller use up its resources (MCP-SEC-HTTP-3)":
  if ServesSessions:
    test "Given a session limit reached by sessions never used again, when another client initializes, then it gets a session and the oldest unused one is dropped":
      let env = startOpen()
      env.transport.maxSessions = 3
      let first = env.initialize()
      let second = env.initialize()
      discard env.initialize()
      let fourth = env.initialize()
      check fourth.code == Http200
      check env.transport.sessionCount == 3
      check env.touch(first.session) == Http404
      check env.touch(second.session) == Http200

    test "Given a session limit reached by sessions in use, when another client initializes, then the answer is 503 and the sessions are kept":
      let env = startOpen()
      env.transport.maxSessions = 2
      let a = env.initialize()
      let b = env.initialize()
      check env.touch(a.session) == Http200
      check env.touch(b.session) == Http200
      check env.initialize().code == Http503
      check env.transport.sessionCount == 2

    test "Given a session in use among a flood of initialize requests, when the flood fills the limit, then the session in use survives":
      let env = startOpen()
      env.transport.maxSessions = 3
      let kept = env.initialize()
      check env.touch(kept.session) == Http200
      for _ in 1 .. 10:
        check env.initialize().code == Http200
      check env.transport.sessionCount == 3
      check env.touch(kept.session) == Http200

    test "Given a client address at its session limit with sessions in use, when it initializes again, then the answer is 503":
      let env = startOpen()
      env.transport.maxSessionsPerPeer = 2
      check env.touch(env.initialize().session) == Http200
      check env.touch(env.initialize().session) == Http200
      check env.initialize().code == Http503

    test "Given a client address at its session limit with unused sessions, when it initializes again, then its own oldest unused session is dropped":
      let env = startOpen()
      env.transport.maxSessionsPerPeer = 2
      discard env.initialize()
      discard env.initialize()
      check env.initialize().code == Http200
      check env.transport.sessionCount == 2

  if ServesLegacySse:
    test "Given a client address at its limit, when it opens another HTTP+SSE stream, then the answer is 503":
      let env = startOpen()
      env.transport.maxSessionsPerPeer = 2
      let a = open(env.base & "/sse", HttpGet, "", @[("Accept", "text/event-stream")])
      let b = open(env.base & "/sse", HttpGet, "", @[("Accept", "text/event-stream")])
      discard a.next()
      discard b.next()
      let c = open(env.base & "/sse", HttpGet, "", @[("Accept", "text/event-stream")])
      check c.code == Http503
      a.close()
      b.close()
      c.close()

  if mpv20250326 in Spoken:
    test "Given a batch longer than the limit, when posted, then the answer is 400, and a batch within it is answered":
      let env = startOpen(mpv20250326)
      env.transport.maxBatchItems = 2
      let reply = send(env.base & "/mcp", HttpPost, initializeAs("2025-03-26"))
      let session = $reply.headers["Mcp-Session-Id"]
      let headers = @[("Mcp-Session-Id", session)]
      let ping = %*{"jsonrpc": "2.0", "id": 5, "method": "ping"}
      let ping2 = %*{"jsonrpc": "2.0", "id": 6, "method": "ping"}
      let ping3 = %*{"jsonrpc": "2.0", "id": 7, "method": "ping"}
      check send(env.base & "/mcp", HttpPost, $(%[ping, ping2, ping3]), headers).code == Http400
      check send(env.base & "/mcp", HttpPost, $(%[ping, ping2]), headers).code == Http200

  proc firstRequest(): tuple[body: string, headers: seq[(string, string)]] =
    ## A request that the transport accepts at any default version.
    if DefaultProtocolVersion.isModern:
      (hangCall(%1, true), @[("MCP-Protocol-Version", "2026-07-28"),
                             ("Mcp-Method", "tools/call"), ("Mcp-Name", "hang")])
    else:
      (initializeBody(), @[])

  test "Given requests in progress up to the limit, when another arrives, then the answer is 503 with Retry-After":
    let transport = newHttpServerTransport(port = 0)
    transport.listen()
    asyncCheck transport.serve()
    transport.maxPendingRequests = 2
    let base = "http://127.0.0.1:" & $transport.port & "/mcp"
    let (body, headers) = firstRequest()
    var held: seq[AsyncHttpClient]
    for _ in 1 .. 2:
      let http = newAsyncHttpClient()
      let all = newHttpHeaders({"Content-Type": "application/json",
                                "Accept": "application/json, text/event-stream"})
      for (name, value) in headers:
        all[name] = value
      discard http.request(base, HttpPost, body, all)
      held.add http
    waitFor sleepAsync(100)
    check transport.pendingExchangeCount == 2
    let reply = send(base, HttpPost, body, headers)
    check reply.code == Http503
    check reply.headers.hasKey("Retry-After")
    for http in held:
      http.close()

  test "Given messages waiting for the server up to the limit, when another arrives, then the answer is 503":
    let transport = newHttpServerTransport(port = 0)
    transport.listen()
    asyncCheck transport.serve()
    transport.maxQueuedMessages = 2
    let base = "http://127.0.0.1:" & $transport.port & "/mcp"
    let (body, headers) = firstRequest()
    var held: seq[AsyncHttpClient]
    for _ in 1 .. 2:
      let http = newAsyncHttpClient()
      let all = newHttpHeaders({"Content-Type": "application/json",
                                "Accept": "application/json, text/event-stream"})
      for (name, value) in headers:
        all[name] = value
      discard http.request(base, HttpPost, body, all)
      held.add http
    waitFor sleepAsync(100)
    check send(base, HttpPost, body, headers).code == Http503
    for http in held:
      http.close()

proc sendAs(host, url: string, httpMethod: HttpMethod, body = ""): HttpCode =
  ## Sends with a Host header of its own, as a rebound DNS name does.
  let http = newAsyncHttpClient()
  defer: http.close()
  let headers = newHttpHeaders({"Host": host, "Content-Type": "application/json",
                                "Accept": "application/json, text/event-stream"})
  (waitFor http.request(url, httpMethod, body, headers)).code

suite "The Host header names this server (MCP-SEC-HTTP-5)":
  test "Given a transport bound to loopback, when a request names another host, then the answer is 403 on every endpoint":
    let env = startOpen()
    env.transport.documents["/.well-known/server-card.json"] = HttpDocument(
      contentType: "application/json", body: "{}")
    check sendAs("evil.example", env.base & "/mcp", HttpPost, rpc(1, "ping")) == Http403
    check sendAs("evil.example:80", env.base & "/mcp", HttpGet) == Http403
    check sendAs("evil.example", env.base & "/sse", HttpGet) == Http403
    check sendAs("evil.example", env.base & "/messages?sessionId=x", HttpPost, rpc(1, "ping")) == Http403
    check sendAs("evil.example", env.base & "/.well-known/server-card.json", HttpGet) == Http403
    check env.transport.sessionCount == 0
    check env.script.received.len == 0

  test "Given a transport bound to loopback, when a request names a loopback host with a port, then it is served":
    let env = startOpen()
    let port = $env.transport.port
    for host in ["localhost", "localhost:" & port, "127.0.0.1:" & port, "[::1]:" & port, "LOCALHOST",
                 "127.0.0.2:" & port, "[0:0:0:0:0:0:0:1]:" & port]:   # nim-loopback LB-01, 02
      check sendAs(host, env.base & "/mcp", HttpPost, rpc(1, "ping")) != Http403

  test "Given a transport bound to loopback, when a request names a host that only looks like loopback, then the answer is 403":
    # nim-loopback LB-01, 04: 0177 may be read as octal; a port that is not a number is not a port
    let env = startOpen()
    let port = $env.transport.port
    for host in ["0177.0.0.1:" & port, "127.0.0.1:http", "localhost.:" & port, "127.0.0.1.evil.example"]:
      check sendAs(host, env.base & "/mcp", HttpPost, rpc(1, "ping")) == Http403

  test "Given allowed hosts, when a request names one of them or another, then the first is served and the second is 403":
    let env = startOpen()
    env.transport.allowedHosts = @["mcp.example.com"]
    check sendAs("mcp.example.com", env.base & "/mcp", HttpPost, rpc(1, "ping")) != Http403
    check sendAs("MCP.example.com:8443", env.base & "/mcp", HttpPost, rpc(1, "ping")) != Http403
    check sendAs("evil.example", env.base & "/mcp", HttpPost, rpc(1, "ping")) == Http403

  test "Given a transport that listens on every interface and names no hosts, when a request names any host, then it is served":
    let transport = newHttpServerTransport(host = "0.0.0.0", port = 0)
    transport.listen()
    asyncCheck transport.serve()
    asyncCheck runScript(transport, Script())
    check sendAs("public.example", "http://127.0.0.1:" & $transport.port & "/mcp", HttpPost,
                 rpc(1, "ping")) != Http403

  test "Given a transport that listens on every interface and names hosts, when a request names another host, then the answer is 403":
    let transport = newHttpServerTransport(host = "0.0.0.0", port = 0)
    transport.allowedHosts = @["public.example"]
    transport.listen()
    asyncCheck transport.serve()
    let base = "http://127.0.0.1:" & $transport.port & "/mcp"
    check sendAs("evil.example", base, HttpPost, rpc(1, "ping")) == Http403

import std/asyncnet

suite "The Host header names this server, in its odd forms (mutation review, g2f-hs-a)":
  test "Given a transport bound to loopback, when a request names the bare IPv6 loopback address, then it is served":
    let env = startOpen()
    check sendAs("::1", env.base & "/mcp", HttpPost, rpc(1, "ping")) != Http403

  test "Given a transport bound to loopback, when a request carries no Host header at all, then the answer is 403":
    let env = startOpen()
    let socket = waitFor asyncnet.dial("127.0.0.1", Port(env.transport.port))
    waitFor socket.send("GET /mcp HTTP/1.0\c\L\c\L")
    let status = waitFor socket.recvLine()
    socket.close()
    check " 403 " in status


proc sendWithin(url: string, httpMethod: HttpMethod, body: string,
                headers: openArray[(string, string)] = [], ms = 2000):
    Option[tuple[code: HttpCode, headers: HttpHeaders, body: string]] =
  ## The reply, or none when the server has not answered within `ms`: a
  ## transport that forgets to answer must fail a check, not hang the test.
  let http = newAsyncHttpClient()
  defer: http.close()
  let all = newHttpHeaders({"Content-Type": "application/json",
                            "Accept": "application/json, text/event-stream"})
  for (name, value) in headers:
    all[name] = value
  let pending = http.request(url, httpMethod, body, all)
  if waitFor withTimeout(pending, ms):
    let response = pending.read()
    some((response.code, response.headers, waitFor response.body))
  else:
    none(tuple[code: HttpCode, headers: HttpHeaders, body: string])

suite "A hook that fails lets nothing through (mutation review, g2f-hs-b)":
  test "Given an authorization hook that raises, when a request arrives, then the answer is 500 and nothing reaches the server":
    let env = startOpen()
    env.transport.auth = HttpServerAuth(
      check: proc(httpMethod, path: string, authorization: Option[string]):
                 Future[HttpServerAuthOutcome] {.async.} =
        raise newException(ValueError, "the hook could not decide"))
    let reply = sendWithin(env.base & "/mcp", HttpPost, initializeBody())
    require reply.isSome
    check reply.get.code == Http500
    waitFor sleepAsync(50)
    check env.script.received.len == 0
    check env.transport.sessionCount == 0

if ServesLegacySse:
  suite "The limits hold on the HTTP+SSE endpoints (mutation review, g2f-hs-b)":
    test "Given requests in progress up to the limit, when a client of HTTP+SSE posts another, then the answer is 503 with Retry-After":
      let env = startOpen()
      env.transport.maxPendingRequests = 1
      let stream = open(env.base & "/sse", HttpGet, "", @[("Accept", "text/event-stream")])
      let endpoint = stream.next().get.data
      check send(env.base & endpoint, HttpPost, rpc(1, "hang")).code == Http202
      waitFor sleepAsync(30)
      check env.transport.pendingExchangeCount == 1
      let reply = sendWithin(env.base & endpoint, HttpPost, rpc(2, "hang"))
      require reply.isSome
      check reply.get.code == Http503
      check reply.get.headers.hasKey("Retry-After")
      stream.close()

import std/os

if ServesSessions:
  suite "A failure inside the transport is logged and not told to the peer (mutation review, g2f-hs-c)":
    proc loggedWhile(body: proc()): string =
      ## Everything the code under test wrote to stderr.
      let path = getTempDir() / "mcp-security-http-" & $getCurrentProcessId() & ".log"
      let saved = stderr
      stderr = open(path, fmWrite)
      try:
        body()
      finally:
        stderr.close()
        stderr = saved
      result = readFile(path)
      removeFile(path)

    test "Given a session whose end callback raises, when the client sends DELETE, then the answer is a bare 500, the log names the failure and the server goes on":
      let version = latestLegacyVersion(Spoken).get
      let env = startOpen(version)
      env.transport.onSessionEnd = proc(session: string) {.closure, gcsafe.} =
        raise newException(ValueError, "end callback failed")
      let reply = send(env.base & "/mcp", HttpPost, initializeBody())
      check reply.code == Http200
      let session = $reply.headers["Mcp-Session-Id"]
      var answer: tuple[code: HttpCode, headers: HttpHeaders, body: string]
      let log = loggedWhile(proc() =
        answer = send(env.base & "/mcp", HttpDelete, "", @[("Mcp-Session-Id", session)]))
      check answer.code == Http500
      check answer.body == ""
      check "end callback failed" notin answer.body
      check log.contains("[mcp-http-server] ValueError: end callback failed")
      check send(env.base & "/mcp", HttpPost, initializeBody()).code == Http200
      env.transport.onSessionEnd = nil  # close ends the second session too
      waitFor env.transport.close()
