## Tasks on the client side (2025-11-25).
##
## As the requestor: call a tool as a task, poll it, wait for its result,
## list and cancel tasks (`callToolAsTask`, `getTask`, `waitForTask`,
## `taskResult`, ...). As the receiver of a task-augmented request of the
## server (sampling, elicitation): `enableClientTasks` keeps the tasks and
## answers `tasks/get`, `tasks/result`, `tasks/list` and `tasks/cancel`.
## The state machine and the store are `protocol/tasks`.
##
## A connection that did not settle on 2025-11-25 has none of this: every
## operation raises McpUnsupportedError before anything is sent, and a
## request of the server that carries a `task` is answered as a plain one.

import std/[asyncdispatch, json, options, tables]
import ./client
import ./content
import ./tools
import ../protocol/types
import ../protocol/diagnostic
import ../protocol/features
import ../protocol/tasks
import ../protocol/task_methods
from ../server/errors import plainMessage

export tasks

type
  McpCreatedTask* = object
    ## The answer to a task-augmented request.
    task*: McpTask
    immediateResponse*: Option[string]
      ## `io.modelcontextprotocol/model-immediate-response`: text a host may
      ## hand to the model as the tool result while the task runs.

  ClientTaskConfig* = object
    list*: bool = true
    cancel*: bool = true
    sampling*: bool = true
      ## Let the server augment `sampling/createMessage` with a task. Needs
      ## the sampling handler to be set first.
    elicitation*: bool = false
      ## Likewise for `elicitation/create`, once its handler is set.
    pageSize*: int = 50

proc taskSupport*(tool: McpTool): TaskSupport =
  ## What the tool says about being called as a task; nothing is forbidden.
  if tool.execution.isNone: tsForbidden else: taskSupportOf(%*{"execution": tool.execution.get})

# The requestor

proc requireTasks(client: McpClient, operation: string): McpTasksCapability =
  ## What the server declared, once the connection is one that has tasks.
  client.requireFeature(ftTasks, operation)
  let declared = client.serverCapabilities.get.tasks
  client.requireServerCapability(declared.isSome, operation, "tasks")
  declared.get

proc taskOf(reply: JsonNode, operation: string): McpTask =
  let parsed = taskFromJson(reply)
  if parsed.isNone:
    raise newException(McpProtocolError, operation & ": the answer is not a task")
  parsed.get

proc callToolAsTask*(client: McpClient, tool: McpTool, arguments: JsonNode = newJObject(),
                     ttlMs = none(int64),
                     options: McpRequestOptions = McpRequestOptions()): Future[McpCreatedTask] {.async.} =
  ## Call `tool` as a task: the answer is the new task, not the tool's result
  ## (`waitForTask` and `taskResult` bring that). Raises McpUnsupportedError,
  ## sending nothing, unless the server declared `tasks.requests.tools.call`
  ## and the tool allows a task.
  let declared = client.requireTasks("tools/call")
  client.requireServerCapability(declared.toolsCall, "tools/call", "tasks.requests.tools.call")
  if tool.taskSupport == tsForbidden:
    raise newException(McpUnsupportedError,
      "tools/call: the tool " & tool.name & " does not allow being called as a task")
  let reply = await client.callMethod("tools/call", %*{
    "name": tool.name, "arguments": arguments,
    "task": (if ttlMs.isSome: %*{"ttl": ttlMs.get} else: newJObject())}, options)
  result.task = taskOf(reply{"task"}, "tools/call")
  let immediate = reply{"_meta", ModelImmediateResponseKey}
  if not immediate.isNil and immediate.kind == JString:
    result.immediateResponse = some(immediate.getStr())

proc getTask*(client: McpClient, taskId: string,
              options: McpRequestOptions = McpRequestOptions()): Future[McpTask] {.async.} =
  discard client.requireTasks("tasks/get")
  return taskOf(await client.callMethod("tasks/get", %*{"taskId": taskId}, options), "tasks/get")

proc listTasks*(client: McpClient, cursor: Option[string] = none(string),
                options: McpRequestOptions = McpRequestOptions()
               ): Future[tuple[tasks: seq[McpTask], nextCursor: Option[string]]] {.async.} =
  ## One page of the tasks; needs `tasks.list` of the server.
  let declared = client.requireTasks("tasks/list")
  client.requireServerCapability(declared.list, "tasks/list", "tasks.list")
  let reply = await client.callMethod("tasks/list", pageParams(cursor), options)
  for item in requiredArray(reply, "tasks", "tasks/list"):
    result.tasks.add taskOf(item, "tasks/list")
  result.nextCursor = parseNextCursor(reply, "tasks/list")

proc listAllTasks*(client: McpClient,
                   options: McpRequestOptions = McpRequestOptions()): Future[seq[McpTask]] =
  ## Every task, following nextCursor to the last page.
  allPages("tasks/list", proc(cursor: Option[string]): Future[tuple[items: seq[McpTask], next: Option[string]]] {.async.} =
    let page = await client.listTasks(cursor, options)
    return (items: page.tasks, next: page.nextCursor))

proc cancelTask*(client: McpClient, taskId: string,
                 options: McpRequestOptions = McpRequestOptions()): Future[McpTask] {.async.} =
  ## Needs `tasks.cancel` of the server. A task that is over cannot be
  ## cancelled: the server's error is raised.
  let declared = client.requireTasks("tasks/cancel")
  client.requireServerCapability(declared.cancel, "tasks/cancel", "tasks.cancel")
  return taskOf(await client.callMethod("tasks/cancel", %*{"taskId": taskId}, options),
                "tasks/cancel")

proc taskResult*(client: McpClient, taskId: string,
                 options: McpRequestOptions = McpRequestOptions()): Future[JsonNode] {.async.} =
  ## What the request behind the task returned, as the server sent it (with
  ## the related-task `_meta`). Waits until the task is over, serving the
  ## requests the server makes meanwhile through the handlers of this client.
  ## A request that ended in a JSON-RPC error raises McpRequestError. No
  ## timeout applies unless `options` set one.
  discard client.requireTasks("tasks/result")
  var unlimited = options
  if unlimited.timeoutMs.isNone:
    unlimited.timeoutMs = some(0)
  return await client.callMethod("tasks/result", %*{"taskId": taskId}, unlimited)

proc waitForTask*(client: McpClient, taskId: string, onStatus: TaskStatusCallback = nil,
                  sleep: SleepProc = nil, defaultPollMs = DefaultPollIntervalMs,
                  options: McpRequestOptions = McpRequestOptions()): Future[McpTask] {.async.} =
  ## Poll `tasks/get`, at the task's own `pollInterval` when it suggests one,
  ## until the task is over or needs input; the task then is returned. A task
  ## that needs input is waited for with `taskResult`, not by polling.
  ## `onStatus` sees every change of status.
  return await pollTask(proc(): Future[McpTask] = client.getTask(taskId, options),
                        onStatus, sleep, defaultPollMs)

proc callToolWithTask*(client: McpClient, tool: McpTool, arguments: JsonNode = newJObject(),
                       ttlMs = none(int64), onStatus: TaskStatusCallback = nil,
                       sleep: SleepProc = nil, defaultPollMs = DefaultPollIntervalMs,
                       options: McpRequestOptions = McpRequestOptions()
                      ): Future[McpToolContent] {.async.} =
  ## `callTool` through a task: create it, wait for it, fetch the result. A
  ## task that failed because the tool reported `isError` gives the result
  ## with `isError`, as a plain call does; a task that ended in a JSON-RPC
  ## error or was cancelled raises McpRequestError.
  let created = await client.callToolAsTask(tool, arguments, ttlMs, options)
  discard await client.waitForTask(created.task.taskId, onStatus, sleep, defaultPollMs, options)
  return toolContentOf(await client.taskResult(created.task.taskId, options))

proc onTaskStatus*(client: McpClient, callback: TaskStatusCallback) =
  ## Receive `notifications/tasks/status`. The server need not send them:
  ## keep polling.
  client.registerNotificationHandler("notifications/tasks/status",
    proc(notification: JsonRpcNotification): Future[void] {.async.} =
      let task = taskFromJson(notification.params)
      if task.isNone:
        stderr.writeLine("[mcp-client] notifications/tasks/status without a task ignored")
      else:
        callback(task.get))

# The receiver

proc tasksActive(client: McpClient): bool =
  client.negotiatedVersion.isSome and client.negotiatedVersion.get.has(ftTasks)

proc runHandler(handler: McpServerRequestHandler,
                request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
  ## What the client does with a request of the server, as a task's work.
  try:
    return await handler(request)
  except McpRequestError as e:
    return newJsonRpcErrorResponse(request.id, e.code, e.plainMessage, e.data)

proc withoutTask(request: JsonRpcRequest): JsonRpcRequest =
  result = request
  result.params = request.params.copy()
  result.params.delete("task")

proc announceStatus(client: McpClient, task: McpTask) {.async.} =
  try:
    await client.sendNotification("notifications/tasks/status", task.toJson())
  except CatchableError as e:
    stderr.writeLine("[mcp-client] could not send the status of task " & task.taskId &
                     ": " & peerText(e.msg))

proc augmentWithTasks*(client: McpClient, store: TaskStore, methodName: string) =
  ## Let the server augment `methodName` with a task: the handler that is set
  ## for it then runs as the task's work, and the server gets the task at
  ## once. Declares the capability, so call before connect(), after setting
  ## the handler. Known: sampling/createMessage and elicitation/create.
  client.requireNotConnected("augmenting " & methodName & " with tasks")
  if methodName notin client.requestHandlers:
    raise newException(McpError, "tasks for " & methodName &
      ": set its handler first")
  var declared = client.capabilities.tasks.get(McpTasksCapability())
  case methodName
  of "sampling/createMessage": declared.samplingCreateMessage = true
  of "elicitation/create": declared.elicitationCreate = true
  else:
    raise newException(McpError, methodName & " cannot be augmented with a task")
  client.capabilities.tasks = some(declared)
  let inner = client.requestHandlers[methodName]
  client.requestHandlers[methodName] = proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
    var asked: Option[Option[int64]]
    try:
      asked = parseTaskParam(request.params)
    except McpTaskError as e:
      return newJsonRpcErrorResponse(request.id, e.code, e.msg)
    if asked.isNone or not client.tasksActive:
      return await inner(request)
    var created: McpTask
    try:
      # A handler cannot be stopped: cancelling the task only stops waiting
      # for its result.
      created = runAsTask(store, "", asked.get, proc(taskId: string): TaskWork =
        (response: runHandler(inner, request.withoutTask), cancel: nil))
    except McpTaskError as e:
      return newJsonRpcErrorResponse(request.id, e.code, e.msg)
    return newJsonRpcResponse(request.id, createTaskResult(created))

proc enableClientTasks*(client: McpClient, config = ClientTaskConfig(),
                        store: TaskStore = nil): TaskStore =
  ## Make this client a receiver of tasks: declare the `tasks` capability,
  ## answer the task methods of the server, and let it augment the requests
  ## the config names. Returns the store that holds the tasks. Call before
  ## connect(), after the handlers of the requests to augment are set;
  ## raises McpError for a request whose handler is not set.
  client.requireNotConnected("enabling tasks")
  let tasksStore = if store.isNil: newTaskStore() else: store
  client.capabilities.tasks = some(McpTasksCapability(
    list: config.list, cancel: config.cancel))
  tasksStore.onStatusChange = proc(owner: string, task: McpTask) =
    asyncCheck client.announceStatus(task)
  for methodName in TaskMethods:
    client.registerRequestHandler(methodName,
      proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
        if not client.tasksActive:
          return newJsonRpcErrorResponse(request.id, -32601,
            "Method not found: " & request.`method`)
        return await tasksStore.handleTaskMethod("", client.capabilities.tasks.get,
                                                 config.pageSize, request))
  if config.sampling:
    if client.capabilities.sampling.isNone:
      raise newException(McpError,
        "enableClientTasks: sampling is not enabled; call setSamplingHandler first or set sampling to false")
    client.augmentWithTasks(tasksStore, "sampling/createMessage")
  if config.elicitation:
    client.augmentWithTasks(tasksStore, "elicitation/create")
  tasksStore
