## The Tasks extension (io.modelcontextprotocol/tasks, ext-tasks at
## 5246bc3d0253c1c4b09e682f690b7e8b97362500) on the server, as a client of
## 2026-07-28 sees it on the wire: what is declared and to whom, when a
## request becomes a task, what tasks/get, tasks/update and tasks/cancel
## answer, and who may see a task.

import std/[asyncdispatch, json, options, os, sequtils, strutils, unittest]
import ./server_harness
import server/extensions
import server/mrtr
import protocol/extensions as protoExt
import protocol/modern
import protocol/tasks
import protocol/subscriptions
import protocol/version
import ext/tasks
import transport/transport as wireTransport

const Ext = TasksExtensionId

proc caps(extra: JsonNode = nil): JsonNode =
  ## The client capabilities of a request that declares the extension.
  var declared = %*{"extensions": {Ext: {}}}
  if not extra.isNil:
    for key, value in extra.pairs:
      declared[key] = value
  %*{"io.modelcontextprotocol/clientCapabilities": declared}

type Fixture = object
  server: McpServer
  tasks: TasksExtension
  gate: Future[void]
  cancelled: ref bool

proc fixture(decide: TaskDecider = nil, ownerOf: TaskOwnerOf = nil,
             store: TaskStore = nil): Fixture =
  ## A server whose tools are `report` (answers at once), `slow` (waits for
  ## the gate), `bad` (a tool error result), `broken` (a JSON-RPC error) and
  ## `ask` (needs input from the client while it runs).
  let gate = newFuture[void]("gate")
  let cancelled = new bool
  let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  let tasks = server.enableTasksExtension(TasksExtensionConfig(
    decide: if decide.isNil: toolsNamed(["report", "slow", "bad", "broken", "ask"]) else: decide,
    ownerOf: ownerOf), store)
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "slow":
      let stopped = ctx.whenCancelled()
      await (gate or stopped)
      if ctx.cancelled:
        cancelled[] = true
      return %*{"content": [{"type": "text", "text": "slow done"}]}
    of "bad":
      return %*{"content": [{"type": "text", "text": "no such file"}], "isError": true}
    of "broken":
      raise newRequestError(-32603, "API rate limit exceeded")
    of "ask":
      let answer = await tasks.requestInput(ctx, %*{
        "method": "elicitation/create",
        "params": {"mode": "form", "message": "Your name?",
                   "requestedSchema": {"type": "object",
                                       "properties": {"name": {"type": "string"}}}}})
      return %*{"content": [{"type": "text", "text": "Hello, " &
                             answer{"content", "name"}.getStr() & "!"}]}
    else:
      return %*{"content": [{"type": "text", "text": "report of " & arguments{"topic"}.getStr()}]})
  Fixture(server: server, tasks: tasks, gate: gate, cancelled: cancelled)

proc newPeer(f: Fixture): Peer =
  f.server.connect(f.server.attach(), mpv20260728)

proc call(peer: Peer, name: string, arguments: JsonNode = nil,
          extension = true): JsonNode =
  peer.ask("tools/call", %*{"name": name, "arguments": if arguments.isNil: newJObject() else: arguments},
           meta = if extension: caps() else: nil)

proc taskIdOf(created: JsonNode): string =
  created["result"]["taskId"].getStr()

proc getTask(peer: Peer, id: string, extension = true): JsonNode =
  peer.ask("tasks/get", %*{"taskId": id}, meta = if extension: caps() else: nil)

let elicitationDeclared = %*{"elicitation": {"form": {}}}

let askForm = %*{"method": "elicitation/create",
                 "params": {"mode": "form", "message": "q",
                            "requestedSchema": {"type": "object", "properties": {}}}}

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-ext-tasks-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

if isSupported(mpv20260728):

  suite "Tasks extension: wire form":

    test "Given the specification's CreateTaskResult example, when parsed and written, then it round-trips with ttlMs and pollIntervalMs":
      let example = %*{
        "resultType": "task", "taskId": "786512e2-9e0d-44bd-8f29-789f320fe840",
        "status": "working", "statusMessage": "The operation is now in progress.",
        "createdAt": "2025-11-25T10:30:00Z", "lastUpdatedAt": "2025-11-25T10:40:00Z",
        "ttlMs": 60000, "pollIntervalMs": 5000}
      let parsed = parseTask(example)
      check parsed.problem.isNone
      check parsed.task.ttlMs == some(60000'i64)
      check parsed.task.pollIntervalMs == some(5000)
      let written = taskHandle(parsed.task)
      check written["resultType"].getStr() == "task"
      check written["ttlMs"].getInt() == 60000
      check written["pollIntervalMs"].getInt() == 5000
      check not written.hasKey("ttl")
      check not written.hasKey("task")
      check written["createdAt"].getStr().startsWith("2025-11-25T10:30:00")

    test "Given a task with unlimited lifetime, when written, then ttlMs is null":
      let parsed = parseTask(%*{"taskId": "a", "status": "working", "createdAt": "2025-11-25T10:30:00Z",
                                "lastUpdatedAt": "2025-11-25T10:30:00Z", "ttlMs": nil})
      check parsed.problem.isNone
      check parsed.task.ttlMs.isNone
      check taskHandle(parsed.task)["ttlMs"].kind == JNull

    test "Given a task of each status, when parsed as a DetailedTask, then the fields of the status are required":
      let base = %*{"taskId": "a", "createdAt": "2025-11-25T10:30:00Z",
                    "lastUpdatedAt": "2025-11-25T10:30:00Z", "ttlMs": 1}
      proc with(status: string, extra: JsonNode = nil): JsonNode =
        result = base.copy()
        result["status"] = %status
        if not extra.isNil:
          for key, value in extra.pairs:
            result[key] = value
      check parseDetailedTask(with("working")).problem.isNone
      check parseDetailedTask(with("cancelled")).problem.isNone
      check parseDetailedTask(with("completed")).problem.isSome
      check parseDetailedTask(with("completed", %*{"result": {"content": []}})).problem.isNone
      check parseDetailedTask(with("failed")).problem.isSome
      check parseDetailedTask(with("failed", %*{"error": {"code": -32603, "message": "x"}})).problem.isNone
      check parseDetailedTask(with("input_required")).problem.isSome
      check parseDetailedTask(with("input_required", %*{"inputRequests": {"k": {"method": "elicitation/create"}}})).problem.isNone
      check parseDetailedTask(with("exploded")).problem.isSome

    test "Given a Task with one field missing or of the wrong kind, when parsed, then the problem names that field":
      let good = %*{"taskId": "a", "status": "working", "createdAt": "2025-11-25T10:30:00Z",
                    "lastUpdatedAt": "2025-11-25T10:30:00Z", "ttlMs": 1, "pollIntervalMs": 5}
      check parseTask(good).problem.isNone
      proc problemWith(key: string, value: JsonNode): string =
        var task = good.copy()
        if value.isNil:
          task.delete(key)
        else:
          task[key] = value
        let parsed = parseTask(task)
        check parsed.problem.isSome
        if parsed.problem.isSome:
          result = parsed.problem.get
      check "object" in parseTask(nil).problem.get
      check "object" in parseTask(%*["a"]).problem.get
      check "taskId" in problemWith("taskId", nil)
      check "taskId" in problemWith("taskId", %"")
      check "taskId" in problemWith("taskId", %5)
      check "status" in problemWith("status", %"exploded")
      check "createdAt" in problemWith("createdAt", %"yesterday")
      check "lastUpdatedAt" in problemWith("lastUpdatedAt", %"yesterday")
      check "lastUpdatedAt" in problemWith("lastUpdatedAt", nil)
      check "ttlMs" in problemWith("ttlMs", nil)
      check "ttlMs" in problemWith("ttlMs", %"60000")
      check "pollIntervalMs" in problemWith("pollIntervalMs", %"5")

    test "Given a failed task whose error lacks a code or a message of the right kind, when parsed, then it is a problem":
      let base = %*{"taskId": "a", "status": "failed", "createdAt": "2025-11-25T10:30:00Z",
                    "lastUpdatedAt": "2025-11-25T10:30:00Z", "ttlMs": 1}
      proc failedWith(error: JsonNode): JsonNode =
        result = base.copy()
        result["error"] = error
      check parseDetailedTask(failedWith(%*{"code": -32603, "message": "x"})).problem.isNone
      check parseDetailedTask(failedWith(%"boom")).problem.isSome
      check parseDetailedTask(failedWith(%*{"message": "x"})).problem.isSome
      check parseDetailedTask(failedWith(%*{"code": "-32603", "message": "x"})).problem.isSome
      check parseDetailedTask(failedWith(%*{"code": -32603})).problem.isSome
      check parseDetailedTask(failedWith(%*{"code": -32603, "message": 5})).problem.isSome

    test "Given a failed task with error data, when written and parsed, then the data survives; without data the key is absent":
      let task = McpTask(taskId: "a", status: tsFailed, ttlMs: some(1'i64))
      proc failedWith(data: JsonNode): DetailedTask =
        DetailedTask(task: task, error: some(JsonRpcError(code: -32603, message: "x", data: data)))
      let withData = failedWith(%*{"retryAfter": 3}).toWire()
      check withData["error"]["data"] == %*{"retryAfter": 3}
      check parseDetailedTask(withData).detailed.error.get.data == %*{"retryAfter": 3}
      check not failedWith(nil).toWire()["error"].hasKey("data")
      check not failedWith(newJNull()).toWire()["error"].hasKey("data")

    test "Given a listen filter with taskIds, when parsed and written, then the ids round-trip and a malformed list is rejected":
      let node = %*{"toolsListChanged": true, "taskIds": ["a", "b"]}
      let parsed = parseSubscriptionFilter(node)
      check parsed.problem.isNone
      check parsed.filter.taskIds == @["a", "b"]
      check parsed.filter.toJson() == node
      check parseSubscriptionFilter(%*{"taskIds": "a"}).problem.isSome
      check parseSubscriptionFilter(%*{"taskIds": [1]}).problem.isSome
      check parsed.filter.wants("notifications/tasks", %*{"taskId": "a"})
      check not parsed.filter.wants("notifications/tasks", %*{"taskId": "c"})

    test "Given the specification's capability example, when the extension is enabled, then the server declares exactly that":
      let f = fixture()
      let answer = f.newPeer.ask("server/discover")
      check answer["result"]["capabilities"]["extensions"][Ext] == newJObject()
      check parseJson(readFile(currentSourcePath().parentDir.parentDir / "fixtures" / "2026-07-28" /
        "ServerCapabilities_extensions-tasks.json"))["extensions"] ==
        answer["result"]["capabilities"]["extensions"]

  suite "Tasks extension: negotiation":

    test "Given a server that did not enable the extension, when a client discovers it, then the extension is not declared":
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let answer = server.connect(server.attach(), mpv20260728).ask("server/discover")
      check not answer["result"]["capabilities"].hasKey("extensions")

    test "Given a server that did not enable the extension, when a client declaring it asks for a task, then the answer is method not found":
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let peer = server.connect(server.attach(), mpv20260728)
      check peer.ask("tasks/get", %*{"taskId": "x"}, meta = caps()).errorCode == -32601
      check peer.ask("tasks/cancel", %*{"taskId": "x"}, meta = caps()).errorCode == -32601

    test "Given a client that did not declare the extension, when it uses tasks/get, tasks/update or tasks/cancel, then the answer is -32021 naming the extension":
      let peer = fixture().newPeer
      for methodName in ["tasks/get", "tasks/update", "tasks/cancel"]:
        let answer = peer.ask(methodName, %*{"taskId": "x", "inputResponses": {}})
        check answer.errorCode == -32021
        check answer["error"]["data"]["requiredCapabilities"]["extensions"][Ext] == newJObject()

    test "Given a client that did not declare the extension, when it calls a tool the server would make a task of, then it gets the result":
      let f = fixture()
      let answer = f.newPeer.call("report", %*{"topic": "sales"}, extension = false)
      check answer["result"]["resultType"].getStr() == "complete"
      check answer.textOf == "report of sales"

    test "Given a tool that exists only as a task, when a client that did not declare the extension calls it, then the answer is -32021":
      let f = fixture(decide = proc(ctx: McpRequestContext, name: string,
                                    arguments: JsonNode): TaskDecision = tdTaskRequired)
      let answer = f.newPeer.call("report", extension = false)
      check answer.errorCode == -32021
      check answer["error"]["data"]["requiredCapabilities"]["extensions"][Ext] == newJObject()
      check f.newPeer.call("report")["result"]["resultType"].getStr() == "task"

    test "Given a client that declared the extension, when the server decides against a task, then it gets the plain result":
      let f = fixture(decide = proc(ctx: McpRequestContext, name: string,
                                    arguments: JsonNode): TaskDecision = tdInline)
      let answer = f.newPeer.call("report", %*{"topic": "q"})
      check answer["result"]["resultType"].getStr() == "complete"
      check answer.textOf == "report of q"

    test "Given a server without a decider, when a client declaring the extension calls a tool, then no task is made":
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      discard server.enableTasksExtension()
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        return %*{"content": []})
      let answer = server.connect(server.attach(), mpv20260728).ask(
        "tools/call", %*{"name": "t"}, meta = caps())
      check answer["result"]["resultType"].getStr() == "complete"

    test "Given a build or a server that does not speak 2026-07-28, when the extension is enabled, then it raises":
      if isSupported(mpv20251125):
        let server = newMcpServer(McpServerInfo(name: "old", version: "1"), mpv20251125)
        expect ValueError:
          discard server.enableTasksExtension()
        check server.capabilities.extensions.isNone

    test "Given the methods the extension reserves, when another extension registers one, then it raises":
      let f = fixture()
      f.server.registerExtension("com.example/widgets")
      for methodName in ["tasks/get", "tasks/cancel", "tasks/update", "tasks/result", "tasks/list"]:
        expect ValueError:
          f.server.registerExtensionMethod("com.example/widgets", methodName,
            proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} = return newJObject())

    test "Given tasks/result and tasks/list, when a client that declared the extension asks, then both are method not found":
      let peer = fixture().newPeer
      check peer.ask("tasks/result", %*{"taskId": "x"}, meta = caps()).errorCode == -32601
      check peer.ask("tasks/list", meta = caps()).errorCode == -32601

    test "Given tasks/get, tasks/update and tasks/cancel over Streamable HTTP, when the headers are built and checked, then Mcp-Name carries the taskId":
      for methodName in ["tasks/get", "tasks/update", "tasks/cancel"]:
        let params = withRequestMeta(%*{"taskId": "task-1"}, modernMeta())
        let headers = modernRequestHeaders(methodName, params)
        check (HeaderName, "task-1") in headers
        # The rule holds on a server that serves the method for the extension.
        check checkRequestHeaders(some("2026-07-28"), some(methodName), some("task-1"),
                                  methodName, params, extensionMethodServed = true).isNone
        check checkRequestHeaders(some("2026-07-28"), some(methodName), some("task-2"),
                                  methodName, params, extensionMethodServed = true).isSome
        check checkRequestHeaders(some("2026-07-28"), some(methodName), none(string),
                                  methodName, params, extensionMethodServed = true).isSome
        check checkRequestHeaders(some("2026-07-28"), some(methodName), none(string),
                                  methodName, params).isNone

  suite "Tasks extension: creating and following a task":

    test "Given a client that declared the extension, when the server makes a task of a call, then the answer is a CreateTaskResult it can poll at once":
      let f = fixture(store = newTaskStore(pollIntervalMs = some(5000)))
      let peer = f.newPeer
      let created = peer.call("slow")
      check created["result"]["resultType"].getStr() == "task"
      check created["result"]["status"].getStr() == "working"
      check created["result"]["ttlMs"].getInt() == 3_600_000
      check created["result"]["pollIntervalMs"].getInt() == 5000
      check created["result"].hasKey("createdAt") and created["result"].hasKey("lastUpdatedAt")
      check not created["result"].hasKey("content")
      let id = created.taskIdOf
      check id.len >= 32
      let polled = peer.getTask(id)
      check polled["result"]["resultType"].getStr() == "complete"
      check polled["result"]["status"].getStr() == "working"
      check not polled["result"].hasKey("result")

    test "Given a task that finished, when it is polled, then the result of the tool call is inlined without a resultType of its own":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("report", %*{"topic": "sales"}).taskIdOf
      settle()
      let done = peer.getTask(id)["result"]
      check done["status"].getStr() == "completed"
      check done["result"]["content"][0]["text"].getStr() == "report of sales"
      check not done["result"].hasKey("resultType")
      check not done.hasKey("error")

    test "Given a tool call that returned isError, when the task is polled, then it is completed, not failed":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("bad").taskIdOf
      settle()
      let done = peer.getTask(id)["result"]
      check done["status"].getStr() == "completed"
      check done["result"]["isError"].getBool()

    test "Given a tool call that ended in a JSON-RPC error, when the task is polled, then it is failed with that error":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("broken").taskIdOf
      settle()
      let done = peer.getTask(id)["result"]
      check done["status"].getStr() == "failed"
      check done["error"]["code"].getInt() == -32603
      check done["error"]["message"].getStr() == "API rate limit exceeded"
      check not done.hasKey("result")

    test "Given a task that is working, when the work finishes between polls, then the next poll shows completed":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("slow").taskIdOf
      check peer.getTask(id)["result"]["status"].getStr() == "working"
      f.gate.complete()
      settle()
      check peer.getTask(id)["result"]["status"].getStr() == "completed"

    test "Given an unknown or malformed taskId, when tasks/get, tasks/update or tasks/cancel is sent, then the answer is -32602":
      let peer = fixture().newPeer
      for methodName in ["tasks/get", "tasks/update", "tasks/cancel"]:
        check peer.ask(methodName, %*{"taskId": "nope", "inputResponses": {}}, meta = caps()).errorCode == -32602
        check peer.ask(methodName, %*{"inputResponses": {}}, meta = caps()).errorCode == -32602
        check peer.ask(methodName, %*{"taskId": 7, "inputResponses": {}}, meta = caps()).errorCode == -32602

    test "Given a task whose ttl elapsed, when it is polled, then it is gone: -32602":
      var now = 1_700_000_000_000'i64
      let f = fixture(store = newTaskStore(clock = proc(): int64 = now,
                                           defaultTtlMs = some(60_000'i64)))
      let peer = f.newPeer
      let id = peer.call("report").taskIdOf
      settle()
      check peer.getTask(id)["result"]["ttlMs"].getInt() == 60_000
      now += 60_000
      check peer.getTask(id).errorCode == -32602

    test "Given a tool that is not the one the server makes tasks of, when a declaring client calls it, then the answer is the plain result":
      let f = fixture(decide = toolsNamed(["slow"]))
      check f.newPeer.call("report")["result"]["resultType"].getStr() == "complete"

    test "Given a tools/call whose name is missing or not a string, when a client declaring the extension sends it, then the server's own -32602 answers":
      let f = fixture()
      let peer = f.newPeer
      check peer.ask("tools/call", %*{"arguments": {}}, meta = caps()).errorCode == -32602
      check peer.ask("tools/call", %*{"name": 5}, meta = caps()).errorCode == -32602

    test "Given a request already running as a task, when it reaches the server's own handling, then it is not made a task again":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("report", %*{"topic": "once"}).taskIdOf
      settle()
      let done = peer.getTask(id)["result"]
      check done["status"].getStr() == "completed"
      check done["result"]["content"][0]["text"].getStr() == "report of once"

    test "Given an owner limit of one active task, when a second task is asked for, then the answer is an error and no task is made":
      let f = fixture(store = newTaskStore(maxActivePerOwner = 1))
      let peer = f.newPeer
      check peer.call("slow")["result"]["resultType"].getStr() == "task"
      let second = peer.call("slow")
      check second.errorCode == -32603

  suite "Tasks extension: cancellation":

    test "Given a working task, when tasks/cancel is sent, then the answer is an empty acknowledgement and the work is told to stop":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("slow").taskIdOf
      let ack = peer.ask("tasks/cancel", %*{"taskId": id}, meta = caps())
      check ack["result"]["resultType"].getStr() == "complete"
      check ack["result"].len == 2 or ack["result"].len == 1  # resultType, _meta
      check not ack["result"].hasKey("taskId")
      settle()
      check f.cancelled[]
      check peer.getTask(id)["result"]["status"].getStr() == "cancelled"

    test "Given a task that is over, when tasks/cancel is sent, then it is acknowledged and the task keeps its status":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("report").taskIdOf
      settle()
      check not peer.ask("tasks/cancel", %*{"taskId": id}, meta = caps()).hasKey("error")
      check peer.getTask(id)["result"]["status"].getStr() == "completed"

    test "Given a cancelled task, when the work finishes anyway, then the task stays cancelled":
      let f = fixture(decide = toolsNamed(["slow"]))
      let peer = f.newPeer
      let id = peer.call("slow").taskIdOf
      discard peer.ask("tasks/cancel", %*{"taskId": id}, meta = caps())
      f.gate.complete()
      settle()
      let state = peer.getTask(id)["result"]
      check state["status"].getStr() == "cancelled"
      check not state.hasKey("result")

  suite "Tasks extension: input during a task":

    proc inputRequiredTask(f: Fixture, peer: Peer): string =
      let created = peer.ask("tools/call", %*{"name": "ask"}, meta = caps(elicitationDeclared))
      result = created.taskIdOf
      settle()

    test "Given a task that needs input, when it is polled, then it is input_required with the outstanding requests":
      let f = fixture()
      let peer = f.newPeer
      let id = f.inputRequiredTask(peer)
      let state = peer.getTask(id)["result"]
      check state["status"].getStr() == "input_required"
      check state["inputRequests"].len == 1
      for key, request in state["inputRequests"].pairs:
        check request["method"].getStr() == "elicitation/create"
        check request["params"]["message"].getStr() == "Your name?"
      check peer.getTask(id)["result"]["inputRequests"] == state["inputRequests"]

    test "Given an input_required task, when the client answers with tasks/update, then it is acknowledged and the task finishes with the answer":
      let f = fixture()
      let peer = f.newPeer
      let id = f.inputRequiredTask(peer)
      let key = peer.getTask(id)["result"]["inputRequests"].pairs.toSeq[0][0]
      let ack = peer.ask("tasks/update", %*{"taskId": id, "inputResponses": {
        key: {"action": "accept", "content": {"name": "Luca"}}}}, meta = caps())
      check ack["result"]["resultType"].getStr() == "complete"
      settle()
      let done = peer.getTask(id)["result"]
      check done["status"].getStr() == "completed"
      check done["result"]["content"][0]["text"].getStr() == "Hello, Luca!"

    test "Given responses for keys that are not outstanding, when tasks/update is sent, then they are ignored and the task stays input_required":
      let f = fixture()
      let peer = f.newPeer
      let id = f.inputRequiredTask(peer)
      let ack = peer.ask("tasks/update", %*{"taskId": id, "inputResponses": {
        "never-issued": {"action": "accept"}}}, meta = caps())
      check not ack.hasKey("error")
      settle()
      check peer.getTask(id)["result"]["status"].getStr() == "input_required"

    test "Given inputResponses that are not an object of objects or missing, when tasks/update is sent, then the answer is -32602":
      let f = fixture()
      let peer = f.newPeer
      let id = f.inputRequiredTask(peer)
      check peer.ask("tasks/update", %*{"taskId": id}, meta = caps()).errorCode == -32602
      check peer.ask("tasks/update", %*{"taskId": id, "inputResponses": []}, meta = caps()).errorCode == -32602
      check peer.ask("tasks/update", %*{"taskId": id, "inputResponses": {"k": 3}}, meta = caps()).errorCode == -32602

    test "Given a task that asks twice, when each request is answered, then the keys differ and a key already answered is not outstanding again":
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let tasks = server.enableTasksExtension(TasksExtensionConfig(decide: toolsNamed(["twice"])))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        let ask = %*{"method": "elicitation/create",
                     "params": {"mode": "form", "message": "q",
                                "requestedSchema": {"type": "object", "properties": {}}}}
        discard await tasks.requestInput(ctx, ask)
        discard await tasks.requestInput(ctx, ask)
        return %*{"content": []})
      let peer = server.connect(server.attach(), mpv20260728)
      let id = peer.ask("tools/call", %*{"name": "twice"}, meta = caps(elicitationDeclared)).taskIdOf
      settle()
      let first = peer.getTask(id)["result"]["inputRequests"].pairs.toSeq[0][0]
      discard peer.ask("tasks/update", %*{"taskId": id, "inputResponses": {first: {"action": "decline"}}},
                       meta = caps())
      settle()
      let second = peer.getTask(id)["result"]
      check second["status"].getStr() == "input_required"
      check second["inputRequests"].len == 1
      check not second["inputRequests"].hasKey(first)
      let secondKey = second["inputRequests"].pairs.toSeq[0][0]
      check secondKey != first
      discard peer.ask("tasks/update", %*{"taskId": id, "inputResponses": {
        first: {"action": "decline"}, secondKey: {"action": "decline"}}}, meta = caps())
      settle()
      check peer.getTask(id)["result"]["status"].getStr() == "completed"

    test "Given a task that waits on two requests at once, when one is answered, then it stays input_required until the other is answered too":
      let gate = newFuture[void]("gate")
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let tasks = server.enableTasksExtension(TasksExtensionConfig(decide: toolsNamed(["both"])))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        let first = tasks.requestInput(ctx, askForm, "a")
        let second = tasks.requestInput(ctx, askForm, "b")
        discard await first
        discard await second
        await gate
        return %*{"content": []})
      let peer = server.connect(server.attach(), mpv20260728)
      let id = peer.ask("tools/call", %*{"name": "both"}, meta = caps(elicitationDeclared)).taskIdOf
      settle()
      check peer.getTask(id)["result"]["inputRequests"].len == 2
      discard peer.ask("tasks/update", %*{"taskId": id, "inputResponses": {"a": {"action": "decline"}}},
                       meta = caps())
      settle()
      let half = peer.getTask(id)["result"]
      check half["status"].getStr() == "input_required"
      check half["inputRequests"].len == 1
      check half["inputRequests"].hasKey("b")
      discard peer.ask("tasks/update", %*{"taskId": id, "inputResponses": {"b": {"action": "decline"}}},
                       meta = caps())
      settle()
      let resumed = peer.getTask(id)["result"]
      check resumed["status"].getStr() == "working"
      check not resumed.hasKey("inputRequests")
      gate.complete()
      settle()
      check peer.getTask(id)["result"]["status"].getStr() == "completed"

    test "Given a working task, when tasks/update names only keys nobody asked for, then the task is left as it was":
      let now = new int64
      now[] = 1_764_067_800_000'i64
      let f = fixture(store = newTaskStore(clock = proc(): int64 = now[]))
      let peer = f.newPeer
      let id = peer.call("slow").taskIdOf
      settle()
      let before = peer.getTask(id)["result"]
      now[] += 5_000
      let ack = peer.ask("tasks/update", %*{"taskId": id, "inputResponses": {
        "nobody": {"action": "accept"}}}, meta = caps())
      check not ack.hasKey("error")
      let after = peer.getTask(id)["result"]
      check after["status"].getStr() == "working"
      check after["lastUpdatedAt"] == before["lastUpdatedAt"]
      f.gate.complete()

    test "Given a key a task used and had answered, when the tool asks again with that key, then it raises ValueError":
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let tasks = server.enableTasksExtension(TasksExtensionConfig(decide: toolsNamed(["again"])))
      let raised = new string
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        discard await tasks.requestInput(ctx, askForm, "k")
        try:
          discard await tasks.requestInput(ctx, askForm, "k")
        except ValueError as e:
          raised[] = e.msg
        return %*{"content": []})
      let peer = server.connect(server.attach(), mpv20260728)
      let id = peer.ask("tools/call", %*{"name": "again"}, meta = caps(elicitationDeclared)).taskIdOf
      settle()
      discard peer.ask("tasks/update", %*{"taskId": id, "inputResponses": {"k": {"action": "decline"}}},
                       meta = caps())
      settle()
      check "'k'" in raised[]
      check peer.getTask(id)["result"]["status"].getStr() == "completed"

    test "Given a task cancelled while its tool runs on, when the tool asks for input afterwards, then the task is no longer one the extension serves":
      let gate = newFuture[void]("gate")
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let tasks = server.enableTasksExtension(TasksExtensionConfig(decide: toolsNamed(["late"])))
      let raised = new string
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        await gate
        try:
          discard await tasks.requestInput(ctx, askForm)
        except ValueError as e:
          raised[] = e.msg
        return %*{"content": []})
      let peer = server.connect(server.attach(), mpv20260728)
      let id = peer.ask("tools/call", %*{"name": "late"}, meta = caps(elicitationDeclared)).taskIdOf
      discard peer.ask("tasks/cancel", %*{"taskId": id}, meta = caps())
      gate.complete()
      settle()
      check "running as a task" in raised[]

    test "Given a tool whose request in a task ends asking for input the multi round-trip way, when the task is polled, then it failed with an internal error and the log points to requestInput":
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      discard server.enableTasksExtension(TasksExtensionConfig(decide: toolsNamed(["multi"])))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        raise newInputRequired([(key: "confirm", methodName: "elicitation/create",
          params: askForm["params"])]))
      let peer = server.connect(server.attach(), mpv20260728)
      var id = ""
      let logged = loggedWhile(proc() =
        id = peer.ask("tools/call", %*{"name": "multi"}, meta = caps(elicitationDeclared)).taskIdOf
        settle())
      let state = peer.getTask(id)["result"]
      check state["status"].getStr() == "failed"
      check state["error"]["code"].getInt() == -32603
      check state["error"]["message"].getStr() == "Internal error"
      check "requestInput" in logged

    test "Given a task cancelled while it waits for input, when it is polled, then it is cancelled and the work stopped":
      let f = fixture()
      let peer = f.newPeer
      let id = f.inputRequiredTask(peer)
      discard peer.ask("tasks/cancel", %*{"taskId": id}, meta = caps())
      settle()
      check peer.getTask(id)["result"]["status"].getStr() == "cancelled"

    test "Given a client that did not declare elicitation, when a task asks it for input, then the tool fails and the task is not input_required":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("ask").taskIdOf
      settle()
      let state = peer.getTask(id)["result"]
      check state["status"].getStr() == "failed"
      check state["error"]["code"].getInt() == -32603

    test "Given a call outside a task, when the tool asks for input the task way, then it raises ValueError":
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let tasks = server.enableTasksExtension(TasksExtensionConfig())
      var raised = ""
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        try:
          discard await tasks.requestInput(ctx, %*{"method": "roots/list"})
        except ValueError as e:
          raised = e.msg
        return %*{"content": []})
      discard server.connect(server.attach(), mpv20260728).ask(
        "tools/call", %*{"name": "t"}, meta = caps())
      check "running as a task" in raised

    test "Given a decider that waits for input gathered with multi round-trip requests, when the retry arrives, then the task starts only then":
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      discard server.enableTasksExtension(TasksExtensionConfig(
        decide: proc(ctx: McpRequestContext, name: string,
                     arguments: JsonNode): TaskDecision =
          if ctx.inputResponses.len > 0: tdTask else: tdInline))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        if ctx.inputResponses.len == 0:
          raise newInputRequired([(key: "confirm", methodName: "elicitation/create",
            params: %*{"mode": "form", "message": "Go?",
                       "requestedSchema": {"type": "object", "properties": {}}})])
        return %*{"content": [{"type": "text", "text": "started"}]})
      let peer = server.connect(server.attach(), mpv20260728)
      let first = peer.ask("tools/call", %*{"name": "t"}, meta = caps(elicitationDeclared))
      check first["result"]["resultType"].getStr() == "input_required"
      let retry = peer.ask("tools/call", %*{"name": "t", "inputResponses": {
        "confirm": {"action": "accept"}}}, meta = caps(elicitationDeclared))
      check retry["result"]["resultType"].getStr() == "task"

  suite "Tasks extension: whose task it is":

    proc whoOwns(ctx: McpRequestContext): string =
      ctx.clientExtension(Ext).get{"who"}.getStr()

    proc asOwner(who: string): JsonNode =
      %*{"io.modelcontextprotocol/clientCapabilities": {"extensions": {Ext: {"who": who}}}}

    test "Given tasks of two owners, when one asks for the other's task, then it is unknown to it":
      let f = fixture(ownerOf = whoOwns)
      let peer = f.newPeer
      let mine = peer.ask("tools/call", %*{"name": "slow"}, meta = asOwner("alice")).taskIdOf
      check peer.ask("tasks/get", %*{"taskId": mine}, meta = asOwner("alice"))["result"]["status"].getStr() == "working"
      check peer.ask("tasks/get", %*{"taskId": mine}, meta = asOwner("bob")).errorCode == -32602
      check peer.ask("tasks/cancel", %*{"taskId": mine}, meta = asOwner("bob")).errorCode == -32602
      check peer.ask("tasks/update", %*{"taskId": mine, "inputResponses": {}}, meta = asOwner("bob")).errorCode == -32602
      check peer.ask("tasks/get", %*{"taskId": mine}, meta = asOwner("alice"))["result"]["status"].getStr() == "working"

    proc askAs(f: Fixture, principal: Option[string], methodName: string, params: JsonNode): JsonNode =
      ## A 2026-07-28 request as the transport hands it over after authorization.
      var body = params.copy()
      body["_meta"] = caps()
      body["_meta"]["io.modelcontextprotocol/protocolVersion"] = %"2026-07-28"
      body["_meta"]["io.modelcontextprotocol/clientInfo"] = %*{"name": "c", "version": "1"}
      var request = newJsonRpcRequest("r" & $methodName.len & $body.len, methodName, body)
      request.principal = principal
      return wireTransport.toJson(waitFor f.server.handleRequest(request))

    test "Given no ownerOf and authorized requests, when another principal asks for a task, then it is unknown to them":
      let f = fixture()
      let mine = f.askAs(some("alice"), "tools/call", %*{"name": "slow", "arguments": {}}).taskIdOf
      check f.askAs(some("alice"), "tasks/get", %*{"taskId": mine})["result"]["status"].getStr() == "working"
      check f.askAs(some("bob"), "tasks/get", %*{"taskId": mine}).errorCode == -32602
      check f.askAs(some("bob"), "tasks/cancel", %*{"taskId": mine}).errorCode == -32602
      check f.askAs(none(string), "tasks/get", %*{"taskId": mine}).errorCode == -32602

    test "Given no ownerOf and no authorization, when two clients ask, then they are one owner and the unguessable task id is the only separation":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("slow").taskIdOf
      check peer.getTask(id)["result"]["status"].getStr() == "working"
      check peer.call("slow").taskIdOf != id

  suite "Tasks extension: status notifications":

    proc listenFor(peer: Peer, id: string, taskIds: seq[string], meta: JsonNode = caps()) =
      peer.send(%id, "subscriptions/listen", %*{"notifications": {"taskIds": taskIds}}, meta = meta)

    proc acknowledged(peer: Peer): seq[JsonNode] =
      for sent in peer.transport.messagesOf("notifications/subscriptions/acknowledged"):
        result.add sent.message

    proc taskNotifications(peer: Peer): seq[JsonNode] =
      for sent in peer.transport.messagesOf("notifications/tasks"):
        result.add sent.message["params"]

    test "Given a client that did not declare the extension, when it listens for task ids, then the answer is -32021":
      let peer = fixture().newPeer
      peer.listenFor("l1", @["any"], meta = nil)
      check peer.transport.responseTo("l1").errorCode == -32021
      check peer.transport.responseTo("l1")["error"]["data"]["requiredCapabilities"]["extensions"][Ext] ==
        newJObject()

    test "Given task ids of its own and unknown ones, when a client listens, then the acknowledgement lists only its own":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("slow").taskIdOf
      peer.listenFor("l1", @[id, "unknown"])
      untilTrue("the acknowledgement", proc(): bool = peer.acknowledged.len > 0)
      check peer.acknowledged[0]["params"]["notifications"]["taskIds"] == %*[id]

    test "Given a task the client listened for, when its status changes, then the stream gets notifications/tasks with the whole task":
      let f = fixture()
      let peer = f.newPeer
      let id = peer.call("slow").taskIdOf
      peer.listenFor("l1", @[id])
      untilTrue("the acknowledgement", proc(): bool = peer.acknowledged.len > 0)
      f.gate.complete()
      untilTrue("the notification", proc(): bool = peer.taskNotifications.len > 0)
      let note = peer.taskNotifications[0]
      check note["taskId"].getStr() == id
      check note["status"].getStr() == "completed"
      check note["result"]["content"][0]["text"].getStr() == "slow done"
      check note["ttlMs"].getInt() == 3_600_000
      check note["_meta"].hasKey("io.modelcontextprotocol/subscriptionId")
      check not note.hasKey("resultType")

    test "Given a task of another owner, when a client listens for its id, then it is not acknowledged and gets nothing":
      let f = fixture(ownerOf = proc(ctx: McpRequestContext): string =
        ctx.clientExtension(Ext).get{"who"}.getStr())
      let peer = f.newPeer
      let alice = %*{"io.modelcontextprotocol/clientCapabilities": {"extensions": {Ext: {"who": "alice"}}}}
      let bob = %*{"io.modelcontextprotocol/clientCapabilities": {"extensions": {Ext: {"who": "bob"}}}}
      let id = peer.ask("tools/call", %*{"name": "slow"}, meta = alice).taskIdOf
      peer.listenFor("l1", @[id], meta = bob)
      untilTrue("the acknowledgement", proc(): bool = peer.acknowledged.len > 0)
      check not peer.acknowledged[0]["params"]["notifications"].hasKey("taskIds")
      f.gate.complete()
      settle()
      check peer.taskNotifications.len == 0

    test "Given a task the client did not list, when its status changes, then the stream is not told":
      let f = fixture()
      let peer = f.newPeer
      let listed = peer.call("slow").taskIdOf
      let other = peer.call("report").taskIdOf
      peer.listenFor("l1", @[listed])
      untilTrue("the acknowledgement", proc(): bool = peer.acknowledged.len > 0)
      settle()
      check other.len > 0
      check peer.taskNotifications.len == 0
