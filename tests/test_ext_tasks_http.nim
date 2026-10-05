## The Tasks extension over Streamable HTTP on 127.0.0.1: the client's
## tasks/get, tasks/update and tasks/cancel carry Mcp-Name = taskId and the
## SDK's server accepts them (and refuses a request whose header disagrees).
##
## The scenarios exist only where the build speaks 2026-07-28.

import std/[unittest, asyncdispatch, httpclient, json, options]
import transport/http
import transport/http_server
import server/server
import client/client
import protocol/types
import protocol/tasks
import ext/tasks

proc startServer(gate: Future[void]): string =
  let transport = newHttpServerTransport(port = 0)
  transport.listen()
  asyncCheck transport.serve()
  let server = newMcpServer(McpServerInfo(name: "http-tasks", version: "1"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  discard server.enableTasksExtension(TasksExtensionConfig(decide: toolsNamed(["slow"])))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    await (gate or ctx.whenCancelled())
    return %*{"content": [{"type": "text", "text": "slow done"}]})
  waitFor server.attachTransport(transport)
  "http://127.0.0.1:" & $transport.port & "/mcp"

if isSupported(mpv20260728):

  suite "Tasks extension over Streamable HTTP":

    test "Given a task over HTTP, when the client polls, cancels and updates it, then every request passes the header check":
      let gate = newFuture[void]("gate")
      let url = startServer(gate)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), mpv20260728)
      client.enableTasksExtension()
      waitFor client.connect(newStreamableHttpTransport(url))
      let taskId = waitFor(client.startToolCall("slow")).task.get.taskId
      check waitFor(client.getTask(taskId)).task.status == tsWorking
      waitFor client.updateTask(taskId, newJObject())
      waitFor client.cancelTask(taskId)
      check waitFor(client.getTask(taskId)).task.status == tsCancelled

    test "Given a task over HTTP, when tasks/get carries another Mcp-Name than its taskId, then the server answers a header mismatch":
      let gate = newFuture[void]("gate")
      let url = startServer(gate)
      let client = newMcpClient(McpClientInfo(name: "c", version: "1"), mpv20260728)
      client.enableTasksExtension()
      waitFor client.connect(newStreamableHttpTransport(url))
      let taskId = waitFor(client.startToolCall("slow")).task.get.taskId
      let http = newAsyncHttpClient()
      http.headers = newHttpHeaders({
        "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tasks/get",
        "Mcp-Name": "another-task"})
      let body = %*{"jsonrpc": "2.0", "id": "1", "method": "tasks/get", "params": {
        "taskId": taskId, "_meta": {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "1"},
          "io.modelcontextprotocol/clientCapabilities": {
            "extensions": {TasksExtensionId: {}}}}}}
      let response = waitFor http.request(url, httpMethod = HttpPost, body = $body)
      check parseJson(waitFor response.body)["error"]["code"].getInt() == -32020
      gate.complete()
