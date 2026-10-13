## MCP Apps between the SDK's own host (client) and server over an
## in-process transport in 2026-07-28: the two halves must agree on the wire,
## not only each with a hand-written peer.

import std/[asyncdispatch, json, options, strutils, unittest]
import server/server except McpRequestError
import server/pagination
import client/client
import client/extensions
import protocol/[types, version]

import ext/apps
import ./loopback_transport

const
  Html = "<!DOCTYPE html><html><body>weather</body></html>"
  Uri = "ui://weather-server/dashboard-template"

proc weatherServer(): McpServer =
  let registry = newAppsRegistry()
  registry.addUiResource(Uri, "weather_dashboard", Html, meta = UiResourceMeta(
    csp: some(UiCsp(connectDomains: @["https://api.openweathermap.org"])),
    permissions: {upGeolocation}, prefersBorder: some(true)))
  let server = newMcpServer(McpServerInfo(name: "weather", version: "1"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability()),
                                         resources: some(McpResourcesCapability())))
  server.onResourcesList(registry.listHandler())
  server.onResourceRead(registry.readHandler())
  let schema = %*{"type": "object"}
  server.onToolsList(pagedList(proc(): Future[seq[JsonNode]] {.async.} =
    return @[registry.appToolInfo("get_weather", "Get the weather", schema, Uri),
             registry.appToolInfo("refresh", "Refresh", schema, Uri, visibility = {tvApp}),
             %*{"name": "plain", "description": "no UI", "inputSchema": schema}], 0))
  server.degradeForPlainHosts()
  server

proc connected(server: McpServer, declare: bool, version: McpProtocolVersion): McpClient =
  let pair = newLoopbackPair()
  waitFor server.attachTransport(pair.server)
  let client = newMcpClient(McpClientInfo(name: "host", version: "1"), version)
  if declare:
    client.declareApps()
  waitFor client.connect(pair.client)
  client

suite "MCP Apps end to end, in every version the build speaks":

  test "Given a host that declared MCP Apps, when it lists tools and fetches the UI, then it gets the references, the HTML and the declarations":
    for v in SupportedProtocolVersions:
      let client = connected(weatherServer(), declare = true, v)
      check client.negotiatedVersion == some(v)
      let tools = waitFor client.listAppTools()
      check tools.len == 3
      check tools[0].ui.get.resourceUri == some(Uri)
      check tools[1].ui.get.visibility == {tvApp}
      check tools[2].ui.isNone
      var visible: seq[string]
      for tool in tools.modelVisible:
        visible.add tool.name
      check visible == @["get_weather", "plain"]
      let ui = waitFor client.fetchToolUi(tools[0])
      check ui.html == Html
      check ui.meta.csp.get.connectDomains == @["https://api.openweathermap.org"]
      check ui.meta.permissions == {upGeolocation}
      check permissionPolicy(ui.meta.permissions) == "geolocation"
      check "connect-src 'self' https://api.openweathermap.org" in contentSecurityPolicy(ui.meta.csp)
      waitFor client.close()

  test "Given a host that did not declare MCP Apps, when it lists tools in any version, then the server shows plain tools":
    for v in SupportedProtocolVersions:
      let client = connected(weatherServer(), declare = false, v)
      let tools = waitFor client.listAppTools()
      check tools.len == 3
      for tool in tools:
        check tool.ui.isNone
        check not tool.definition.hasKey("_meta")
      waitFor client.close()

  test "Given a server that registered MCP Apps, when a client connects in any version, then the server declares no extension":
    for v in SupportedProtocolVersions:
      let client = connected(weatherServer(), declare = true, v)
      check client.serverExtension(ExtensionId).isNone
      waitFor client.close()
