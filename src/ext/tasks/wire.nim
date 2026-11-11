## The Tasks extension (`io.modelcontextprotocol/tasks`) on the wire: the
## `Task` and `DetailedTask` of its schema, `CreateTaskResult`, and the
## parsing a requestor does of what a receiver sends.
##
## Based on the specification of the official extension, ext-tasks at commit
## 5246bc3d0253c1c4b09e682f690b7e8b97362500 (specification/2026-07-28/tasks.md,
## schema/2026-07-28/schema.ts). The state machine and the store are the
## core's (`protocol/tasks`); what differs from 2025-11-25 is only how a task
## is written: `ttlMs` and `pollIntervalMs` instead of `ttl` and
## `pollInterval`, flat instead of under `task`, and the outcome of the
## request inlined in the task instead of fetched with `tasks/result`.

import std/[json, options]
import ../../protocol/types
import ../../protocol/tasks
import ../../protocol/task_store
import ../../protocol/mrtr
import ../../protocol/extensions

export TasksExtensionId

const
  TaskResultType* = "task"
    ## The `resultType` of a `CreateTaskResult`; reserved for this extension.
  GetTaskMethod* = "tasks/get"
  UpdateTaskMethod* = "tasks/update"
  CancelTaskMethod* = "tasks/cancel"
  TaskStatusMethod* = "notifications/tasks"

type
  DetailedTask* = object
    ## A task with what its status adds: the outstanding requests of
    ## `input_required`, the result of `completed`, the error of `failed`.
    task*: McpTask
    inputRequests*: Option[JsonNode]
      ## Key -> request object (MRTR); only with `input_required`.
    result*: Option[JsonNode]
      ## What the request the task stands for returned; only with
      ## `completed`, and an `isError` tool result is one.
    error*: Option[JsonRpcError]
      ## The JSON-RPC error that ended the request; only with `failed`.

proc toWire*(task: McpTask): JsonNode =
  ## The `Task` of the schema.
  result = %*{
    "taskId": task.taskId,
    "status": $task.status,
    "createdAt": isoTimestamp(task.createdAtMs),
    "lastUpdatedAt": isoTimestamp(task.lastUpdatedAtMs),
    "ttlMs": if task.ttlMs.isSome: %task.ttlMs.get else: newJNull()
  }
  if task.statusMessage.isSome:
    result["statusMessage"] = %task.statusMessage.get
  if task.pollIntervalMs.isSome:
    result["pollIntervalMs"] = %task.pollIntervalMs.get

proc toWire*(detailed: DetailedTask): JsonNode =
  ## The `DetailedTask` of the schema: a `GetTaskResult` once `resultType` is
  ## added by the server, the params of a `notifications/tasks`.
  result = detailed.task.toWire()
  if detailed.inputRequests.isSome:
    result["inputRequests"] = detailed.inputRequests.get
  if detailed.result.isSome:
    result["result"] = detailed.result.get
  if detailed.error.isSome:
    let error = detailed.error.get
    result["error"] = %*{"code": error.code, "message": error.message}
    if not error.data.isNil and error.data.kind != JNull:
      result["error"]["data"] = error.data

proc taskHandle*(task: McpTask): JsonNode =
  ## The `CreateTaskResult` a server answers `tools/call` with in place of a
  ## `CallToolResult`: the task itself and `resultType: "task"`.
  result = task.toWire()
  result["resultType"] = %TaskResultType

proc parseTask*(node: JsonNode): tuple[task: McpTask, problem: Option[string]] =
  ## The `Task` in `node`, or why it is not one. Keys the schema does not
  ## define are ignored.
  if node.isNil or node.kind != JObject:
    return (McpTask(), some("a task must be an object"))
  func textAt(key: string): Option[string] =
    let value = node{key}
    if value.isNil or value.kind != JString: none(string) else: some(value.getStr())
  let id = textAt("taskId")
  if id.isNone or id.get.len == 0:
    return (McpTask(), some("taskId must be a non-empty string"))
  let statusText = textAt("status")
  var status = none(TaskStatus)
  if statusText.isSome:
    for candidate in TaskStatus:
      if $candidate == statusText.get:
        status = some(candidate)
  if status.isNone:
    return (McpTask(), some("status is not a task status"))
  let created = if textAt("createdAt").isSome: parseIsoTimestamp(textAt("createdAt").get)
                else: none(int64)
  let updated = if textAt("lastUpdatedAt").isSome: parseIsoTimestamp(textAt("lastUpdatedAt").get)
                else: none(int64)
  if created.isNone:
    return (McpTask(), some("createdAt must be an ISO 8601 timestamp"))
  if updated.isNone:
    return (McpTask(), some("lastUpdatedAt must be an ISO 8601 timestamp"))
  let ttl = node{"ttlMs"}
  if ttl.isNil or ttl.kind notin {JNull, JInt}:
    return (McpTask(), some("ttlMs must be an integer or null"))
  var task = McpTask(taskId: id.get, status: status.get, createdAtMs: created.get,
                     lastUpdatedAtMs: updated.get)
  if ttl.kind == JInt:
    task.ttlMs = some(ttl.getBiggestInt().int64)
  task.statusMessage = textAt("statusMessage")
  let poll = node{"pollIntervalMs"}
  if not poll.isNil:
    if poll.kind != JInt:
      return (McpTask(), some("pollIntervalMs must be an integer"))
    task.pollIntervalMs = some(poll.getInt())
  (task, none(string))

proc parseDetailedTask*(node: JsonNode): tuple[detailed: DetailedTask,
                                                problem: Option[string]] =
  ## The `DetailedTask` in `node`: a `Task` that also has what its status
  ## requires (`inputRequests`, `result`, `error`). Fields of another status
  ## are ignored, as the schema gives each status its own shape.
  let parsed = parseTask(node)
  if parsed.problem.isSome:
    return (DetailedTask(), parsed.problem)
  var detailed = DetailedTask(task: parsed.task)
  case parsed.task.status
  of tsInputRequired:
    let requests = node{"inputRequests"}
    if requests.isNil:
      return (DetailedTask(), some("a task in input_required must carry inputRequests"))
    let invalid = validateInputRequests(requests)
    if invalid.isSome:
      return (DetailedTask(), invalid)
    detailed.inputRequests = some(requests)
  of tsCompleted:
    let outcome = node{"result"}
    if outcome.isNil or outcome.kind != JObject:
      return (DetailedTask(), some("a completed task must carry a result object"))
    detailed.result = some(outcome)
  of tsFailed:
    let error = node{"error"}
    if error.isNil or error.kind != JObject or error{"code"}.isNil or
       error{"code"}.kind != JInt or error{"message"}.isNil or
       error{"message"}.kind != JString:
      return (DetailedTask(), some("a failed task must carry an error with a code and a message"))
    detailed.error = some(JsonRpcError(
      code: error["code"].getInt(), message: error["message"].getStr(),
      data: if error.hasKey("data"): error["data"] else: newJNull()))
  of tsWorking, tsCancelled:
    discard
  (detailed, none(string))
