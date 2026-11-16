## The time limits of one client's requests, kept by one watcher.
##
## `sleepAsync` cannot be taken back: asyncdispatch keeps its timer until the
## time is up, so a request that used one for its limit left a timer (and its
## callback) in the event loop for up to the whole limit (60 s by default)
## after its answer came. Here a request enters its limit in a table and
## takes it out when it is done; one loop sleeps for the nearest limit in the
## table, and ends when the table is empty. What is left in the event loop
## after the last answer is that loop's one sleep, at most `WatchTickMs` long.
##
## Internal to the SDK: not exported from `mcp`.

import std/[asyncdispatch, monotimes, tables, times]
import ../transport/first_of

const
  WatchTickMs* = 200
    ## The longest the watcher sleeps at a time, so the longest an idle
    ## client's event loop is kept busy by it after its last request ended
    ## (a process that runs the loop until it is empty ends that much later).
    ## Longer makes that delay longer; shorter wakes a client that waits for a
    ## slow answer more often (at 200 ms: five cheap wake-ups a second, only
    ## while a request with a limit is outstanding). Limits do not wait for
    ## the tick: a nearer limit wakes the watcher at once.

type
  Deadline* = object
    ## One request's limit. `due` completes when the limit is over; it never
    ## does for a request without one.
    id: int
    due*: Future[void]

  DeadlineWatch* = ref object
    entries: Table[int, tuple[at: MonoTime, due: Future[void]]]
    nextId: int
    running: bool
    wake: Future[void]
      ## Set while the loop sleeps: completing it ends the sleep.
    wakeAt: MonoTime
      ## When the sleep in progress ends by itself.

proc newDeadlineWatch*(): DeadlineWatch =
  DeadlineWatch(entries: initTable[int, tuple[at: MonoTime, due: Future[void]]]())

proc milliseconds(span: Duration): int =
  ## Rounded up, and at least 1, so a limit a hair away is not slept for 0 ms
  ## over and over.
  let nanos = span.inNanoseconds
  int(max(1'i64, (nanos + 999_999) div 1_000_000))

proc dueEntries(watch: DeadlineWatch, now: MonoTime): seq[Future[void]] =
  ## The limits that are over, taken out of the table.
  var ids: seq[int]
  for id, entry in watch.entries.pairs:
    if entry.at <= now:
      ids.add id
  for id in ids:
    result.add watch.entries[id].due
    watch.entries.del(id)

proc nearest(watch: DeadlineWatch): MonoTime =
  var first = true
  for entry in watch.entries.values:
    if first or entry.at < result:
      result = entry.at
      first = false

proc run(watch: DeadlineWatch) {.async.} =
  ## Sleeps for the nearest limit (at most a tick) while there is one, ends
  ## when there is none. The limits that are over are completed after the
  ## table is updated, so what they wake may enter or leave limits.
  try:
    while watch.entries.len > 0:
      let now = getMonoTime()
      for due in watch.dueEntries(now):
        due.complete()
      if watch.entries.len == 0:
        break
      let wait = min(watch.nearest - getMonoTime(), initDuration(milliseconds = WatchTickMs))
      let sleep = sleepAsync(wait.milliseconds)
      watch.wake = newFuture[void]("DeadlineWatch.wake")
      watch.wakeAt = getMonoTime() + wait
      await firstOf(sleep, watch.wake)
      watch.wake = nil
  finally:
    watch.wake = nil
    watch.running = false

proc start*(watch: DeadlineWatch, timeoutMs: int): Deadline =
  ## Enter a limit of `timeoutMs` from now; 0 or less has none.
  result.due = newFuture[void]("DeadlineWatch.due")
  if timeoutMs <= 0:
    return
  inc watch.nextId
  result.id = watch.nextId
  let at = getMonoTime() + initDuration(milliseconds = timeoutMs)
  watch.entries[result.id] = (at: at, due: result.due)
  if not watch.running:
    watch.running = true
    asyncCheck watch.run()
  elif not watch.wake.isNil and at < watch.wakeAt:
    let wake = watch.wake
    watch.wake = nil
    wake.complete()

proc release*(watch: DeadlineWatch, deadline: Deadline) =
  ## Take a limit back, because its request is done (answered, cancelled or
  ## failed). A limit that is over is already gone; that is not an error.
  if deadline.id != 0:
    watch.entries.del(deadline.id)

proc dropAll*(watch: DeadlineWatch) =
  ## The client is closed: the limits that are left are not kept. The loop,
  ## if it is asleep, ends when it wakes next.
  watch.entries.clear()
