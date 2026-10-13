## The server limits how fast one sender may make requests (completion: "Rate
## limit completion requests", "Implement appropriate rate limiting"; tasks:
## "receivers SHOULD implement rate limiting on task operations"). A sender is
## the principal the transport's authorization names, else the session, else
## the whole connection. A request beyond the allowance is answered with
## ErrRateLimited and no handler runs; the table of senders has a size.

import std/[unittest, asyncdispatch, httpclient, json, options, deques, os, strutils]
import ./server_harness
import transport/transport
import transport/http_server

var handled = 0

proc completionServer(): McpServer =
  result = newServer(McpServerCapabilities(
    prompts: some(McpPromptsCapability()), completions: some(McpCompletionsCapability())))
  result.onComplete(proc(ctx: McpRequestContext,
                         request: McpCompletionRequest): Future[McpCompletion] {.async.} =
    inc handled
    return McpCompletion(values: @["python"]))

proc complete(peer: Peer): JsonNode =
  peer.ask("completion/complete",
    %*{"ref": {"type": "ref/prompt", "name": "p"}, "argument": {"name": "a", "value": "p"}})

func limited(reply: JsonNode): bool =
  reply.hasKey("error") and reply.errorCode == 429

suite "the requests of one sender":

  test "Given a server with the default settings, then it allows 100 requests per second and 20 progress notifications per second":
    let server = completionServer()
    check server.maxRequestsPerSecond == 100
    check server.maxProgressPerSecond == 20

  test "Given a limit of 2 per second, when a client sends three completion requests, then the third is refused and the handler is not run for it":
    for v in SupportedProtocolVersions:
      handled = 0
      let server = completionServer()
      let peer = server.connect(server.attach(), v, session = "a")
      server.maxRequestsPerSecond = 2
      check peer.complete().hasKey("result")
      check peer.complete().hasKey("result")
      let refused = peer.complete()
      check refused.limited
      check not refused.hasKey("result")
      check handled == 2

  test "Given a refused request, then the error says how long to wait":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let peer = server.connect(server.attach(), v, session = "a")
      server.maxRequestsPerSecond = 1
      discard peer.complete()
      let refused = peer.complete()
      check refused.limited
      check refused["error"]["data"]["retryAfterMs"].getInt() > 0
      check refused["error"]["data"]["retryAfterMs"].getInt() <= 1000

  test "Given a limit of 2 per second, when a client of a version with ping sends pings, then the third is refused too":
    for v in legacyVersions():
      let server = completionServer()
      let peer = server.connect(server.attach(), v, session = "a")
      server.maxRequestsPerSecond = 2
      check peer.ask("ping").hasKey("result")
      check peer.ask("ping").hasKey("result")
      check peer.ask("ping").limited

  test "Given a limit of 0, when a client sends many requests, then none is refused":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let peer = server.connect(server.attach(), v, session = "a")
      server.maxRequestsPerSecond = 0
      for _ in 1 .. 150:
        check not peer.complete().limited

  test "Given a limit of 2 per second and a client that has used it up, when it waits, then it is answered again":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let peer = server.connect(server.attach(), v, session = "a")
      server.maxRequestsPerSecond = 2
      discard peer.complete()
      discard peer.complete()
      check peer.complete().limited
      waitFor sleepAsync(1500)
      check peer.complete().hasKey("result")

  test "Given two sessions, when one has used its allowance, then the other is still answered":
    for v in legacyVersions():
      let server = completionServer()
      let t = server.attach()
      let first = server.connect(t, v, session = "a")
      let second = server.connect(t, v, session = "b")
      server.maxRequestsPerSecond = 2
      discard first.complete()
      discard first.complete()
      check first.complete().limited
      check second.complete().hasKey("result")

# A transport that names a principal for each message, as Streamable HTTP
# does behind an authorization hook.

type
  PrincipalTransport = ref object of McpTransport
    inbox: Deque[McpIncoming]
    waiters: Deque[Future[McpIncoming]]
    answers: seq[JsonNode]

method receive(t: PrincipalTransport): Future[McpIncoming] {.async.} =
  if t.inbox.len > 0:
    return t.inbox.popFirst()
  let waiter = newFuture[McpIncoming]("PrincipalTransport.receive")
  t.waiters.addLast(waiter)
  return await waiter

method receiveMessage(t: PrincipalTransport): Future[JsonNode] {.async.} =
  return (await t.receive()).message

method sendResponse(t: PrincipalTransport, response: JsonRpcResponse): Future[void] {.async.} =
  t.answers.add parseJson(encodeMessage(response))

method close(t: PrincipalTransport): Future[void] {.async.} =
  discard

proc complete(t: PrincipalTransport, session, principal: string, peer = ""): JsonNode =
  let id = freshId()
  let incoming = McpIncoming(
    message: rpcRequest(id, "completion/complete", %*{
      "ref": {"type": "ref/prompt", "name": "p"}, "argument": {"name": "a", "value": "p"},
      "_meta": modernMeta()}),
    session: session, principal: (if principal.len > 0: some(principal) else: none(string)),
    peer: peer)
  if t.waiters.len > 0:
    t.waiters.popFirst().complete(incoming)
  else:
    t.inbox.addLast(incoming)
  untilTrue("the answer to " & id, proc(): bool =
    for a in t.answers:
      if a{"id"}.getStr() == id:
        return true
    false)
  for a in t.answers:
    if a{"id"}.getStr() == id:
      return a

suite "the principal of a request":

  test "Given a limit of 2 per second, when one principal uses two sessions, then they share one allowance and another principal has its own":
    let server = completionServer()
    let t = PrincipalTransport(kind: mtkStreamable, inbox: initDeque[McpIncoming](),
                               waiters: initDeque[Future[McpIncoming]]())
    waitFor server.attachTransport(t)
    server.maxRequestsPerSecond = 2
    check t.complete("s1", "alice").hasKey("result")
    check t.complete("s2", "alice").hasKey("result")
    check t.complete("s3", "alice").limited
    check t.complete("s1", "bob").hasKey("result")

  test "Given a limit of 2 senders, when a third sender speaks, then the sender quiet longest is forgotten and has its full allowance again":
    let server = completionServer()
    let t = PrincipalTransport(kind: mtkStreamable, inbox: initDeque[McpIncoming](),
                               waiters: initDeque[Future[McpIncoming]]())
    waitFor server.attachTransport(t)
    server.maxRequestsPerSecond = 1
    server.maxRateLimitedSenders = 2
    check t.complete("s", "alice").hasKey("result")
    check t.complete("s", "alice").limited
    check t.complete("s", "bob").hasKey("result")
    check t.complete("s", "carol").hasKey("result")
    check t.complete("s", "alice").hasKey("result")

suite "the address of a request":

  proc anonymousServer(): tuple[server: McpServer, transport: PrincipalTransport] =
    let server = completionServer()
    let t = PrincipalTransport(kind: mtkStreamable, inbox: initDeque[McpIncoming](),
                               waiters: initDeque[Future[McpIncoming]]())
    waitFor server.attachTransport(t)
    server.maxRequestsPerSecond = 2
    (server, t)

  test "Given requests without a principal and without a session, when they come from different addresses, then each address has its own allowance":
    let (_, t) = anonymousServer()
    check t.complete("", "", "10.0.0.1").hasKey("result")
    check t.complete("", "", "10.0.0.1").hasKey("result")
    check t.complete("", "", "10.0.0.1").limited
    check t.complete("", "", "10.0.0.2").hasKey("result")
    check t.complete("", "", "2001:db8::1").hasKey("result")

  test "Given requests without a principal and without a session, when they come from one address, then they share one allowance":
    let (_, t) = anonymousServer()
    check t.complete("", "", "10.0.0.1").hasKey("result")
    check t.complete("", "", "10.0.0.1").hasKey("result")
    check t.complete("", "", "10.0.0.1").limited

  test "Given a request with a session, when its address is another one, then the session still decides":
    let (_, t) = anonymousServer()
    check t.complete("s1", "", "10.0.0.1").hasKey("result")
    check t.complete("s1", "", "10.0.0.2").hasKey("result")
    check t.complete("s1", "", "10.0.0.3").limited

  test "Given requests without an address, a principal or a session, as on stdio, then the connection is the one sender":
    let (_, t) = anonymousServer()
    check t.complete("", "").hasKey("result")
    check t.complete("", "").hasKey("result")
    check t.complete("", "").limited

  test "Given a Streamable HTTP server of 2026-07-28 without authorization, when two connections from one address make three requests, then the third is refused":
    if not isModern(DefaultProtocolVersion):
      skip()
    else:
      let server = completionServer()
      let transport = newHttpServerTransport(port = 0, protocolVersion = mpv20260728)
      transport.listen()
      asyncCheck transport.serve()
      waitFor server.attachTransport(transport)
      server.maxRequestsPerSecond = 2
      let url = "http://127.0.0.1:" & $transport.port & "/mcp"
      let body = $(%*{"jsonrpc": "2.0", "id": 1, "method": "completion/complete",
        "params": {"ref": {"type": "ref/prompt", "name": "p"},
                   "argument": {"name": "a", "value": "p"},
                   "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                             "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "0"},
                             "io.modelcontextprotocol/clientCapabilities": {}}}})
      proc post(): JsonNode =
        let http = newAsyncHttpClient()
        defer: http.close()
        let response = waitFor http.request(url, HttpPost, body, newHttpHeaders({
          "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
          "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "completion/complete"}))
        parseJson(waitFor response.body)
      check post().hasKey("result")
      check post().hasKey("result")
      check post().limited

suite "the code of the refusal":

  test "Given the error of a refused request, then its code is outside the range JSON-RPC and MCP reserve":
    check ErrRateLimited < -32768 or ErrRateLimited > -32000
    check ErrRateLimited == 429

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-request-rate-fix-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

suite "the record of a sender over its allowance":

  # A sender that keeps sending is allowed a request now and then as its
  # allowance fills; were each of those to start the record anew, the flood
  # would write a line for every one of them.
  test "Given a sender that keeps sending over its allowance, when requests pass now and then, then stderr says it once":
    let server = completionServer()
    let peer = server.connect(server.attach(), SupportedProtocolVersions[^1], session = "a")
    server.maxRequestsPerSecond = 5
    var allowed = 0
    var refused = 0
    let log = loggedWhile(proc() =
      for i in 0 ..< 60:
        if peer.complete().limited: inc refused else: inc allowed
        waitFor sleepAsync(20))
    checkpoint "stderr: " & log.escape
    check allowed > 5   # the allowance filled while the sender kept sending
    check refused > 0
    check log.count("requests per second") == 1

  test "Given a sender that was over its allowance, when it has been quiet until the allowance is full and goes over again, then stderr says it again":
    let server = completionServer()
    let peer = server.connect(server.attach(), SupportedProtocolVersions[^1], session = "a")
    server.maxRequestsPerSecond = 5
    let log = loggedWhile(proc() =
      for i in 0 ..< 7: discard peer.complete()
      waitFor sleepAsync(1200)
      for i in 0 ..< 7: discard peer.complete())
    checkpoint "stderr: " & log.escape
    check log.count("requests per second") == 2
