## The token with which a caller withdraws requests.
##
## `newMcpCancelToken`, `cancel`, `isCancelled`, `whenCancelled` and
## `cancelReason` are the SDK's public API; `client` re-exports exactly
## those. `watchCancellation`, `unwatchCancellation` and `heldWaiters` are the
## client's own: they let any number of requests share a token without
## putting a callback on its future per request, and they are imported from
## here (by `client`, `subscriptions` and the tests of this) and not through
## `mcp`.

import std/asyncdispatch

type
  McpCancelToken* = ref object
    ## Lets the caller of an operation withdraw it. Pass it in
    ## McpRequestOptions; `cancel` makes the waiting call raise
    ## McpCancelledError and tells the server to stop.
    reason: string
    signal: Future[void]
    waiters: seq[Future[void]]

proc newMcpCancelToken*(): McpCancelToken =
  McpCancelToken(signal: newFuture[void]("McpCancelToken"))

proc cancel*(token: McpCancelToken, reason: string = "") =
  ## Idempotent: only the first call counts.
  if not token.signal.finished:
    token.reason = reason
    token.signal.complete()
    # Each waiter is woken from here and not by a callback on `signal`: a
    # callback cannot be taken off a future again, so one per request would
    # stay on a token that outlives its requests.
    let woken = token.waiters
    token.waiters = @[]
    for waiter in woken:
      if not waiter.finished:
        waiter.complete()

proc isCancelled*(token: McpCancelToken): bool = token.signal.finished

proc whenCancelled*(token: McpCancelToken): Future[void] = token.signal
  ## Completes when the token is cancelled.

proc cancelReason*(token: McpCancelToken): string = token.reason

proc watchCancellation*(token: McpCancelToken): Future[void] =
  ## A future that completes when `token` is cancelled, for one request to
  ## wait on; give it back with `unwatchCancellation` when the request ends.
  ## Unlike `whenCancelled` it touches no callback of the token's own
  ## future, so any number of requests can share a token.
  result = newFuture[void]("McpCancelToken.watch")
  if token.signal.finished:
    result.complete()
  else:
    token.waiters.add result

proc unwatchCancellation*(token: McpCancelToken, waiter: Future[void]) =
  ## The request that waited with `waiter` has ended.
  let at = token.waiters.find(waiter)
  if at >= 0:
    token.waiters.del(at)

proc heldWaiters*(token: McpCancelToken): int =
  ## How many requests are still waiting on `token`; for tests.
  token.waiters.len
