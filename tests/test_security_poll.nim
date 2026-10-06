## A poll interval a peer suggests is a time a peer chooses: a requestor must
## neither spin on 0 nor wait for days on what the peer says.

import std/[asyncdispatch, options, unittest]
import protocol/tasks
import protocol/task_methods

proc recordingSleep(slept: ref seq[int]): SleepProc =
  result = proc(ms: int): Future[void] =
    slept[].add ms
    let done = newFuture[void]("sleep")
    done.complete()
    done

proc pollOnceMore(suggested: Option[int]): seq[int] =
  ## The waits of a poll of a task that works once, suggests `suggested`
  ## and then completes.
  var polls = 0
  let slept = new seq[int]
  let fetch = proc(): Future[McpTask] {.async.} =
    inc polls
    return McpTask(taskId: "t", status: if polls == 1: tsWorking else: tsCompleted,
                   pollIntervalMs: suggested)
  discard waitFor pollTask(fetch, nil, recordingSleep(slept), 777)
  slept[]

suite "security sweep: the poll interval a peer suggests":
  test "Given a task that suggests a poll interval of 0, when polled, then the wait is the minimum":
    check pollOnceMore(some(0)) == @[MinPollIntervalMs]

  test "Given a task that suggests a negative poll interval, when polled, then the wait is the minimum":
    check pollOnceMore(some(-5)) == @[MinPollIntervalMs]

  test "Given a task that suggests days, when polled, then the wait is the maximum":
    check pollOnceMore(some(int.high)) == @[MaxPollIntervalMs]

  test "Given a task that suggests a reasonable interval, when polled, then it is respected":
    check pollOnceMore(some(250)) == @[250]

  test "Given a task that suggests none, when polled, then the caller's default is used as given":
    check pollOnceMore(none(int)) == @[777]

