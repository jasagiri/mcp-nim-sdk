## The Tasks extension on the client (2026-07-28): declare it, call a tool and
## learn whether the server made a task of the call, follow the task with
## `tasks/get`, answer the input it asks for with `tasks/update`, cancel it.
##
##   client.enableTasksExtension()                    # before connect()
##   await client.connect(transport)
##   let started = await client.startToolCall("report", %*{"topic": "sales"})
##   if started.task.isSome:
##     let done = await client.awaitTask(started.task.get.taskId)
##   # or, as if the call had been synchronous:
##   let result = await client.callToolAwaitingTask("report", %*{"topic": "sales"})
##
## Declaring the extension tells the server, in every request, that it may
## answer with a task; the client must then be ready for either answer. The
## task IDs are the caller's to keep: `awaitTask` can resume a task after a
## restart from its ID alone.

import std/[asyncdispatch, json, options, sets, tables]
import ../../client/client
import ../../client/extensions
import ../../client/subscriptions
import ../../protocol/types
import ../../protocol/diagnostic
import ../../protocol/features
import ../../protocol/lifecycle
import ../../protocol/mrtr
import ../../protocol/tasks
import ../../protocol/task_methods
import ../../protocol/subscriptions
import ./wire
import ../official_common

export wire
export tasks

type
  ToolCallStart* = object
    ## The answer to a `tools/call`: the result, or the task the server made.
    result*: Option[JsonNode]
      ## The `CallToolResult`, when the server answered directly.
    task*: Option[McpTask]
      ## The task, when the server made one; its `resultType` was "task".

  InputAnswerer* = proc(key: string, request: JsonNode): Future[JsonNode] {.closure.}
    ## Answers one entry of a task's `inputRequests` (`request` is
    ## `{"method", "params"}`) with the `InputResponse` to send back.

  McpTaskCancelledError* = object of McpError
    ## The task ended `cancelled`, so there is no result to return.

proc enableTasksExtension*(client: McpClient) =
  ## Declare `io.modelcontextprotocol/tasks` in the capabilities of every
  ## request. Call before connect(). Raises ValueError, naming the extension
  ## and its target version, when this client is limited to a version older
  ## than the target (`officialTasks`).
  requireTargetSpoken(client.protocolVersion, officialTasks)
  client.declareExtension(TasksExtensionId, nil, resultTypes = [TaskResultType])

proc requireDeclared(client: McpClient, operation: string) =
  client.requireFeature(ftExtensions, operation)
  if client.capabilities.extensions.isNone or
     not client.capabilities.extensions.get.hasKey(TasksExtensionId):
    raise newException(McpUnsupportedError,
      operation & ": this client did not declare the Tasks extension (enableTasksExtension)")

proc detailedOf(answer: JsonNode, operation: string): DetailedTask =
  let parsed = parseDetailedTask(answer)
  if parsed.problem.isSome:
    raise newException(McpProtocolError, operation & ": " & parsed.problem.get)
  parsed.detailed

proc startToolCall*(client: McpClient, name: string, arguments: JsonNode = nil,
                    options: McpRequestOptions = McpRequestOptions()): Future[ToolCallStart] {.async.} =
  ## Call tool `name`. The server decides whether to answer with the result
  ## or with a task, so the caller gets either. Raises McpUnsupportedError,
  ## sending nothing, when the connection is not 2026-07-28 or the extension
  ## was not declared; McpProtocolError for a task the server had no
  ## business answering with (it did not declare the extension) or that is
  ## malformed; McpRequestError for the server's errors.
  client.requireDeclared("tools/call")
  var params = %*{"name": name}
  if not arguments.isNil:
    params["arguments"] = arguments
  let answer = await client.callMethod("tools/call", params, options)
  if answer{"resultType"}.getStr("complete") != TaskResultType:
    return ToolCallStart(result: some(answer))
  if client.serverExtension(TasksExtensionId).isNone:
    raise newException(McpProtocolError,
      "tools/call: the server answered with a task but did not declare the Tasks extension")
  let parsed = parseTask(answer)
  if parsed.problem.isSome:
    raise newException(McpProtocolError, "tools/call: " & parsed.problem.get)
  ToolCallStart(task: some(parsed.task))

proc getTask*(client: McpClient, taskId: string,
              options: McpRequestOptions = McpRequestOptions()): Future[DetailedTask] {.async.} =
  ## The task as it is now, with its result, error or outstanding input
  ## requests. An unknown or expired task raises McpRequestError (-32602).
  client.requireDeclared(GetTaskMethod)
  let answer = await client.callExtension(TasksExtensionId, GetTaskMethod,
                                          %*{"taskId": taskId}, options)
  return detailedOf(answer, GetTaskMethod)

proc updateTask*(client: McpClient, taskId: string, inputResponses: JsonNode,
                 options: McpRequestOptions = McpRequestOptions()): Future[void] {.async.} =
  ## Answer outstanding `inputRequests` of a task: `inputResponses` maps each
  ## key to its `InputResponse`. The acknowledgement is eventually
  ## consistent: the task may still say `input_required` for a moment.
  client.requireDeclared(UpdateTaskMethod)
  discard await client.callExtension(TasksExtensionId, UpdateTaskMethod,
    %*{"taskId": taskId, "inputResponses": inputResponses}, options)

proc cancelTask*(client: McpClient, taskId: string,
                 options: McpRequestOptions = McpRequestOptions()): Future[void] {.async.} =
  ## Ask the server to cancel a task. Only an acknowledgement comes back:
  ## the server may still finish the work, so the task can end in any status.
  client.requireDeclared(CancelTaskMethod)
  discard await client.callExtension(TasksExtensionId, CancelTaskMethod,
                                     %*{"taskId": taskId}, options)

proc watchTasks*(client: McpClient, taskIds: seq[string],
                 onTask: proc(task: DetailedTask) {.closure.},
                 options: McpRequestOptions = McpRequestOptions()): Future[McpSubscription] {.async.} =
  ## Have the server push the status of `taskIds` instead of, or besides,
  ## polling: opens a `subscriptions/listen` stream with `taskIds` and calls
  ## `onTask` with the whole task on each `notifications/tasks`. The server
  ## need not agree to every id (see `unsupported` of the returned stream:
  ## keep polling those) and need not send anything at all. `onTask` is also
  ## called once per agreed task with its state as of the subscription, so a
  ## change before the stream was open is not missed; a task may therefore be
  ## seen twice in the same state. Raises what `listen` raises.
  client.requireDeclared(ListenMethod)
  let subscription = await client.listen(SubscriptionFilter(taskIds: taskIds), options)
  subscription.onNotification = proc(methodName: string, params: JsonNode) =
    if methodName != TaskStatusMethod:
      return
    # A copy: `onTask` is given nodes of it, and the notification goes on to
    # the client's own handlers after this callback.
    let parsed = parseDetailedTask(params.copy())
    if parsed.problem.isSome:
      stderr.writeLine("[mcp-tasks] ignored a malformed " & TaskStatusMethod & ": " &
                       peerText(parsed.problem.get))
      return
    onTask(parsed.detailed)
  for id in subscription.acknowledged.get.taskIds:
    onTask(await client.getTask(id))
  return subscription

proc answerFromHandlers(client: McpClient, key: string,
                        request: JsonNode): Future[JsonNode] {.async.} =
  ## The `InputResponse` for one input request, from the handler the client
  ## registered for its method: the one that serves the same request when a
  ## server sends it on its own. A request is subject to the same trust
  ## model as a direct one.
  let inputMethod = request{"method"}.getStr()
  let undeclared = missingCapabilities(%*{key: request}, client.capabilities.toJson())
  if undeclared.len > 0:
    raise newException(McpProtocolError, "a task asked for " & inputMethod &
      ", but this client did not declare " & $undeclared)
  if inputMethod notin client.requestHandlers:
    raise newException(McpUnsupportedError,
      "a task asked for " & inputMethod & ", and this client has no handler for it")
  let answer = await client.requestHandlers[inputMethod](
    newJsonRpcRequest(key, inputMethod, request{"params"}))
  if answer.error.isSome:
    let error = answer.error.get
    var failure = newException(McpRequestError, inputMethod & ": " & error.message)
    failure.code = error.code
    failure.data = error.data
    raise failure
  return answer.result.get(newJObject())

proc awaitTask*(client: McpClient, taskId: string,
                onInput: InputAnswerer = nil, onStatus: TaskStatusCallback = nil,
                sleep: SleepProc = nil,
                defaultPollMs = DefaultPollIntervalMs): Future[DetailedTask] {.async.} =
  ## Poll the task, at the interval it suggests (`defaultPollMs` when it
  ## suggests none), until it is over, and return it. When the task needs
  ## input, each request not seen before (by key) goes to `onInput`, or to
  ## the client's handler for its method when `onInput` is nil, and the
  ## answers go back with `tasks/update`; a key is answered once however
  ## often it is listed. `onStatus` sees every change of status. `sleep`
  ## replaces the wait between polls.
  var lastStatus = none(TaskStatus)
  var answered = initHashSet[string]()
  while true:
    let current = await client.getTask(taskId)
    if lastStatus != some(current.task.status):
      lastStatus = some(current.task.status)
      if not onStatus.isNil:
        onStatus(current.task)
    if current.task.status.isTerminal:
      return current
    if current.task.status == tsInputRequired:
      var responses = newJObject()
      for key, request in current.inputRequests.get.pairs:
        if key in answered:
          continue
        responses[key] = if onInput.isNil: await client.answerFromHandlers(key, request)
                         else: await onInput(key, request)
        answered.incl key
      if responses.len > 0:
        await client.updateTask(taskId, responses)
    let pause = pollPauseMs(current.task.pollIntervalMs, defaultPollMs)
    if sleep.isNil:
      await sleepAsync(pause)
    else:
      await sleep(pause)

proc callToolAwaitingTask*(client: McpClient, name: string, arguments: JsonNode = nil,
                           onInput: InputAnswerer = nil, onCreated: TaskStatusCallback = nil,
                           sleep: SleepProc = nil, defaultPollMs = DefaultPollIntervalMs,
                           options: McpRequestOptions = McpRequestOptions()): Future[JsonNode] {.async.} =
  ## Call tool `name` and return its `CallToolResult` whichever way the
  ## server answered, driving the task when it made one, so that a caller
  ## written for synchronous calls need not change. A task that failed raises
  ## McpRequestError with the error it ended in; a cancelled one raises
  ## McpTaskCancelledError. `onCreated` sees the task as soon as the server
  ## made one: the moment to keep its id, for `awaitTask` to resume after a
  ## restart.
  let started = await client.startToolCall(name, arguments, options)
  if started.result.isSome:
    return started.result.get
  if not onCreated.isNil:
    onCreated(started.task.get)
  let finished = await client.awaitTask(started.task.get.taskId, onInput, nil, sleep, defaultPollMs)
  case finished.task.status
  of tsCompleted:
    return finished.result.get
  of tsFailed:
    let error = finished.error.get
    var failure = newException(McpRequestError, "tools/call: " & error.message)
    failure.code = error.code
    failure.data = error.data
    raise failure
  of tsCancelled:
    raise newException(McpTaskCancelledError,
      "tools/call: task " & finished.task.taskId & " was cancelled")
  of tsWorking, tsInputRequired:
    raise newException(McpProtocolError, "tools/call: awaitTask returned a task that is not over")
