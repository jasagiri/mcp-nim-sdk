## The Tasks extension on the client (2026-07-28), against the SDK's own
## server over an in-process transport and against a hand-written peer: what
## it declares, what a call returns when the server makes a task of it, how
## it polls, and how it answers the input a task asks for.

import std/[asyncdispatch, json, monotimes, options, strutils, times, unittest]
import server/server except McpRequestError
import client/client
import client/elicitation
import client/extensions
import client/subscriptions
import protocol/types
import protocol/tasks
import protocol/version
import ext/tasks
import ./client_peer except Peer, ask
import ./loopback_transport

type World = object
  server: McpServer
  gate: Future[void]
  tasks: TasksExtension

proc world(): World =
  let gate = newFuture[void]("gate")
  let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let tasks = server.enableTasksExtension(TasksExtensionConfig(
    decide: toolsNamed(["slow", "bad", "broken", "ask"])),
    newTaskStore(pollIntervalMs = some(250)))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "slow":
      let stopped = ctx.whenCancelled()
      await (gate or stopped)
      return %*{"content": [{"type": "text", "text": "slow done"}]}
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
      return %*{"content": [{"type": "text", "text": "plain " & name}]})
  World(server: server, gate: gate, tasks: tasks)

proc connected(w: World, configure: proc(client: McpClient) = nil): McpClient =
  let pair = newLoopbackPair()
  waitFor w.server.attachTransport(pair.server)
  let client = newMcpClient(McpClientInfo(name: "c", version: "1"), mpv20260728)
  client.enableTasksExtension()
  if not configure.isNil:
    configure(client)
  waitFor client.connect(pair.client)
  client

proc taskJson(status: string, extra: JsonNode = nil): JsonNode =
  ## What a server answers tasks/get with.
  result = %*{"resultType": "complete", "taskId": "t1", "status": status,
              "createdAt": "2025-11-25T10:30:00Z", "lastUpdatedAt": "2025-11-25T10:30:00Z",
              "ttlMs": nil}
  if not extra.isNil:
    for key, value in extra.pairs:
      result[key] = value

let taskServer = %*{"tools": {}, "extensions": {TasksExtensionId: {}}}

proc release(gate: Future[void]) =
  if not gate.finished:
    gate.complete()

proc recordingSleep(slept: ref seq[int], onSleep: proc() = nil): SleepProc =
  ## A wait that takes no time: it records how long it was asked to wait.
  result = proc(ms: int): Future[void] =
    slept[].add ms
    if not onSleep.isNil:
      onSleep()
    let done = newFuture[void]("sleep")
    done.complete()
    done

if isSupported(mpv20260728):

  suite "Tasks extension: the client declares it":

    test "Given enableTasksExtension, when the client calls, then every request declares the extension and the task result type":
      let w = world()
      let client = w.connected()
      check client.capabilities.extensions.get.hasKey(TasksExtensionId)
      check client.serverExtension(TasksExtensionId).isSome

    test "Given a client limited to a version before 2026-07-28, when it enables the extension, then it raises":
      if isSupported(mpv20251125):
        let client = newMcpClient(McpClientInfo(name: "c", version: "1"), mpv20251125)
        expect ValueError:
          client.enableTasksExtension()
        check client.capabilities.extensions.isNone

    test "Given a client that did not enable the extension, when it calls a tool as a task, then it raises and sends nothing":
      let w = world()
      let pair = newLoopbackPair()
      waitFor w.server.attachTransport(pair.server)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), mpv20260728)
      waitFor client.connect(pair.client)
      let before = pair.client.sent.len
      expect McpUnsupportedError:
        discard waitFor client.startToolCall("slow")
      expect McpUnsupportedError:
        discard waitFor client.getTask("x")
      check pair.client.sent.len == before

    test "Given a client that enabled the extension but negotiated an earlier version, when it calls a tool as a task, then it raises and sends nothing":
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/call":
          peer.reply(message["id"], %*{"content": []}))
      let client = peer.connectedClient(mpv20260728, proc(c: McpClient) = c.enableTasksExtension())
      let before = peer.received.len
      expect McpUnsupportedError:
        discard waitFor client.startToolCall("t")
      check peer.received.len == before

    test "Given a client that did not enable the extension, when it follows, answers, cancels or watches a task, then each raises McpUnsupportedError pointing to enableTasksExtension and sends nothing":
      let w = world()
      let pair = newLoopbackPair()
      waitFor w.server.attachTransport(pair.server)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), mpv20260728)
      waitFor client.connect(pair.client)
      let before = pair.client.sent.len
      proc refusal(call: proc()): string =
        try:
          call()
          fail()
        except McpUnsupportedError as e:
          result = e.msg
      check "enableTasksExtension" in refusal(proc() = discard waitFor client.getTask("x"))
      check "enableTasksExtension" in refusal(proc() = waitFor client.updateTask("x", newJObject()))
      check "enableTasksExtension" in refusal(proc() = waitFor client.cancelTask("x"))
      check "enableTasksExtension" in refusal(proc() =
        discard waitFor client.watchTasks(@["x"], proc(task: DetailedTask) = discard))
      check pair.client.sent.len == before

  suite "Tasks extension: starting a call":

    test "Given a tool the server makes a task of, when the client calls it, then it learns the task and not a result":
      let w = world()
      let client = w.connected()
      let started = waitFor client.startToolCall("slow")
      check started.result.isNone
      check started.task.get.status == tsWorking
      check started.task.get.pollIntervalMs == some(250)
      check started.task.get.taskId.len >= 32

    test "Given a tool the server answers directly, when the client calls it, then it gets the result":
      let w = world()
      let client = w.connected()
      let started = waitFor client.startToolCall("other")
      check started.task.isNone
      check started.result.get["content"][0]["text"].getStr() == "plain other"

    test "Given a server that answers with a task without having declared the extension, when the client calls, then it raises McpProtocolError":
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/call":
          peer.reply(message["id"], %*{
            "resultType": "task", "taskId": "t1", "status": "working",
            "createdAt": "2025-11-25T10:30:00Z", "lastUpdatedAt": "2025-11-25T10:30:00Z",
            "ttlMs": nil}), modern = true)
      let client = peer.connectedClient(mpv20260728, proc(c: McpClient) = c.enableTasksExtension())
      expect McpProtocolError:
        discard waitFor client.startToolCall("t")

    test "Given a server whose task is malformed, when the client calls, then it raises McpProtocolError":
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/call":
          peer.reply(message["id"], %*{"resultType": "task", "taskId": "t1", "status": "working"}),
        modern = true, capabilities = %*{"tools": {}, "extensions": {TasksExtensionId: {}}})
      let client = peer.connectedClient(mpv20260728, proc(c: McpClient) = c.enableTasksExtension())
      expect McpProtocolError:
        discard waitFor client.startToolCall("t")

  suite "Tasks extension: following a task":

    test "Given a working task, when the client polls and cancels, then it sees the state and the acknowledgement":
      let w = world()
      let client = w.connected()
      let id = waitFor client.startToolCall("slow")
      let taskId = id.task.get.taskId
      check waitFor(client.getTask(taskId)).task.status == tsWorking
      waitFor client.cancelTask(taskId)
      check waitFor(client.getTask(taskId)).task.status == tsCancelled

    test "Given an unknown task, when the client polls, then it raises McpRequestError with -32602":
      let w = world()
      let client = w.connected()
      try:
        discard waitFor client.getTask("nope")
        fail()
      except McpRequestError as e:
        check e.code == -32602

    test "Given a task that finishes while the client waits, when it polls, then it waits the interval the task suggests between polls":
      let w = world()
      let client = w.connected()
      let taskId = waitFor(client.startToolCall("slow")).task.get.taskId
      let slept = new seq[int]
      var polls = 0
      let finished = waitFor client.awaitTask(taskId,
        sleep = recordingSleep(slept, proc() =
          inc polls
          if polls == 3:
            w.gate.release()),
        defaultPollMs = 9)
      check finished.task.status == tsCompleted
      check finished.result.get["content"][0]["text"].getStr() == "slow done"
      check slept[].len >= 3
      for ms in slept[]:
        check ms == 250

    test "Given a task that suggests no interval, when the client waits, then it uses its own default":
      let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
        capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
      let gate = newFuture[void]("gate")
      discard server.enableTasksExtension(TasksExtensionConfig(decide: toolsNamed(["slow"])),
        newTaskStore(pollIntervalMs = none(int)))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        await gate
        return %*{"content": []})
      let w = World(server: server, gate: gate)
      let client = w.connected()
      let taskId = waitFor(client.startToolCall("slow")).task.get.taskId
      let slept = new seq[int]
      discard waitFor client.awaitTask(taskId, sleep = recordingSleep(slept, proc() =
        gate.release()), defaultPollMs = 9)
      check slept[].len >= 1
      for ms in slept[]:
        check ms == 9

    test "Given a task that suggests an interval, when the client waits without a sleep of its own, then it really waits between polls":
      var polls = 0
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tasks/get":
          inc polls
          peer.reply(message["id"], if polls < 3: taskJson("working", %*{"pollIntervalMs": 50})
                                    else: taskJson("completed", %*{"result": {"content": []}})),
        modern = true, capabilities = taskServer)
      let client = peer.connectedClient(mpv20260728, proc(c: McpClient) = c.enableTasksExtension())
      let started = getMonoTime()
      let finished = waitFor client.awaitTask("t1")
      check finished.task.status == tsCompleted
      check polls == 3
      check (getMonoTime() - started).inMilliseconds >= 90

    test "Given every status change, when the client waits, then the callback sees each status once":
      let w = world()
      let client = w.connected()
      let taskId = waitFor(client.startToolCall("slow")).task.get.taskId
      var seen: seq[TaskStatus]
      let slept = new seq[int]
      let record = proc(task: McpTask) =
        seen.add task.status
      discard waitFor client.awaitTask(taskId, onStatus = record,
        sleep = recordingSleep(slept, proc() =
          if slept[].len == 2:
            w.gate.release()))
      check seen == @[tsWorking, tsCompleted]

  suite "Tasks extension: input during a task":

    proc withElicitation(answers: ref seq[string]): proc(client: McpClient) =
      result = proc(client: McpClient) =
        client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
          answers[].add request.message
          return McpElicitResult(action: eaAccept, content: %*{"name": "Luca"}))

    test "Given a task that needs input, when the client waits, then it answers from its elicitation handler and the task finishes":
      let w = world()
      let answers = new seq[string]
      let client = w.connected(withElicitation(answers))
      let taskId = waitFor(client.startToolCall("ask")).task.get.taskId
      let slept = new seq[int]
      let finished = waitFor client.awaitTask(taskId, sleep = recordingSleep(slept))
      check finished.task.status == tsCompleted
      check finished.result.get["content"][0]["text"].getStr() == "Hello, Luca!"
      check answers[] == @["Your name?"]

    proc declaresElicitation(client: McpClient) =
      client.capabilities.elicitation = some(McpElicitationCapability(form: true))

    test "Given an input request listed on several polls, when the client waits, then it answers a key once":
      let w = world()
      let client = w.connected(declaresElicitation)
      let taskId = waitFor(client.startToolCall("ask")).task.get.taskId
      var asked = 0
      let slept = new seq[int]
      let finished = waitFor client.awaitTask(taskId,
        onInput = proc(key: string, request: JsonNode): Future[JsonNode] {.async.} =
          inc asked
          return %*{"action": "accept", "content": {"name": "Mona"}},
        sleep = recordingSleep(slept))
      check asked == 1
      check finished.result.get["content"][0]["text"].getStr() == "Hello, Mona!"

    test "Given a server that lists an answered input request again, when the client waits, then it neither answers it again nor sends an empty update":
      var polls = 0
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        case message{"method"}.getStr()
        of "tasks/get":
          inc polls
          peer.reply(message["id"], if polls < 4:
            taskJson("input_required", %*{"inputRequests": {"k": {
              "method": "elicitation/create",
              "params": {"mode": "form", "message": "q",
                         "requestedSchema": {"type": "object", "properties": {}}}}}})
            else: taskJson("completed", %*{"result": {"content": []}}))
        of "tasks/update":
          peer.reply(message["id"], newJObject())
        else:
          discard,
        modern = true, capabilities = taskServer)
      let client = peer.connectedClient(mpv20260728, proc(c: McpClient) = c.enableTasksExtension())
      var asked = 0
      let finished = waitFor client.awaitTask("t1",
        onInput = proc(key: string, request: JsonNode): Future[JsonNode] {.async.} =
          inc asked
          return %*{"action": "decline"},
        sleep = recordingSleep(new seq[int]))
      check finished.task.status == tsCompleted
      check polls == 4
      check asked == 1
      check peer.requestsFor("tasks/update").len == 1

    test "Given a task that asks for something the client has no handler for, when it waits, then it raises McpUnsupportedError":
      let w = world()
      let client = w.connected(declaresElicitation)
      let taskId = waitFor(client.startToolCall("ask")).task.get.taskId
      expect McpUnsupportedError:
        discard waitFor client.awaitTask(taskId, sleep = recordingSleep(new seq[int]))

  suite "Tasks extension: a call as if it were synchronous":

    test "Given a tool that answers directly, when called with callToolAwaitingTask, then the result is returned":
      let w = world()
      let client = w.connected()
      let answer = waitFor client.callToolAwaitingTask("other")
      check answer["content"][0]["text"].getStr() == "plain other"

    test "Given a tool the server makes a task of, when called with callToolAwaitingTask, then the final result is returned":
      let w = world()
      let client = w.connected()
      let slept = new seq[int]
      let answer = waitFor client.callToolAwaitingTask("slow",
        sleep = recordingSleep(slept, proc() = w.gate.release()))
      check answer["content"][0]["text"].getStr() == "slow done"

    test "Given a task that failed, when called with callToolAwaitingTask, then it raises McpRequestError with the task's error":
      let w = world()
      let client = w.connected()
      try:
        discard waitFor client.callToolAwaitingTask("broken", sleep = recordingSleep(new seq[int]))
        fail()
      except McpRequestError as e:
        check e.code == -32603
        check "rate limit" in e.msg

    test "Given a task that was cancelled, when called with callToolAwaitingTask, then it raises McpTaskCancelledError":
      let w = world()
      let client = w.connected()
      let cancelIt = proc(task: McpTask) =
        waitFor client.cancelTask(task.taskId)
      expect McpTaskCancelledError:
        discard waitFor client.callToolAwaitingTask("slow", onCreated = cancelIt,
          sleep = recordingSleep(new seq[int]))

    test "Given a task the server made, when called with callToolAwaitingTask, then the caller is given the task id first":
      let w = world()
      let client = w.connected()
      var kept = ""
      let keep = proc(task: McpTask) =
        kept = task.taskId
      discard waitFor client.callToolAwaitingTask("slow", onCreated = keep,
        sleep = recordingSleep(new seq[int], proc() = w.gate.release()))
      check kept.len >= 32
      check waitFor(client.getTask(kept)).task.status == tsCompleted

  suite "Tasks extension: watching tasks":

    proc untilSeen(what: string, seen: proc(): bool) =
      var waited = 0
      while not seen():
        doAssert waited < 2000, "timed out waiting for " & what
        waitFor sleepAsync(2)
        waited += 2

    test "Given a task being watched, when it completes, then the callback gets the whole task":
      let w = world()
      let client = w.connected()
      let taskId = waitFor(client.startToolCall("slow")).task.get.taskId
      var seen: seq[DetailedTask]
      let collect = proc(task: DetailedTask) =
        seen.add task
      let subscription = waitFor client.watchTasks(@[taskId], collect)
      check subscription.unsupported().taskIds.len == 0
      w.gate.release()
      untilSeen("completion", proc(): bool =
        seen.len > 0 and seen[^1].task.status == tsCompleted)
      check seen[0].task.status == tsWorking  # the state as of the subscription
      check seen[^1].result.get["content"][0]["text"].getStr() == "slow done"
      waitFor subscription.cancel()

    test "Given an id the server did not agree to, when the client watches, then unsupported names it":
      let w = world()
      let client = w.connected()
      let subscription = waitFor client.watchTasks(@["not-a-task"], proc(task: DetailedTask) = discard)
      check subscription.unsupported().taskIds == @["not-a-task"]
      waitFor subscription.cancel()
