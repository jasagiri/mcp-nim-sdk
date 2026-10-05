## An MCP server on stdin/stdout with one tool, `get_time`, that renders its
## result with an MCP Apps UI (`ui://clock/view.html`), and an app-only tool,
## `refresh`, that the UI itself calls.
##
##   nim c -r examples/ext_apps_server.nim
##
## MCP Apps is an official extension: it is off unless the program imports
## `ext/apps` and registers a UI resource. It works in every protocol version
## the build speaks. A host that did not declare `io.modelcontextprotocol/ui`
## sees plain tools.
## Stdout carries the protocol, so anything for people goes to stderr.

import std/[asyncdispatch, json, options, times]
import mcp
import ext/apps
import server/pagination

const
  ViewUri = "ui://clock/view.html"
  View = """<!DOCTYPE html>
<html><body><p id="t">...</p><script>
// The View talks JSON-RPC over postMessage; see the specification.
</script></body></html>"""

proc main() =
  let apps = newAppsRegistry()
  apps.addUiResource(ViewUri, "clock_view", View,
    description = "A clock",
    meta = UiResourceMeta(prefersBorder: some(true)))  # no csp: no network access

  let server = newMcpServer(
    McpServerInfo(name: "clock-server", version: "0.1.0"),
    capabilities = McpServerCapabilities(
      tools: some(McpToolsCapability()),
      resources: some(McpResourcesCapability())))

  server.onResourcesList(apps.listHandler())
  server.onResourceRead(apps.readHandler())

  let schema = %*{"type": "object"}
  server.onToolsList(pagedList(proc(): Future[seq[JsonNode]] {.async.} =
    return @[
      apps.appToolInfo("get_time", "The current time, shown as a clock", schema, ViewUri),
      apps.appToolInfo("refresh", "Refresh the clock", schema, ViewUri,
                       visibility = {tvApp})], 0))
  server.degradeForPlainHosts()  # UI references only for hosts that declared the extension

  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    if name notin ["get_time", "refresh"]:
      raise newUnknownTool(name)
    let now = now().format("HH:mm:ss")
    return %*{"content": [{"type": "text", "text": now}],
              "structuredContent": {"time": now}})

  server.transport = newStdioTransport()
  waitFor server.processMessages()

main()
