## State a receiver keeps per task, for tasks a peer makes, lets go of it when
## the task expires: expiry is no status change, so a hook says so.

import std/[options, unittest]
import protocol/tasks

suite "security sweep: state kept for a task lets go when the task expires":
  test "Given a task that expires while it works, when the store is used, then the expiry hook sees it once":
    var now = 1_000'i64
    let store = newTaskStore(clock = proc(): int64 = now)
    var seen: seq[string]
    store.onExpire = proc(owner: string, task: McpTask) =
      seen.add owner & "/" & task.taskId
    let task = store.create("alice", some(500'i64))
    discard store.create("bob", some(100_000'i64))
    now += 1_000
    check store.list("bob").len == 1
    check store.list("bob").len == 1
    check seen == @["alice/" & task.taskId]

  test "Given an expiry hook that raises, when a task expires, then the others are still removed and heard":
    var now = 1_000'i64
    let store = newTaskStore(clock = proc(): int64 = now)
    var heard = 0
    store.onExpire = proc(owner: string, task: McpTask) =
      inc heard
      raise newException(ValueError, "hook failed")
    discard store.create("a", some(500'i64))
    discard store.create("b", some(500'i64))
    now += 1_000
    check store.list("c").len == 0
    check heard == 2

