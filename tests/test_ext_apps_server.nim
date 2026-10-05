## MCP Apps on the server: UI resources, tools that point at them, and what a
## host that did not declare the extension sees. Specification:
## ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f,
## specification/2026-01-26/apps.mdx ("UI Resource Format", "Resource
## Discovery", "Client<>Server Capability Negotiation").

import std/[unittest, asyncdispatch, json, options, base64, strutils]
import ./server_harness
import ext/apps
import server/[server, pagination]
import protocol/types

const
  Html = "<!DOCTYPE html><html><body>weather</body></html>"
  Uri = "ui://weather-server/dashboard-template"

proc hostCaps(settings: JsonNode): JsonNode =
  %*{"io.modelcontextprotocol/clientCapabilities": {"extensions": {ExtensionId: settings}}}

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

proc connectHost(server: McpServer, v: McpProtocolVersion,
                 settings: JsonNode = nil): tuple[peer: Peer, meta: JsonNode] =
  ## A client of version `v` that declares MCP Apps with `settings` (none:
  ## declares nothing): in `_meta` of each request in 2026-07-28, in
  ## `initialize` before it.
  if isModern(v):
    result.peer = server.connect(server.attach(), v)
    result.meta = if settings.isNil: nil else: hostCaps(settings)
  else:
    result.peer = server.connect(server.attach(), v,
      clientCapabilities = if settings.isNil: nil else: %*{"extensions": {ExtensionId: settings}})

let uiSettings = %*{"mimeTypes": [ResourceMimeType]}

suite "registering MCP Apps":

  test "Given a registry, when it is made in any build, then the server declares no extension for it":
    let server = weatherServer(weatherRegistry())
    check server.capabilities.extensions.isNone
    check server.legacyExtensions.len == 0

suite "UI resources":

  test "Given bad registrations, when made, then each raises ValueError":
    let registry = weatherRegistry()
    for uri in ["https://x/y", "ui://", "ui://a b", ""]:
      expect ValueError: registry.addUiResource(uri, "n", Html)
    expect ValueError: registry.addUiResource(Uri, "again", Html)
    expect ValueError: registry.addUiResource("ui://empty", "n", "  \n ")
    expect ValueError: registry.addUiResource("ui://evil", "n", Html,
      meta = UiResourceMeta(csp: some(UiCsp(connectDomains: @["https://a.com; script-src *"]))))
    check not registry.hasUiResource("ui://evil")

  test "Given a registered UI resource, when listed, then the entry has the uri, name, description and the MCP Apps mime type":
    let entry = weatherRegistry().listUiResources()[0]
    check entry == %*{"uri": Uri, "name": "weather_dashboard",
                      "description": "Interactive weather dashboard view",
                      "mimeType": ResourceMimeType}

  test "Given a registered UI resource, when read, then the content item has text, the mime type and _meta.ui on the item":
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
    let registry = newAppsRegistry()
    registry.addUiResource("ui://b", "b", Html, asBlob = true)
    let item = registry.readUiResource("ui://b").get[0]
    check base64.decode(item["blob"].getStr()) == Html
    check not item.hasKey("text")
    check not item.hasKey("_meta")

  test "Given a URI that was not registered, when read, then none":
    check weatherRegistry().readUiResource("ui://other").isNone

  test "Given a server wired with the registry, when a client lists and reads resources, then it gets the UI resource and a not-found error for other URIs":
    for v in SupportedProtocolVersions:
      let server = weatherServer(weatherRegistry())
      let (peer, meta) = server.connectHost(v, uiSettings)
      let listed = peer.ask("resources/list", meta = meta)
      check listed["result"]["resources"][0]["uri"].getStr() == Uri
      let read = peer.ask("resources/read", %*{"uri": Uri}, meta = meta)
      check read["result"]["contents"][0]["text"].getStr() == Html
      check read["result"]["contents"][0]["_meta"]["ui"]["prefersBorder"].getBool()
      check peer.ask("resources/read", %*{"uri": "ui://nope"}, meta = meta).hasKey("error")

  test "Given a fallback read handler, when a non-UI URI is read, then the fallback answers":
    for v in SupportedProtocolVersions:
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
    let tool = weatherRegistry().appToolInfo("get_weather", "d", schema, Uri)
    check tool["_meta"] == %*{"ui": {"resourceUri": Uri, "visibility": ["model", "app"]}}
    check tool["name"].getStr() == "get_weather"

  test "Given an app-only tool, when built, then visibility is app":
    let tool = weatherRegistry().appToolInfo("refresh", "d", schema, Uri, visibility = {tvApp})
    check tool["_meta"]["ui"]["visibility"] == %*["app"]

  test "Given legacyKey, when built, then the deprecated flat key is added too":
    let tool = weatherRegistry().appToolInfo("t", "d", schema, Uri, legacyKey = true)
    check tool["_meta"][LegacyResourceUriKey].getStr() == Uri
    check tool["_meta"]["ui"]["resourceUri"].getStr() == Uri
    check not weatherRegistry().appToolInfo("t", "d", schema, Uri)["_meta"].hasKey(LegacyResourceUriKey)

  test "Given a resource that is not registered, when a tool is built for it, then ValueError because the resource must exist":
    expect ValueError:
      discard weatherRegistry().appToolInfo("t", "d", schema, "ui://missing")

suite "hosts that did and did not declare MCP Apps":

  proc listTools(h: tuple[peer: Peer, meta: JsonNode]): seq[JsonNode] =
    h.peer.ask("tools/list", meta = h.meta)["result"]["tools"].getElems()

  test "Given a host that declared MCP Apps, when it lists tools in any version, then the UI references are there":
    for v in SupportedProtocolVersions:
      let server = weatherServer(weatherRegistry())
      let tools = server.connectHost(v, uiSettings).listTools()
      check tools[0]["_meta"]["ui"]["resourceUri"].getStr() == Uri
      check tools[1]["_meta"]["ui"]["visibility"] == %*["app"]

  test "Given a client that declared nothing, when it lists tools in any version, then they are plain tools without _meta":
    for v in SupportedProtocolVersions:
      let server = weatherServer(weatherRegistry())
      for tool in server.connectHost(v).listTools():
        check not tool.hasKey("_meta")

  test "Given a host that declared the extension without the HTML mime type, when it lists tools, then they are plain":
    for v in SupportedProtocolVersions:
      for settings in [%*{"mimeTypes": ["text/uri-list"]}, %*{}, %*{"mimeTypes": "x"}]:
        let server = weatherServer(weatherRegistry())
        for tool in server.connectHost(v, settings).listTools():
          check not tool.hasKey("_meta")

  test "Given a tool with other _meta keys, when listed to a plain client, then only the UI keys are removed":
    for v in SupportedProtocolVersions:
      let registry = weatherRegistry()
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolsList(pagedList(proc(): Future[seq[JsonNode]] {.async.} =
        var tool = registry.appToolInfo("t", "d", schema, Uri, legacyKey = true)
        tool["_meta"]["com.example/x"] = %1
        return @[tool], 0))
      server.degradeForPlainHosts()
      check server.connectHost(v).listTools()[0]["_meta"] == %*{"com.example/x": 1}
      let other = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      other.onToolsList(pagedList(proc(): Future[seq[JsonNode]] {.async.} =
        return @[registry.appToolInfo("t", "d", schema, Uri, legacyKey = true)], 0))
      other.degradeForPlainHosts()
      check other.connectHost(v, uiSettings).listTools()[0]["_meta"].hasKey(LegacyResourceUriKey)

  test "Given a handler, when it asks whether the host supports apps, then it is true only for the declared HTML mime type":
    for v in SupportedProtocolVersions:
      proc supports(settings: JsonNode): string =
        let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
        server.onToolCall(proc(ctx: McpRequestContext, name: string,
                               arguments: JsonNode): Future[JsonNode] {.async.} =
          return %*{"content": [{"type": "text", "text": $ctx.hostSupportsApps}]})
        let (peer, meta) = server.connectHost(v, settings)
        peer.ask("tools/call", %*{"name": "t"}, meta = meta).textOf
      check supports(uiSettings) == "true"
      check supports(nil) == "false"
      check supports(%*{"mimeTypes": ["text/uri-list"]}) == "false"
