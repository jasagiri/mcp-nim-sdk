## Tasks on the client side (2025-11-25, basic/utilities/tasks): a client that
## calls a tool as a task, polls, waits for the result and cancels; and a client
## that is itself the receiver of a task-augmented sampling request. The
## server is a hand-written peer; waiting uses a replaceable sleep, so nothing
## here waits for real.

import std/[asyncdispatch, json, options, sequtils, strutils, unittest]
import client/client
import client/sampling
import client/content
import client/tools
import client/tasks
import protocol/types
import protocol/tasks
import ./client_peer

const
  TaskVersion = mpv20251125
  RelatedTask = "io.modelcontextprotocol/related-task"

let ServerWithTasks = %*{
  "tools": {},
  "tasks": {"list": {}, "cancel": {}, "requests": {"tools": {"call": {}}}}}

template taskTest(name: string, body: untyped) =
  ## A test of 2025-11-25 behaviour; skipped in a build older than that.
  test name:
    if not isSupported(TaskVersion):
      skip()
    else:
      body

proc wireTask(id, status: string, poll = 5_000, ttl = 60_000): JsonNode =
  %*{"taskId": id, "status": status, "createdAt": "2025-11-25T10:30:00Z",
     "lastUpdatedAt": "2025-11-25T10:40:00Z", "ttl": ttl, "pollInterval": poll}

proc optionalTool(): McpTool =
  McpTool(name: "slow", inputSchema: %*{"type": "object"},
          execution: some(%*{"taskSupport": "optional"}))

proc immediately(): Future[void] =
  result = newFuture[void]("immediately")
  result.complete()

proc noSleep(ms: int): Future[void] =
  immediately()

proc answerOf(peer: Peer, id: string): JsonNode =
  ## The client's response to a request the peer made.
  for _ in 1 .. 500:
    for message in peer.received:
      if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
        return message
    waitFor sleepAsync(2)
  raise newException(AssertionDefect, "no answer to " & id)

proc connect(peer: Peer, version = TaskVersion): McpClient =
  peer.connectedClient(version)

suite "tasks client: calling a tool as a task":
  taskTest "Given a server that allows tasks on tools/call and an optional tool, when called as a task, then the request carries the ttl and the task comes back":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        self.reply(message["id"], %*{"task": wireTask("t-1", "working"),
          "_meta": {"io.modelcontextprotocol/model-immediate-response": "On it."}}),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    let created = waitFor client.callToolAsTask(optionalTool(), %*{"city": "Oslo"}, some(30_000'i64))
    check created.task.taskId == "t-1"
    check created.task.status == tsWorking
    check created.task.pollIntervalMs == some(5_000)
    check created.immediateResponse == some("On it.")
    let sent = peer.requestsFor("tools/call")[0]["params"]
    check sent["name"].getStr() == "slow"
    check sent["arguments"]["city"].getStr() == "Oslo"
    check sent["task"]["ttl"].getInt() == 30_000

  taskTest "Given no ttl, when called as a task, then the task field is present and empty":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        self.reply(message["id"], %*{"task": wireTask("t-1", "working")}),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    discard waitFor client.callToolAsTask(optionalTool())
    check peer.requestsFor("tools/call")[0]["params"]["task"] == newJObject()

  taskTest "Given a server that did not declare tasks on tools/call, when called as a task, then nothing is sent":
    let peer = startPeer(nil, capabilities = %*{"tools": {}, "tasks": {"list": {}}})
    let client = peer.connect()
    expect McpUnsupportedError:
      discard waitFor client.callToolAsTask(optionalTool())
    check peer.requestsFor("tools/call").len == 0

  taskTest "Given a tool that forbids tasks or says nothing, when called as a task, then nothing is sent":
    let peer = startPeer(nil, capabilities = ServerWithTasks)
    let client = peer.connect()
    var forbidden = optionalTool()
    forbidden.execution = some(%*{"taskSupport": "forbidden"})
    var silent = optionalTool()
    silent.execution = none(JsonNode)
    expect McpUnsupportedError:
      discard waitFor client.callToolAsTask(forbidden)
    expect McpUnsupportedError:
      discard waitFor client.callToolAsTask(silent)
    check peer.requestsFor("tools/call").len == 0

  taskTest "Given a connection of an older version, when called as a task, then nothing is sent":
    let peer = startPeer(nil, capabilities = ServerWithTasks)
    let client = peer.connect(mpv20250618)
    expect McpUnsupportedError:
      discard waitFor client.callToolAsTask(optionalTool())
    check peer.requestsFor("tools/call").len == 0

  taskTest "Given an answer without a task, when called as a task, then the protocol error is raised":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        self.reply(message["id"], %*{"content": []}),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    expect McpProtocolError:
      discard waitFor client.callToolAsTask(optionalTool())

  taskTest "Given a tool list with execution, when listed, then taskSupport is read, and absent means forbidden":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        self.reply(message["id"], %*{"tools": [
          {"name": "a", "inputSchema": {}, "execution": {"taskSupport": "required"}},
          {"name": "b", "inputSchema": {}, "execution": {"taskSupport": "optional"}},
          {"name": "c", "inputSchema": {}}]}),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    let tools = waitFor client.listAllTools()
    check tools[0].taskSupport == tsRequired
    check tools[1].taskSupport == tsOptional
    check tools[2].taskSupport == tsForbidden

suite "tasks client: operations on a task":
  taskTest "Given a task, when asked for, then the request names it and the answer is parsed":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tasks/get":
        self.reply(message["id"], wireTask(message["params"]["taskId"].getStr(), "working")),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    let task = waitFor client.getTask("t-9")
    check task.taskId == "t-9"
    check task.ttlMs == some(60_000'i64)
    check peer.requestsFor("tasks/get")[0]["params"]["taskId"].getStr() == "t-9"
    check not peer.requestsFor("tasks/get")[0]["params"].hasKey("_meta")

  taskTest "Given an unknown task, when asked for, then the server's error is raised":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tasks/get":
        self.replyError(message["id"], -32602, "Failed to retrieve task: Task not found"),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    try:
      discard waitFor client.getTask("nope")
      fail()
    except McpRequestError as e:
      check e.code == -32602

  taskTest "Given a task answer that is not a task, when asked for, then the protocol error is raised":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tasks/get":
        self.reply(message["id"], %*{"taskId": "t"}),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    expect McpProtocolError:
      discard waitFor client.getTask("t")

  taskTest "Given a server with list, when listing page by page, then every task is returned":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tasks/list":
        if message["params"]{"cursor"}.getStr() == "":
          self.reply(message["id"], %*{"tasks": [wireTask("a", "working")], "nextCursor": "c2"})
        else:
          self.reply(message["id"], %*{"tasks": [wireTask("b", "completed")]}),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    let all = waitFor client.listAllTasks()
    check all.len == 2
    check all[1].status == tsCompleted
    check peer.requestsFor("tasks/list")[1]["params"]["cursor"].getStr() == "c2"

  taskTest "Given a server without list or cancel, when listing or cancelling, then nothing is sent":
    let peer = startPeer(nil, capabilities = %*{"tools": {}, "tasks": {"requests": {"tools": {"call": {}}}}})
    let client = peer.connect()
    expect McpUnsupportedError:
      discard waitFor client.listTasks()
    expect McpUnsupportedError:
      discard waitFor client.cancelTask("t")
    check peer.requestsFor("tasks/list").len == 0
    check peer.requestsFor("tasks/cancel").len == 0

  taskTest "Given a working task, when cancelled, then the cancelled task is returned":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tasks/cancel":
        self.reply(message["id"], wireTask(message["params"]["taskId"].getStr(), "cancelled")),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    check waitFor(client.cancelTask("t-1")).status == tsCancelled

  taskTest "Given a completed task, when its result is fetched, then it is the raw result with the related-task meta":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tasks/result":
        self.reply(message["id"], %*{"content": [{"type": "text", "text": "72F"}],
          "_meta": {RelatedTask: {"taskId": "t-1"}}}),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    let payload = waitFor client.taskResult("t-1")
    check payload["content"][0]["text"].getStr() == "72F"
    check payload["_meta"][RelatedTask]["taskId"].getStr() == "t-1"

  taskTest "Given a task whose request failed, when its result is fetched, then the JSON-RPC error is raised":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tasks/result":
        self.replyError(message["id"], -32602, "bad arguments"),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    try:
      discard waitFor client.taskResult("t-1")
      fail()
    except McpRequestError as e:
      check e.code == -32602
      check "bad arguments" in e.msg

suite "tasks client: waiting for a task":
  taskTest "Given a task that works twice and then completes, when waited for, then it polls at the suggested interval and stops at the end":
    var states = @["working", "working", "completed"]
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tasks/get":
        self.reply(message["id"], wireTask("t-1", states[0], poll = 700))
        if states.len > 1:
          states.delete(0),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    var slept: seq[int]
    var seen: seq[TaskStatus]
    let record = proc(ms: int): Future[void] =
      slept.add ms
      immediately()
    let watch = proc(task: McpTask) =
      seen.add task.status
    let finished = waitFor client.waitForTask("t-1", onStatus = watch, sleep = record)
    check finished.status == tsCompleted
    check slept == @[700, 700]
    check seen == @[tsWorking, tsCompleted]
    check peer.requestsFor("tasks/get").len == 3

  taskTest "Given a task without a suggested interval, when waited for, then the default is used":
    var states = @["working", "completed"]
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tasks/get":
        var task = wireTask("t-1", states[0])
        task.delete("pollInterval")
        self.reply(message["id"], task)
        if states.len > 1:
          states.delete(0),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    var slept: seq[int]
    let record = proc(ms: int): Future[void] =
      slept.add ms
      immediately()
    discard waitFor client.waitForTask("t-1", defaultPollMs = 123, sleep = record)
    check slept == @[123]

  taskTest "Given a task that needs input, when waited for, then polling stops so that tasks/result can be called":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tasks/get":
        self.reply(message["id"], wireTask("t-1", "input_required")),
      capabilities = ServerWithTasks)
    let client = peer.connect()
    let refuse = proc(ms: int): Future[void] =
      raise newException(AssertionDefect, "must not sleep")
    let stopped = waitFor client.waitForTask("t-1", sleep = refuse)
    check stopped.status == tsInputRequired

  taskTest "Given an optional tool, when called with a task and waited for, then the tool's result is returned":
    var polled = 0
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      case message{"method"}.getStr()
      of "tools/call":
        self.reply(message["id"], %*{"task": wireTask("t-1", "working")})
      of "tasks/get":
        inc polled
        self.reply(message["id"], wireTask("t-1", if polled < 2: "working" else: "completed"))
      of "tasks/result":
        self.reply(message["id"], %*{"content": [{"type": "text", "text": "72F"}],
          "isError": false, "_meta": {RelatedTask: {"taskId": "t-1"}}})
      else: discard,
      capabilities = ServerWithTasks)
    let client = peer.connect()
    let content = waitFor client.callToolWithTask(optionalTool(), %*{"city": "Oslo"},
      sleep = noSleep)
    check content.contentItems[0].text == "72F"
    check not content.isError
    check peer.sentMethods.count("tasks/result") == 1

  taskTest "Given a tool that needs input mid-way, when called with a task and waited for, then the client asks for the result at once":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      case message{"method"}.getStr()
      of "tools/call":
        self.reply(message["id"], %*{"task": wireTask("t-1", "working")})
      of "tasks/get":
        self.reply(message["id"], wireTask("t-1", "input_required"))
      of "tasks/result":
        self.reply(message["id"], %*{"content": [{"type": "text", "text": "done"}]})
      else: discard,
      capabilities = ServerWithTasks)
    let client = peer.connect()
    let content = waitFor client.callToolWithTask(optionalTool(),
      sleep = noSleep)
    check content.contentItems[0].text == "done"

  taskTest "Given a task that failed with a tool result, when called with a task and waited for, then isError is reported as for a plain call":
    let peer = startPeer(proc(self: Peer, message: JsonNode) =
      case message{"method"}.getStr()
      of "tools/call":
        self.reply(message["id"], %*{"task": wireTask("t-1", "working")})
      of "tasks/get":
        self.reply(message["id"], wireTask("t-1", "failed"))
      of "tasks/result":
        self.reply(message["id"], %*{"content": [{"type": "text", "text": "rate limit"}],
                                     "isError": true})
      else: discard,
      capabilities = ServerWithTasks)
    let client = peer.connect()
    let content = waitFor client.callToolWithTask(optionalTool(),
      sleep = noSleep)
    check content.isError

suite "tasks client: status notifications":
  taskTest "Given a callback, when the server pushes a task status, then the callback gets the whole task":
    let peer = startPeer(nil, capabilities = ServerWithTasks)
    let client = peer.connect()
    var seen: seq[McpTask]
    client.onTaskStatus(proc(task: McpTask) = seen.add task)
    peer.push("notifications/tasks/status", wireTask("t-1", "completed"))
    waitFor sleepAsync(20)
    check seen.len == 1
    check seen[0].taskId == "t-1"
    check seen[0].status == tsCompleted

suite "tasks client: capabilities":
  taskTest "Given a client that receives tasks, when it connects, then initialize declares list, cancel and the sampling request":
    let peer = startPeer(nil, capabilities = ServerWithTasks)
    discard peer.connectedClient(TaskVersion, proc(client: McpClient) =
      client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
        return McpSamplingResult(role: "assistant", model: "m",
          content: McpContentItem(kind: mckText, text: "x")))
      discard client.enableClientTasks())
    let declared = peer.requestsFor("initialize")[0]["params"]["capabilities"]
    check declared["tasks"] == %*{"list": {}, "cancel": {}, "requests": {"sampling": {"createMessage": {}}}}

  taskTest "Given sampling asked for but no sampling handler, when tasks are enabled, then it is an error":
    let peer = startPeer(nil, capabilities = ServerWithTasks)
    let client = newMcpClient(McpClientInfo(name: "c", version: "0"), TaskVersion)
    expect McpError:
      discard client.enableClientTasks()
    discard peer

suite "tasks client: as the receiver of a task-augmented sampling request":
  proc sampler(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
    if request.systemPrompt == some("fail"):
      raise newException(McpRequestError, "the user rejected the request")
    return McpSamplingResult(role: "assistant", model: "m",
      content: McpContentItem(kind: mckText, text: "echo:" & request.messages[0].content.text))

  proc samplingParams(task: JsonNode = nil, systemPrompt = ""): JsonNode =
    result = %*{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}],
                "maxTokens": 10}
    if systemPrompt.len > 0:
      result["systemPrompt"] = %systemPrompt
    if not task.isNil:
      result["task"] = task

  proc receiving(): tuple[peer: Peer, client: McpClient, store: TaskStore] =
    let store = newTaskStore(pollIntervalMs = some(500))
    let peer = startPeer(nil, capabilities = ServerWithTasks)
    let client = peer.connectedClient(TaskVersion, proc(client: McpClient) =
      client.setSamplingHandler(sampler)
      discard client.enableClientTasks(store = store))
    (peer: peer, client: client, store: store)

  taskTest "Given a sampling request with a task, when it arrives, then a working task is answered at once and the result follows by tasks/result":
    let r = receiving()
    r.peer.ask(%"s1", "sampling/createMessage", samplingParams(%*{"ttl": 20_000}))
    let created = r.peer.answerOf("s1")["result"]["task"]
    check created["status"].getStr() == "working"
    check created["ttl"].getInt() == 20_000
    check created["pollInterval"].getInt() == 500
    let id = created["taskId"].getStr()
    r.peer.ask(%"g1", "tasks/get", %*{"taskId": id})
    check r.peer.answerOf("g1")["result"]["taskId"].getStr() == id
    r.peer.ask(%"r1", "tasks/result", %*{"taskId": id})
    let outcome = r.peer.answerOf("r1")["result"]
    check outcome["content"]["text"].getStr() == "echo:hi"
    check outcome["model"].getStr() == "m"
    check outcome["_meta"][RelatedTask]["taskId"].getStr() == id
    r.peer.ask(%"g2", "tasks/get", %*{"taskId": id})
    check r.peer.answerOf("g2")["result"]["status"].getStr() == "completed"

  taskTest "Given a sampling request without a task, when it arrives, then the result comes directly":
    let r = receiving()
    r.peer.ask(%"s1", "sampling/createMessage", samplingParams())
    let answer = r.peer.answerOf("s1")["result"]
    check answer["content"]["text"].getStr() == "echo:hi"
    check not answer.hasKey("task")

  taskTest "Given a handler that rejects the request, when the task's result is fetched, then it is that error and the task failed":
    let r = receiving()
    r.peer.ask(%"s1", "sampling/createMessage", samplingParams(%*{}, systemPrompt = "fail"))
    let id = r.peer.answerOf("s1")["result"]["task"]["taskId"].getStr()
    r.peer.ask(%"r1", "tasks/result", %*{"taskId": id})
    check r.peer.answerOf("r1")["error"]["message"].getStr() == "the user rejected the request"
    r.peer.ask(%"g1", "tasks/get", %*{"taskId": id})
    check r.peer.answerOf("g1")["result"]["status"].getStr() == "failed"

  taskTest "Given tasks of the client, when the server lists and cancels, then it can, and a finished task cannot be cancelled":
    let r = receiving()
    r.peer.ask(%"s1", "sampling/createMessage", samplingParams(%*{}))
    let id = r.peer.answerOf("s1")["result"]["task"]["taskId"].getStr()
    r.peer.ask(%"r1", "tasks/result", %*{"taskId": id})
    discard r.peer.answerOf("r1")
    r.peer.ask(%"l1", "tasks/list", newJObject())
    check r.peer.answerOf("l1")["result"]["tasks"][0]["taskId"].getStr() == id
    r.peer.ask(%"c1", "tasks/cancel", %*{"taskId": id})
    check r.peer.answerOf("c1")["error"]["code"].getInt() == -32602

  taskTest "Given a task of the client, when its status changes, then the server is told":
    let r = receiving()
    r.peer.ask(%"s1", "sampling/createMessage", samplingParams(%*{}))
    let id = r.peer.answerOf("s1")["result"]["task"]["taskId"].getStr()
    for _ in 1 .. 500:
      if r.peer.requestsFor("notifications/tasks/status").len > 0: break
      waitFor sleepAsync(2)
    let notice = r.peer.requestsFor("notifications/tasks/status")[0]["params"]
    check notice["taskId"].getStr() == id
    check notice["status"].getStr() == "completed"

  taskTest "Given a connection of an older version, when a sampling request carries a task, then it is answered directly":
    let store = newTaskStore()
    let peer = startPeer(nil, capabilities = ServerWithTasks)
    discard peer.connectedClient(mpv20250618, proc(client: McpClient) =
      client.setSamplingHandler(sampler)
      discard client.enableClientTasks(store = store))
    peer.ask(%"s1", "sampling/createMessage", samplingParams(%*{}))
    check peer.answerOf("s1")["result"]["content"]["text"].getStr() == "echo:hi"
    peer.ask(%"g1", "tasks/get", %*{"taskId": "x"})
    check peer.answerOf("g1")["error"]["code"].getInt() == -32601
