## Icons (2025-11-25 and later) on tools, resources, resource templates,
## prompts and resource links: sent where the version has them, read by the
## client, and screened before a client fetches or shows one.

import std/[unittest, asyncdispatch, json, options]
import ../external/server_harness
import client/tools
import client/resources
import client/prompts
import server/tools as serverTools

let Icon = %*{"src": "https://example.com/icon.png", "mimeType": "image/png",
              "sizes": ["48x48", "96x96"], "theme": "dark"}

proc iconServer(): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()), resources: some(McpResourcesCapability()),
    prompts: some(McpPromptsCapability())))
  proc one(item: JsonNode): ListHandler =
    result = proc(cursor: Option[string]): Future[McpPage] {.async.} =
      return McpPage(items: @[item])
  result.onToolsList(one(%*{"name": "t", "inputSchema": {"type": "object"}, "icons": [Icon]}))
  result.onResourcesList(one(%*{"name": "r", "uri": "file:///r", "icons": [Icon]}))
  result.onResourceTemplatesList(one(%*{"name": "tpl", "uriTemplate": "file:///{x}", "icons": [Icon]}))
  result.onPromptsList(one(%*{"name": "p", "icons": [Icon]}))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    return %*{"content": [{"type": "resource_link", "uri": "file:///r", "name": "r", "icons": [Icon]}]})

const Lists = [("tools/list", "tools"), ("resources/list", "resources"),
               ("resources/templates/list", "resourceTemplates"), ("prompts/list", "prompts")]

suite "icons on the server":


  test "Given a tool built with icons, when its definition is made, then the icons are in it":
    let info = createToolInfo("t", "d", createInputSchema(newJObject()),
                              icons = @[McpIcon(src: "https://example.com/i.png")])
    check info["icons"] == %*[{"src": "https://example.com/i.png"}]


suite "icon uris":

  proc icon(src: string): McpIcon = McpIcon(src: src)

