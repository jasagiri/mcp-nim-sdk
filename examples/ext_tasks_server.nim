## An MCP server on stdin/stdout whose slow tool, `report`, runs as a task
## for clients that support the Tasks extension (io.modelcontextprotocol/tasks).
##
##   nim c -r examples/ext_tasks_server.nim
##
## The extension is an explicit opt-in: `import ext/tasks` is not part of
## `import mcp`, and only `enableTasksExtension` declares it. It needs a
## build that speaks 2026-07-28 (the default); a client that does not declare
## the extension calls `report` as an ordinary tool and waits for the result.
## Stdout carries the protocol, so anything for people goes to stderr.
##
## Who owns a task: a request knows no authenticated user, so give
## `TasksExtensionConfig.ownerOf` the user your transport authenticated;
## without it every client is the same owner and only the unguessable task id
## keeps a task private.

import std/[asyncdispatch, json, options]
import mcp
import ext/tasks

proc main() =
  let server = newMcpServer(
    McpServerInfo(name: "report-server", version: "0.1.0"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))

  discard server.enableTasksExtension(TasksExtensionConfig(
    decide: toolsNamed(["report"])))

  server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[
      %*{"name": "report", "description": "A report that takes a while",
         "inputSchema": {"type": "object", "properties": {"topic": {"type": "string"}}}},
      %*{"name": "echo", "description": "Returns the text it is given",
         "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]))

  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "report":
      # A task is cancelled with tasks/cancel: stop when the context says so.
      let cancelled = ctx.whenCancelled()
      await (sleepAsync(3000) or cancelled)
      ctx.checkCancelled()
      return %*{"content": [{"type": "text",
                             "text": "Report on " & arguments{"topic"}.getStr("everything")}]}
    else:
      return %*{"content": [{"type": "text", "text": arguments{"text"}.getStr()}]})

  server.transport = newStdioTransport()
  waitFor server.processMessages()

main()
