## The server limits how fast one sender may make requests (completion: "Rate
## limit completion requests", "Implement appropriate rate limiting"; tasks:
## "receivers SHOULD implement rate limiting on task operations"). A sender is
## the principal the transport's authorization names, else the session, else
## the whole connection. A request beyond the allowance is answered with
## ErrRateLimited and no handler runs; the table of senders has a size.
##
## The allowance fills as time passes, so a request is over it only when it
## comes soon enough after the ones before it. Each test that expects a
## refusal measures that its requests came within that time and repeats the
## run with a fresh server when they did not (a loaded machine); it never
## takes a slow run as evidence either way.

import std/[unittest, asyncdispatch, httpclient, json, options, deques, os, strutils,
            monotimes, times]
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

type
  Seen = seq[(string, bool)]
    ## What one run observed, each with what it means.
  Run = tuple[took: Duration, seen: Seen]
    ## How long the requests that must come quickly took, and what was seen.

const Runs = 5

func windowOf(perSecond: int): Duration =
  ## How long an allowance of `perSecond` takes to regain one request.
  initDuration(milliseconds = 1000 div perSecond)

proc quickRun(perSecond: int, run: proc(): Run): Seen =
  ## What `run` saw, from a run whose timed requests all came within the
  ## window of `perSecond`. Slower runs are repeated; when none of `Runs` is
  ## quick enough the test fails, since nothing was learned about the limit.
  var took: seq[Duration]
  for _ in 1 .. Runs:
    let r = run()
    if r.took < windowOf(perSecond):
      return r.seen
    took.add r.took
  raise newException(AssertionDefect, "no run sent its requests within " &
    $windowOf(perSecond) & "; they took " & $took)

template checkAll(seen: Seen) =
  for (what, held) in seen:
    checkpoint what
    check held

suite "the requests of one sender":

  test "Given a server with the default settings, then it allows 100 requests per second and 20 progress notifications per second":
    let server = completionServer()
    check server.maxRequestsPerSecond == 100
    check server.maxProgressPerSecond == 20

  test "Given a limit of 2 per second, when a client sends three completion requests, then the third is refused and the handler is not run for it":
    for v in SupportedProtocolVersions:
      let version = v
      checkAll quickRun(2, proc(): Run =
        handled = 0
        let server = completionServer()
        let peer = server.connect(server.attach(), version, session = "a")
        server.maxRequestsPerSecond = 2
        let start = getMonoTime()
        let first = peer.complete()
        let second = peer.complete()
        let refused = peer.complete()
        (getMonoTime() - start, @[
          ($version & ": the first is answered", first.hasKey("result")),
          ($version & ": the second is answered", second.hasKey("result")),
          ($version & ": the third is refused", refused.limited),
          ($version & ": the third has no result", not refused.hasKey("result")),
          ($version & ": the handler ran twice", handled == 2)]))

  test "Given a refused request, then the error says how long to wait":
    for v in SupportedProtocolVersions:
      let version = v
      checkAll quickRun(1, proc(): Run =
        let server = completionServer()
        let peer = server.connect(server.attach(), version, session = "a")
        server.maxRequestsPerSecond = 1
        let start = getMonoTime()
        discard peer.complete()
        let refused = peer.complete()
        let wait = refused{"error", "data", "retryAfterMs"}.getInt()
        (getMonoTime() - start, @[
          ($version & ": the second is refused", refused.limited),
          ($version & ": the wait is above 0 ms", wait > 0),
          ($version & ": the wait is at most 1000 ms", wait <= 1000)]))

  test "Given a limit of 2 per second, when a client of a version with ping sends pings, then the third is refused too":
    for v in legacyVersions():
      let version = v
      checkAll quickRun(2, proc(): Run =
        let server = completionServer()
        let peer = server.connect(server.attach(), version, session = "a")
        server.maxRequestsPerSecond = 2
        let start = getMonoTime()
        let first = peer.ask("ping")
        let second = peer.ask("ping")
        let third = peer.ask("ping")
        (getMonoTime() - start, @[
          ($version & ": the first ping is answered", first.hasKey("result")),
          ($version & ": the second ping is answered", second.hasKey("result")),
          ($version & ": the third ping is refused", third.limited)]))

  test "Given a limit of 0, when a client sends many requests, then none is refused":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let peer = server.connect(server.attach(), v, session = "a")
      server.maxRequestsPerSecond = 0
      for _ in 1 .. 150:
        check not peer.complete().limited

  test "Given a limit of 2 per second and a client that has used it up, when it waits, then it is answered again":
    for v in SupportedProtocolVersions:
      let version = v
      checkAll quickRun(2, proc(): Run =
        let server = completionServer()
        let peer = server.connect(server.attach(), version, session = "a")
        server.maxRequestsPerSecond = 2
        let start = getMonoTime()
        discard peer.complete()
        discard peer.complete()
        let third = peer.complete()
        let took = getMonoTime() - start
        waitFor sleepAsync(1500)
        let later = peer.complete()
        (took, @[
          ($version & ": the third is refused", third.limited),
          ($version & ": after the wait it is answered", later.hasKey("result"))]))

  test "Given two sessions, when one has used its allowance, then the other is still answered":
    for v in legacyVersions():
      let version = v
      checkAll quickRun(2, proc(): Run =
        let server = completionServer()
        let t = server.attach()
        let first = server.connect(t, version, session = "a")
        let second = server.connect(t, version, session = "b")
        server.maxRequestsPerSecond = 2
        let start = getMonoTime()
        discard first.complete()
        discard first.complete()
        let third = first.complete()
        let took = getMonoTime() - start
        let other = second.complete()
        (took, @[
          ($version & ": the first session's third is refused", third.limited),
          ($version & ": the other session is answered", other.hasKey("result"))]))

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

proc principalServer(perSecond: int): PrincipalTransport =
  let server = completionServer()
  result = PrincipalTransport(kind: mtkStreamable, inbox: initDeque[McpIncoming](),
                              waiters: initDeque[Future[McpIncoming]]())
  waitFor server.attachTransport(result)
  server.maxRequestsPerSecond = perSecond

suite "the principal of a request":

  test "Given a limit of 2 per second, when one principal uses two sessions, then they share one allowance and another principal has its own":
    checkAll quickRun(2, proc(): Run =
      let t = principalServer(2)
      let start = getMonoTime()
      let first = t.complete("s1", "alice")
      let second = t.complete("s2", "alice")
      let third = t.complete("s3", "alice")
      let took = getMonoTime() - start
      let bob = t.complete("s1", "bob")
      (took, @[
        ("alice's first is answered", first.hasKey("result")),
        ("alice's second, in another session, is answered", second.hasKey("result")),
        ("alice's third, in a third session, is refused", third.limited),
        ("bob is answered", bob.hasKey("result"))]))

  test "Given a limit of 2 senders, when a third sender speaks, then the sender quiet longest is forgotten and has its full allowance again":
    checkAll quickRun(1, proc(): Run =
      let server = completionServer()
      let t = PrincipalTransport(kind: mtkStreamable, inbox: initDeque[McpIncoming](),
                                 waiters: initDeque[Future[McpIncoming]]())
      waitFor server.attachTransport(t)
      server.maxRequestsPerSecond = 1
      server.maxRateLimitedSenders = 2
      let start = getMonoTime()
      let first = t.complete("s", "alice")
      let second = t.complete("s", "alice")
      let took = getMonoTime() - start
      let bob = t.complete("s", "bob")
      let carol = t.complete("s", "carol")
      let again = t.complete("s", "alice")
      (took, @[
        ("alice's first is answered", first.hasKey("result")),
        ("alice's second is refused", second.limited),
        ("bob is answered", bob.hasKey("result")),
        ("carol is answered", carol.hasKey("result")),
        ("alice, forgotten, is answered again", again.hasKey("result"))]))

suite "the address of a request":

  test "Given requests without a principal and without a session, when they come from different addresses, then each address has its own allowance":
    checkAll quickRun(2, proc(): Run =
      let t = principalServer(2)
      let start = getMonoTime()
      let first = t.complete("", "", "10.0.0.1")
      let second = t.complete("", "", "10.0.0.1")
      let third = t.complete("", "", "10.0.0.1")
      let took = getMonoTime() - start
      let other = t.complete("", "", "10.0.0.2")
      let v6 = t.complete("", "", "2001:db8::1")
      (took, @[
        ("10.0.0.1's first is answered", first.hasKey("result")),
        ("10.0.0.1's second is answered", second.hasKey("result")),
        ("10.0.0.1's third is refused", third.limited),
        ("10.0.0.2 is answered", other.hasKey("result")),
        ("2001:db8::1 is answered", v6.hasKey("result"))]))

  test "Given requests without a principal and without a session, when they come from one address, then they share one allowance":
    checkAll quickRun(2, proc(): Run =
      let t = principalServer(2)
      let start = getMonoTime()
      let first = t.complete("", "", "10.0.0.1")
      let second = t.complete("", "", "10.0.0.1")
      let third = t.complete("", "", "10.0.0.1")
      (getMonoTime() - start, @[
        ("the first is answered", first.hasKey("result")),
        ("the second is answered", second.hasKey("result")),
        ("the third is refused", third.limited)]))

  test "Given a request with a session, when its address is another one, then the session still decides":
    checkAll quickRun(2, proc(): Run =
      let t = principalServer(2)
      let start = getMonoTime()
      let first = t.complete("s1", "", "10.0.0.1")
      let second = t.complete("s1", "", "10.0.0.2")
      let third = t.complete("s1", "", "10.0.0.3")
      (getMonoTime() - start, @[
        ("the first is answered", first.hasKey("result")),
        ("the second, from another address, is answered", second.hasKey("result")),
        ("the third, from a third address, is refused", third.limited)]))

  test "Given requests without an address, a principal or a session, as on stdio, then the connection is the one sender":
    checkAll quickRun(2, proc(): Run =
      let t = principalServer(2)
      let start = getMonoTime()
      let first = t.complete("", "")
      let second = t.complete("", "")
      let third = t.complete("", "")
      (getMonoTime() - start, @[
        ("the first is answered", first.hasKey("result")),
        ("the second is answered", second.hasKey("result")),
        ("the third is refused", third.limited)]))

  test "Given a Streamable HTTP server of 2026-07-28 without authorization, when two connections from one address make three requests, then the third is refused":
    if not isModern(DefaultProtocolVersion):
      skip()
    else:
      let body = $(%*{"jsonrpc": "2.0", "id": 1, "method": "completion/complete",
        "params": {"ref": {"type": "ref/prompt", "name": "p"},
                   "argument": {"name": "a", "value": "p"},
                   "_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                             "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "0"},
                             "io.modelcontextprotocol/clientCapabilities": {}}}})
      checkAll quickRun(2, proc(): Run =
        let server = completionServer()
        let transport = newHttpServerTransport(port = 0, protocolVersion = mpv20260728)
        transport.listen()
        asyncCheck transport.serve()
        waitFor server.attachTransport(transport)
        server.maxRequestsPerSecond = 2
        let url = "http://127.0.0.1:" & $transport.port & "/mcp"
        proc post(): JsonNode =
          let http = newAsyncHttpClient()
          defer: http.close()
          let response = waitFor http.request(url, HttpPost, body, newHttpHeaders({
            "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "completion/complete"}))
          parseJson(waitFor response.body)
        let start = getMonoTime()
        let first = post()
        let second = post()
        let third = post()
        let took = getMonoTime() - start
        waitFor transport.close()
        (took, @[
          ("the first is answered", first.hasKey("result")),
          ("the second is answered", second.hasKey("result")),
          ("the third is refused", third.limited)]))

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
    # The given holds only when the sender outpaces its allowance, which a
    # loaded machine may not let it do: such a run is repeated.
    var observed = false
    for _ in 1 .. Runs:
      let server = completionServer()
      let peer = server.connect(server.attach(), SupportedProtocolVersions[^1], session = "a")
      server.maxRequestsPerSecond = 5
      var allowed = 0
      var refused = 0
      let log = loggedWhile(proc() =
        for i in 0 ..< 60:
          if peer.complete().limited: inc refused else: inc allowed
          waitFor sleepAsync(20))
      if refused > 0 and allowed > 5:
        checkpoint "stderr: " & log.escape
        check log.count("requests per second") == 1
        observed = true
        break
      checkpoint "a run with " & $allowed & " allowed and " & $refused & " refused"
    check observed

  test "Given a sender that was over its allowance, when it has been quiet until the allowance is full and goes over again, then stderr says it again":
    var observed = false
    for _ in 1 .. Runs:
      let server = completionServer()
      let peer = server.connect(server.attach(), SupportedProtocolVersions[^1], session = "a")
      server.maxRequestsPerSecond = 5
      var refusedFirst = 0
      var refusedSecond = 0
      let log = loggedWhile(proc() =
        for i in 0 ..< 7:
          if peer.complete().limited: inc refusedFirst
        waitFor sleepAsync(1200)
        for i in 0 ..< 7:
          if peer.complete().limited: inc refusedSecond)
      if refusedFirst > 0 and refusedSecond > 0:
        checkpoint "stderr: " & log.escape
        check log.count("requests per second") == 2
        observed = true
        break
      checkpoint "a run with " & $refusedFirst & " and " & $refusedSecond & " refused"
    check observed
