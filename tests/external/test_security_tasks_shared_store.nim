## The Tasks extension and the core's tasks share one store: what a client of
## the core asks of it must not cost a client of the extension.

import std/[asyncdispatch, json, options, unittest]
import ./server_harness
import protocol/tasks
import protocol/version
import server/tasks
import ext/tasks

type FakeTime = ref object
  nowMs: int64

proc storeAt(time: FakeTime, maxTtlMs = some(DefaultMaxTtlMs)): TaskStore =
  newTaskStore(clock = proc(): int64 = time.nowMs, maxTtlMs = maxTtlMs)

proc reportServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"name": "report", "inputSchema": {"type": "object"},
                               "execution": {"taskSupport": "optional"}}]))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    return %*{"content": [{"type": "text", "text": "done"}]})

if isSupported(mpv20251125) and isSupported(mpv20260728):
  suite "security: the Tasks extension shares the store":
    test "Given a core client that asked for the largest ttl, when an extension client uses the store, then it is answered":
      let server = reportServer()
      let store = storeAt(FakeTime(nowMs: 1_764_067_800_000))
      discard server.enableTasks(store = store)
      discard server.enableTasksExtension(
        TasksExtensionConfig(decide: toolsNamed(["report"])), store)
      let transport = server.attach()
      let mallory = server.connect(transport, mpv20251125, "mallory")
      discard mallory.ask("tools/call", %*{"name": "report", "arguments": {},
                                            "task": {"ttl": int64.high}})
      let modern = server.connect(transport, mpv20260728)
      let created = modern.ask("tools/call", %*{"name": "report", "arguments": {}},
        meta = %*{"io.modelcontextprotocol/clientCapabilities":
                  {"extensions": {TasksExtensionId: {}}}})
      check created["result"]["resultType"].getStr() == "task"
      check created["result"]["ttlMs"].getBiggestInt() <= DefaultMaxTtlMs
