## Tasks of 2025-11-25 (basic/utilities/tasks, basic/utilities/progress) seen
## from the requestor: progress that goes on under the token of the
## task-augmented request and stops with the task, the cause of an error in
## its message, the diagnostic of a failed task, and the status notification.

import std/[asyncdispatch, json, options, strutils, tables, unittest]
import ./server_harness
import server/tasks

const
  TaskVersion = mpv20251125
  RelatedTask = "io.modelcontextprotocol/related-task"

type Fixture = ref object
  server: McpServer
  transport: SessionedTransport
  gate: Future[void]
  kept: Table[string, McpRequestContext]

proc textResult(text: string): JsonNode =
  %*{"content": [{"type": "text", "text": text}]}

proc fixture(maxActive = 0): Fixture =
  let fx = Fixture(gate: newFuture[void]("gate"), kept: initTable[string, McpRequestContext]())
  fx.server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  fx.server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    var items: seq[JsonNode]
    for name in ["done", "fails", "waits", "broken", "crash"]:
      items.add %*{"name": name, "inputSchema": {"type": "object"},
                   "execution": {"taskSupport": "optional"}}
    return McpPage(items: items))
  fx.server.onToolCall(proc(ctx: McpRequestContext, name: string,
                            arguments: JsonNode): Future[JsonNode] {.async.} =
    fx.kept[name] = ctx
    case name
    of "done":
      await fx.gate
      await ctx.reportProgress(1, some(2.0))
      return textResult("done")
    of "fails":
      raise newToolFailure("rate limit exceeded")
    of "broken":
      raise newInvalidParams("bad arguments")
    of "crash":
      raise newException(ValueError, "disk on fire")
    of "waits":
      await fx.gate
      await ctx.reportProgress(5)
      return textResult("waited")
    else:
      raise newUnknownTool(name))
  discard fx.server.enableTasks(TaskConfig(), newTaskStore(pollIntervalMs = some(5),
                                                           maxActivePerOwner = maxActive))
  fx.transport = fx.server.attach()
  fx

proc connectTo(fx: Fixture, session = "s1"): Peer =
  fx.server.connect(fx.transport, TaskVersion, session)

proc createTask(peer: Peer, name: string, meta: JsonNode = nil): JsonNode =
  let response = peer.ask("tools/call", %*{"name": name, "arguments": {}, "task": {"ttl": 60_000}},
                          meta = meta)
  check not response.hasKey("error")
  response["result"]["task"]

proc taskParams(taskId: string): JsonNode =
  %*{"taskId": taskId}

proc statusOf(peer: Peer, taskId: string): string =
  peer.ask("tasks/get", taskParams(taskId))["result"]["status"].getStr()

proc untilStatus(peer: Peer, taskId, status: string) =
  untilTrue("task " & taskId & " to be " & status, proc(): bool =
    peer.statusOf(taskId) == status)

proc progressCount(fx: Fixture): int =
  fx.transport.messagesOf("notifications/progress").len

if isSupported(TaskVersion):

  suite "progress of a task (2025-11-25)":

    test "Given a task-augmented request with a progress token, when the task reports after the CreateTaskResult, then the notification carries the token of the request":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "done", "arguments": {}, "task": {"ttl": 60_000}},
                meta = %*{"progressToken": "tok-7"})
      let created = fx.transport.responseTo(id)
      check created["result"]["task"]["status"].getStr() == "working"
      check fx.progressCount == 0
      fx.gate.complete()
      untilTrue("the progress notification", proc(): bool = fx.progressCount == 1)
      let notice = fx.transport.messagesOf("notifications/progress")[0].message["params"]
      check notice["progressToken"].getStr() == "tok-7"
      check notice["progress"].getFloat() == 1.0

    test "Given a task that reached completed, failed or cancelled, when its context reports progress, then nothing is sent":
      let fx = fixture()
      let peer = fx.connectTo()
      let meta = %*{"progressToken": "tok"}
      let finished = peer.createTask("done", meta)["taskId"].getStr()
      let failed = peer.createTask("fails", meta)["taskId"].getStr()
      let cancelled = peer.createTask("waits", meta)["taskId"].getStr()
      discard peer.ask("tasks/cancel", taskParams(cancelled))
      check peer.statusOf(cancelled) == "cancelled"
      fx.gate.complete()
      peer.untilStatus(finished, "completed")
      peer.untilStatus(failed, "failed")
      settle()
      check peer.statusOf(cancelled) == "cancelled"
      let before = fx.progressCount
      for name in ["done", "fails", "waits"]:
        waitFor fx.kept[name].reportProgress(50)
      settle()
      check fx.progressCount == before

  suite "errors of the task methods say what went wrong":

    test "Given a task that does not exist, a task that is over and a cursor nobody issued, when the requestor asks, then each message names the cause":
      let fx = fixture()
      let peer = fx.connectTo()
      let unknown = peer.ask("tasks/get", taskParams("no-such-task"))
      check unknown.errorCode == -32602
      check "not found" in unknown["error"]["message"].getStr().toLowerAscii
      let id = peer.createTask("fails")["taskId"].getStr()
      peer.untilStatus(id, "failed")
      let over = peer.ask("tasks/cancel", taskParams(id))
      check over.errorCode == -32602
      check "failed" in over["error"]["message"].getStr()
      let cursor = peer.ask("tasks/list", %*{"cursor": "nobody-issued-this"})
      check cursor.errorCode == -32602
      check "cursor" in cursor["error"]["message"].getStr().toLowerAscii

    test "Given a limit of active tasks, when it is reached, then the refusal says that a limit was reached":
      let fx = fixture(maxActive = 1)
      let peer = fx.connectTo()
      discard peer.createTask("waits")
      let refused = peer.ask("tools/call", %*{"name": "waits", "arguments": {}, "task": {"ttl": 60_000}})
      check refused.errorCode == -32603
      check "limit" in refused["error"]["message"].getStr().toLowerAscii or
            "too many" in refused["error"]["message"].getStr().toLowerAscii

  suite "a failed task carries a diagnostic":

    test "Given a tool that reports an error, raises a JSON-RPC error or breaks, when tasks/get is asked, then the failed task has a statusMessage":
      let fx = fixture()
      let peer = fx.connectTo()
      for (tool, expected) in [("fails", "rate limit exceeded"), ("broken", "bad arguments")]:
        let id = peer.createTask(tool)["taskId"].getStr()
        peer.untilStatus(id, "failed")
        check peer.ask("tasks/get", taskParams(id))["result"]["statusMessage"].getStr() == expected
      let crashed = peer.createTask("crash")["taskId"].getStr()
      peer.untilStatus(crashed, "failed")
      check peer.ask("tasks/get", taskParams(crashed))["result"]["statusMessage"].getStr().len > 0

  suite "the status notification":

    test "Given a task that changes status, when the receiver announces it, then the notification names the task in its params and carries no related-task metadata":
      let fx = fixture()
      let peer = fx.connectTo()
      let id = peer.createTask("done", %*{RelatedTask: {"taskId": "someone-else"}})["taskId"].getStr()
      fx.gate.complete()
      peer.untilStatus(id, "completed")
      let notices = fx.transport.messagesOf("notifications/tasks/status")
      check notices.len >= 1
      for notice in notices:
        let params = notice.message["params"]
        check params["taskId"].getStr() == id
        check not params.hasKey("_meta") or not params["_meta"].hasKey(RelatedTask)
