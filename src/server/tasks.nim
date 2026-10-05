## Tasks on the server side (2025-11-25): a client may augment `tools/call`
## with a task, poll it, wait for its result, list and cancel tasks. The
## state machine and the store are `protocol/tasks`; this connects them to a
## server.
##
## Only the version 2025-11-25 has tasks in the core. A client that
## negotiated another version is served as if this module were not there: the
## `task` parameter is ignored and `tasks/*` are unknown methods.

import std/[asyncdispatch, json, options]
import ./server
import ../protocol/types
import ../protocol/features
import ../protocol/tasks
import ../protocol/task_methods

export tasks, task_methods

type
  TaskSupport* = enum
    ## `execution.taskSupport` of a tool.
    tsForbidden = "forbidden"
    tsOptional = "optional"
    tsRequired = "required"

  TaskConfig* = object
    list*: bool = true
      ## Declare and serve `tasks/list`. Only with an owner for every task:
      ## the tasks of a requestor are the ones of its session.
    cancel*: bool = true
    toolsCall*: bool = true
      ## Declare `tasks.requests.tools.call`.
    pageSize*: int = 50
      ## Tasks per page of `tasks/list`; 0 puts them on one page.
    immediateResponse*: string
      ## When not empty, the CreateTaskResult of a tools/call carries it as
      ## `io.modelcontextprotocol/model-immediate-response`.

const MethodNotFound = -32601

func taskSupportOf(tool: JsonNode): TaskSupport =
  case tool{"execution", "taskSupport"}.getStr("forbidden")
  of "optional": tsOptional
  of "required": tsRequired
  else: tsForbidden

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

  tasksStore.onStatusChange = proc(owner: string, task: McpTask) =
    asyncCheck server.announceStatus(owner, task)

  server.addRequestInterceptor(proc(ctx: McpRequestContext, request: JsonRpcRequest
                                   ): Future[Option[JsonRpcResponse]] {.async.} =
    if not ctx.version.has(ftTasks):
      return none(JsonRpcResponse)
    if request.`method`.isTaskMethod:
      return some(await tasksStore.handleTaskMethod(request.session, capability,
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
    let support = tool.get.taskSupportOf
    if asked.isNone:
      if support == tsRequired:
        return some(newJsonRpcErrorResponse(request.id, MethodNotFound,
          "Task augmentation required for tools/call requests"))
      return none(JsonRpcResponse)
    if support == tsForbidden:
      return some(newJsonRpcErrorResponse(request.id, MethodNotFound,
        "Tool " & name.getStr() & " does not support task augmentation"))
    let owner = request.session
    var created: McpTask
    try:
      created = runAsTask(tasksStore, owner, asked.get, proc(taskId: string): TaskWork =
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
