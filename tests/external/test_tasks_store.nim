## The state machine and the store of tasks (2025-11-25, basic/utilities/tasks):
## what a receiver keeps for a task, independent of whether the receiver is a
## server or a client. The clock is a variable, so no test sleeps.

import std/[asyncdispatch, json, options, os, sequtils, sets, strutils, times, unittest]
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

suite "tasks: creation":
  test "Given a new task, when created, then it works, has the requested ttl and a receiver-made id":
    let time = FakeTime(nowMs: 1_000)
    let store = storeAt(time)
    let task = store.create("alice", some(5_000'i64))
    check task.status == tsWorking
    check task.ttlMs == some(5_000'i64)
    check task.pollIntervalMs == some(250)
    check task.createdAtMs == 1_000
    check task.lastUpdatedAtMs == 1_000
    check task.taskId.len > 0

  test "Given many tasks, when created, then every id differs and none can be guessed from a counter":
    let time = FakeTime()
    let store = newTaskStore(clock = proc(): int64 = time.nowMs, maxActivePerOwner = 0,
                             maxTasksPerOwner = 0)
    var ids = initHashSet[string]()
    for _ in 1 .. 200:
      ids.incl store.create("alice", none(int64)).taskId
    check ids.len == 200
    for id in ids:
      check id.len >= 32  # at least 128 bits of the system's random source

  test "Given no requested ttl, when created, then the store's default applies":
    let store = storeAt(FakeTime(), defaultTtlMs = some(7_000'i64))
    check store.create("a", none(int64)).ttlMs == some(7_000'i64)

  test "Given a store that retains tasks for ever by default, when created without ttl, then the ttl is unlimited":
    let store = storeAt(FakeTime(), defaultTtlMs = none(int64))
    check store.create("a", none(int64)).ttlMs.isNone

  test "Given a maximum ttl, when a longer one is requested, then the receiver overrides it":
    let store = storeAt(FakeTime(), maxTtlMs = some(10_000'i64))
    check store.create("a", some(99_000'i64)).ttlMs == some(10_000'i64)
    check store.create("a", none(int64)).ttlMs == some(10_000'i64)

  test "Given a task, when rendered, then it has the fields of the schema, ISO 8601 times and a null ttl when unlimited":
    let store = storeAt(FakeTime(nowMs: 1_764_067_800_000), defaultTtlMs = none(int64))
    let task = store.create("a", none(int64))
    let node = task.toJson()
    check node["taskId"].getStr() == task.taskId
    check node["status"].getStr() == "working"
    check node["createdAt"].getStr() == "2025-11-25T10:50:00.000Z"
    check node["lastUpdatedAt"].getStr() == "2025-11-25T10:50:00.000Z"
    check node.hasKey("ttl") and node["ttl"].kind == JNull
    check node["pollInterval"].getInt() == 250
    check not node.hasKey("statusMessage")

suite "tasks: parameters of a task-augmented request":
  test "Given params with a task and a ttl, when parsed, then the ttl is returned":
    let asked = parseTaskParam(%*{"name": "x", "task": {"ttl": 60000}})
    check asked.isSome
    check asked.get == some(60_000'i64)

  test "Given params with an empty task object, when parsed, then a task is asked for without ttl":
    let asked = parseTaskParam(%*{"task": {}})
    check asked.isSome
    check asked.get.isNone

  test "Given params without a task, when parsed, then none is asked for":
    check parseTaskParam(%*{"name": "x"}).isNone
    check parseTaskParam(nil).isNone

  test "Given a task that is not an object or a ttl that is not a number, when parsed, then it is Invalid params":
    for params in [%*{"task": "yes"}, %*{"task": {"ttl": "soon"}}, %*{"task": {"ttl": -1}}]:
      expect McpTaskError:
        discard parseTaskParam(params)
      try:
        discard parseTaskParam(params)
      except McpTaskError as e:
        check e.code == -32602

suite "tasks: status lifecycle":
  test "Given a working task, when it moves to each status the specification allows, then it does":
    for next in [tsInputRequired, tsCompleted, tsFailed, tsCancelled]:
      let store = storeAt(FakeTime())
      let task = store.create("a", none(int64))
      check store.transition(task.taskId, next)
      check store.get("a", task.taskId).status == next

  test "Given an input_required task, when it moves on, then working, completed, failed and cancelled are allowed":
    for next in [tsWorking, tsCompleted, tsFailed, tsCancelled]:
      let store = storeAt(FakeTime())
      let task = store.create("a", none(int64))
      check store.transition(task.taskId, tsInputRequired)
      check store.transition(task.taskId, next)
      check store.get("a", task.taskId).status == next

  test "Given a terminal task, when another status is set, then it stays and the change is refused":
    for terminal in [tsCompleted, tsFailed, tsCancelled]:
      let store = storeAt(FakeTime())
      let task = store.create("a", none(int64))
      check store.transition(task.taskId, terminal)
      for next in [tsWorking, tsInputRequired, tsCompleted, tsFailed, tsCancelled]:
        check not store.transition(task.taskId, next)
        check store.get("a", task.taskId).status == terminal

  test "Given a task that changes, when it does, then lastUpdatedAt moves and createdAt does not":
    let time = FakeTime(nowMs: 1_000)
    let store = storeAt(time)
    let task = store.create("a", none(int64))
    time.nowMs = 4_000
    check store.transition(task.taskId, tsInputRequired, some("needs a name"))
    let changed = store.get("a", task.taskId)
    check changed.createdAtMs == 1_000
    check changed.lastUpdatedAtMs == 4_000
    check changed.statusMessage == some("needs a name")

  test "Given a status change, when it happens, then the store reports the full task to its owner":
    let store = storeAt(FakeTime())
    var seen: seq[(string, TaskStatus)]
    store.onStatusChange = proc(owner: string, task: McpTask) =
      seen.add (owner, task.status)
    let task = store.create("alice", none(int64))
    discard store.transition(task.taskId, tsInputRequired)
    discard store.transition(task.taskId, tsWorking)
    check store.finish(task.taskId, success(%*{"ok": true}))
    check seen == @[("alice", tsInputRequired), ("alice", tsWorking), ("alice", tsCompleted)]

suite "tasks: finishing":
  test "Given a request that succeeded, when finished, then the task is completed and keeps the result":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    check store.finish(task.taskId, success(%*{"content": []}))
    check store.get("a", task.taskId).status == tsCompleted
    let outcome = waitFor store.awaitOutcome("a", task.taskId)
    check outcome.result.get["content"].len == 0

  test "Given a request that ended in a JSON-RPC error, when finished, then the task failed with the error's message":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    check store.finish(task.taskId, failure(-32602, "bad arguments"))
    let failed = store.get("a", task.taskId)
    check failed.status == tsFailed
    check failed.statusMessage == some("bad arguments")
    let outcome = waitFor store.awaitOutcome("a", task.taskId)
    check outcome.error.get.code == -32602

  test "Given a tool result with isError, when finished, then the task failed and the result is kept as it was":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    let toolResult = %*{"content": [{"type": "text", "text": "rate limit"}], "isError": true}
    check store.finish(task.taskId, success(toolResult))
    check store.get("a", task.taskId).status == tsFailed
    check store.get("a", task.taskId).statusMessage == some("rate limit")
    let outcome = waitFor store.awaitOutcome("a", task.taskId)
    check outcome.result.get == toolResult

  test "Given a cancelled task, when its execution finishes later, then it stays cancelled":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    discard store.cancel("a", task.taskId)
    check not store.finish(task.taskId, success(%*{}))
    check store.get("a", task.taskId).status == tsCancelled

suite "tasks: retrieval":
  test "Given a working task, when the result is awaited, then the wait ends when the task does":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    let waiting = store.awaitOutcome("a", task.taskId)
    check not waiting.finished
    check store.finish(task.taskId, success(%*{"n": 1}))
    check waitFor(waiting).result.get["n"].getInt() == 1

  test "Given an input_required task, when the result is awaited, then it still waits":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    discard store.transition(task.taskId, tsInputRequired)
    let waiting = store.awaitOutcome("a", task.taskId)
    check not waiting.finished
    discard store.finish(task.taskId, success(%*{}))
    check waitFor(waiting).result.isSome

  test "Given a cancelled task, when the result is awaited, then it is a JSON-RPC error, not a result":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    discard store.cancel("a", task.taskId)
    let outcome = waitFor store.awaitOutcome("a", task.taskId)
    check outcome.result.isNone
    check outcome.error.isSome

  test "Given an id nobody made, when looked up, then it is Invalid params 'not found'":
    let store = storeAt(FakeTime())
    try:
      discard store.get("a", "no-such-task")
      fail()
    except McpTaskError as e:
      check e.code == -32602
      check "not found" in e.msg.toLowerAscii

suite "tasks: listing":
  test "Given tasks of two owners, when one lists, then it sees its own in creation order":
    let store = storeAt(FakeTime())
    let a1 = store.create("alice", none(int64))
    discard store.create("bob", none(int64))
    let a2 = store.create("alice", none(int64))
    check store.list("alice").mapIt(it.taskId) == @[a1.taskId, a2.taskId]
    check store.list("carol").len == 0

  test "Given a task that get returns, when listed, then it is in the list too":
    let store = storeAt(FakeTime())
    let task = store.create("alice", none(int64))
    discard store.finish(task.taskId, success(%*{}))
    check task.taskId in store.list("alice").mapIt(it.taskId)

suite "tasks: cancellation":
  test "Given a working task, when cancelled, then it is cancelled before the call returns":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    let cancelled = store.cancel("a", task.taskId)
    check cancelled.status == tsCancelled
    check store.get("a", task.taskId).status == tsCancelled

  test "Given a terminal task, when cancelled, then it is Invalid params and names the status":
    for terminal in [tsCompleted, tsFailed, tsCancelled]:
      let store = storeAt(FakeTime())
      let task = store.create("a", none(int64))
      discard store.transition(task.taskId, terminal)
      try:
        discard store.cancel("a", task.taskId)
        fail()
      except McpTaskError as e:
        check e.code == -32602
        check $terminal in e.msg

  test "Given a task with work attached, when cancelled, then the work is told to stop":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    var told = ""
    store.attachWork(task.taskId, proc(reason: string) = told = reason)
    discard store.cancel("a", task.taskId, "the user changed their mind")
    check told == "the user changed their mind"

suite "tasks: expiry":
  test "Given a task whose ttl has elapsed, when looked up, then it is gone, whatever its status":
    let time = FakeTime(nowMs: 0)
    let store = storeAt(time)
    let working = store.create("a", some(1_000'i64))
    let done = store.create("a", some(1_000'i64))
    discard store.finish(done.taskId, success(%*{}))
    time.nowMs = 999
    check store.get("a", working.taskId).status == tsWorking
    time.nowMs = 1_000
    expect McpTaskError:
      discard store.get("a", working.taskId)
    expect McpTaskError:
      discard store.get("a", done.taskId)
    check store.list("a").len == 0

  test "Given a task that expires while working, when swept, then its work is told to stop":
    let time = FakeTime(nowMs: 0)
    let store = storeAt(time)
    let task = store.create("a", some(1_000'i64))
    var told = false
    store.attachWork(task.taskId, proc(reason: string) = told = true)
    time.nowMs = 2_000
    check store.sweep() == @[task.taskId]
    check told

  test "Given a result awaited on a task that then expires, when the time comes, then the wait fails as not found":
    let time = FakeTime(nowMs: 0)
    let store = storeAt(time)
    let task = store.create("a", some(1_000'i64))
    let waiting = store.awaitOutcome("a", task.taskId)
    time.nowMs = 5_000
    discard store.sweep()
    expect McpTaskError:
      discard waitFor waiting

  test "Given a task with unlimited ttl, when much time passes, then it stays":
    let time = FakeTime(nowMs: 0)
    let store = storeAt(time, defaultTtlMs = none(int64))
    let task = store.create("a", none(int64))
    time.nowMs = high(int64) div 2
    check store.get("a", task.taskId).status == tsWorking

suite "tasks: isolation":
  test "Given a task of one owner, when another asks for it, then it is not found, as if it did not exist":
    let store = storeAt(FakeTime())
    let task = store.create("alice", none(int64))
    for attempt in 1 .. 3:
      try:
        case attempt
        of 1: discard store.get("mallory", task.taskId)
        of 2: discard store.cancel("mallory", task.taskId)
        else: discard waitFor store.awaitOutcome("mallory", task.taskId)
        fail()
      except McpTaskError as e:
        check e.code == -32602
    check store.get("alice", task.taskId).status == tsWorking

suite "tasks: resource limits":
  test "Given a limit of active tasks per owner, when it is reached, then a new task is refused until one ends":
    let store = newTaskStore(maxActivePerOwner = 2)
    let first = store.create("a", none(int64))
    discard store.create("a", none(int64))
    expect McpTaskError:
      discard store.create("a", none(int64))
    check store.create("b", none(int64)).status == tsWorking
    discard store.finish(first.taskId, success(%*{}))
    check store.create("a", none(int64)).status == tsWorking

suite "tasks: related-task metadata":
  test "Given a result, when tagged for a task, then its _meta names the task and keeps other keys":
    let tagged = withRelatedTask(%*{"content": [], "_meta": {"other": 1}}, "t-1")
    check tagged["_meta"]["io.modelcontextprotocol/related-task"]["taskId"].getStr() == "t-1"
    check tagged["_meta"]["other"].getInt() == 1

  test "Given params without _meta, when tagged, then _meta is created and the original is untouched":
    let original = %*{"a": 1}
    let tagged = withRelatedTask(original, "t-1")
    check tagged["_meta"]["io.modelcontextprotocol/related-task"]["taskId"].getStr() == "t-1"
    check not original.hasKey("_meta")

suite "tasks: reading a task from the wire":
  test "Given a rendered task, when read back, then every field survives":
    let store = storeAt(FakeTime(nowMs: 1_764_067_800_123))
    let task = store.create("a", some(5_000'i64))
    discard store.transition(task.taskId, tsInputRequired, some("needs a name"))
    let read = taskFromJson(store.get("a", task.taskId).toJson())
    check read.isSome
    check read.get == store.get("a", task.taskId)

  test "Given the example of the specification, when read, then times without milliseconds and a missing pollInterval are accepted":
    let read = taskFromJson(%*{
      "taskId": "abc123-def456-ghi789", "status": "completed",
      "createdAt": "2025-11-25T09:15:00Z", "lastUpdatedAt": "2025-11-25T10:40:00Z",
      "ttl": 60000})
    check read.isSome
    check read.get.createdAtMs == 1_764_062_100_000
    check read.get.pollIntervalMs.isNone

  test "Given a time with an offset, when read, then it is the same instant in UTC":
    let read = taskFromJson(%*{
      "taskId": "t", "status": "working", "createdAt": "2025-11-25T18:15:00+09:00",
      "lastUpdatedAt": "2025-11-25T09:15:00.500Z", "ttl": nil})
    check read.get.createdAtMs == 1_764_062_100_000
    check read.get.lastUpdatedAtMs == 1_764_062_100_500
    check read.get.ttlMs.isNone

  test "Given something that is not a task, when read, then none is returned":
    let good = %*{"taskId": "t", "status": "working", "createdAt": "2025-11-25T09:15:00Z",
                  "lastUpdatedAt": "2025-11-25T09:15:00Z", "ttl": 1}
    check taskFromJson(good).isSome
    for key in ["taskId", "status", "createdAt", "lastUpdatedAt", "ttl"]:
      var broken = good.copy()
      broken.delete(key)
      check taskFromJson(broken).isNone
    var unknownStatus = good.copy()
    unknownStatus["status"] = %"paused"
    check taskFromJson(unknownStatus).isNone
    var badTime = good.copy()
    badTime["createdAt"] = %"yesterday"
    check taskFromJson(badTime).isNone
    check taskFromJson(%*[1, 2]).isNone
    check taskFromJson(nil).isNone

  test "Given a time whose minute or second is out of range, when a task is read, then none is returned":
    # Found by fuzzing (tests/fuzz: clientAnswers): std/times raised a Defect.
    let good = %*{"taskId": "t", "status": "working", "createdAt": "2025-11-25T09:15:00Z",
                  "lastUpdatedAt": "2025-11-25T09:15:00Z", "ttl": 1}
    for time in ["2025-11-25T09:15:80Z", "2025-11-25T09:99:00Z", "2025-11-25T09:15:61+09:00",
                 "2025-11-25T09:60:00.5Z"]:
      var broken = good.copy()
      broken["createdAt"] = %time
      check taskFromJson(broken).isNone
    var leap = good.copy()
    leap["createdAt"] = %"2016-12-31T23:59:60Z"
    check taskFromJson(leap).isSome

  test "Given a time that is not RFC 3339, such as a signed year, when a task is read, then none is returned":
    # Found by fuzzing (tests/fuzz: clientAnswers, libFuzzer): a sign before
    # the year moved the second out of the place the range check looked at,
    # and std/times raised a Defect for it.
    let good = %*{"taskId": "t", "status": "working", "createdAt": "2025-11-25T09:15:00Z",
                  "lastUpdatedAt": "2025-11-25T09:15:00Z", "ttl": 1}
    for time in ["+4052-01-01T00:00:80Z", "+2025-11-25T09:15:00Z", "-2025-11-25T09:15:00Z",
                 "02025-11-25T09:15:00Z", "2025-11-25T25:15:00Z", "2025-11-25T09:15:00+24:00"]:
      var broken = good.copy()
      broken["createdAt"] = %time
      check taskFromJson(broken).isNone

suite "tasks: the exact values of the rules":
  test "Given a terminal status, when asked about a move from it, then no status is allowed":
    for terminal in [tsCompleted, tsFailed, tsCancelled]:
      for next in TaskStatus:
        check not canTransition(terminal, next)

  test "Given the system clock, when read, then it counts milliseconds since the epoch":
    let seconds = epochTime()
    let ms = systemClock()
    check ms >= int64(seconds * 1000) - 1
    check ms <= int64(seconds * 1000) + 5_000

  test "Given a time whose fraction ends the text, when read, then it is not a time":
    check parseIsoTimestamp("2025-11-25T10:30:00.123").isNone

  test "Given a task without statusMessage, when read, then it has none":
    let read = taskFromJson(%*{
      "taskId": "t", "status": "working", "createdAt": "2025-11-25T09:15:00Z",
      "lastUpdatedAt": "2025-11-25T09:15:00Z", "ttl": 1})
    check read.get.statusMessage.isNone
    let said = taskFromJson(%*{
      "taskId": "t", "status": "working", "createdAt": "2025-11-25T09:15:00Z",
      "lastUpdatedAt": "2025-11-25T09:15:00Z", "ttl": 1, "statusMessage": "halfway"})
    check said.get.statusMessage == some("halfway")

  test "Given no immediate response, when a CreateTaskResult is made, then it has no _meta":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    check not createTaskResult(task).hasKey("_meta")
    check createTaskResult(task, "On it.")["_meta"][ModelImmediateResponseKey].getStr() == "On it."

  test "Given a ttl of 0, when the params are parsed, then the task is asked for with that ttl":
    check parseTaskParam(%*{"task": {"ttl": 0}}) == some(some(0'i64))
    check parseTaskParam(parseJson("""{"task": {"ttl": 0.0}}""")) == some(some(0'i64))

  test "Given a ttl that is not a non-negative whole number, when the params are parsed, then it is Invalid params":
    for ttl in [parseJson("-2.0"), parseJson("-1.5"), parseJson("1.5"), %Inf, %NaN]:
      try:
        discard parseTaskParam(%*{"task": {"ttl": ttl}})
        fail()
      except McpTaskError as e:
        check e.code == -32602

  test "Given a ttl of 2^63 milliseconds, when the params are parsed, then it is read as the largest":
    check parseTaskParam(%*{"task": {"ttl": 9223372036854775808.0}}) == some(some(high(int64)))

  test "Given a ttl of 0, when a task is created, then it has ttl 0":
    let store = storeAt(FakeTime())
    check store.create("a", some(0'i64)).ttlMs == some(0'i64)


  test "Given an id the store does not hold, when a status is set or the request finished, then nothing happens":
    let store = storeAt(FakeTime())
    check not store.transition("nope", tsCompleted)
    check not store.finish("nope", success(%*{}))

  test "Given a working task, when working is set again with a message, then only the message changes":
    let store = storeAt(FakeTime())
    let task = store.create("a", none(int64))
    check store.transition(task.taskId, tsWorking, some("halfway"))
    let now = store.get("a", task.taskId)
    check now.status == tsWorking
    check now.statusMessage == some("halfway")

  test "Given a tool result with isError and no text, when finished, then the task failed without a message":
    for payload in [%*{"isError": true}, %*{"isError": true, "content": "text"},
                    %*{"isError": true, "content": [{"type": "image"}]}]:
      let store = storeAt(FakeTime())
      let task = store.create("a", none(int64))
      check store.finish(task.taskId, success(payload))
      let now = store.get("a", task.taskId)
      check now.status == tsFailed
      check now.statusMessage.isNone

suite "tasks: waiting and expiry in time":
  test "Given a task with unlimited ttl, when its result is awaited, then the wait ends when the task does":
    let store = storeAt(FakeTime(), defaultTtlMs = none(int64))
    let task = store.create("a", none(int64))
    let waiting = store.awaitOutcome("a", task.taskId)
    waitFor sleepAsync(20)
    check not waiting.finished
    check store.finish(task.taskId, success(%*{"ok": true}))
    check waitFor(waiting).result.get["ok"].getBool()

  test "Given a result awaited on a task that expires, when another operation sweeps it, then the wait fails at once":
    let time = FakeTime(nowMs: 0)
    let store = storeAt(time, defaultTtlMs = some(600_000'i64))
    let task = store.create("a", none(int64))
    let waiting = store.awaitOutcome("a", task.taskId)
    time.nowMs = 600_000
    check store.list("a").len == 0
    waitFor sleepAsync(50)
    check waiting.finished
    check waiting.failed

  test "Given a result awaited on a task with a short ttl, when the ttl elapses, then the wait fails by itself":
    let store = newTaskStore(defaultTtlMs = some(150'i64))
    let task = store.create("a", none(int64))
    let waiting = store.awaitOutcome("a", task.taskId)
    for _ in 1 .. 150:
      if waiting.finished: break
      waitFor sleepAsync(20)
    check waiting.finished
    check waiting.failed

  test "Given work that cannot be stopped, when its task expires, then the others are swept too and the failure is logged":
    let time = FakeTime(nowMs: 0)
    let store = storeAt(time)
    let first = store.create("a", some(1_000'i64))
    let second = store.create("a", some(1_000'i64))
    store.attachWork(first.taskId, proc(reason: string) = raise newException(ValueError, "cannot stop"))
    var expired: seq[string]
    store.onExpire = proc(owner: string, task: McpTask) = expired.add task.taskId
    time.nowMs = 2_000
    let log = loggedWhile(proc() = discard store.sweep())
    check "stopping the work of expired task " & first.taskId in log
    check "cannot stop" in log
    check store.list("a").len == 0
    check expired.len == 2
    check second.taskId in expired

  test "Given an expiry hook that raises, when a task expires, then the sweep goes on and the failure is logged":
    let time = FakeTime(nowMs: 0)
    let store = storeAt(time)
    let task = store.create("a", some(1_000'i64))
    store.onExpire = proc(owner: string, task: McpTask) = raise newException(ValueError, "hook broke")
    time.nowMs = 2_000
    let log = loggedWhile(proc() = check store.sweep() == @[task.taskId])
    check "the expiry hook for task " & task.taskId in log
    check "hook broke" in log

suite "tasks: running the request a task stands for":
  proc ending(store: TaskStore, work: Future[JsonRpcResponse]): McpTask =
    runAsTask(store, "a", none(int64), proc(id: string): TaskWork =
      (response: work, cancel: nil))

  test "Given work that raises, when it ends, then the task failed with a bare internal error and the cause is logged":
    let store = storeAt(FakeTime())
    let work = newFuture[JsonRpcResponse]("work")
    let task = store.ending(work)
    let log = loggedWhile(proc() =
      work.fail(newException(ValueError, "disk full"))
      waitFor sleepAsync(20))
    check "task " & task.taskId & " raised disk full" in log
    check store.get("a", task.taskId).status == tsFailed
    let outcome = waitFor store.awaitOutcome("a", task.taskId)
    check outcome.error.get.message == "Internal error"

  test "Given work that succeeds, when it ends, then nothing is logged":
    let store = storeAt(FakeTime())
    let work = newFuture[JsonRpcResponse]("work")
    let task = store.ending(work)
    let log = loggedWhile(proc() =
      work.complete(newJsonRpcResponse("1", %*{"ok": true}))
      waitFor sleepAsync(20))
    check log == ""
    check store.get("a", task.taskId).status == tsCompleted

  test "Given work that raises after its task was cancelled, when it ends, then nothing is logged and the task stays cancelled":
    let store = storeAt(FakeTime())
    let work = newFuture[JsonRpcResponse]("work")
    let task = store.ending(work)
    discard store.cancel("a", task.taskId)
    let log = loggedWhile(proc() =
      work.fail(newException(ValueError, "stopped"))
      waitFor sleepAsync(20))
    check log == ""
    check store.get("a", task.taskId).status == tsCancelled

  test "Given tasks/list with a cursor that is not a string, when answered, then it is Invalid params":
    let store = storeAt(FakeTime())
    let request = newJsonRpcRequest("1", "tasks/list", %*{"cursor": 5})
    let response = waitFor handleTaskMethod(store, "a", McpTasksCapability(list: true, cancel: true), 50, request)
    check response.error.get.code == -32602

  test "Given a method that is no task method, when answered, then it is not found":
    let store = storeAt(FakeTime())
    let request = newJsonRpcRequest("1", "tasks/other", newJObject())
    let response = waitFor handleTaskMethod(store, "a", McpTasksCapability(list: true, cancel: true), 50, request)
    check response.error.get.code == -32601
