## Requests of the server to the client before 2026-07-28: sampling, roots,
## ping, and what happens when the client does not, or cannot, answer.

import std/[unittest, asyncdispatch, json, options]
import transport/transport
import ./server_harness

const Legacy = DefaultProtocolVersion.min(mpv20251125)

let
  SamplingAndRoots = %*{"sampling": {}, "roots": {"listChanged": true}}
  Params = %*{"messages": [], "maxTokens": 5}

proc requestServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    let answer = await ctx.createMessage(%*{
      "messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}],
      "maxTokens": 10})
    return %*{"content": [{"type": "text", "text": answer["content"]["text"].getStr()}]})

proc awaitRequest(t: SessionedTransport, methodName: string, session = ""): Sent =
  untilTrue("the server's " & methodName, proc(): bool =
    for s in t.messagesOf(methodName):
      if s.session == session:
        return true
    false)
  for s in t.messagesOf(methodName):
    if s.session == session:
      return s

proc answer(t: SessionedTransport, asked: Sent, resultNode: JsonNode) =
  t.inject(asked.session, %*{"jsonrpc": "2.0", "id": asked.message["id"], "result": resultNode})

proc fail(t: SessionedTransport, asked: Sent, code: int, message: string) =
  t.inject(asked.session, %*{"jsonrpc": "2.0", "id": asked.message["id"],
                             "error": {"code": code, "message": message}})

suite "requests of the server (before 2026-07-28)":

  test "Given a client that can sample, when the server asks for a message, then the request names the session and the result comes back":
    for v in versionsWith(ftServerInitiatedRequests):
      let server = requestServer()
      let t = server.attach()
      discard server.connect(t, v, session = "s", clientCapabilities = SamplingAndRoots)
      let pending = server.createMessage("s", Params)
      let asked = t.awaitRequest("sampling/createMessage", "s")
      check asked.message["params"] == Params
      check asked.message["jsonrpc"].getStr() == "2.0"
      t.answer(asked, %*{"role": "assistant", "content": {"type": "text", "text": "hello"}})
      check waitFor(pending)["content"]["text"].getStr() == "hello"

  test "Given a client with roots, when the server lists them, then the roots come back":
    let server = requestServer()
    let t = server.attach()
    discard server.connect(t, Legacy, clientCapabilities = SamplingAndRoots)
    let pending = server.listRoots()
    let asked = t.awaitRequest("roots/list")
    t.answer(asked, %*{"roots": [{"uri": "file:///home", "name": "Home"}]})
    check waitFor(pending)[0]["uri"].getStr() == "file:///home"

  test "Given a client that answers roots/list without a roots array, when the server lists them, then McpRemoteError is raised":
    for answer in [newJObject(), %*{"roots": "file:///home"}, %*{"roots": nil}]:
      let server = requestServer()
      let t = server.attach()
      discard server.connect(t, Legacy, clientCapabilities = SamplingAndRoots)
      let pending = server.listRoots()
      t.answer(t.awaitRequest("roots/list"), answer)
      expect McpRemoteError:
        discard waitFor pending

  test "Given a client, when the server pings it, then the ping completes on the empty result":
    for v in versionsWith(ftServerInitiatedRequests):
      let server = requestServer()
      let t = server.attach()
      discard server.connect(t, v)
      let pending = server.ping()
      t.answer(t.awaitRequest("ping"), newJObject())
      waitFor pending

  test "Given a client without the sampling or roots capability, when the server asks, then it raises and sends nothing":
    let server = requestServer()
    let t = server.attach()
    discard server.connect(t, Legacy)
    expect McpCapabilityError:
      discard waitFor server.createMessage("", Params)
    expect McpCapabilityError:
      discard waitFor server.listRoots()
    check t.messagesOf("sampling/createMessage").len == 0
    check t.messagesOf("roots/list").len == 0

  test "Given a client that answers with an error, when the server asks, then McpRemoteError carries its code":
    let server = requestServer()
    let t = server.attach()
    discard server.connect(t, Legacy, clientCapabilities = SamplingAndRoots)
    let pending = server.createMessage("", Params)
    t.fail(t.awaitRequest("sampling/createMessage"), -1, "User rejected sampling request")
    var code = 0
    try:
      discard waitFor pending
    except McpRemoteError as e:
      code = e.code
    check code == -1

  test "Given a client that never answers, when the timeout passes, then McpRequestTimeout is raised and the request is cancelled":
    let server = requestServer()
    let t = server.attach()
    discard server.connect(t, Legacy, clientCapabilities = SamplingAndRoots)
    let pending = server.request("", "sampling/createMessage", Params, timeoutMs = 30)
    let asked = t.awaitRequest("sampling/createMessage")
    expect McpRequestTimeout:
      discard waitFor pending
    let cancelled = t.messagesOf("notifications/cancelled")
    check cancelled.len == 1
    check cancelled[0].message["params"]["requestId"] == asked.message["id"]

  test "Given a late answer after the timeout, when it arrives, then it is ignored and the server goes on":
    let server = requestServer()
    let t = server.attach()
    let peer = server.connect(t, Legacy, clientCapabilities = SamplingAndRoots)
    let pending = server.request("", "ping", newJObject(), timeoutMs = 20)
    let asked = t.awaitRequest("ping")
    expect McpRequestTimeout:
      discard waitFor pending
    t.answer(asked, newJObject())
    settle()
    check peer.ask("ping").hasKey("result")

  test "Given a session that ends while the server waits, when it ends, then the wait fails":
    let server = requestServer()
    let t = server.attach()
    discard server.connect(t, Legacy, session = "s", clientCapabilities = SamplingAndRoots)
    let pending = server.createMessage("s", Params)
    discard t.awaitRequest("sampling/createMessage", "s")
    server.endSession("s")
    expect McpTransportClosedError:
      discard waitFor pending

  test "Given a transport that closes while the server waits, when it closes, then the wait fails and in-flight requests are cancelled":
    let server = requestServer()
    let t = server.attach()
    discard server.connect(t, Legacy, clientCapabilities = SamplingAndRoots)
    let pending = server.createMessage("", Params)
    discard t.awaitRequest("sampling/createMessage")
    t.hangUp()
    expect McpTransportClosedError:
      discard waitFor pending

  test "Given requests to two clients, when they answer in the other order, then each request gets its own answer":
    let server = requestServer()
    let t = server.attach()
    discard server.connect(t, Legacy, session = "a", clientCapabilities = SamplingAndRoots)
    discard server.connect(t, Legacy, session = "b", clientCapabilities = SamplingAndRoots)
    let forA = server.createMessage("a", Params)
    let forB = server.createMessage("b", Params)
    let askedA = t.awaitRequest("sampling/createMessage", "a")
    let askedB = t.awaitRequest("sampling/createMessage", "b")
    check askedA.message["id"] != askedB.message["id"]
    t.answer(askedB, %*{"who": "b"})
    t.answer(askedA, %*{"who": "a"})
    check waitFor(forA)["who"].getStr() == "a"
    check waitFor(forB)["who"].getStr() == "b"

  test "Given a client that has not sent initialized, when the server asks, then it raises":
    let server = requestServer()
    let t = server.attach()
    let id = freshId()
    t.inject("s", rpcRequest(id, "initialize", %*{
      "protocolVersion": $Legacy, "capabilities": {"sampling": {}},
      "clientInfo": {"name": "c", "version": "1"}}))
    discard t.responseTo(id)
    expect McpCapabilityError:
      discard waitFor server.createMessage("s", Params)

  test "Given a response to a request nobody sent, when it arrives, then the server ignores it":
    let server = requestServer()
    let t = server.attach()
    let peer = server.connect(t, Legacy)
    t.inject("", %*{"jsonrpc": "2.0", "id": "srv-999", "result": {}})
    settle()
    check peer.ask("ping").hasKey("result")

  test "Given a handler that asks the client, when a tool is called, then the request belongs to the tool call and its answer becomes the tool result":
    for v in versionsWith(ftServerInitiatedRequests):
      let server = requestServer()
      let t = server.attach()
      let peer = server.connect(t, v, clientCapabilities = SamplingAndRoots)
      let callId = freshId()
      peer.send(%callId, "tools/call", %*{"name": "summarize"})
      let asked = t.awaitRequest("sampling/createMessage")
      check asked.related == callId
      t.answer(asked, %*{"content": {"type": "text", "text": "a summary"}})
      check textOf(t.responseTo(callId)) == "a summary"

suite "requests of the server that belong to a task":

  proc connected(): tuple[server: McpServer, t: SessionedTransport] =
    let server = requestServer()
    let t = server.attach()
    discard server.connect(t, Legacy, clientCapabilities = SamplingAndRoots)
    (server, t)

  test "Given a request with no time limit, when the client answers after a while, then the answer is returned":
    let (server, t) = connected()
    let pending = server.request("", "ping", newJObject(), timeoutMs = 0)
    let asked = t.awaitRequest("ping")
    settle()
    check not pending.finished
    t.answer(asked, newJObject())
    check waitFor(pending).result.isSome

  test "Given no hold hook, when a request names a task, then it is sent at once":
    let (server, t) = connected()
    let pending = server.request("", "ping", newJObject(), relatedTask = "t1", timeoutMs = 0)
    let asked = t.awaitRequest("ping")
    check asked.message["params"]["_meta"]["io.modelcontextprotocol/related-task"]["taskId"].getStr() == "t1"
    t.answer(asked, newJObject())
    discard waitFor pending

  test "Given a hold hook that declines, when a request names a task, then it is sent at once":
    let (server, t) = connected()
    var asked: seq[string]
    server.holdForTask = proc(taskId: string, request: JsonRpcRequest): bool =
      asked.add taskId
      false
    let pending = server.request("", "ping", newJObject(), relatedTask = "t1", timeoutMs = 0)
    let sent = t.awaitRequest("ping")
    check asked == @["t1"]
    t.answer(sent, newJObject())
    discard waitFor pending

  test "Given a hold hook that keeps, when a request names a task and a request of the client, then it is sent at once on that request and the hook is not asked":
    let (server, t) = connected()
    var asked = 0
    server.holdForTask = proc(taskId: string, request: JsonRpcRequest): bool =
      inc asked
      true
    let pending = server.request("", "ping", newJObject(), "call-1", timeoutMs = 0, relatedTask = "t1")
    let sent = t.awaitRequest("ping")
    check sent.related == "call-1"
    check asked == 0
    t.answer(sent, newJObject())
    discard waitFor pending

  test "Given a hold hook that keeps, when a request names no task, then it is sent at once and the hook is not asked":
    let (server, t) = connected()
    var asked = 0
    server.holdForTask = proc(taskId: string, request: JsonRpcRequest): bool =
      inc asked
      true
    let pending = server.request("", "ping", newJObject(), timeoutMs = 0)
    let sent = t.awaitRequest("ping")
    check asked == 0
    t.answer(sent, newJObject())
    discard waitFor pending

  test "Given a hold hook that keeps, when a request names a task only, then it waits until sendHeld puts it on the stream of a tasks/result request":
    let (server, t) = connected()
    var held: JsonRpcRequest
    server.holdForTask = proc(taskId: string, request: JsonRpcRequest): bool =
      held = request
      true
    let pending = server.request("", "ping", newJObject(), relatedTask = "t1", timeoutMs = 0)
    settle()
    check t.messagesOf("ping").len == 0
    check held.id.len > 0
    waitFor server.sendHeld(held, "result-1")
    let sent = t.awaitRequest("ping")
    check sent.related == "result-1"
    check sent.message["id"].getStr() == held.id
    t.answer(sent, newJObject())
    discard waitFor pending

  test "Given a held request whose time ran out, when sendHeld is called for it, then nothing is sent":
    let (server, t) = connected()
    var held: JsonRpcRequest
    server.holdForTask = proc(taskId: string, request: JsonRpcRequest): bool =
      held = request
      true
    let pending = server.request("", "ping", newJObject(), relatedTask = "t1", timeoutMs = 30)
    expect McpRequestTimeout:
      discard waitFor pending
    waitFor server.sendHeld(held, "result-1")
    check t.messagesOf("ping").len == 0

  test "Given a hold hook that refuses, when a request names a task, then the refusal is raised, nothing is sent, and sendHeld for it sends nothing":
    let (server, t) = connected()
    var held: JsonRpcRequest
    server.holdForTask = proc(taskId: string, request: JsonRpcRequest): bool =
      held = request
      raise newException(McpCapabilityError, "the task cannot ask")
    expect McpCapabilityError:
      discard waitFor server.request("", "ping", newJObject(), relatedTask = "t1")
    waitFor server.sendHeld(held, "result-1")
    check t.messagesOf("ping").len == 0

if isModern(DefaultProtocolVersion):
  suite "requests of the server in 2026-07-28":

    test "Given a 2026-07-28 client, when the server asks for a message, then it raises and sends nothing":
      let server = requestServer()
      let t = server.attach()
      discard server.connect(t, mpv20260728)
      expect McpCapabilityError:
        discard waitFor server.createMessage("", Params)
      expect McpCapabilityError:
        waitFor server.ping()
      check t.sent.len == 0

    test "Given a handler that asks the client, when a 2026-07-28 tool call arrives, then the call fails and no request is sent":
      let server = requestServer()
      let t = server.attach()
      let reply = server.connect(t, mpv20260728).ask("tools/call", %*{"name": "summarize"})
      check reply.errorCode == -32603
      check t.messagesOf("sampling/createMessage").len == 0
