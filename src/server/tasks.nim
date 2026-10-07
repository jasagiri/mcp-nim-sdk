## Tasks on the server side (2025-11-25): a client may augment `tools/call`
## with a task, poll it, wait for its result, list and cancel tasks. The
## state machine and the store are `protocol/tasks`; this connects them to a
## server.
##
## Only the version 2025-11-25 has tasks in the core. A client that
## negotiated another version is served as if this module were not there: the
## `task` parameter is ignored and `tasks/*` are unknown methods.

import std/[asyncdispatch, json, options, tables]
import ./server
import ../protocol/types
import ../protocol/features
import ../protocol/tasks
import ../protocol/task_methods

export tasks, task_methods

type
  TaskConfig* = object
    list*: bool = true
      ## Declare and serve `tasks/list`. Only with an owner for every task:
      ## the tasks of a requestor are the ones of its session.
    cancel*: bool = true
    toolsCall*: bool = true
      ## Declare `tasks.requests.tools.call`.
    pageSize*: int = 50
      ## Tasks per page of `tasks/list`; 0 puts them on one page.
    maxQueuedMessages*: int = 32
      ## Requests of a task to its requestor that wait for `tasks/result` (the
      ## stream they travel on, see `enableTasks`), per task. One more is
      ## refused: the tool's `ctx.elicit` or `ctx.createMessage` raises.
    immediateResponse*: string
      ## When not empty, the CreateTaskResult of a tools/call carries it as
      ## `io.modelcontextprotocol/model-immediate-response`.

const MethodNotFound = -32601

proc findTool(server: McpServer, request: JsonRpcRequest,
              name: string): Future[Option[JsonNode]] {.async.} =
  ## The tool `name` in the server's own tools/list, page by page: what a
  ## tool says about tasks is stated once, there.
  var cursor = ""
  while true:
    var listing = newJsonRpcRequest(request.id, "tools/list",
      if cursor.len > 0: %*{"cursor": cursor} else: newJObject())
    listing.session = request.session
    let answer = await server.handleRequest(listing)
    if answer.result.isNone:
      return none(JsonNode)
    let page = answer.result.get
    for tool in page{"tools"}.getElems():
      if tool{"name"}.getStr() == name:
        return some(tool)
    cursor = page{"nextCursor"}.getStr()
    if cursor.len == 0:
      return none(JsonNode)

func withoutTask(request: JsonRpcRequest): JsonRpcRequest =
  result = request
  result.params = request.params.copy()
  result.params.delete("task")

func ownerOf(request: JsonRpcRequest): string =
  ## Who a task belongs to: the principal the authorization names, else the
  ## transport's session (2025-11-25 tasks, Security). The prefix keeps a
  ## principal from being taken for a session id.
  if request.principal.isSome: "principal:" & request.principal.get else: request.session

proc announceStatus(server: McpServer, owner: string, task: McpTask) {.async.} =
  ## Tell the owner of a task that its status changed (optional for a
  ## receiver). A session that cannot be reached is logged, not fatal: the
  ## requestor polls.
  try:
    await server.sendNotification("notifications/tasks/status", task.toJson(), owner)
  except CatchableError as e:
    stderr.writeLine("[mcp-tasks] could not send the status of task " & task.taskId &
                     " to session '" & owner & "': " & e.msg)

proc enableTasks*(server: McpServer, config = TaskConfig(),
                  store: TaskStore = nil): TaskStore =
  ## Let clients of 2025-11-25 use tasks on this server. Returns the store
  ## that holds the tasks. Declares the capability; `tools/call` of a tool
  ## whose `execution.taskSupport` is "optional" or "required" may then
  ## carry a `task`.
  let tasksStore = if store.isNil: newTaskStore() else: store
  let capability = McpTasksCapability(
    list: config.list, cancel: config.cancel, toolsCall: config.toolsCall)
  server.capabilities.tasks = some(capability)

  # A request the task makes of its requestor (a question for the user) has
  # no stream of its own: the one of the `tools/call` ended with the
  # CreateTaskResult. The specification's way is `input_required` and a
  # `tasks/result` request that serves as the stream, so the request waits for
  # one, held here. Notifications are not held: they go to the GET stream.
  var held = initTable[string, seq[JsonRpcRequest]]()
  server.holdForTask = proc(taskId: string, request: JsonRpcRequest): bool =
    var queue = held.getOrDefault(taskId)
    if queue.len >= config.maxQueuedMessages:
      raise newTaskError(-32603, "task " & taskId & " has " & $queue.len &
        " requests waiting for tasks/result already")
    queue.add request
    held[taskId] = queue
    true
  tasksStore.onResultStream = proc(owner, taskId, requestId: string) =
    var queue: seq[JsonRpcRequest]
    if held.pop(taskId, queue):
      for request in queue:
        asyncCheck server.sendHeld(request, requestId)

  # The owner of a task may be a principal, which is no address: the status
  # goes to the session the task was made on.
  var sessionOf = initTable[string, string]()
  tasksStore.onStatusChange = proc(owner: string, task: McpTask) =
    let session = sessionOf.getOrDefault(task.taskId, owner)
    if task.status.isTerminal:
      held.del(task.taskId)  # nobody is left to read them
      sessionOf.del(task.taskId)
    asyncCheck server.announceStatus(session, task)

  # An expired task never reaches a terminal status here, so its entries
  # would stay for as long as the server runs.
  tasksStore.onExpire = proc(owner: string, task: McpTask) =
    held.del(task.taskId)
    sessionOf.del(task.taskId)

  server.addRequestInterceptor(proc(ctx: McpRequestContext, request: JsonRpcRequest
                                   ): Future[Option[JsonRpcResponse]] {.async.} =
    if not ctx.version.has(ftTasks):
      return none(JsonRpcResponse)
    if request.`method`.isTaskMethod:
      return some(await tasksStore.handleTaskMethod(request.ownerOf, capability,
                                                    config.pageSize, request))
    if request.`method` != "tools/call" or not capability.toolsCall:
      return none(JsonRpcResponse)
    let name = request.params{"name"}
    if name.isNil or name.kind != JString:
      return none(JsonRpcResponse)  # the server's own handling says what is wrong
    var asked: Option[Option[int64]]
    try:
      asked = parseTaskParam(request.params)
    except McpTaskError as e:
      return some(newJsonRpcErrorResponse(request.id, e.code, e.plainMessage))
    let tool = await server.findTool(request, name.getStr())
    if tool.isNone:
      return none(JsonRpcResponse)
    let support = tool.get.taskSupportOf()
    if asked.isNone:
      if support == tsRequired:
        return some(newJsonRpcErrorResponse(request.id, MethodNotFound,
          "Task augmentation required for tools/call requests"))
      return none(JsonRpcResponse)
    if support == tsForbidden:
      return some(newJsonRpcErrorResponse(request.id, MethodNotFound,
        "Tool " & name.getStr() & " does not support task augmentation"))
    let owner = request.ownerOf
    var created: McpTask
    try:
      created = runAsTask(tasksStore, owner, asked.get, proc(taskId: string): TaskWork =
        sessionOf[taskId] = request.session
        let scope = TaskScope(
          taskId: taskId,
          awaitingInput: proc(waiting: bool) =
            # A task that is over, or gone, has nothing to move.
            discard tasksStore.transition(taskId, if waiting: tsInputRequired else: tsWorking),
          resultStream: proc(): string = tasksStore.resultStream(taskId))
        server.serveDetached(request.withoutTask, scope))
    except McpTaskError as e:
      return some(newJsonRpcErrorResponse(request.id, e.code, e.plainMessage))
    return some(newJsonRpcResponse(request.id,
                                   createTaskResult(created, config.immediateResponse))))
  tasksStore

# The server as the requestor of a task-augmented request of a client

proc requireClientTasks(server: McpServer, session, operation: string): McpTasksCapability =
  ## What the client on `session` declared, once its connection is one that
  ## has tasks. Raises McpCapabilityError otherwise: nothing is to be sent.
  let known = server.session(session)
  if known.negotiatedVersion.isNone or not known.negotiatedVersion.get.has(ftTasks):
    raise newException(McpCapabilityError,
      operation & ": the client on session '" & session & "' has not agreed on a version with tasks")
  if known.clientCapabilities.isNone or known.clientCapabilities.get.tasks.isNone:
    raise newException(McpCapabilityError,
      operation & ": the client on session '" & session & "' did not declare the tasks capability")
  known.clientCapabilities.get.tasks.get

proc taskOf(node: JsonNode, operation: string): McpTask =
  let parsed = taskFromJson(node)
  if parsed.isNone:
    raise newException(McpRemoteError, operation & ": the answer is not a task")
  parsed.get

proc requestAsTask*(server: McpServer, session, methodName: string, params: JsonNode,
                    ttlMs = none(int64), relatedRequestId = "",
                    relatedTask = ""): Future[McpTask] {.async.} =
  ## Send `methodName` to the client on `session` as a task-augmented request
  ## and return the task the client made of it. Known: sampling/createMessage
  ## and elicitation/create, which the client must have declared in
  ## `tasks.requests`; raises McpCapabilityError, sending nothing, if not.
  let declared = server.requireClientTasks(session, methodName)
  let allowed = case methodName
    of "sampling/createMessage": declared.samplingCreateMessage
    of "elicitation/create": declared.elicitationCreate
    else: false
  if not allowed:
    raise newException(McpCapabilityError,
      methodName & ": the client on session '" & session & "' did not declare tasks for it")
  var augmented = params.copy()
  augmented["task"] = if ttlMs.isSome: %*{"ttl": ttlMs.get} else: newJObject()
  let answer = resultOf(await server.request(session, methodName, augmented,
    relatedRequestId, relatedTask = relatedTask), methodName)
  return taskOf(answer{"task"}, methodName)

proc getClientTask*(server: McpServer, session, taskId: string): Future[McpTask] {.async.} =
  discard server.requireClientTasks(session, "tasks/get")
  return taskOf(resultOf(await server.request(session, "tasks/get", %*{"taskId": taskId}),
                         "tasks/get"), "tasks/get")

proc listClientTasks*(server: McpServer, session: string,
                      cursor = none(string)): Future[tuple[tasks: seq[McpTask],
                                                           nextCursor: Option[string]]] {.async.} =
  ## One page of the client's tasks; needs its `tasks.list`.
  let declared = server.requireClientTasks(session, "tasks/list")
  if not declared.list:
    raise newException(McpCapabilityError,
      "tasks/list: the client on session '" & session & "' did not declare tasks.list")
  let answer = resultOf(await server.request(session, "tasks/list",
    if cursor.isSome: %*{"cursor": cursor.get} else: newJObject()), "tasks/list")
  for item in answer{"tasks"}.getElems():
    result.tasks.add taskOf(item, "tasks/list")
  let next = answer{"nextCursor"}
  if not next.isNil and next.kind == JString:
    result.nextCursor = some(next.getStr())

proc cancelClientTask*(server: McpServer, session, taskId: string): Future[McpTask] {.async.} =
  ## Needs the client's `tasks.cancel`.
  let declared = server.requireClientTasks(session, "tasks/cancel")
  if not declared.cancel:
    raise newException(McpCapabilityError,
      "tasks/cancel: the client on session '" & session & "' did not declare tasks.cancel")
  return taskOf(resultOf(await server.request(session, "tasks/cancel", %*{"taskId": taskId}),
                         "tasks/cancel"), "tasks/cancel")

proc clientTaskResult*(server: McpServer, session, taskId: string,
                       timeoutMs = 0): Future[JsonNode] {.async.} =
  ## What the request behind the client's task returned, as the client sent
  ## it; waits until the task is over (`timeoutMs` 0: no limit). A request
  ## that ended in a JSON-RPC error raises McpRemoteError.
  discard server.requireClientTasks(session, "tasks/result")
  return resultOf(await server.request(session, "tasks/result", %*{"taskId": taskId},
                                       timeoutMs = timeoutMs), "tasks/result")

proc awaitClientTask*(server: McpServer, session, taskId: string,
                      onStatus: TaskStatusCallback = nil, sleep: SleepProc = nil,
                      defaultPollMs = DefaultPollIntervalMs): Future[McpTask] =
  ## Poll the client's task until it is over or needs input.
  pollTask(proc(): Future[McpTask] = server.getClientTask(session, taskId),
           onStatus, sleep, defaultPollMs)

proc createMessageAsTask*(server: McpServer, session: string, params: JsonNode,
                          ttlMs = none(int64), onStatus: TaskStatusCallback = nil,
                          sleep: SleepProc = nil,
                          defaultPollMs = DefaultPollIntervalMs): Future[JsonNode] {.async.} =
  ## `createMessage` through a task of the client: create it, wait for it,
  ## fetch the result. The client must have declared
  ## `tasks.requests.sampling.createMessage`.
  let created = await server.requestAsTask(session, "sampling/createMessage", params, ttlMs)
  discard await server.awaitClientTask(session, created.taskId, onStatus, sleep, defaultPollMs)
  return await server.clientTaskResult(session, created.taskId)
