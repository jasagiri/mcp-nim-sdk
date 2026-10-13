## The Tasks extension shares the core's store and polls like the core's
## client: what a peer chooses in a task (a poll interval) and what it leaves
## behind when the task expires must not cost the other side.

import std/[asyncdispatch, json, options, unittest]
import server/server except McpRequestError
import client/client
import protocol/types
import protocol/tasks
import protocol/task_methods
import protocol/version
import ext/tasks
import ./loopback_transport

type FakeTime = ref object
  nowMs: int64

proc recordingSleep(slept: ref seq[int], onSleep: proc() = nil): SleepProc =
  result = proc(ms: int): Future[void] =
    slept[].add ms
    if not onSleep.isNil:
      onSleep()
    let done = newFuture[void]("sleep")
    done.complete()
    done

proc release(gate: Future[void]) =
  if not gate.finished:
    gate.complete()

proc connected(server: McpServer): McpClient =
  let pair = newLoopbackPair()
  waitFor server.attachTransport(pair.server)
  let client = newMcpClient(McpClientInfo(name: "c", version: "1"), mpv20260728)
  client.enableTasksExtension()
  waitFor client.connect(pair.client)
  client

proc pollWaits(suggested: int): seq[int] =
  ## The waits of a client polling a task whose server suggests `suggested`.
  let gate = newFuture[void]("gate")
  let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  discard server.enableTasksExtension(TasksExtensionConfig(decide: toolsNamed(["slow"])),
    newTaskStore(pollIntervalMs = some(suggested)))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    await gate
    return %*{"content": []})
  let client = connected(server)
  let taskId = waitFor(client.startToolCall("slow")).task.get.taskId
  let slept = new seq[int]
  discard waitFor client.awaitTask(taskId, sleep = recordingSleep(slept, proc() =
    gate.release()), defaultPollMs = 777)
  slept[]

if isSupported(mpv20260728):

  suite "security: the Tasks extension client polls at a bounded interval":
    test "Given a server that suggests a poll interval of 0, when the client waits for a task, then it waits the minimum":
      let waits = pollWaits(0)
      check waits.len >= 1
      for ms in waits:
        check ms == MinPollIntervalMs

    test "Given a server that suggests days, when the client waits for a task, then it waits the maximum":
      let waits = pollWaits(int(int32.high))
      check waits.len >= 1
      for ms in waits:
        check ms == MaxPollIntervalMs

  suite "security: the Tasks extension lets go of an expired task":
    test "Given a task that expires while its tool runs, when the tool asks for input afterwards, then the task is unknown to the extension":
      let time = FakeTime(nowMs: 1_764_067_800_000)
      let gate = newFuture[void]("gate")
      let outcome = newFuture[string]("outcome")
      let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
        capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
      let tasks = server.enableTasksExtension(TasksExtensionConfig(
        decide: toolsNamed(["late"])),
        newTaskStore(clock = proc(): int64 = time.nowMs, defaultTtlMs = some(1_000'i64)))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        await gate
        try:
          discard await tasks.requestInput(ctx, %*{"method": "roots/list", "params": {}})
          outcome.complete("asked")
        except ValueError:
          outcome.complete("unknown task")
        except CatchableError as e:
          outcome.complete("other: " & e.msg)
        return %*{"content": []})
      let client = connected(server)
      discard waitFor client.startToolCall("late")
      time.nowMs += 2_000
      # Any use of the store sweeps the expired task away.
      check tasks.store.list("nobody").len == 0
      gate.release()
      check waitFor(outcome) == "unknown task"
