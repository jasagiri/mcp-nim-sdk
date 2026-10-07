## `firstOf` and `Doorbell`: waiting for the first of several futures
## without removing the callbacks others have on them (which `or` does).

import std/[unittest, asyncdispatch]
import transport/first_of

proc settle() =
  ## Let the callbacks that were scheduled run.
  waitFor sleepAsync(2)

suite "waiting for the first of several futures":

  test "Given two futures, when one completes, then the wait completes":
    let a = newFuture[void]("a")
    let b = newFuture[void]("b")
    let wait = firstOf(a, b)
    check not wait.finished
    b.complete()
    settle()
    check wait.finished and not wait.failed
    check not a.finished

  test "Given a future that already finished, when it is waited on, then the wait completes":
    let done = newFuture[void]("done")
    done.complete()
    let wait = firstOf(done, newFuture[void]("never"))
    settle()
    check wait.finished

  test "Given a failed future, when it is the first to finish, then the wait fails with its error":
    let a = newFuture[void]("a")
    let b = newFuture[void]("b")
    let wait = firstOf(a, b)
    a.fail(newException(ValueError, "boom"))
    settle()
    check wait.failed
    check wait.readError().msg == "boom"

  test "Given a future with a callback, when it is waited on, then the callback still runs":
    let shared = newFuture[void]("shared")
    var ran = 0
    shared.addCallback(proc() = inc ran)
    let wait = firstOf(shared, newFuture[void]("other"))
    shared.complete()
    settle()
    check wait.finished
    check ran == 1

  test "Given two waits on the same future, when it completes, then both complete":
    let shared = newFuture[void]("shared")
    let first = firstOf(shared, newFuture[void]("one"))
    let second = firstOf(shared, newFuture[void]("two"))
    shared.complete()
    settle()
    check first.finished
    check second.finished

  test "Given a wait that was answered, when the other future finishes later, then nothing happens":
    let a = newFuture[void]("a")
    let b = newFuture[void]("b")
    let wait = firstOf(a, b)
    a.complete()
    settle()
    b.fail(newException(ValueError, "late"))
    settle()
    check wait.finished and not wait.failed

suite "a doorbell for futures that outlive one wait":

  test "Given a watched future, when it finishes during a wait, then the wait completes":
    let bell = newDoorbell()
    let source = newFuture[void]("source")
    bell.watch(source)
    let wait = bell.wait()
    check not wait.finished
    source.complete()
    settle()
    check wait.finished

  test "Given a future that finished while nobody waited, when a wait starts, then it completes at once":
    let bell = newDoorbell()
    let source = newFuture[void]("source")
    bell.watch(source)
    source.complete()
    settle()
    check bell.wait().finished

  test "Given a ring that was heard, when the next wait starts, then it waits again":
    let bell = newDoorbell()
    let first = newFuture[void]("first")
    let second = newFuture[void]("second")
    bell.watch(first)
    bell.watch(second)
    first.complete()
    settle()
    check bell.wait().finished
    let again = bell.wait()
    settle()
    check not again.finished
    second.complete()
    settle()
    check again.finished

  test "Given a watched future that fails, when a wait starts, then the wait fails with its error":
    let bell = newDoorbell()
    let source = newFuture[void]("source")
    bell.watch(source)
    source.fail(newException(ValueError, "boom"))
    settle()
    let wait = bell.wait()
    check wait.failed
    check wait.readError().msg == "boom"
