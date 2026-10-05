## The requests every receiver of tasks answers the same way, whether it is a
## server or a client: `tasks/get`, `tasks/result`, `tasks/list` and
## `tasks/cancel`, and the start of a task-augmented request.

import std/[asyncdispatch, json, options]
import ./types
import ./tasks
import ../server/pagination
import ../server/errors

const
  TaskMethods* = ["tasks/get", "tasks/result", "tasks/list", "tasks/cancel"]
  MethodNotFoundCode = -32601
  InternalErrorCode = -32603

func isTaskMethod*(methodName: string): bool =
  methodName in TaskMethods

proc errorResponse(request: JsonRpcRequest, code: int, message: string): JsonRpcResponse =
  newJsonRpcErrorResponse(request.id, code, message)

proc taskIdOf(request: JsonRpcRequest): string =
  ## The taskId parameter is the only source of truth: any related-task
  ## metadata in the request is not looked at.
  let node = request.params{"taskId"}
  if node.isNil or node.kind != JString:
    raise newTaskError(-32602, request.`method` & " requires a string taskId")
  node.getStr()

proc handleTaskMethod*(store: TaskStore, owner: string,
                       capability: McpTasksCapability, pageSize: int,
                       request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
  ## The answer to a task method for the requestor bound to `owner`.
  ## `tasks/list` and `tasks/cancel` are unknown methods unless the
  ## capability declares them.
  try:
    case request.`method`
    of "tasks/get":
      return newJsonRpcResponse(request.id, store.get(owner, request.taskIdOf).toJson())
    of "tasks/result":
      let id = request.taskIdOf
      discard store.get(owner, id)
      store.setResultStream(id, request.id)
      var outcome: TaskOutcome
      try:
        outcome = await store.awaitOutcome(owner, id)
      finally:
        if store.resultStream(id) == request.id:
          store.setResultStream(id, "")
      if outcome.error.isSome:
        let error = outcome.error.get
        return newJsonRpcErrorResponse(request.id, error.code, error.message, error.data)
      return newJsonRpcResponse(request.id, withRelatedTask(outcome.result.get, id))
    of "tasks/list":
      if not capability.list:
        return errorResponse(request, MethodNotFoundCode, "Method not found: tasks/list")
      let cursor = request.params{"cursor"}
      if not cursor.isNil and cursor.kind != JString:
        return errorResponse(request, -32602, "cursor must be a string")
      var items: seq[JsonNode]
      for task in store.list(owner):
        items.add task.toJson()
      let page = pageOf(items, if cursor.isNil: none(string) else: some(cursor.getStr()),
                        pageSize)
      var payload = %*{"tasks": page.items}
      if page.nextCursor.isSome:
        payload["nextCursor"] = %page.nextCursor.get
      return newJsonRpcResponse(request.id, payload)
    of "tasks/cancel":
      if not capability.cancel:
        return errorResponse(request, MethodNotFoundCode, "Method not found: tasks/cancel")
      return newJsonRpcResponse(request.id, store.cancel(owner, request.taskIdOf).toJson())
    else:
      return errorResponse(request, MethodNotFoundCode, "Method not found: " & request.`method`)
  except McpTaskError as e:
    return errorResponse(request, e.code, e.plainMessage)
  except McpRequestError as e:
    return errorResponse(request, e.code, e.plainMessage)

func outcomeOf*(response: JsonRpcResponse): TaskOutcome =
  TaskOutcome(result: response.result, error: response.error)

type
  TaskWork* = tuple[response: Future[JsonRpcResponse],
                    cancel: proc(reason: string) {.closure.}]

const DefaultPollIntervalMs* = 1_000
  ## Used when a task suggests no `pollInterval`.

proc pollTask*(fetch: proc(): Future[McpTask] {.closure.}, onStatus: TaskStatusCallback,
               sleep: SleepProc, defaultPollMs: int): Future[McpTask] {.async.} =
  ## Poll a task of a peer with `fetch` (a `tasks/get`), at the task's own
  ## `pollInterval` when it suggests one, until it is no longer working: over,
  ## or needing input. `onStatus` sees every change of status.
  var lastStatus = none(TaskStatus)
  while true:
    let task = await fetch()
    if lastStatus != some(task.status):
      lastStatus = some(task.status)
      if not onStatus.isNil:
        onStatus(task)
    if task.status != tsWorking:
      return task
    let pause = task.pollIntervalMs.get(defaultPollMs)
    if sleep.isNil:
      await sleepAsync(pause)
    else:
      await sleep(pause)

proc finishWhenDone(store: TaskStore, taskId: string,
                    response: Future[JsonRpcResponse], toolErrorsFail: bool) {.async.} =
  var outcome: TaskOutcome
  var raised = ""
  try:
    outcome = outcomeOf(await response)
  except CatchableError as e:
    # The cause stays on this side; the requestor is told an internal error.
    raised = e.msg
    outcome = TaskOutcome(error: some(JsonRpcError(
      code: InternalErrorCode, message: "Internal error", data: newJNull())))
  # False when the task is over already (cancelled, or expired): it stays so,
  # and work that stops because it was told to is not a failure to report.
  if store.finish(taskId, outcome, toolErrorsFail) and raised.len > 0:
    stderr.writeLine("[mcp-tasks] the request of task " & taskId & " raised " & raised)

proc runAsTask*(store: TaskStore, owner: string, ttlMs: Option[int64],
                start: proc(taskId: string): TaskWork {.closure.},
                toolErrorsFail = true): McpTask =
  ## Create a task for `owner` and run the request it stands for. `start`
  ## begins the work (it gets the task's id) and says how to stop it; when
  ## the work ends, the task is completed or failed (`toolErrorsFail`: see
  ## `finish`). The request is not
  ## waited for: the task is returned at once, still working.
  let task = store.create(owner, ttlMs)
  let work = start(task.taskId)
  store.attachWork(task.taskId, work.cancel)
  asyncCheck finishWhenDone(store, task.taskId, work.response, toolErrorsFail)
  task
