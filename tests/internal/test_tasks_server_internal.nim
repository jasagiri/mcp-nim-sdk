## Tasks on the server side (2025-11-25, basic/utilities/tasks): what a client
## sees when it augments a tools/call with a task, and polls, waits, lists and
## cancels. Only 2025-11-25 has tasks in the core; 2026-07-28 and the versions
## before 2025-11-25 must behave as if the feature did not exist.

import std/[asyncdispatch, json, options, os, strutils, unittest]
import ../external/server_harness
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


  suite "tasks server: tasks/get and tasks/result":


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

