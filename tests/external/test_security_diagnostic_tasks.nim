## What a client makes a task's server write is made harmless in the
## diagnostics of the Tasks extension (MCP-SEC-HTTP-7).

import std/[asyncdispatch, json, options, os, strutils, unittest]
import server/server except McpRequestError
import client/client
import client/subscriptions
import protocol/types
import protocol/version
import ext/tasks
import ./loopback_transport

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-sec-diagnostic-tasks-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

const Hostile = "x\n[mcp-tasks] forged line \e[2J"

# The extension is registered only in a build that speaks 2026-07-28.
if isSupported(mpv20260728):
  suite "peer text in the diagnostics of the Tasks extension (MCP-SEC-HTTP-7)":
    test "Given a status notification whose input request key is hostile, when the client logs that it ignored it, then the log holds one line of escapes":
      let gate = newFuture[void]("gate")
      let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
        capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
      discard server.enableTasksExtension(TasksExtensionConfig(decide: toolsNamed(["slow"])),
        newTaskStore())
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        await gate
        return %*{"content": []})
      let pair = newLoopbackPair()
      waitFor server.attachTransport(pair.server)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), mpv20260728)
      client.enableTasksExtension()
      waitFor client.connect(pair.client)
      let taskId = waitFor(client.startToolCall("slow")).task.get.taskId
      var seen = 0
      let subscription = waitFor client.watchTasks(@[taskId], proc(task: DetailedTask) =
        inc seen)
      let logged = loggedWhile(proc() =
        waitFor server.notifySubscribers(TaskStatusMethod, %*{
          "taskId": taskId, "status": "input_required",
          "createdAt": "2026-01-01T00:00:00Z", "lastUpdatedAt": "2026-01-01T00:00:00Z",
          "ttlMs": nil, "inputRequests": {Hostile: 5}})
        waitFor sleepAsync(100))
      check "\e" notin logged
      check logged.count('\n') == 1
      check "ignored a malformed" in logged
      check "x\\n[mcp-tasks] forged line \\x1b[2J" in logged
      waitFor subscription.cancel()
      gate.complete()
      waitFor client.close()
