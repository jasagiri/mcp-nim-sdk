## MCP Apps on the server: UI resources, tools that point at them, and what a
## host that did not declare the extension sees. Specification:
## ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f,
## specification/2026-01-26/apps.mdx ("UI Resource Format", "Resource
## Discovery", "Client<>Server Capability Negotiation").

import std/[unittest, asyncdispatch, json, options, base64, strutils]
import ./server_harness
import ext/apps
import server/[server, pagination]
import protocol/[features, types]

const
  Html = "<!DOCTYPE html><html><body>weather</body></html>"
  Uri = "ui://weather-server/dashboard-template"

proc hostCaps(settings: JsonNode): JsonNode =
  %*{"io.modelcontextprotocol/clientCapabilities": {"extensions": {ExtensionId: settings}}}

let uiHost = hostCaps(%*{"mimeTypes": [ResourceMimeType]})

let schema = %*{"type": "object", "properties": {"location": {"type": "string"}}}

proc weatherServer(registry: AppsRegistry): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability()),
                                           resources: some(McpResourcesCapability())))
  result.onResourcesList(registry.listHandler())
  result.onResourceRead(registry.readHandler())
  result.onToolsList(pagedList(proc(): Future[seq[JsonNode]] {.async.} =
    return @[registry.appToolInfo("get_weather", "Get the weather", schema, Uri),
             registry.appToolInfo("refresh", "Refresh", schema, Uri, visibility = {tvApp}),
             %*{"name": "plain", "description": "no UI", "inputSchema": schema}], 0))
  result.degradeForPlainHosts()

proc weatherRegistry(): AppsRegistry =
  result = newAppsRegistry()
  result.addUiResource(Uri, "weather_dashboard", Html,
    meta = UiResourceMeta(csp: some(UiCsp(connectDomains: @["https://api.openweathermap.org"],
                                          resourceDomains: @["https://cdn.jsdelivr.net"])),
                          prefersBorder: some(true)),
    description = "Interactive weather dashboard view")

proc modernBuild(): bool =
  versionsWith(ftExtensions).len > 0

suite "registering MCP Apps":

  test "Given a build that speaks no version with extensions, when a registry is made, then ValueError; otherwise it is made":
    if modernBuild():
      discard newAppsRegistry()
    else:
      expect ValueError:
        discard newAppsRegistry()

  test "Given a registry, when it is made, then the server declares no extension for it":
    if modernBuild():
      let server = weatherServer(weatherRegistry())
      check server.capabilities.extensions.isNone

suite "UI resources":

  test "Given bad registrations, when made, then each raises ValueError":
    if modernBuild():
      let registry = weatherRegistry()
      for uri in ["https://x/y", "ui://", "ui://a b", ""]:
        expect ValueError: registry.addUiResource(uri, "n", Html)
      expect ValueError: registry.addUiResource(Uri, "again", Html)
      expect ValueError: registry.addUiResource("ui://empty", "n", "  \n ")
      expect ValueError: registry.addUiResource("ui://evil", "n", Html,
        meta = UiResourceMeta(csp: some(UiCsp(connectDomains: @["https://a.com; script-src *"]))))
      check not registry.hasUiResource("ui://evil")

  test "Given a registered UI resource, when listed, then the entry has the uri, name, description and the MCP Apps mime type":
    if modernBuild():
      let entry = weatherRegistry().listUiResources()[0]
      check entry == %*{"uri": Uri, "name": "weather_dashboard",
                        "description": "Interactive weather dashboard view",
                        "mimeType": ResourceMimeType}

  test "Given a registered UI resource, when read, then the content item has text, the mime type and _meta.ui on the item":
    if modernBuild():
      let contents = weatherRegistry().readUiResource(Uri).get
      check contents.len == 1
      check contents[0]["uri"].getStr() == Uri
      check contents[0]["mimeType"].getStr() == ResourceMimeType
      check contents[0]["text"].getStr() == Html
      check not contents[0].hasKey("blob")
      check contents[0]["_meta"]["ui"] == %*{
        "csp": {"connectDomains": ["https://api.openweathermap.org"],
                "resourceDomains": ["https://cdn.jsdelivr.net"]},
        "prefersBorder": true}

  test "Given a resource registered as a blob, when read, then blob is the base64 of the HTML and there is no text":
    if modernBuild():
      let registry = newAppsRegistry()
      registry.addUiResource("ui://b", "b", Html, asBlob = true)
      let item = registry.readUiResource("ui://b").get[0]
      check base64.decode(item["blob"].getStr()) == Html
      check not item.hasKey("text")
      check not item.hasKey("_meta")

  test "Given a URI that was not registered, when read, then none":
    if modernBuild():
      check weatherRegistry().readUiResource("ui://other").isNone

  test "Given a server wired with the registry, when a client lists and reads resources, then it gets the UI resource and a not-found error for other URIs":
    for v in versionsWith(ftExtensions):
      let server = weatherServer(weatherRegistry())
      let peer = server.connect(server.attach(), v)
      let listed = peer.ask("resources/list", meta = uiHost)
      check listed["result"]["resources"][0]["uri"].getStr() == Uri
      let read = peer.ask("resources/read", %*{"uri": Uri}, meta = uiHost)
      check read["result"]["contents"][0]["text"].getStr() == Html
      check read["result"]["contents"][0]["_meta"]["ui"]["prefersBorder"].getBool()
      check peer.ask("resources/read", %*{"uri": "ui://nope"}, meta = uiHost).hasKey("error")

  test "Given a fallback read handler, when a non-UI URI is read, then the fallback answers":
    for v in versionsWith(ftExtensions):
      let registry = weatherRegistry()
      let server = newServer(McpServerCapabilities(resources: some(McpResourcesCapability())))
      server.onResourceRead(registry.readHandler(
        proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
          return @[%*{"uri": uri, "mimeType": "text/plain", "text": "plain"}]))
      let peer = server.connect(server.attach(), v)
      check peer.ask("resources/read", %*{"uri": "file:///a"})["result"]["contents"][0]["text"].getStr() == "plain"
      check peer.ask("resources/read", %*{"uri": Uri})["result"]["contents"][0]["text"].getStr() == Html

suite "tools that render with a UI":

  test "Given a registered resource, when a tool is built for it, then _meta.ui has the resourceUri and visibility":
    if modernBuild():
      let tool = weatherRegistry().appToolInfo("get_weather", "d", schema, Uri)
      check tool["_meta"] == %*{"ui": {"resourceUri": Uri, "visibility": ["model", "app"]}}
      check tool["name"].getStr() == "get_weather"

  test "Given an app-only tool, when built, then visibility is app":
    if modernBuild():
      let tool = weatherRegistry().appToolInfo("refresh", "d", schema, Uri, visibility = {tvApp})
      check tool["_meta"]["ui"]["visibility"] == %*["app"]

  test "Given legacyKey, when built, then the deprecated flat key is added too":
    if modernBuild():
      let tool = weatherRegistry().appToolInfo("t", "d", schema, Uri, legacyKey = true)
      check tool["_meta"][LegacyResourceUriKey].getStr() == Uri
      check tool["_meta"]["ui"]["resourceUri"].getStr() == Uri
      check not weatherRegistry().appToolInfo("t", "d", schema, Uri)["_meta"].hasKey(LegacyResourceUriKey)

  test "Given a resource that is not registered, when a tool is built for it, then ValueError because the resource must exist":
    if modernBuild():
      expect ValueError:
        discard weatherRegistry().appToolInfo("t", "d", schema, "ui://missing")

suite "hosts that did and did not declare MCP Apps":

  proc listTools(peer: Peer, meta: JsonNode = nil): seq[JsonNode] =
    peer.ask("tools/list", meta = meta)["result"]["tools"].getElems()

  test "Given a host that declared MCP Apps, when it lists tools, then the UI references are there":
    for v in versionsWith(ftExtensions):
      let server = weatherServer(weatherRegistry())
      let tools = server.connect(server.attach(), v).listTools(uiHost)
      check tools[0]["_meta"]["ui"]["resourceUri"].getStr() == Uri
      check tools[1]["_meta"]["ui"]["visibility"] == %*["app"]

  test "Given a client that declared nothing, when it lists tools, then they are plain tools without _meta":
    for v in versionsWith(ftExtensions):
      let server = weatherServer(weatherRegistry())
      for tool in server.connect(server.attach(), v).listTools():
        check not tool.hasKey("_meta")
        check not tool.hasKey("ui")

  test "Given a host that declared the extension without the HTML mime type, when it lists tools, then they are plain":
    for v in versionsWith(ftExtensions):
      let server = weatherServer(weatherRegistry())
      let peer = server.connect(server.attach(), v)
      for settings in [%*{"mimeTypes": ["text/uri-list"]}, %*{}, %*{"mimeTypes": "x"}]:
        for tool in peer.listTools(hostCaps(settings)):
          check not tool.hasKey("_meta")

  test "Given a tool with other _meta keys, when listed to a plain client, then only the UI keys are removed":
    for v in versionsWith(ftExtensions):
      let registry = weatherRegistry()
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolsList(pagedList(proc(): Future[seq[JsonNode]] {.async.} =
        var tool = registry.appToolInfo("t", "d", schema, Uri, legacyKey = true)
        tool["_meta"]["com.example/x"] = %1
        return @[tool], 0))
      server.degradeForPlainHosts()
      let peer = server.connect(server.attach(), v)
      check peer.listTools()[0]["_meta"] == %*{"com.example/x": 1}
      check peer.listTools(uiHost)[0]["_meta"].hasKey(LegacyResourceUriKey)

  test "Given a handler, when it asks whether the host supports apps, then it is true only for the declared HTML mime type":
    for v in versionsWith(ftExtensions):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        return %*{"content": [{"type": "text", "text": $ctx.hostSupportsApps}]})
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/call", %*{"name": "t"}, meta = uiHost).textOf == "true"
      check peer.ask("tools/call", %*{"name": "t"}).textOf == "false"
      check peer.ask("tools/call", %*{"name": "t"},
        meta = hostCaps(%*{"mimeTypes": ["text/uri-list"]})).textOf == "false"
