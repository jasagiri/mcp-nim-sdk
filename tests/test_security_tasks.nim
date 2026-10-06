## H4 of the security review: a ttl chosen by one requestor must not stop the
## tasks of the others. The store sweeps on every operation, so a task whose
## expiry cannot be computed, or whose cleanup raises, would reach everyone.

import std/[asyncdispatch, json, options, unittest]
import ./server_harness
import protocol/tasks
import protocol/version
import server/tasks

type FakeTime = ref object
  nowMs: int64

proc storeAt(time: FakeTime, maxTtlMs = some(DefaultMaxTtlMs)): TaskStore =
  newTaskStore(clock = proc(): int64 = time.nowMs, maxTtlMs = maxTtlMs)

proc raisesTaskError(action: proc() {.closure.}, code: int): bool =
  try:
    action()
  except McpTaskError as e:
    return e.code == code
  false

suite "security: a task's ttl does not reach other owners":
  test "Given a task asked for with the largest ttl, when another owner uses the store, then every operation still works":
    let time = FakeTime(nowMs: 1_764_067_800_000)
    let store = storeAt(time)
    var survived = false
    try:
      discard store.create("mallory", some(int64.high))
      let mine = store.create("alice", some(60_000'i64))
      check store.get("alice", mine.taskId).taskId == mine.taskId
      check store.list("alice").len == 1
      survived = true
    except OverflowDefect as e:
      checkpoint "OverflowDefect: " & e.msg
    check survived

  test "Given a store that grants any ttl, when the largest is asked for, then the task never expires and the others are untouched":
    let time = FakeTime(nowMs: 1_764_067_800_000)
    let store = storeAt(time, maxTtlMs = none(int64))
    var survived = false
    try:
      let forever = store.create("mallory", some(int64.high))
      discard store.create("alice", some(60_000'i64))
      time.nowMs += 120_000
      check store.list("alice").len == 0
      check store.get("mallory", forever.taskId).ttlMs == some(int64.high)
      survived = true
    except OverflowDefect as e:
      checkpoint "OverflowDefect: " & e.msg
    check survived

  test "Given the default store, when a ttl beyond the maximum is asked for, then the task gets the maximum":
    let store = storeAt(FakeTime(nowMs: 1_000))
    check store.create("a", some(int64.high)).ttlMs == some(DefaultMaxTtlMs)
    check store.create("b", some(DefaultMaxTtlMs + 1)).ttlMs == some(DefaultMaxTtlMs)
    check store.create("c", some(DefaultMaxTtlMs)).ttlMs == some(DefaultMaxTtlMs)
    check store.create("d", some(5_000'i64)).ttlMs == some(5_000'i64)

  test "Given a negative ttl, when a task is created, then it is invalid params and nothing is stored":
    let store = storeAt(FakeTime(nowMs: 1_000))
    check raisesTaskError(proc() = discard store.create("a", some(-1'i64)), -32602)
    check store.list("a").len == 0

  test "Given a task whose work cannot be stopped, when it expires, then the other expired tasks are still removed":
    let time = FakeTime(nowMs: 1_000)
    let store = storeAt(time)
    let broken = store.create("a", some(1_000'i64))
    store.attachWork(broken.taskId, proc(reason: string) = raise newException(ValueError, "no"))
    discard store.create("b", some(1_000'i64))
    let kept = store.create("c", some(100_000'i64))
    time.nowMs += 2_000
    check store.list("c").len == 1
    check store.list("a").len == 0
    check store.list("b").len == 0
    check store.get("c", kept.taskId).taskId == kept.taskId

suite "security: what one owner may make the store keep":
  test "Given the default store, when an owner has the default number of active tasks, then the next is refused and another owner is not":
    let store = storeAt(FakeTime(nowMs: 1_000))
    for _ in 1 .. DefaultMaxActivePerOwner:
      discard store.create("mallory", none(int64))
    check raisesTaskError(proc() = discard store.create("mallory", none(int64)), -32603)
    discard store.create("alice", none(int64))

  test "Given an owner whose tasks are over, when the kept ones reach the limit, then no more are made until they expire":
    let time = FakeTime(nowMs: 1_000)
    let store = newTaskStore(clock = proc(): int64 = time.nowMs, maxTasksPerOwner = 3)
    for _ in 1 .. 3:
      let task = store.create("mallory", some(10_000'i64))
      discard store.finish(task.taskId, TaskOutcome(result: some(newJObject())))
    check raisesTaskError(proc() = discard store.create("mallory", none(int64)), -32603)
    time.nowMs += 10_000
    discard store.create("mallory", none(int64))

  test "Given a store with a total limit, when many owners fill it, then a new task is refused until some expire":
    let time = FakeTime(nowMs: 1_000)
    let store = newTaskStore(clock = proc(): int64 = time.nowMs, maxTasks = 5)
    for owner in 1 .. 5:
      discard store.create("owner-" & $owner, some(10_000'i64))
    check raisesTaskError(proc() = discard store.create("late", none(int64)), -32603)
    time.nowMs += 10_000
    discard store.create("late", none(int64))

  test "Given limits of 0, when many tasks are made, then none is refused":
    let store = newTaskStore(clock = proc(): int64 = 1_000, maxActivePerOwner = 0,
                             maxTasksPerOwner = 0, maxTasks = 0)
    for _ in 1 .. 600:
      discard store.create("a", none(int64))
    check store.list("a").len == 600

suite "security: the ttl of a task parameter":
  proc ttlOf(ttl: JsonNode): Option[Option[int64]] =
    parseTaskParam(%*{"task": {"ttl": ttl}})

  test "Given a whole number written as a float, when parsed, then it is that many milliseconds":
    check ttlOf(%1.5e6) == some(some(1_500_000'i64))
    check ttlOf(%0.0) == some(some(0'i64))

  test "Given a float beyond what a ttl can be, when parsed, then it is the largest and the store grants its maximum":
    check ttlOf(%1e30) == some(some(int64.high))

  test "Given a fraction, a negative number, a string or a boolean, when parsed, then it is invalid params":
    for bad in [%1.5, %(-1), %(-0.5), %"1000", %true, %*[1], %*{"ms": 1}]:
      check raisesTaskError(proc() = discard ttlOf(bad), -32602)

  test "Given a ttl of null or none, when parsed, then the task asks for the default":
    check ttlOf(newJNull()) == some(none(int64))
    check parseTaskParam(%*{"task": {}}) == some(none(int64))

proc reportServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"name": "report", "inputSchema": {"type": "object"},
                               "execution": {"taskSupport": "optional"}}]))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    return %*{"content": [{"type": "text", "text": "done"}]})

if isSupported(mpv20251125):
  suite "security: through the server":
    test "Given a client that asks for the largest ttl, when another client lists its tasks, then it is answered":
      let server = reportServer()
      discard server.enableTasks(store = storeAt(FakeTime(nowMs: 1_764_067_800_000)))
      let transport = server.attach()
      let mallory = server.connect(transport, mpv20251125, "mallory")
      let created = mallory.ask("tools/call", %*{"name": "report", "arguments": {},
                                                  "task": {"ttl": int64.high}})
      check created["result"]["task"]["ttl"].getBiggestInt() == DefaultMaxTtlMs
      let alice = server.connect(transport, mpv20251125, "alice")
      let listed = alice.ask("tasks/list")
      check not listed.hasKey("error")
      check listed["result"]["tasks"].len == 0

    test "Given a ttl that is a fraction, when a task is asked for, then the call is invalid params":
      let server = reportServer()
      discard server.enableTasks(store = storeAt(FakeTime(nowMs: 1_764_067_800_000)))
      let peer = server.connect(server.attach(), mpv20251125, "p")
      let answer = peer.ask("tools/call", %*{"name": "report", "arguments": {},
                                              "task": {"ttl": 1.5}})
      check answer["error"]["code"].getInt() == -32602
