## The range of versions a build speaks, `OldestProtocolVersion` to
## `DefaultProtocolVersion`, and what a server answers to the traffic of a
## version outside it.
##
## Expectations are derived from the two constants, so the same file passes
## on a build that speaks every version up to its default and on one that
## speaks 2026-07-28 alone (`-d:mcpOldestProtocolVersion=2026-07-28`).

import std/[unittest, asyncdispatch, httpclient, json, options, sequtils, strutils]
import transport/http_server
import server/server
import protocol/types
import protocol/features

const
  SpeaksModern = isModern(DefaultProtocolVersion)
  SpeaksLegacy = SupportedProtocolVersions.anyIt(not isModern(it))
  GetStreamSpoken = SupportedProtocolVersions.anyIt(it.has(ftHttpGetStream))
  SessionsSpoken = SpeaksLegacy
    ## The transport keeps a session for every client that initializes.

proc plainServer(): McpServer =
  newMcpServer(McpServerInfo(name: "ExampleServer", version: "1.0.0"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))

proc startServer(): string =
  let transport = newHttpServerTransport(port = 0)
  transport.listen()
  asyncCheck transport.serve()
  waitFor plainServer().attachTransport(transport)
  "http://127.0.0.1:" & $transport.port

type Reply = tuple[code: HttpCode, headers: HttpHeaders, body: string]

proc send(url: string, httpMethod: HttpMethod, body = "",
          headers: openArray[(string, string)] = []): Reply =
  let http = newAsyncHttpClient()
  defer: http.close()
  let response = waitFor http.request(url, httpMethod, body, newHttpHeaders(headers))
  (response.code, response.headers, waitFor response.body)

proc allowedWithoutVersion(): string =
  ## What `Allow` names for a request that does not say which version it speaks.
  result = "POST"
  if GetStreamSpoken: result.add ", GET"
  if SessionsSpoken: result.add ", DELETE"

proc legacyInitialize(): JsonNode =
  %*{"protocolVersion": "2025-11-25", "capabilities": {},
     "clientInfo": {"name": "ExampleClient", "version": "1.0.0"}}

proc newestFirst(versions: seq[McpProtocolVersion]): JsonNode =
  result = newJArray()
  for i in countdown(versions.high, 0):
    result.add %($versions[i])

suite "the versions a build speaks":

  test "Given a build, when its versions are listed, then they are every version from the oldest to the default":
    check OldestProtocolVersion <= DefaultProtocolVersion
    check SupportedProtocolVersions == toSeq(McpProtocolVersion).filterIt(
      it >= OldestProtocolVersion and it <= DefaultProtocolVersion)
    for v in McpProtocolVersion:
      check isSupported(v) == (v in SupportedProtocolVersions)

  test "Given a ceiling, when the spoken versions up to it are listed, then none is older than the build's oldest":
    for ceiling in McpProtocolVersion:
      check spokenVersionsUpTo(ceiling) == toSeq(McpProtocolVersion).filterIt(
        it >= OldestProtocolVersion and it <= ceiling)

  test "Given a version outside the build's range, when a server is created for it, then ValueError is raised":
    for v in McpProtocolVersion:
      if v notin SupportedProtocolVersions:
        expect ValueError:
          discard newMcpServer(McpServerInfo(name: "s", version: "1"), protocolVersion = v)

suite "a legacy client at a server":

  test "Given an initialize request, when the server speaks no legacy version, then the error names the versions it speaks":
    let server = plainServer()
    let answer = waitFor server.handleRequest(
      newJsonRpcRequest("1", "initialize", legacyInitialize()))
    if SpeaksLegacy:
      check answer.error.isNone
      check answer.result.get["protocolVersion"].getStr() == "2025-11-25" or
            answer.result.get["protocolVersion"].getStr() == $DefaultProtocolVersion
    else:
      check answer.error.get.code == -32022
      check answer.error.get.data["supported"] == newestFirst(SupportedProtocolVersions)
      check answer.error.get.data["requested"].getStr() == "2025-11-25"

  test "Given a request without the per-request fields, when the server speaks no legacy version, then it is invalid params":
    if not SpeaksLegacy:
      let server = plainServer()
      let answer = waitFor server.handleRequest(newJsonRpcRequest("1", "tools/list", newJObject()))
      check answer.error.get.code == -32602

suite "GET and DELETE at the MCP endpoint":

  test "Given a GET that names no version and no session, when it arrives, then it is 400 where a spoken version has the stream and 405 otherwise":
    let reply = send(startServer() & "/mcp", HttpGet, headers = {"Accept": "text/event-stream"})
    if GetStreamSpoken:
      check reply.code == Http400
    else:
      check reply.code == Http405
      check $reply.headers["Allow"] == allowedWithoutVersion()

  test "Given a DELETE that names no version and no session, when it arrives, then it is 400 where a spoken version has sessions and 405 otherwise":
    let reply = send(startServer() & "/mcp", HttpDelete)
    if SessionsSpoken:
      check reply.code == Http400
    else:
      check reply.code == Http405
      check $reply.headers["Allow"] == allowedWithoutVersion()

  test "Given a method the endpoint does not serve, when it arrives, then Allow names what the spoken versions use":
    let reply = send(startServer() & "/mcp", HttpPut, "{}")
    check reply.code == Http405
    check $reply.headers["Allow"] == allowedWithoutVersion()

  test "Given a GET or DELETE that names 2026-07-28, when it arrives, then it is 405 and only POST is allowed":
    if SpeaksModern:
      let url = startServer() & "/mcp"
      for httpMethod in [HttpGet, HttpDelete]:
        for extra in [@[("MCP-Protocol-Version", "2026-07-28")],
                      @[("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Session-Id", "abc")]]:
          let reply = send(url, httpMethod, headers = extra)
          check reply.code == Http405
          check $reply.headers["Allow"] == "POST"

suite "a server that speaks 2026-07-28 alone, over HTTP":

  test "Given a request with Mcp-Session-Id and Last-Event-ID, when it is served, then both are ignored and no session id comes back":
    if SpeaksModern and not SpeaksLegacy:
      let body = %*{"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": {"_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "1"},
        "io.modelcontextprotocol/clientCapabilities": {}}}}
      let reply = send(startServer() & "/mcp", HttpPost, $body, {
        "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "server/discover",
        "Mcp-Session-Id": "not-a-session", "Last-Event-ID": "7"})
      check reply.code == Http200
      check not reply.headers.hasKey("Mcp-Session-Id")

  test "Given a legacy initialize, when it is posted, then the answer is 400 and names the versions the server speaks":
    if SpeaksModern and not SpeaksLegacy:
      let body = %*{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": legacyInitialize()}
      let reply = send(startServer() & "/mcp", HttpPost, $body, {
        "Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
      check reply.code == Http400
      check not reply.headers.hasKey("Mcp-Session-Id")
      let error = parseJson(reply.body)["error"]
      check error["code"].getInt() == -32022
      check error["data"]["supported"] == newestFirst(SupportedProtocolVersions)

  test "Given the HTTP+SSE paths, when no spoken version has that transport, then they do not exist":
    if not SupportedProtocolVersions.anyIt(it.has(ftHttpSse)):
      let base = startServer()
      check send(base & "/sse", HttpGet).code == Http404
      check send(base & "/messages", HttpPost, "{}").code == Http404

suite "an HTTP server transport for a version outside the build (mutation review, g2f-hs-a)":
  test "Given a version the build does not speak, when a transport is made for it, then ValueError is raised":
    # With every version spoken (the default build) nothing is outside the
    # range; the floor build (-d:mcpOldestProtocolVersion=2026-07-28) is the
    # one in which this test has something to refuse.
    for v in McpProtocolVersion:
      if not isSupported(v):
        expect ValueError:
          discard newHttpServerTransport(port = 0, protocolVersion = v)

  test "Given a request in progress on a server of 2026-07-28 alone, when a cancellation naming its id comes without a session, then it is not passed to the server":
    # Only here does a notification reach the transport without a session:
    # a build that also speaks a legacy version refuses it for want of one.
    if SpeaksModern and not SpeaksLegacy:
      type Seen = ref object
        methods: seq[string]
      let seen = Seen()
      let transport = newHttpServerTransport(port = 0)
      transport.listen()
      asyncCheck transport.serve()
      proc record() {.async.} =
        while true:
          let incoming = await transport.receive()
          seen.methods.add incoming.message{"method"}.getStr()
      asyncCheck record()
      let url = "http://127.0.0.1:" & $transport.port & "/mcp"
      let held = newAsyncHttpClient()
      let body = %*{"jsonrpc": "2.0", "id": 1, "method": "hang", "params": {"_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "1"},
        "io.modelcontextprotocol/clientCapabilities": {}}}}
      discard held.request(url, HttpPost, $body, newHttpHeaders({
        "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "hang"}))
      waitFor sleepAsync(50)
      check seen.methods == @["hang"]
      let reply = send(url, HttpPost, $(%*{"jsonrpc": "2.0", "method": "notifications/cancelled",
                                           "params": {"requestId": 1}}), {
        "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": "2026-07-28"})
      check reply.code == Http202
      waitFor sleepAsync(50)
      check seen.methods == @["hang"]
      held.close()

proc sendWithin(url: string, httpMethod: HttpMethod, body: string,
                headers: openArray[(string, string)], ms = 2000): Reply =
  ## Like `send`, but a server that never answers fails the check (code 0)
  ## instead of hanging the test.
  let http = newAsyncHttpClient()
  defer: http.close()
  let pending = http.request(url, httpMethod, body, newHttpHeaders(headers))
  if waitFor withTimeout(pending, ms):
    let response = pending.read()
    (response.code, response.headers, waitFor response.body)
  else:
    (HttpCode(0), newHttpHeaders(), "")

suite "a server that speaks 2026-07-28 alone, over HTTP (mutation review, g2f-hs-b)":
  const SessionlessHeaders = {"Content-Type": "application/json",
                              "Accept": "application/json, text/event-stream",
                              "MCP-Protocol-Version": "2026-07-28"}

  test "Given a batch whose first message is a 2026-07-28 request, when it is posted, then the answer is 400 invalid request":
    # 2026-07-28 has no batches, and a batch is not answered as its first request.
    if SpeaksModern and not SpeaksLegacy:
      let request = %*{"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": {"_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "1"},
        "io.modelcontextprotocol/clientCapabilities": {}}}}
      let reply = sendWithin(startServer() & "/mcp", HttpPost, $(%[request]),
                       @SessionlessHeaders & @[("Mcp-Method", "server/discover")])
      check reply.code == Http400
      check parseJson(reply.body)["error"]["code"].getInt() == -32600

  test "Given a notification that names 2026-07-28, when it is posted, then the answer is 202":
    # A notification has no per-request fields to check; only a request is held to them.
    if SpeaksModern and not SpeaksLegacy:
      let reply = sendWithin(startServer() & "/mcp", HttpPost,
        $(%*{"jsonrpc": "2.0", "method": "notifications/roots/list_changed"}), SessionlessHeaders)
      check reply.code == Http202

  test "Given a notification whose method is initialize, when it is posted, then the answer is 202 and not the legacy-client refusal":
    # Only an initialize request tells a legacy client from a current one.
    if SpeaksModern and not SpeaksLegacy:
      let reply = sendWithin(startServer() & "/mcp", HttpPost,
        $(%*{"jsonrpc": "2.0", "method": "initialize", "params": legacyInitialize()}), SessionlessHeaders)
      check reply.code == Http202
