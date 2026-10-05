## One server, one TaskStore, both Tasks: a client of 2025-11-25 gets the
## core's, a client of 2026-07-28 gets the extension's, and neither sees the
## other's tasks. (ext-tasks, SEP-2663: "implementations that need to
## interoperate with both surfaces can shim at the SDK level ... dispatching
## on the negotiated protocol version and the client capability the peer
## declared".)

import std/[asyncdispatch, json, options, unittest]
import ./server_harness
import protocol/tasks
import protocol/version
import server/tasks
import ext/tasks

const Ext = TasksExtensionId

type Dual = object
  server: McpServer
  store: TaskStore
  transport: SessionedTransport
  now: ref int64

proc textResult(text: string): JsonNode =
  %*{"content": [{"type": "text", "text": text}]}

proc dual(enableCore = true, enableExtension = true): Dual =
  let now = new int64
  now[] = 1_764_067_800_000'i64
  let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[
      %*{"name": "report", "inputSchema": {"type": "object"},
         "execution": {"taskSupport": "optional"}}]))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    return textResult("report of " & arguments{"topic"}.getStr()))
  let store = newTaskStore(clock = proc(): int64 = now[],
                           defaultTtlMs = some(60_000'i64), maxTtlMs = some(30_000'i64),
                           pollIntervalMs = some(250))
  # The core first: it owns the store's status callback, which the
  # extension keeps calling for the tasks that are not its own.
  if enableCore:
    discard server.enableTasks(store = store)
  if enableExtension:
    discard server.enableTasksExtension(
      TasksExtensionConfig(decide: toolsNamed(["report"])), store)
  Dual(server: server, store: store, transport: server.attach(), now: now)

proc legacy(d: Dual, session: string, capabilities: JsonNode = nil): Peer =
  d.server.connect(d.transport, mpv20251125, session, capabilities)

proc modern(d: Dual): Peer =
  d.server.connect(d.transport, mpv20260728)

let withExtension = %*{"io.modelcontextprotocol/clientCapabilities": {"extensions": {Ext: {}}}}

if isSupported(mpv20251125) and isSupported(mpv20260728):

  suite "both Tasks on one server":

    test "Given a server with both, when each client discovers it, then the 2025-11-25 client sees tasks and the 2026-07-28 client sees the extension":
      let d = dual()
      discard d.legacy("s1")
      let discovered = d.modern.ask("server/discover")["result"]["capabilities"]
      check discovered["extensions"][Ext] == newJObject()
      check not discovered.hasKey("tasks")
      let initialize = d.transport.sent[0].message["result"]["capabilities"]
      check initialize.hasKey("tasks")
      check not initialize.hasKey("extensions")

    test "Given a 2025-11-25 client that asks for a task, when the call is made, then it gets the core's nested task with ttl and pollInterval":
      let d = dual()
      let old = d.legacy("s1")
      let created = old.ask("tools/call", %*{"name": "report", "arguments": {"topic": "a"},
                                              "task": {"ttl": 20_000}})
      check created["result"]["task"]["ttl"].getInt() == 20_000
      check created["result"]["task"]["pollInterval"].getInt() == 250
      check not created["result"].hasKey("resultType")
      settle()
      let id = created["result"]["task"]["taskId"].getStr()
      check old.ask("tasks/get", %*{"taskId": id})["result"]["status"].getStr() == "completed"
      check old.ask("tasks/result", %*{"taskId": id}).textOf == "report of a"

    test "Given a 2026-07-28 client that declared the extension, when the call is made, then it gets the extension's flat task with ttlMs and pollIntervalMs":
      let d = dual()
      let peer = d.modern
      let created = peer.ask("tools/call", %*{"name": "report", "arguments": {"topic": "b"}},
                             meta = withExtension)
      check created["result"]["resultType"].getStr() == "task"
      check created["result"]["ttlMs"].getInt() == 30_000
      check created["result"]["pollIntervalMs"].getInt() == 250
      check not created["result"].hasKey("task")
      settle()
      let id = created["result"]["taskId"].getStr()
      let done = peer.ask("tasks/get", %*{"taskId": id}, meta = withExtension)
      check done["result"]["status"].getStr() == "completed"
      check done["result"]["result"]["content"][0]["text"].getStr() == "report of b"
      check peer.ask("tasks/result", %*{"taskId": id}, meta = withExtension).errorCode == -32601

    test "Given a task of each kind, when the other kind of client asks for it, then it is unknown":
      let d = dual()
      let old = d.legacy("s1")
      let peer = d.modern
      let coreId = old.ask("tools/call", %*{"name": "report", "arguments": {}, "task": {}})[
        "result"]["task"]["taskId"].getStr()
      let extId = peer.ask("tools/call", %*{"name": "report", "arguments": {}},
                           meta = withExtension)["result"]["taskId"].getStr()
      check peer.ask("tasks/get", %*{"taskId": coreId}, meta = withExtension).errorCode == -32602
      check old.ask("tasks/get", %*{"taskId": extId}).errorCode == -32602
      check old.ask("tasks/cancel", %*{"taskId": extId}).errorCode == -32602
      check peer.ask("tasks/cancel", %*{"taskId": coreId}, meta = withExtension).errorCode == -32602
      check old.ask("tasks/get", %*{"taskId": coreId}).hasKey("result")
      check peer.ask("tasks/get", %*{"taskId": extId}, meta = withExtension).hasKey("result")

    test "Given one store, when its clock passes the ttl, then the tasks of both kinds expire":
      let d = dual()
      let old = d.legacy("s1")
      let peer = d.modern
      let coreId = old.ask("tools/call", %*{"name": "report", "arguments": {}, "task": {}})[
        "result"]["task"]["taskId"].getStr()
      let extId = peer.ask("tools/call", %*{"name": "report", "arguments": {}},
                           meta = withExtension)["result"]["taskId"].getStr()
      d.now[] += 30_000
      check old.ask("tasks/get", %*{"taskId": coreId}).errorCode == -32602
      check peer.ask("tasks/get", %*{"taskId": extId}, meta = withExtension).errorCode == -32602

    test "Given the extension was enabled after the core, when a core task changes status, then the core still announces it to its session":
      let d = dual()
      let old = d.legacy("s1")
      discard old.ask("tools/call", %*{"name": "report", "arguments": {}, "task": {}})
      settle()
      check d.transport.messagesOf("notifications/tasks/status").len >= 1

    test "Given a 2025-11-25 client that declares an extensions capability, when it calls a tool, then the extension does not apply":
      let d = dual(enableCore = false)
      let old = d.legacy("s1", %*{"extensions": {Ext: {}}})
      let answer = old.ask("tools/call", %*{"name": "report", "arguments": {"topic": "c"}})
      check answer.textOf == "report of c"
      check not answer["result"].hasKey("taskId")
      check old.ask("tasks/get", %*{"taskId": "x"}).errorCode == -32601

    test "Given a server with only the extension, when a 2025-11-25 client asks for a task, then the task parameter is ignored":
      let d = dual(enableCore = false)
      let old = d.legacy("s1")
      let answer = old.ask("tools/call", %*{"name": "report", "arguments": {"topic": "d"},
                                             "task": {"ttl": 1}})
      check answer.textOf == "report of d"

    test "Given a server with only the core's tasks, when a 2026-07-28 client declares the extension and asks, then it gets the result and no tasks methods":
      let d = dual(enableExtension = false)
      let peer = d.modern
      let answer = peer.ask("tools/call", %*{"name": "report", "arguments": {"topic": "e"}},
                            meta = withExtension)
      check answer["result"]["resultType"].getStr() == "complete"
      check peer.ask("tasks/get", %*{"taskId": "x"}, meta = withExtension).errorCode == -32601
