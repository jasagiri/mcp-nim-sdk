## The Tasks extension on the server (2026-07-28): a `tools/call` the server
## decides to run as a task is answered with a `CreateTaskResult`; the
## client then follows it with `tasks/get`, gives it input with
## `tasks/update` and withdraws it with `tasks/cancel`.
##
##   let tasks = server.enableTasksExtension(TasksExtensionConfig(
##     decide: toolsNamed("report")))
##
## Nothing here is on by default: only a server that called
## `enableTasksExtension` declares the extension, and only to clients that
## negotiated 2026-07-28. A client of 2025-11-25 is served the core's Tasks
## (`server/tasks`) if the server enabled them, on the same `TaskStore`.
##
## Who owns a task. 2026-07-28 has no session, and the request context knows
## no authenticated principal, so the owner comes from `ownerOf`, which the
## application supplies from whatever it authenticated (the specification
## requires an authorization check on every task request). Without it every
## requestor is the same owner and the task ID, which is unguessable, is the
## only thing between a requestor and another's task. An owner of this
## extension never sees a task of the core's, nor the other way round.

import std/[asyncdispatch, json, options, sets, strutils, tables]
import ../../server/server
import ../../server/errors
import ../../server/extensions
import ../../protocol/types
import ../../protocol/features
import ../../protocol/version
import ../../protocol/modern
import ../../protocol/mrtr
import ../../protocol/tasks
import ../../protocol/task_methods
import ../../protocol/extensions
import ./wire

export wire, tasks

const
  ExtOwnerPrefix = "ext-tasks:"
    ## What keeps the owners of this extension apart from the sessions that
    ## own the core's tasks in the same store.
  InputKeyPrefix = "input-"

type
  TaskDecision* = enum
    ## What the server makes of one `tools/call`.
    tdInline         ## answer with the result
    tdTask           ## make a task of it, for a client that declared the
                     ## extension; answer with the result for one that did not
    tdTaskRequired   ## make a task of it; a client that did not declare the
                     ## extension gets the missing-capability error

  TaskDecider* = proc(ctx: McpRequestContext, toolName: string,
                      arguments: JsonNode): TaskDecision {.closure.}
    ## The server is the sole decider, request by request. `ctx.inputResponses`
    ## tells a retry of a request that was answered with `input_required`: a
    ## tool that needs input before it can start (multi round-trip requests)
    ## answers inline until it has it, and decides on a task only then.

  TaskOwnerOf* = proc(ctx: McpRequestContext): string {.closure.}

  TasksExtensionConfig* = object
    decide*: TaskDecider
      ## nil: no request becomes a task.
    ownerOf*: TaskOwnerOf
      ## The owner of the tasks a request creates, and the only one that may
      ## read, update or cancel them. nil: one owner for all.

  PendingInput = object
    request: JsonNode
    answered: Future[JsonNode]

  TaskInputs = ref object
    pending: OrderedTable[string, PendingInput]
    used: HashSet[string]
      ## Every key ever issued: a key is never used twice in a task's life.
    counter: int

  TasksExtension* = ref object
    server: McpServer
    store*: TaskStore
    config: TasksExtensionConfig
    inputs: Table[string, TaskInputs]
      ## By task id, for the tasks this extension made.

func toolsNamed*(names: openArray[string]): TaskDecider =
  ## Every call of the named tools becomes a task.
  let named = @names
  result = proc(ctx: McpRequestContext, toolName: string,
                arguments: JsonNode): TaskDecision =
    if toolName in named: tdTask else: tdInline

proc ownerOf(ext: TasksExtension, ctx: McpRequestContext): string =
  ExtOwnerPrefix & (if ext.config.ownerOf.isNil: "" else: ext.config.ownerOf(ctx))

proc taskIdParam(params: JsonNode, methodName: string): string =
  let node = if params.isNil or params.kind != JObject: nil else: params{"taskId"}
  if node.isNil or node.kind != JString:
    raise newRequestError(ErrInvalidParams, methodName & " requires a string taskId")
  node.getStr()

proc internalError(what: string): ref McpRequestError =
  stderr.writeLine("[mcp-tasks] " & what)
  newRequestError(ErrInternal, "Internal error")

proc detailed(ext: TasksExtension, owner: string,
              task: McpTask): Future[DetailedTask] {.async.} =
  ## The task with what its status adds.
  result.task = task
  case task.status
  of tsInputRequired:
    var requests = newJObject()
    let inputs = ext.inputs.getOrDefault(task.taskId)
    if not inputs.isNil:
      for key, pending in inputs.pending.pairs:
        requests[key] = pending.request
    result.inputRequests = some(requests)
  of tsCompleted, tsFailed:
    let outcome = await ext.store.awaitOutcome(owner, task.taskId)
    if task.status == tsCompleted:
      if outcome.result.isNone:
        raise internalError("task " & task.taskId & " is completed without a result")
      result.result = outcome.result
    else:
      if outcome.error.isNone:
        raise internalError("task " & task.taskId & " is failed without an error")
      result.error = outcome.error
  of tsWorking, tsCancelled:
    discard

proc fulfil(ext: TasksExtension, taskId: string, responses: JsonNode) =
  ## Hand each response to the request of its key that is still outstanding;
  ## a response to any other key is ignored, as the specification says. The
  ## task is working again once nothing is outstanding.
  let inputs = ext.inputs.getOrDefault(taskId)
  if inputs.isNil:
    return
  var answeredAny = false
  for key, response in responses.pairs:
    if key in inputs.pending:
      let pending = inputs.pending[key]
      inputs.pending.del(key)
      pending.answered.complete(response)
      answeredAny = true
  if answeredAny and inputs.pending.len == 0:
    discard ext.store.transition(taskId, tsWorking)

proc requestInput*(ext: TasksExtension, ctx: McpRequestContext, request: JsonNode,
                   key = ""): Future[JsonNode] {.async.} =
  ## From the tool a task runs: ask the client for input the way
  ## `inputRequests` do, `request` being `{"method": "elicitation/create" |
  ## "sampling/createMessage" | "roots/list", "params": {...}}`. The task is
  ## `input_required` while a request is outstanding; the answer is the
  ## client's `InputResponse` once it sent it with `tasks/update`. `key`
  ## names the request (one is made up when empty) and is never used twice in
  ## a task. Raises ValueError for a call outside a task of this extension, a
  ## malformed request or a reused key, McpCapabilityError when the client
  ## did not declare what the request needs, and McpCancelled when the task
  ## is cancelled while waiting.
  let scope = ctx.taskScope
  if scope.isNil or scope.taskId notin ext.inputs:
    raise newException(ValueError, "requestInput is for a tool running as a task of this extension")
  let inputs = ext.inputs[scope.taskId]
  var issued = key
  if issued.len == 0:
    while true:
      inc inputs.counter
      issued = InputKeyPrefix & $inputs.counter
      if issued notin inputs.used:
        break
  elif issued in inputs.used:
    raise newException(ValueError, "the input request key '" & issued &
      "' was used already in task " & scope.taskId)
  let single = %*{issued: request}
  let invalid = validateInputRequests(single)
  if invalid.isSome:
    raise newException(ValueError, invalid.get)
  let undeclared = missingCapabilities(single, ctx.clientCapabilities)
  if undeclared.len > 0:
    raise newException(McpCapabilityError,
      "the client of task " & scope.taskId & " did not declare " & $undeclared)
  let answered = newFuture[JsonNode]("TasksExtension.requestInput")
  inputs.used.incl issued
  inputs.pending[issued] = PendingInput(request: request, answered: answered)
  if inputs.pending.len == 1:
    discard ext.store.transition(scope.taskId, tsInputRequired)
  let cancelled = ctx.whenCancelled()
  await (answered or cancelled)
  if not answered.finished:
    inputs.pending.del(issued)
    raise newException(McpCancelled, "task " & scope.taskId & " was cancelled while it waited for input")
  return answered.read

proc asTaskOutcome(response: Future[JsonRpcResponse]): Future[JsonRpcResponse] {.async.} =
  ## What the request ended with, as the outcome of its task: the result
  ## object a `tasks/get` inlines, without the `resultType` that only
  ## belongs to the response. A request cannot end in `input_required`
  ## inside a task (it uses `requestInput`), which is a defect of the tool.
  var answer = await response
  if answer.result.isSome:
    let payload = answer.result.get
    let resultType = payload{"resultType"}.getStr("complete")
    if resultType != "complete":
      stderr.writeLine("[mcp-tasks] a task's request ended with resultType '" &
                       resultType & "'; use requestInput to ask the client for input")
      return newJsonRpcErrorResponse(answer.id, ErrInternal, "Internal error")
    payload.delete("resultType")
  return answer

proc statusChanged(ext: TasksExtension, task: McpTask) =
  if task.status.isTerminal:
    ext.inputs.del(task.taskId)

proc registerMethods(ext: TasksExtension) =
  let server = ext.server
  server.registerExtensionMethod(TasksExtensionId, GetTaskMethod,
    proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} =
      let id = taskIdParam(params, GetTaskMethod)
      let owner = ext.ownerOf(ctx)
      try:
        return (await ext.detailed(owner, ext.store.get(owner, id))).toWire()
      except McpTaskError as e:
        raise newRequestError(e.code, e.plainMessage))
  server.registerExtensionMethod(TasksExtensionId, UpdateTaskMethod,
    proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} =
      let id = taskIdParam(params, UpdateTaskMethod)
      let responses = params{"inputResponses"}
      if responses.isNil:
        raise newRequestError(ErrInvalidParams, UpdateTaskMethod & " requires inputResponses")
      let invalid = rejectInvalidInputParams(params)
      if invalid.isSome:
        raise newRequestError(invalid.get.code, invalid.get.message)
      try:
        discard ext.store.get(ext.ownerOf(ctx), id)
      except McpTaskError as e:
        raise newRequestError(e.code, e.plainMessage)
      ext.fulfil(id, responses)
      return newJObject())
  server.registerExtensionMethod(TasksExtensionId, CancelTaskMethod,
    proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} =
      let id = taskIdParam(params, CancelTaskMethod)
      let owner = ext.ownerOf(ctx)
      try:
        # Cooperative: a task that is over already is not an error, the
        # acknowledgement only says the request was heard.
        if not ext.store.get(owner, id).status.isTerminal:
          discard ext.store.cancel(owner, id)
      except McpTaskError as e:
        raise newRequestError(e.code, e.plainMessage)
      return newJObject())

proc startAsTask(ext: TasksExtension, ctx: McpRequestContext,
                 request: JsonRpcRequest): JsonRpcResponse =
  ## Create the task and begin the request in it. The task is in the store
  ## before this returns, as the specification requires of the answer.
  let store = ext.store
  var created: McpTask
  try:
    created = runAsTask(store, ext.ownerOf(ctx), none(int64),
      proc(taskId: string): TaskWork =
        ext.inputs[taskId] = TaskInputs()
        let scope = TaskScope(
          taskId: taskId,
          awaitingInput: proc(waiting: bool) =
            discard store.transition(taskId, if waiting: tsInputRequired else: tsWorking),
          resultStream: proc(): string = "")
        let work = ext.server.serveDetached(request, scope)
        (response: asTaskOutcome(work.response), cancel: work.cancel),
      toolErrorsFail = false)
  except McpTaskError as e:
    return newJsonRpcErrorResponse(request.id, e.code, e.plainMessage)
  newJsonRpcResponse(request.id, taskHandle(created))

proc enableTasksExtension*(server: McpServer, config = TasksExtensionConfig(),
                           store: TaskStore = nil): TasksExtension =
  ## Let clients that declare `io.modelcontextprotocol/tasks` get a task for
  ## the `tools/call` that `config.decide` picks. `store` may be the one the
  ## core's `enableTasks` uses: enable the core first, so that the status
  ## changes of its tasks keep reaching its own callback. Raises ValueError
  ## when this build does not speak 2026-07-28, which is the only version
  ## with extensions: nothing is declared silently.
  if mpv20260728 notin spokenVersionsUpTo(server.protocolVersion):
    raise newException(ValueError,
      "the Tasks extension needs 2026-07-28, which this server does not speak (it speaks up to " &
      $server.protocolVersion & ")")
  let ext = TasksExtension(
    server: server, config: config, inputs: initTable[string, TaskInputs](),
    store: if store.isNil: newTaskStore() else: store)
  server.registerExtension(TasksExtensionId, resultTypes = [TaskResultType])
  ext.registerMethods()
  let previous = ext.store.onStatusChange
  ext.store.onStatusChange = proc(owner: string, task: McpTask) =
    if owner.startsWith(ExtOwnerPrefix):
      ext.statusChanged(task)
    elif not previous.isNil:
      previous(owner, task)
  server.addRequestInterceptor(proc(ctx: McpRequestContext, request: JsonRpcRequest
                                   ): Future[Option[JsonRpcResponse]] {.async.} =
    # A request that already runs as a task is the work of one: not a new task.
    if request.`method` != "tools/call" or not ctx.version.has(ftExtensions) or
       not ctx.taskScope.isNil or ext.config.decide.isNil:
      return none(JsonRpcResponse)
    let name = request.params{"name"}
    if name.isNil or name.kind != JString:
      return none(JsonRpcResponse)  # the server's own handling says what is wrong
    let arguments = request.params{"arguments"}
    let decision = ext.config.decide(ctx, name.getStr(),
      if arguments.isNil: newJObject() else: arguments)
    if decision == tdInline:
      return none(JsonRpcResponse)
    if ctx.clientExtension(TasksExtensionId).isNone:
      if decision == tdTask:
        return none(JsonRpcResponse)
      let error = missingCapabilityError(
        "Tool " & name.getStr() & " is only available as a task",
        requiredExtension(TasksExtensionId))
      return some(newJsonRpcErrorResponse(request.id, error.code, error.message, error.data))
    return some(ext.startAsTask(ctx, request)))
  ext
