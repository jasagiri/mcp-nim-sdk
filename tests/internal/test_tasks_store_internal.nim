## The state machine and the store of tasks (2025-11-25, basic/utilities/tasks):
## what a receiver keeps for a task, independent of whether the receiver is a
## server or a client. The clock is a variable, so no test sleeps.

import std/[asyncdispatch, json, options, os, unittest]
import protocol/tasks
import protocol/task_methods
import protocol/types

type FakeTime = ref object
  nowMs: int64

proc storeAt(time: FakeTime, defaultTtlMs = some(60_000'i64),
             maxTtlMs = none(int64)): TaskStore =
  newTaskStore(clock = proc(): int64 = time.nowMs, defaultTtlMs = defaultTtlMs,
               maxTtlMs = maxTtlMs, pollIntervalMs = some(250))

proc failure(code: int, message: string): TaskOutcome =
  TaskOutcome(error: some(JsonRpcError(code: code, message: message, data: newJNull())))

proc success(node: JsonNode): TaskOutcome =
  TaskOutcome(result: some(node))

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-tasks-store-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)


suite "tasks: the exact values of the rules":


  test "Given a hook for result streams, when a stream is set and then cleared, then the hook hears only of the set":
    let store = storeAt(FakeTime())
    var heard: seq[string]
    store.onResultStream = proc(owner, taskId, requestId: string) = heard.add requestId
    let task = store.create("a", none(int64))
    store.setResultStream(task.taskId, "r1")
    check store.resultStream(task.taskId) == "r1"
    store.setResultStream(task.taskId, "")
    check store.resultStream(task.taskId) == ""
    check heard == @["r1"]


suite "tasks: running the request a task stands for":
  proc ending(store: TaskStore, work: Future[JsonRpcResponse]): McpTask =
    runAsTask(store, "a", none(int64), proc(id: string): TaskWork =
      (response: work, cancel: nil))

