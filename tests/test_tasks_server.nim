## Tasks on the server side (2025-11-25, basic/utilities/tasks): what a client
## sees when it augments a tools/call with a task, and polls, waits, lists and
## cancels. Only 2025-11-25 has tasks in the core; 2026-07-28 and the versions
## before 2025-11-25 must behave as if the feature did not exist.

import std/[asyncdispatch, json, options, os, strutils, unittest]
import ./server_harness
import protocol/tasks
import server/tasks

const
  TaskVersion = mpv20251125
  RelatedTask = "io.modelcontextprotocol/related-task"

type
  FakeTime = ref object
    nowMs: int64

  Fixture = ref object
    server: McpServer
    store: TaskStore
    transport: SessionedTransport
    time: FakeTime
    gate: Future[void]
      ## What the tool "slow" waits for.
    sawCancel: bool
    sampled: Future[JsonNode]

proc tool(name, taskSupport: string): JsonNode =
  result = %*{"name": name, "inputSchema": {"type": "object"}}
  if taskSupport.len > 0:
    result["execution"] = %*{"taskSupport": taskSupport}

proc textResult(text: string): JsonNode =
  %*{"content": [{"type": "text", "text": text}]}

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-tasks-server-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc fixture(config = TaskConfig(), withCapability = true, maxActive = 0): Fixture =
  let fx = Fixture(time: FakeTime(nowMs: 1_764_067_800_000), gate: newFuture[void]("gate"))
  fx.server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  fx.server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[
      tool("slow", "optional"), tool("needs_task", "required"),
      tool("never", "forbidden"), tool("plain", ""), tool("quick", "optional"), tool("failing", "optional"),
      tool("broken", "optional"), tool("asks", "optional")]))
  fx.server.onToolCall(proc(ctx: McpRequestContext, name: string,
                            arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "slow", "needs_task":
      await (fx.gate or ctx.whenCancelled())
      if ctx.cancelled:
        fx.sawCancel = true
        ctx.checkCancelled()
      return textResult("slow done")
    of "failing":
      raise newToolFailure("rate limit exceeded")
    of "broken":
      raise newInvalidParams("bad arguments")
    of "asks":
      await fx.gate
      let answer = await ctx.createMessage(%*{"messages": [], "maxTokens": 1})
      fx.sampled.complete(answer)
      return textResult("asked")
    else:  # "plain", "quick", "never"
      return textResult("plain done"))
  fx.sampled = newFuture[JsonNode]("sampled")
  fx.store = newTaskStore(clock = proc(): int64 = fx.time.nowMs, pollIntervalMs = some(250),
                          maxActivePerOwner = maxActive)
  if withCapability:
    discard fx.server.enableTasks(config, fx.store)
  fx.transport = fx.server.attach()
  fx

proc connectTo(fx: Fixture, session = "", version = TaskVersion,
               clientCapabilities: JsonNode = nil): Peer =
  fx.server.connect(fx.transport, version, session, clientCapabilities)

proc asTask(name: string, ttl = 60_000): JsonNode =
  %*{"name": name, "arguments": {}, "task": {"ttl": ttl}}

proc createTask(peer: Peer, name: string, ttl = 60_000): JsonNode =
  let response = peer.ask("tools/call", asTask(name, ttl))
  check not response.hasKey("error")
  response["result"]["task"]

proc taskParams(taskId: string): JsonNode =
  %*{"taskId": taskId}

proc statusOf(peer: Peer, taskId: string): string =
  peer.ask("tasks/get", taskParams(taskId))["result"]["status"].getStr()

proc untilStatus(peer: Peer, taskId, status: string) =
  untilTrue("task " & taskId & " to be " & status, proc(): bool =
    peer.statusOf(taskId) == status)

if isSupported(TaskVersion):
  suite "tasks server: capabilities":
    test "Given tasks enabled, when a 2025-11-25 client handshakes, then the server declares list, cancel and tools/call":
      let fx = fixture()
      let id = freshId()
      fx.transport.inject("", rpcRequest(id, "initialize", %*{
        "protocolVersion": $TaskVersion, "capabilities": {},
        "clientInfo": {"name": "c", "version": "1"}}))
      let tasksCapability = fx.transport.responseTo(id)["result"]["capabilities"]["tasks"]
      check tasksCapability == %*{"list": {}, "cancel": {}, "requests": {"tools": {"call": {}}}}

    test "Given a config without list and cancel, when a client handshakes, then they are not declared":
      let fx = fixture(TaskConfig(list: false, cancel: false, toolsCall: true, pageSize: 50))
      let id = freshId()
      fx.transport.inject("", rpcRequest(id, "initialize", %*{
        "protocolVersion": $TaskVersion, "capabilities": {},
        "clientInfo": {"name": "c", "version": "1"}}))
      check fx.transport.responseTo(id)["result"]["capabilities"]["tasks"] ==
        %*{"requests": {"tools": {"call": {}}}}

    test "Given a client of a version before 2025-11-25, when it handshakes, then no tasks capability is declared":
      let fx = fixture()
      for version in versionsWithout(ftTasks):
        if isModern(version):
          continue
        let id = freshId()
        fx.transport.inject("s-" & $version, rpcRequest(id, "initialize", %*{
          "protocolVersion": $version, "capabilities": {},
          "clientInfo": {"name": "c", "version": "1"}}))
        check not fx.transport.responseTo(id)["result"]["capabilities"].hasKey("tasks")




    test "Given a client of an older version, when it calls tasks/get, then the method is unknown":
      let fx = fixture()
      let peer = fx.connectTo(version = mpv20250618)
      check peer.ask("tasks/get", taskParams("anything")).errorCode == -32601

  suite "tasks server: task-augmented tools/call":
    test "Given an optional tool, when called with a task, then the answer is a working task at once":
      let fx = fixture()
      let peer = fx.connectTo()
      let task = peer.createTask("slow", ttl = 30_000)
      check task["status"].getStr() == "working"
      check task["ttl"].getInt() == 30_000
      check task["pollInterval"].getInt() == 250
      check task["createdAt"].getStr() == "2025-11-25T10:50:00.000Z"
      check task["lastUpdatedAt"].getStr() == "2025-11-25T10:50:00.000Z"
      check task["taskId"].getStr().len >= 32

    test "Given a task-augmented call, when it is answered, then the answer holds no tool result":
      let fx = fixture()
      let peer = fx.connectTo()
      let response = peer.ask("tools/call", asTask("quick"))
      check response["result"].hasKey("task")
      check not response["result"].hasKey("content")

    test "Given a server with an immediate response configured, when a task is created, then _meta carries it":
      let fx = fixture(TaskConfig(list: true, cancel: true, toolsCall: true, pageSize: 50,
                                  immediateResponse: "Working on it."))
      let peer = fx.connectTo()
      let response = peer.ask("tools/call", asTask("slow"))
      check response["result"]["_meta"]["io.modelcontextprotocol/model-immediate-response"].getStr() ==
        "Working on it."

    test "Given a call without a task, when the tool is optional, then it is answered with its result":
      let fx = fixture()
      let peer = fx.connectTo()
      fx.gate.complete()
      check peer.ask("tools/call", %*{"name": "slow", "arguments": {}}).textOf == "slow done"

    test "Given a forbidden tool or one without execution, when called with a task, then the method is not found":
      let fx = fixture()
      let peer = fx.connectTo()
      check peer.ask("tools/call", asTask("never")).errorCode == -32601
      check peer.ask("tools/call", asTask("plain")).errorCode == -32601

    test "Given a tool that requires a task, when called without one, then the method is not found":
      let fx = fixture()
      let peer = fx.connectTo()
      check peer.ask("tools/call", %*{"name": "needs_task", "arguments": {}}).errorCode == -32601
      check peer.createTask("needs_task")["status"].getStr() == "working"

    test "Given a server that did not declare tools/call tasks, when a call carries a task, then it runs normally":
      let fx = fixture(TaskConfig(list: true, cancel: true, toolsCall: false, pageSize: 50))
      let peer = fx.connectTo()
      let response = peer.ask("tools/call", asTask("plain"))
      check response.textOf == "plain done"

    test "Given a server without tasks enabled, when a call carries a task, then it runs normally":
      let fx = fixture(withCapability = false)
      let peer = fx.connectTo()
      check peer.ask("tools/call", asTask("plain")).textOf == "plain done"
      check peer.ask("tasks/get", taskParams("x")).errorCode == -32601

    test "Given a client that negotiated an older version, when a call carries a task, then it runs normally":
      let fx = fixture()
      let peer = fx.connectTo(version = mpv20250618)
      check peer.ask("tools/call", asTask("plain")).textOf == "plain done"

    test "Given a task that is not an object, when a call carries it, then it is Invalid params":
      let fx = fixture()
      let peer = fx.connectTo()
      check peer.ask("tools/call", %*{"name": "slow", "task": "yes"}).errorCode == -32602

  suite "tasks server: finding the tool of a task-augmented call":
    test "Given a call that carries a task but no name, when it arrives, then it is Invalid params, as for a plain call":
      let fx = fixture()
      let peer = fx.connectTo()
      check peer.ask("tools/call", %*{"task": {}}).errorCode == -32602
      check peer.ask("tools/call", %*{"name": 5, "task": {}}).errorCode == -32602

    test "Given a tool listed on the second page, when called with a task, then the first page was asked for without a cursor and the task is made":
      var cursors: seq[Option[string]]
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
        cursors.add cursor
        if cursor.isNone:
          return McpPage(items: @[tool("first", "optional")], nextCursor: some("page-2"))
        return McpPage(items: @[tool("second", "optional")]))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        return textResult(name))
      discard server.enableTasks()
      let peer = server.connect(server.attach(), TaskVersion)
      let created = peer.createTask("second")
      check created["status"].getStr() == "working"
      check cursors[0].isNone
      check some("page-2") in cursors

  suite "tasks server: tasks/get and tasks/result":
    test "Given a working task, when polled, then it is working, has no related-task meta and the same id":
      let fx = fixture()
      let peer = fx.connectTo()
      let created = peer.createTask("slow")
      let polled = peer.ask("tasks/get", taskParams(created["taskId"].getStr()))["result"]
      check polled["taskId"] == created["taskId"]
      check polled["status"].getStr() == "working"
      check polled["ttl"].getInt() == 60_000
      check not polled.hasKey("_meta")

    test "Given a task, when polled with related-task meta naming another task, then the taskId param wins":
      let fx = fixture()
      let peer = fx.connectTo()
      let created = peer.createTask("slow")
      let polled = peer.ask("tasks/get", taskParams(created["taskId"].getStr()),
                            meta = %*{RelatedTask: {"taskId": "someone-else"}})["result"]
      check polled["taskId"] == created["taskId"]

    test "Given an unknown or missing taskId, when polled, then it is Invalid params":
      let fx = fixture()
      let peer = fx.connectTo()
      check peer.ask("tasks/get", taskParams("no-such-task")).errorCode == -32602
      check peer.ask("tasks/get", newJObject()).errorCode == -32602
      check peer.ask("tasks/result", taskParams("no-such-task")).errorCode == -32602

    test "Given a task whose tool finished, when polled, then it is completed":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("slow")["taskId"].getStr()
      fx.gate.complete()
      peer.untilStatus(id, "completed")

    test "Given a working task, when its result is requested, then the answer comes when the tool is done, tagged with the task":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("slow")["taskId"].getStr()
      let waiting = freshId()
      peer.send(%waiting, "tasks/result", taskParams(id))
      settle()
      check fx.transport.sent.len > 0
      var answered = false
      for s in fx.transport.sent:
        if s.message{"id"}.getStr() == waiting:
          answered = true
      check not answered
      fx.gate.complete()
      let response = fx.transport.responseTo(waiting)
      check response["result"]["content"][0]["text"].getStr() == "slow done"
      check response["result"]["_meta"][RelatedTask]["taskId"].getStr() == id

    test "Given a tasks/result that waits on a task, when the task ends, then the task no longer names that request as its stream":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("slow")["taskId"].getStr()
      let waiting = freshId()
      peer.send(%waiting, "tasks/result", taskParams(id))
      untilTrue("tasks/result to wait on the task", proc(): bool = fx.store.resultStream(id) == waiting)
      fx.gate.complete()
      discard fx.transport.responseTo(waiting)
      check fx.store.resultStream(id) == ""

    test "Given a completed task, when its result is requested twice, then both answers are the result":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("quick")["taskId"].getStr()
      peer.untilStatus(id, "completed")
      for attempt in 1 .. 2:
        check peer.ask("tasks/result", taskParams(id)).textOf == "plain done"

    test "Given a tool that failed with isError, when polled, then the task failed with the tool's message, and the result is the tool result":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("failing")["taskId"].getStr()
      peer.untilStatus(id, "failed")
      let polled = peer.ask("tasks/get", taskParams(id))["result"]
      check polled["statusMessage"].getStr() == "rate limit exceeded"
      let payload = peer.ask("tasks/result", taskParams(id))
      check not payload.hasKey("error")
      check payload["result"]["isError"].getBool()

    test "Given a call that ended in a JSON-RPC error, when the result is requested, then it is that same error":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("broken")["taskId"].getStr()
      peer.untilStatus(id, "failed")
      let payload = peer.ask("tasks/result", taskParams(id))
      check payload.errorCode == -32602
      check payload["error"]["message"].getStr() == "bad arguments"
      check peer.ask("tasks/get", taskParams(id))["result"]["statusMessage"].getStr() == "bad arguments"

  suite "tasks server: tasks/list":
    test "Given more tasks than a page, when listed page by page, then every task appears once and the last page has no cursor":
      let fx = fixture(TaskConfig(list: true, cancel: true, toolsCall: true, pageSize: 2))
      let peer = fx.connectTo()
      var created: seq[string]
      for _ in 1 .. 5:
        created.add peer.createTask("slow")["taskId"].getStr()
      var seen: seq[string]
      var cursor = ""
      var pages = 0
      while true:
        let params = if cursor.len > 0: %*{"cursor": cursor} else: newJObject()
        let page = peer.ask("tasks/list", params)["result"]
        inc pages
        check page["tasks"].len <= 2
        for item in page["tasks"]:
          seen.add item["taskId"].getStr()
        if not page.hasKey("nextCursor"):
          break
        cursor = page["nextCursor"].getStr()
      check pages == 3
      check seen == created

    test "Given a cursor nobody issued, when listed, then it is Invalid params":
      let fx = fixture()
      let peer = fx.connectTo()
      discard peer.createTask("slow")
      check peer.ask("tasks/list", %*{"cursor": "not-a-cursor"}).errorCode == -32602

    test "Given a task that tasks/get returns, when listed, then it is in the list":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("quick")["taskId"].getStr()
      peer.untilStatus(id, "completed")
      let listed = peer.ask("tasks/list")["result"]["tasks"]
      check id in (block:
        var ids: seq[string]
        for item in listed: ids.add item["taskId"].getStr()
        ids)

    test "Given a server without the list capability, when a client lists, then the method is not found":
      let fx = fixture(TaskConfig(list: false, cancel: true, toolsCall: true, pageSize: 50))
      let peer = fx.connectTo()
      check peer.ask("tasks/list").errorCode == -32601

  suite "tasks server: tasks/cancel":
    test "Given a working task, when cancelled, then the answer is the cancelled task and the tool is told":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("slow")["taskId"].getStr()
      let cancelled = peer.ask("tasks/cancel", taskParams(id))["result"]
      check cancelled["status"].getStr() == "cancelled"
      check cancelled["taskId"].getStr() == id
      check not cancelled.hasKey("_meta")
      untilTrue("the tool to see the cancellation", proc(): bool = fx.sawCancel)

    test "Given a cancelled task, when its tool finishes anyway, then the task stays cancelled":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("slow")["taskId"].getStr()
      discard peer.ask("tasks/cancel", taskParams(id))
      fx.gate.complete()
      settle()
      check peer.statusOf(id) == "cancelled"

    test "Given a cancelled task, when its result is requested, then the answer is a JSON-RPC error":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("slow")["taskId"].getStr()
      discard peer.ask("tasks/cancel", taskParams(id))
      check peer.ask("tasks/result", taskParams(id)).hasKey("error")

    test "Given a task that is over, when cancelled, then it is Invalid params":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("quick")["taskId"].getStr()
      peer.untilStatus(id, "completed")
      let response = peer.ask("tasks/cancel", taskParams(id))
      check response.errorCode == -32602
      check "completed" in response["error"]["message"].getStr()
      check peer.statusOf(id) == "completed"

    test "Given a server without the cancel capability, when a client cancels, then the method is not found":
      let fx = fixture(TaskConfig(list: true, cancel: false, toolsCall: true, pageSize: 50))
      let peer = fx.connectTo()
      let id = peer.createTask("slow")["taskId"].getStr()
      check peer.ask("tasks/cancel", taskParams(id)).errorCode == -32601

  suite "tasks server: notifications":
    test "Given a task, when its status changes, then the owning session is sent the whole task":
      let fx = fixture()
      let peer = fx.connectTo(session = "s1")
      let id = peer.createTask("slow")["taskId"].getStr()
      fx.gate.complete()
      peer.untilStatus(id, "completed")
      let notices = fx.transport.messagesOf("notifications/tasks/status")
      check notices.len >= 1
      let last = notices[^1]
      check last.session == "s1"
      check last.message["params"]["taskId"].getStr() == id
      check last.message["params"]["status"].getStr() == "completed"
      check last.message["params"].hasKey("createdAt")
      check last.message["params"].hasKey("lastUpdatedAt")
      check last.message["params"].hasKey("ttl")
      check not last.message["params"].hasKey("_meta")

    test "Given a session that cannot be reached, when its task changes status, then the failure is logged and the task goes on":
      let fx = fixture()
      let peer = fx.connectTo(session = "alice")
      let id = peer.createTask("slow")["taskId"].getStr()
      fx.transport.failFor = "alice"
      let log = loggedWhile(proc() =
        fx.gate.complete()
        peer.untilStatus(id, "completed")
        settle())
      check "could not send the status of task " & id & " to session 'alice'" in log
      check "no stream for session alice" in log

  suite "tasks server: expiry":
    test "Given a task whose ttl has passed, when polled, then it is gone and tasks/result agrees":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("quick", ttl = 1_000)["taskId"].getStr()
      peer.untilStatus(id, "completed")
      fx.time.nowMs += 1_001
      check peer.ask("tasks/get", taskParams(id)).errorCode == -32602
      check peer.ask("tasks/result", taskParams(id)).errorCode == -32602
      check peer.ask("tasks/list")["result"]["tasks"].len == 0

    test "Given a working task that expires, when the time passes, then its tool is told to stop":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("slow", ttl = 1_000)["taskId"].getStr()
      fx.time.nowMs += 5_000
      check peer.ask("tasks/get", taskParams(id)).errorCode == -32602
      untilTrue("the tool to see the cancellation", proc(): bool = fx.sawCancel)

  suite "tasks server: isolation":
    test "Given a task of one session, when another session asks for it, then it is not found, whatever the operation":
      let fx = fixture()
      let owner = fx.connectTo(session = "alice")
      let other = fx.connectTo(session = "mallory")
      let id = owner.createTask("slow")["taskId"].getStr()
      check other.ask("tasks/get", taskParams(id)).errorCode == -32602
      check other.ask("tasks/result", taskParams(id)).errorCode == -32602
      check other.ask("tasks/cancel", taskParams(id)).errorCode == -32602
      check owner.statusOf(id) == "working"

    test "Given tasks of two sessions, when each lists, then it sees only its own":
      let fx = fixture()
      let alice = fx.connectTo(session = "alice")
      let bob = fx.connectTo(session = "bob")
      let aliceTask = alice.createTask("slow")["taskId"].getStr()
      let bobTask = bob.createTask("slow")["taskId"].getStr()
      check alice.ask("tasks/list")["result"]["tasks"].len == 1
      check alice.ask("tasks/list")["result"]["tasks"][0]["taskId"].getStr() == aliceTask
      check bob.ask("tasks/list")["result"]["tasks"][0]["taskId"].getStr() == bobTask

    test "Given a task of one session, when its status changes, then only that session is notified":
      let fx = fixture()
      let alice = fx.connectTo(session = "alice")
      discard fx.connectTo(session = "bob")
      discard alice.createTask("quick")
      settle()
      for notice in fx.transport.messagesOf("notifications/tasks/status"):
        check notice.session == "alice"

  suite "tasks server: resource limits":
    test "Given a limit of active tasks, when it is reached, then the call fails with an internal error until one ends":
      let fx = fixture(maxActive = 1)
      let peer = fx.connectTo()
      discard peer.createTask("slow")
      check peer.ask("tools/call", asTask("slow")).errorCode == -32603

  suite "tasks server: input_required":
    test "Given a task whose tool asks the client, when it does, then the task needs input, the request names the task, and it works again after the answer":
      let fx = fixture()
      let peer = fx.connectTo(clientCapabilities = %*{"sampling": {}})
      let id = peer.createTask("asks")["taskId"].getStr()
      fx.gate.complete()
      peer.untilStatus(id, "input_required")
      # the question waits for the requestor's tasks/result, as the
      # specification's input_required flow has it
      check fx.transport.messagesOf("sampling/createMessage").len == 0
      let waiting = freshId()
      peer.send(%waiting, "tasks/result", taskParams(id))
      untilTrue("the sampling request", proc(): bool =
        fx.transport.messagesOf("sampling/createMessage").len == 1)
      let request = fx.transport.messagesOf("sampling/createMessage")[0].message
      check fx.transport.messagesOf("sampling/createMessage")[0].related == waiting
      check request["params"]["_meta"][RelatedTask]["taskId"].getStr() == id
      check peer.statusOf(id) == "input_required"
      fx.transport.inject("", %*{"jsonrpc": "2.0", "id": request["id"],
        "result": {"role": "assistant", "content": {"type": "text", "text": "hi"}, "model": "m"}})
      peer.untilStatus(id, "completed")

    test "Given a question waiting for tasks/result, when the task is cancelled, then a later tasks/result does not send it":
      let fx = fixture()
      let peer = fx.connectTo(clientCapabilities = %*{"sampling": {}})
      let id = peer.createTask("asks")["taskId"].getStr()
      fx.gate.complete()
      peer.untilStatus(id, "input_required")
      discard peer.ask("tasks/cancel", taskParams(id))
      check peer.ask("tasks/result", taskParams(id)).hasKey("error")
      settle()
      check fx.transport.messagesOf("sampling/createMessage").len == 0

    test "Given a task that needs input and a waiting tasks/result, when the tool asks, then the request is sent for that tasks/result":
      let fx = fixture()
      let peer = fx.connectTo(clientCapabilities = %*{"sampling": {}})
      let id = peer.createTask("asks")["taskId"].getStr()
      let waiting = freshId()
      # tasks/result arrives before the tool asks: the request belongs to its stream
      peer.send(%waiting, "tasks/result", taskParams(id))
      settle()
      fx.gate.complete()
      untilTrue("the sampling request", proc(): bool =
        fx.transport.messagesOf("sampling/createMessage").len == 1)
      check fx.transport.messagesOf("sampling/createMessage")[0].related == waiting

  proc immediately(): Future[void] =
    result = newFuture[void]("immediately")
    result.complete()

  proc noSleep(ms: int): Future[void] =
    immediately()

  proc clientTask(id, status: string): JsonNode =
    %*{"taskId": id, "status": status, "createdAt": "2025-11-25T10:30:00Z",
       "lastUpdatedAt": "2025-11-25T10:40:00Z", "ttl": 60000, "pollInterval": 100}

  proc answerNext(fx: Fixture, session, methodName: string, nth: int, body: JsonNode) =
    ## Answer the `nth` (from 0) request of the server with this method as the
    ## client of `session` would.
    untilTrue("the " & methodName & " request", proc(): bool =
      fx.transport.messagesOf(methodName).len > nth)
    let request = fx.transport.messagesOf(methodName)[nth].message
    fx.transport.inject(session, %*{"jsonrpc": "2.0", "id": request["id"], "result": body})

  let samplingParams = %*{"messages": [], "maxTokens": 1}
  let samplingTasks = %*{"sampling": {}, "tasks": {"list": {}, "cancel": {}, "requests": {"sampling": {"createMessage": {}}}}}

  suite "tasks server: as the requestor of a task-augmented sampling request":
    test "Given a client that allows tasks on sampling, when the server asks as a task, then it creates, polls and fetches the result":
      let fx = fixture()
      let peer = fx.connectTo(clientCapabilities = samplingTasks)
      let work = fx.server.createMessageAsTask(peer.session, samplingParams,
                                               ttlMs = some(20_000'i64), sleep = noSleep)
      fx.answerNext("", "sampling/createMessage", 0, %*{"task": clientTask("c-1", "working")})
      let created = fx.transport.messagesOf("sampling/createMessage")[0].message["params"]
      check created["task"]["ttl"].getInt() == 20_000
      fx.answerNext("", "tasks/get", 0, clientTask("c-1", "working"))
      fx.answerNext("", "tasks/get", 1, clientTask("c-1", "completed"))
      fx.answerNext("", "tasks/result", 0, %*{"role": "assistant", "model": "m",
        "content": {"type": "text", "text": "hi"}, "_meta": {RelatedTask: {"taskId": "c-1"}}})
      let answer = waitFor work
      check answer["content"]["text"].getStr() == "hi"
      check fx.transport.messagesOf("tasks/get")[0].message["params"]["taskId"].getStr() == "c-1"

    test "Given a client that did not allow tasks on sampling, when the server asks as a task, then nothing is sent":
      let fx = fixture()
      let peer = fx.connectTo(clientCapabilities = %*{"sampling": {}, "tasks": {"list": {}}})
      expect McpCapabilityError:
        discard waitFor fx.server.createMessageAsTask(peer.session, samplingParams)
      check fx.transport.messagesOf("sampling/createMessage").len == 0

    test "Given a client of an older version, when the server asks as a task, then nothing is sent":
      let fx = fixture()
      let peer = fx.connectTo(version = mpv20250618, clientCapabilities = samplingTasks)
      expect McpCapabilityError:
        discard waitFor fx.server.createMessageAsTask(peer.session, samplingParams)
      check fx.transport.messagesOf("sampling/createMessage").len == 0

    test "Given a task of the client that failed with an error, when its result is fetched, then the error is raised":
      let fx = fixture()
      let peer = fx.connectTo(clientCapabilities = samplingTasks)
      let work = fx.server.createMessageAsTask(peer.session, samplingParams, sleep = noSleep)
      fx.answerNext("", "sampling/createMessage", 0, %*{"task": clientTask("c-1", "working")})
      fx.answerNext("", "tasks/get", 0, clientTask("c-1", "failed"))
      untilTrue("the tasks/result request", proc(): bool =
        fx.transport.messagesOf("tasks/result").len == 1)
      let request = fx.transport.messagesOf("tasks/result")[0].message
      fx.transport.inject("", %*{"jsonrpc": "2.0", "id": request["id"],
        "error": {"code": -1, "message": "User rejected sampling request"}})
      try:
        discard waitFor work
        fail()
      except McpRemoteError as e:
        check e.code == -1

    test "Given a client that declared no tasks, when the server asks as a task, then nothing is sent":
      let fx = fixture()
      let peer = fx.connectTo(clientCapabilities = %*{"sampling": {}})
      expect McpCapabilityError:
        discard waitFor fx.server.createMessageAsTask(peer.session, samplingParams)
      check fx.transport.messagesOf("sampling/createMessage").len == 0

    test "Given a client that declared tasks for sampling only, when the server asks for another request as a task, then nothing is sent":
      let fx = fixture()
      let peer = fx.connectTo(clientCapabilities = samplingTasks)
      expect McpCapabilityError:
        discard waitFor fx.server.requestAsTask(peer.session, "roots/list", newJObject())
      check fx.transport.messagesOf("roots/list").len == 0

    test "Given a client with tasks.list, when the server lists its tasks, then it gets the tasks and the cursor of the page":
      let fx = fixture()
      let peer = fx.connectTo(clientCapabilities = samplingTasks)
      let first = fx.server.listClientTasks(peer.session)
      fx.answerNext("", "tasks/list", 0, %*{
        "tasks": [clientTask("c-1", "working"), clientTask("c-2", "completed")],
        "nextCursor": "more"})
      let page = waitFor first
      check page.tasks.len == 2
      check page.tasks[0].taskId == "c-1"
      check page.tasks[1].status == tsCompleted
      check page.nextCursor == some("more")
      let last = fx.server.listClientTasks(peer.session, some("more"))
      fx.answerNext("", "tasks/list", 1, %*{"tasks": [clientTask("c-3", "working")]})
      let rest = waitFor last
      check rest.tasks.len == 1
      check rest.nextCursor.isNone
      check fx.transport.messagesOf("tasks/list")[1].message["params"]["cursor"].getStr() == "more"

    test "Given a client without the cancel capability, when the server cancels one of its tasks, then nothing is sent":
      let fx = fixture()
      let peer = fx.connectTo(clientCapabilities = %*{"sampling": {}, "tasks": {
        "requests": {"sampling": {"createMessage": {}}}}})
      expect McpCapabilityError:
        discard waitFor fx.server.cancelClientTask(peer.session, "c-1")
      expect McpCapabilityError:
        discard waitFor fx.server.listClientTasks(peer.session)
      check fx.transport.messagesOf("tasks/cancel").len == 0
      check fx.transport.messagesOf("tasks/list").len == 0

if isModern(DefaultProtocolVersion):
  suite "tasks server: 2026-07-28 has no tasks":
    test "Given a 2026-07-28 request, when the server describes itself, then tasks are not declared":
      let fx = fixture()
      let peer = fx.connectTo(version = mpv20260728)
      let described = peer.ask("server/discover")
      check not described["result"]["capabilities"].hasKey("tasks")

    test "Given a 2026-07-28 request, when it calls tasks/get, tasks/result, tasks/list or tasks/cancel, then the method is unknown":
      let fx = fixture()
      let peer = fx.connectTo(version = mpv20260728)
      for methodName in ["tasks/get", "tasks/result", "tasks/list", "tasks/cancel"]:
        check peer.ask(methodName, taskParams("anything")).errorCode == -32601

    test "Given a 2026-07-28 request, when a tools/call carries a task, then it runs as a plain call":
      let fx = fixture()
      let peer = fx.connectTo(version = mpv20260728)
      let response = peer.ask("tools/call", asTask("plain"))
      check response.textOf == "plain done"
      check not response["result"].hasKey("task")
