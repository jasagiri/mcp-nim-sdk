## Wait for the first of several futures without touching the callbacks
## they already have.
##
## Nim's `a or b` assigns `a.callback = ...`, which first CLEARS every
## callback on `a` and `b`. A future that somebody else also waits on (a
## cancel token shared by two requests, a `sent` future the SDK itself
## watches) silently loses that waiter. Everything here only adds callbacks.
##
## Internal to the SDK: not exported from `mcp`.

import std/asyncdispatch

type
  Doorbell* = ref object
    ## Rings once any of the futures given to `watch` has finished. For a
    ## loop that waits many times on futures that outlive one wait: each
    ## future is watched once, instead of once per wait (a callback cannot be
    ## taken off a future again, so `firstOf` per wait would pile them up).
    ## A ring with nobody waiting is kept for the next `wait`, so a wait can
    ## wake for a future the caller has already dealt with: the caller looks
    ## at its futures after waking.
    rung: bool
    failure: ref Exception
    waiting: Future[void]

proc newDoorbell*(): Doorbell =
  Doorbell()

proc deliver(bell: Doorbell, waiting: Future[void]) =
  let failure = bell.failure
  bell.rung = false
  bell.failure = nil
  if failure.isNil:
    waiting.complete()
  else:
    waiting.fail(failure)

proc watch*(bell: Doorbell, source: FutureBase) =
  ## Ring when `source` finishes. A failed `source` makes the next `wait`
  ## fail with the same error, as `or` does.
  source.addCallback(proc() =
    if not bell.rung:
      bell.rung = true
      if source.failed:
        bell.failure = source.error
    if not bell.waiting.isNil:
      let waiting = bell.waiting
      bell.waiting = nil
      bell.deliver(waiting))

proc wait*(bell: Doorbell): Future[void] =
  ## Completes at the next ring, at once when one is already pending.
  result = newFuture[void]("Doorbell.wait")
  if bell.rung:
    bell.deliver(result)
  else:
    bell.waiting = result

proc firstOf*(futures: varargs[FutureBase]): Future[void] =
  ## Completes when the first of `futures` finishes, failing with its error
  ## if it failed; the others are left as they were. Replaces
  ## `await (a or b or c)`.
  let bell = newDoorbell()
  for source in futures:
    bell.watch(source)
  bell.wait()
