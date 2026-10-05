## Icons (2025-11-25 and later) on tools, resources, resource templates,
## prompts and resource links: sent where the version has them, read by the
## client, and screened before a client fetches or shows one.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness
import ./client_peer
import client/client
import client/tools
import client/resources
import client/prompts
import server/tools as serverTools
import protocol/content

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

  test "Given a version that has icons, when each list is requested, then the icons are sent as they are":
    for version in versionsWith(ftIcons):
      let server = iconServer()
      let peer = server.connect(server.attach(), version)
      for (methodName, key) in Lists:
        check peer.ask(methodName)["result"][key][0]["icons"] == %*[Icon]

  test "Given a version without icons, when each list is requested, then no icons are sent":
    for version in versionsWithout(ftIcons):
      let server = iconServer()
      let peer = server.connect(server.attach(), version)
      for (methodName, key) in Lists:
        let item = peer.ask(methodName)["result"][key][0]
        check not item.hasKey("icons")
        check item.hasKey("name")

  test "Given a resource link with icons, when a version decides, then the icons go where icons do":
    for version in versionsWith(ftResourceLinks):
      let server = iconServer()
      let peer = server.connect(server.attach(), version)
      let link = peer.ask("tools/call", %*{"name": "t"})["result"]["content"][0]
      check link.hasKey("icons") == version.has(ftIcons)

  test "Given an icon with only a src, when it is written, then only the src is sent":
    check McpIcon(src: "data:image/png;base64,AA==").toJson == %*{"src": "data:image/png;base64,AA=="}

  test "Given an icon with every field, when it is written and parsed, then it comes back the same":
    let icon = McpIcon(src: "https://example.com/i.svg", mimeType: some("image/svg+xml"),
                       sizes: @["any"], theme: some(itLight))
    check parseIcons(%*[icon.toJson]) == @[icon]

  test "Given a tool built with icons, when its definition is made, then the icons are in it":
    let info = createToolInfo("t", "d", createInputSchema(newJObject()),
                              icons = @[McpIcon(src: "https://example.com/i.png")])
    check info["icons"] == %*[{"src": "https://example.com/i.png"}]

suite "icons in the client":

  test "Given listed items with icons, when the client lists them, then each carries its icons":
    let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      case message{"method"}.getStr()
      of "tools/list":
        peer.reply(message["id"], %*{"tools": [{"name": "t", "inputSchema": {"type": "object"}, "icons": [Icon]}]})
      of "resources/list":
        peer.reply(message["id"], %*{"resources": [{"name": "r", "uri": "file:///r", "icons": [Icon]}]})
      of "resources/templates/list":
        peer.reply(message["id"], %*{"resourceTemplates": [{"name": "tpl", "uriTemplate": "file:///{x}", "icons": [Icon]}]})
      of "prompts/list":
        peer.reply(message["id"], %*{"prompts": [{"name": "p", "icons": [Icon]}]})
      of "tools/call":
        peer.reply(message["id"], %*{"content": [{"type": "resource_link", "uri": "file:///r", "name": "r", "icons": [Icon]}]})
      else: discard,
      capabilities = %*{"tools": {}, "resources": {}, "prompts": {}})
    let client = peer.connectedClient(LegacyDefault)
    let expected = @[McpIcon(src: "https://example.com/icon.png", mimeType: some("image/png"),
                             sizes: @["48x48", "96x96"], theme: some(itDark))]
    check waitFor(client.listAllTools())[0].icons == expected
    check waitFor(client.listAllResources())[0].icons == expected
    check waitFor(client.listAllResourceTemplates())[0].icons == expected
    check waitFor(client.listAllPrompts())[0].icons == expected
    check waitFor(client.callTool("t")).contentItems[0].linkIcons == expected

  test "Given an item without icons, when the client lists it, then it has none":
    let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        peer.reply(message["id"], %*{"tools": [{"name": "t", "inputSchema": {"type": "object"}}]}))
    let client = peer.connectedClient(LegacyDefault)
    check waitFor(client.listAllTools())[0].icons.len == 0

  test "Given a malformed icon, when the client lists tools, then the protocol violation is raised":
    for broken in [%*[{"mimeType": "image/png"}], %*[{"src": 5}],
                   %*[{"src": "https://example.com/i.png", "theme": "sepia"}],
                   %*[{"src": "https://example.com/i.png", "sizes": "48x48"}],
                   %*"not an array"]:
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          peer.reply(message["id"], %*{"tools": [{"name": "t", "inputSchema": {"type": "object"}, "icons": broken}]}))
      let client = peer.connectedClient(LegacyDefault)
      expect McpProtocolError:
        discard waitFor client.listAllTools()

suite "icon uris":

  proc icon(src: string): McpIcon = McpIcon(src: src)

  test "Given https and base64 image data uris, when screened, then they are kept":
    check safeIcons(@[icon("https://example.com/a.png"),
                      icon("data:image/png;base64,iVBORw0KGgo=")]).len == 2

  test "Given unsafe schemes, when screened, then every one is dropped":
    for src in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com/i.png",
                "ws://example.com/i", "http://example.com/i.png", "app://local/icon",
                "data:text/html;base64,PHNjcmlwdD4=", "data:image/png,not-base64", "//example.com/i.png", ""]:
      check safeIcons(@[icon(src)]).len == 0

  test "Given a server origin, when screened, then an https icon from another origin is dropped and data stays":
    let origin = "https://example.com"
    check safeIcons(@[icon("https://example.com/a.png")], origin).len == 1
    check safeIcons(@[icon("https://example.com:443/a.png")], origin).len == 1
    check safeIcons(@[icon("https://cdn.example.net/a.png")], origin).len == 0
    check safeIcons(@[icon("https://example.com:8443/a.png")], origin).len == 0
    check safeIcons(@[icon("https://example.com.evil.net/a.png")], origin).len == 0
    check safeIcons(@[icon("data:image/png;base64,AA==")], origin).len == 1

  test "Given scheme and host in other letter cases, when screened, then they are compared case-insensitively":
    check safeIcons(@[icon("HTTPS://EXAMPLE.com/a.png")], "https://example.COM").len == 1
