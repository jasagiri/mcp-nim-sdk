## Tasks (2025-11-25, basic/utilities/tasks): the state machine and the store
## of a receiver of task-augmented requests.
##
## Nothing here knows whether the receiver is a server or a client, nor which
## request a task wraps: a task has an owner (the authorization context it is
## bound to), a status that follows the specification's transitions, and, once
## terminal, the outcome of the request it stands for. Time comes from a
## clock the caller can replace, so expiry is testable without sleeping.

import std/[asyncdispatch, json, math, options, strutils, sysrand, tables, times]
import ./types
import ./rfc3339

const
  RelatedTaskKey* = "io.modelcontextprotocol/related-task"
    ## `_meta` key that ties a message to a task.
  ModelImmediateResponseKey* = "io.modelcontextprotocol/model-immediate-response"
    ## `_meta` key of a CreateTaskResult: text a host may hand to the model
    ## as the tool result while the task runs.
  TaskIdBytes = 16
    ## 128 bits from the system's random source.
  # The specification asks a receiver to limit concurrent tasks per requestor
  # and the ttl it grants, and to document both (basic/utilities/tasks,
  # "Resource Management"). A task holds its result until its ttl is over, so
  # these three numbers bound what one peer can make the receiver keep.
  DefaultMaxTtlMs* = 86_400_000'i64
    ## 24 hours: a result is worth fetching within a working day; a longer
    ## request is granted this much, and the answer says so.
  DefaultMaxActivePerOwner* = 16
    ## Tasks that are not over, per owner. Each one is running work.
  DefaultMaxTasksPerOwner* = 256
    ## Tasks per owner, over or not: results waiting to be fetched count.
  DefaultMaxTasks* = 4096
    ## Tasks in the whole store. The backstop for owners that cost nothing to
    ## make up (an unauthenticated peer is as many owners as it has sessions).

type
  TaskStatus* = enum
    tsWorking = "working"
    tsInputRequired = "input_required"
    tsCompleted = "completed"
    tsFailed = "failed"
    tsCancelled = "cancelled"

  TaskSupport* = enum
    ## `execution.taskSupport` of a tool: whether a call may, must or must
    ## not be made as a task.
    tsForbidden = "forbidden"
    tsOptional = "optional"
    tsRequired = "required"

  McpTask* = object
    taskId*: string
    status*: TaskStatus
    statusMessage*: Option[string]
    createdAtMs*: int64
      ## Milliseconds since the Unix epoch.
    lastUpdatedAtMs*: int64
    ttlMs*: Option[int64]
      ## How long after creation the receiver may delete the task; none is
      ## unlimited (`null` on the wire).
    pollIntervalMs*: Option[int]

  TaskOutcome* = object
    ## What the request a task stands for returned: a result or an error.
    result*: Option[JsonNode]
    error*: Option[JsonRpcError]

  McpTaskError* = object of CatchableError
    ## A task operation failed in a way the specification gives a JSON-RPC
    ## code for.
    code*: int

  TaskClock* = proc(): int64 {.closure.}
    ## Milliseconds since the Unix epoch.

  TaskStatusCallback* = proc(task: McpTask) {.closure.}

  SleepProc* = proc(ms: int): Future[void] {.closure.}
    ## How a requestor waits between polls; replace it to wait on something
    ## other than the clock.

  TaskEntry = ref object
    task: McpTask
    owner: string
    outcome: Option[TaskOutcome]
    waiters: seq[Future[void]]
    cancelWork: proc(reason: string) {.closure.}
    resultStream: string

  TaskStore* = ref object
    clock: TaskClock
    entries: OrderedTable[string, TaskEntry]
    defaultTtlMs*: Option[int64]
      ## The ttl of a task whose request named none.
    maxTtlMs*: Option[int64]
      ## The longest ttl the receiver grants; a longer request is overridden.
      ## none grants any ttl, `null` (unlimited) included, and is for a
      ## receiver that bounds what it keeps another way.
    pollIntervalMs*: Option[int]
      ## Suggested to requestors in every task.
    maxActivePerOwner*: int
      ## How many tasks that are not terminal one owner may have; 0 is no
      ## limit, for a receiver that admits requests before they get here.
    maxTasksPerOwner*: int
      ## How many tasks, over or not, one owner may have; 0 is no limit.
    maxTasks*: int
      ## How many tasks the store holds; 0 is no limit.
    onStatusChange*: proc(owner: string, task: McpTask) {.closure.}
      ## Called after every change of a task, with the whole task.
    onExpire*: proc(owner: string, task: McpTask) {.closure.}
      ## Called after a task whose ttl elapsed was deleted, whatever its
      ## status: where a receiver keeps state of its own per task, this is
      ## when to let go of it (`onStatusChange` does not run for an expiry).
    onResultStream*: proc(owner, taskId, requestId: string) {.closure.}
      ## Called when a `tasks/result` request (`requestId`) starts to wait on
      ## a task: the stream the receiver can now send the task's messages on.

const
  InvalidParamsCode = -32602
  InternalErrorCode = -32603
  InvalidRequestCode = -32600

func taskSupportOf*(tool: JsonNode): TaskSupport =
  ## What a tool of `tools/list` says about tasks; no `execution`, or no
  ## `taskSupport` in it, is forbidden.
  case tool{"execution", "taskSupport"}.getStr("forbidden")
  of "optional": tsOptional
  of "required": tsRequired
  else: tsForbidden

func isTerminal*(status: TaskStatus): bool {.raises: [].} =
  status in {tsCompleted, tsFailed, tsCancelled}

func canTransition*(current, next: TaskStatus): bool {.raises: [].} =
  ## The paths the specification allows; a terminal status allows none.
  case current
  of tsWorking: next in {tsInputRequired, tsCompleted, tsFailed, tsCancelled}
  of tsInputRequired: next in {tsWorking, tsCompleted, tsFailed, tsCancelled}
  of tsCompleted, tsFailed, tsCancelled: false

func newTaskError*(code: int, message: string): ref McpTaskError =
  (ref McpTaskError)(code: code, msg: message)

proc systemClock*(): int64 =
  (epochTime() * 1000).int64

proc isoTimestamp*(ms: int64): string {.raises: [].} =
  ## ISO 8601 / RFC 3339 in UTC with milliseconds.
  let moment = fromUnix(ms div 1000).utc
  func pad(value, width: int): string =
    intToStr(value, width)
  pad(moment.year, 4) & "-" & pad(ord(moment.month), 2) & "-" &
    pad(moment.monthday, 2) & "T" & pad(moment.hour, 2) & ":" &
    pad(moment.minute, 2) & ":" & pad(moment.second, 2) & "." &
    pad(int(ms mod 1000), 3) & "Z"

proc parseIsoTimestamp*(text: string): Option[int64] =
  ## The instant of an ISO 8601 / RFC 3339 time, with or without fractional
  ## seconds, in UTC (`Z`) or with an offset; none for anything else.
  # std/times reads more than RFC 3339 allows, a signed year among it, and
  # raises a RangeDefect instead of TimeParseError for some of it (a second
  # over 60), so the shape and the ranges are checked first.
  if not isDateTime(text):
    return none(int64)
  var base = text
  var millis = 0'i64
  let dot = base.find('.')
  if dot >= 0:
    var stop = dot + 1
    while stop < base.len and base[stop] in Digits:
      inc stop
    let fraction = base[dot + 1 ..< stop]
    if fraction.len == 0:
      return none(int64)
    millis = parseInt((fraction & "00")[0 ..< 3]).int64
    base = base[0 ..< dot] & base[stop .. ^1]
  if base.endsWith("Z"):
    base = base[0 ..< base.len - 1] & "+00:00"
  try:
    let moment = parse(base, "yyyy-MM-dd'T'HH:mm:sszzz")
    some(moment.toTime.toUnix * 1000 + millis)
  except TimeParseError, ValueError:
    none(int64)

proc taskFromJson*(node: JsonNode): Option[McpTask] =
  ## The `Task` of a peer's answer; none when a required field is missing or
  ## not what the schema says.
  if node.isNil or node.kind != JObject:
    return none(McpTask)
  let id = node{"taskId"}
  let status = node{"status"}
  let ttl = node{"ttl"}
  if id.isNil or id.kind != JString or status.isNil or status.kind != JString or
     ttl.isNil or ttl.kind notin {JNull, JInt}:
    return none(McpTask)
  var parsedStatus = none(TaskStatus)
  for candidate in TaskStatus:
    if $candidate == status.getStr():
      parsedStatus = some(candidate)
  func textAt(key: string): string =
    let value = node{key}
    if value.isNil or value.kind != JString: "" else: value.getStr()
  let created = parseIsoTimestamp(textAt("createdAt"))
  let updated = parseIsoTimestamp(textAt("lastUpdatedAt"))
  if parsedStatus.isNone or created.isNone or updated.isNone:
    return none(McpTask)
  result = some(McpTask(
    taskId: id.getStr(), status: parsedStatus.get, createdAtMs: created.get,
    lastUpdatedAtMs: updated.get,
    ttlMs: if ttl.kind == JInt: some(ttl.getBiggestInt().int64) else: none(int64)))
  if textAt("statusMessage").len > 0:
    result.get.statusMessage = some(textAt("statusMessage"))
  let poll = node{"pollInterval"}
  if not poll.isNil and poll.kind == JInt:
    result.get.pollIntervalMs = some(poll.getInt())

proc toJson*(task: McpTask): JsonNode =
  ## The `Task` of the schema.
  result = %*{
    "taskId": task.taskId,
    "status": $task.status,
    "createdAt": isoTimestamp(task.createdAtMs),
    "lastUpdatedAt": isoTimestamp(task.lastUpdatedAtMs),
    "ttl": if task.ttlMs.isSome: %task.ttlMs.get else: newJNull()
  }
  if task.statusMessage.isSome:
    result["statusMessage"] = %task.statusMessage.get
  if task.pollIntervalMs.isSome:
    result["pollInterval"] = %task.pollIntervalMs.get

proc createTaskResult*(task: McpTask, immediateResponse = ""): JsonNode =
  ## The `CreateTaskResult` a receiver answers a task-augmented request with.
  result = %*{"task": task.toJson()}
  if immediateResponse.len > 0:
    result["_meta"] = %*{ModelImmediateResponseKey: immediateResponse}

func relatedTaskMeta*(taskId: string): JsonNode =
  %*{"taskId": taskId}

func withRelatedTask*(node: JsonNode, taskId: string): JsonNode =
  ## A copy of `node` whose `_meta` names the task; other `_meta` keys stay.
  result = if node.isNil: newJObject() else: node.copy()
  if not result.hasKey("_meta") or result["_meta"].kind != JObject:
    result["_meta"] = newJObject()
  result["_meta"][RelatedTaskKey] = relatedTaskMeta(taskId)

func parseTaskParam*(params: JsonNode): Option[Option[int64]] {.raises: [McpTaskError].} =
  ## Whether a request is task-augmented and which ttl it asks for: none when
  ## `params` has no `task`, `some(none)` for a task without ttl.
  if params.isNil or params.kind != JObject or not params.hasKey("task"):
    return none(Option[int64])
  let task = params{"task"}
  if task.kind != JObject:
    raise newTaskError(InvalidParamsCode, "task must be an object")
  let ttl = task{"ttl"}
  if ttl.isNil or ttl.kind == JNull:
    return some(none(int64))
  const notValid = "task.ttl must be a non-negative whole number of milliseconds"
  case ttl.kind
  of JInt:
    if ttl.getBiggestInt() < 0:
      raise newTaskError(InvalidParamsCode, notValid)
    some(some(ttl.getBiggestInt().int64))
  of JFloat:
    # `1.5e6` is a whole number in JSON; `1.5` is not a number of
    # milliseconds anyone can mean, and `1e30` is a request for more than
    # any receiver grants: it is read as the largest, which the store caps.
    let value = ttl.getFloat()
    if value != value or value < 0 or value == Inf or value != value.floor:
      raise newTaskError(InvalidParamsCode, notValid)
    if value >= 9.223372036854775807e18:
      return some(some(int64.high))
    some(some(value.int64))
  else:
    raise newTaskError(InvalidParamsCode, notValid)

proc newTaskStore*(clock: TaskClock = systemClock,
                   defaultTtlMs = some(3_600_000'i64),
                   maxTtlMs = some(DefaultMaxTtlMs),
                   pollIntervalMs = some(1_000),
                   maxActivePerOwner = DefaultMaxActivePerOwner,
                   maxTasksPerOwner = DefaultMaxTasksPerOwner,
                   maxTasks = DefaultMaxTasks): TaskStore =
  TaskStore(clock: clock, entries: initOrderedTable[string, TaskEntry](),
            defaultTtlMs: defaultTtlMs, maxTtlMs: maxTtlMs,
            pollIntervalMs: pollIntervalMs, maxActivePerOwner: maxActivePerOwner,
            maxTasksPerOwner: maxTasksPerOwner, maxTasks: maxTasks)

proc newTaskId(): string =
  ## Unpredictable: an id is the only thing that keeps a requestor without
  ## an authorization context from another's task.
  const digits = "0123456789abcdef"
  for byte in urandom(TaskIdBytes):
    result.add digits[int(byte shr 4)]
    result.add digits[int(byte and 0x0f)]

proc wake(entry: TaskEntry) =
  let waiting = entry.waiters
  entry.waiters = @[]
  for waiter in waiting:
    if not waiter.finished:
      waiter.complete()

proc notifyChange(store: TaskStore, entry: TaskEntry) =
  if not store.onStatusChange.isNil:
    store.onStatusChange(entry.owner, entry.task)

proc expiresAtMs(entry: TaskEntry): Option[int64] =
  if entry.task.ttlMs.isSome:
    # Saturates: a ttl that reaches past the last instant is no expiry, and
    # the sum must not raise where every operation of the store passes.
    let ttl = entry.task.ttlMs.get
    if ttl > 0 and entry.task.createdAtMs > int64.high - ttl:
      some(int64.high)
    else:
      some(entry.task.createdAtMs + ttl)
  else:
    none(int64)

proc sweep*(store: TaskStore): seq[string] =
  ## Delete the tasks whose ttl has elapsed, whatever their status, and
  ## return their ids. Work that is still running is told to stop.
  let now = store.clock()
  for id, entry in store.entries.pairs:
    let expiry = entry.expiresAtMs
    if expiry.isSome and now >= expiry.get:
      result.add id
  for id in result:
    let entry = store.entries[id]
    store.entries.del(id)
    # One task's cleanup failing must not leave the others' undone: sweep runs
    # in every operation of every owner.
    try:
      if not entry.task.status.isTerminal and not entry.cancelWork.isNil:
        entry.cancelWork("the task expired")
    except CatchableError as e:
      stderr.writeLine("[mcp-tasks] stopping the work of expired task " & id &
                       " raised " & e.msg)
    try:
      if not store.onExpire.isNil:
        store.onExpire(entry.owner, entry.task)
    except CatchableError as e:
      stderr.writeLine("[mcp-tasks] the expiry hook for task " & id & " raised " & e.msg)
    entry.wake()

proc notFound(): ref McpTaskError =
  newTaskError(InvalidParamsCode, "Failed to retrieve task: Task not found")

proc find(store: TaskStore, owner, id: string): TaskEntry =
  ## The entry, only for the owner it is bound to: any other asker learns no
  ## more than that the id is unknown.
  discard store.sweep()
  if id notin store.entries or store.entries[id].owner != owner:
    raise notFound()
  store.entries[id]

proc activeCount(store: TaskStore, owner: string): int =
  for entry in store.entries.values:
    if entry.owner == owner and not entry.task.status.isTerminal:
      inc result

proc ownedCount(store: TaskStore, owner: string): int =
  for entry in store.entries.values:
    if entry.owner == owner:
      inc result

proc create*(store: TaskStore, owner: string, requestedTtlMs: Option[int64]): McpTask =
  ## A new task in `working`, bound to `owner`. The ttl is the one asked for,
  ## or the store's default, and never more than `maxTtlMs`. Raises
  ## McpTaskError for a negative ttl, and when the owner has too many tasks
  ## (not over, or over but kept) or the store holds too many.
  if requestedTtlMs.isSome and requestedTtlMs.get < 0:
    raise newTaskError(InvalidParamsCode, "task.ttl must not be negative")
  discard store.sweep()
  if store.maxActivePerOwner > 0 and store.activeCount(owner) >= store.maxActivePerOwner:
    raise newTaskError(InternalErrorCode, "Too many active tasks")
  if store.maxTasksPerOwner > 0 and store.ownedCount(owner) >= store.maxTasksPerOwner:
    raise newTaskError(InternalErrorCode, "Too many tasks")
  if store.maxTasks > 0 and store.entries.len >= store.maxTasks:
    raise newTaskError(InternalErrorCode, "Too many tasks")
  var ttl = if requestedTtlMs.isSome: requestedTtlMs else: store.defaultTtlMs
  if store.maxTtlMs.isSome and (ttl.isNone or ttl.get > store.maxTtlMs.get):
    ttl = store.maxTtlMs
  let now = store.clock()
  let entry = TaskEntry(owner: owner, task: McpTask(
    taskId: newTaskId(), status: tsWorking, createdAtMs: now, lastUpdatedAtMs: now,
    ttlMs: ttl, pollIntervalMs: store.pollIntervalMs))
  store.entries[entry.task.taskId] = entry
  entry.task

proc get*(store: TaskStore, owner, id: string): McpTask =
  store.find(owner, id).task

proc list*(store: TaskStore, owner: string): seq[McpTask] =
  ## The tasks of `owner` in the order they were created.
  discard store.sweep()
  for entry in store.entries.values:
    if entry.owner == owner:
      result.add entry.task

proc attachWork*(store: TaskStore, id: string, cancel: proc(reason: string) {.closure.}) =
  ## What to call to stop the execution behind a task that is cancelled or
  ## expires while it runs.
  if id in store.entries:
    store.entries[id].cancelWork = cancel

proc setResultStream*(store: TaskStore, id, requestId: string) =
  ## Which `tasks/result` request currently waits on the task ("" for none),
  ## so that the receiver can send its messages for the requestor there.
  if id in store.entries:
    store.entries[id].resultStream = requestId
    if requestId.len > 0 and not store.onResultStream.isNil:
      store.onResultStream(store.entries[id].owner, id, requestId)

proc resultStream*(store: TaskStore, id: string): string =
  if id in store.entries: store.entries[id].resultStream else: ""

proc change(store: TaskStore, entry: TaskEntry, status: TaskStatus,
            message: Option[string]) =
  entry.task.status = status
  entry.task.statusMessage = message
  entry.task.lastUpdatedAtMs = store.clock()
  store.notifyChange(entry)
  if status.isTerminal:
    entry.wake()

proc transition*(store: TaskStore, id: string, status: TaskStatus,
                 message = none(string)): bool =
  ## Move the task to `status`. False, and nothing changes, when the task is
  ## gone or already terminal: a task never leaves a terminal status, and
  ## work that goes on after a cancellation must not undo it. Setting the
  ## status it already has only replaces the message. Any other move the
  ## specification does not allow raises McpTaskError.
  discard store.sweep()
  if id notin store.entries:
    return false
  let entry = store.entries[id]
  if entry.task.status.isTerminal:
    return false
  if status != entry.task.status and not canTransition(entry.task.status, status):
    raise newTaskError(InternalErrorCode,
      "a task cannot move from " & $entry.task.status & " to " & $status)
  store.change(entry, status, message)
  true

func failureMessage(outcome: TaskOutcome): Option[string] =
  if outcome.error.isSome:
    return some(outcome.error.get.message)
  let content = outcome.result.get{"content"}
  if not content.isNil and content.kind == JArray:
    for item in content:
      if item{"type"}.getStr() == "text":
        return some(item{"text"}.getStr())
  none(string)

func isFailure(outcome: TaskOutcome, toolErrorsFail: bool): bool =
  outcome.error.isSome or (toolErrorsFail and outcome.result.get{"isError"}.getBool(false))

proc finish*(store: TaskStore, id: string, outcome: TaskOutcome,
             toolErrorsFail = true): bool =
  ## The request the task stands for ended: completed, or failed when it
  ## ended in an error or, for a tool call, a result with `isError` (2025-11-25;
  ## the Tasks extension of 2026-07-28 keeps such a result `completed`:
  ## pass `toolErrorsFail = false`). False when the task is gone or already
  ## terminal (cancelled, say).
  discard store.sweep()
  if id notin store.entries:
    return false
  let entry = store.entries[id]
  if entry.task.status.isTerminal:
    return false
  entry.outcome = some(outcome)
  if outcome.isFailure(toolErrorsFail):
    store.change(entry, tsFailed, outcome.failureMessage)
  else:
    store.change(entry, tsCompleted, none(string))
  true

proc cancel*(store: TaskStore, owner, id: string,
             message = "The task was cancelled by request."): McpTask =
  ## Cancel a task that is not over; the work behind it is told to stop and
  ## the task is `cancelled` when this returns. Raises McpTaskError for an
  ## unknown task and for one that is already terminal.
  let entry = store.find(owner, id)
  if entry.task.status.isTerminal:
    raise newTaskError(InvalidParamsCode,
      "Cannot cancel task: already in terminal status '" & $entry.task.status & "'")
  if not entry.cancelWork.isNil:
    entry.cancelWork(message)
  store.change(entry, tsCancelled, some(message))
  entry.task

proc outcomeOf(entry: TaskEntry): TaskOutcome =
  if entry.outcome.isSome:
    return entry.outcome.get
  # Cancelled before the request ended: there is nothing the request returned.
  TaskOutcome(error: some(JsonRpcError(
    code: InvalidRequestCode,
    message: "The task was " & $entry.task.status & " and has no result",
    data: newJNull())))

proc awaitOutcome*(store: TaskStore, owner, id: string): Future[TaskOutcome] {.async.} =
  ## What the request the task stands for returned, once the task is terminal.
  ## Raises McpTaskError for an unknown task, also when it expires meanwhile.
  while true:
    let entry = store.find(owner, id)
    if entry.task.status.isTerminal:
      return entry.outcomeOf
    let waiter = newFuture[void]("TaskStore.awaitOutcome")
    entry.waiters.add waiter
    let expiry = entry.expiresAtMs
    if expiry.isSome:
      let remaining = max(1'i64, expiry.get - store.clock())
      if not await waiter.withTimeout(int(min(remaining, int64(high(int32))))):
        continue  # the loop's lookup sweeps the task if its time is up
    else:
      await waiter
