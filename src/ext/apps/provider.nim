## MCP Apps on the server: UI resources, tools that point at them, and what a
## server does not offer to a host that cannot show them.
##
## Based on the stable MCP Apps specification 2026-01-26,
## modelcontextprotocol/ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f.
##
## The specification has the host declare `io.modelcontextprotocol/ui`; the
## server declares nothing and defines no method of its own (everything
## `ui/*` is between host and View). What a server does is serve `ui://`
## resources, mark tools with `_meta.ui`, and check what the host declared.
## An `AppsRegistry` does the first two; hook it into the server's handlers:
##
##   let apps = newAppsRegistry()
##   apps.addUiResource("ui://weather/view.html", "weather_view", html,
##                      meta = UiResourceMeta(csp: some(UiCsp(
##                        connectDomains: @["https://api.weather.example"]))))
##   server.onResourcesList(apps.listHandler())
##   server.onResourceRead(apps.readHandler())
##   server.degradeForPlainHosts()   # tools lose `_meta.ui` for hosts without Apps
##   # tools/list items: apps.appToolInfo("get_weather", "...", schema, "ui://weather/view.html")

import std/[asyncdispatch, base64, json, options, strutils, tables]
import ../../server/[server, extensions, errors, pagination, tools]
import ./model

type
  UiResource* = object
    uri*, name*, description*: string
    text*: Option[string]
    blob*: Option[string]
    meta*: UiResourceMeta

  AppsRegistry* = ref object
    ## The UI resources a server serves and, for the tools built from it,
    ## which ones exist.
    resources: OrderedTable[string, UiResource]

proc newAppsRegistry*(): AppsRegistry =
  ## Declares nothing: the specification has no server-side declaration, and
  ## the host's declaration is read in every protocol version (in 2026-07-28
  ## from the request's `_meta`, before it from `initialize`).
  AppsRegistry()

proc addUiResource*(registry: AppsRegistry, uri, name, html: string,
                    meta: UiResourceMeta = UiResourceMeta(), description = "",
                    asBlob = false) =
  ## Serve `html` at `uri`. Raises ValueError for a URI that is not a
  ## `ui://` URI, a URI already registered, an empty document, or metadata
  ## whose origins are not plain origins. `asBlob` sends it base64-encoded
  ## (`blob`) instead of as `text`. The content is the server's to get right:
  ## only that it is not empty is checked of "a valid HTML5 document".
  let uriProblem = uiUriProblem(uri)
  if uriProblem.isSome:
    raise newException(ValueError, uriProblem.get)
  if uri in registry.resources:
    raise newException(ValueError, "the UI resource " & uri & " is already registered")
  if html.strip().len == 0:
    raise newException(ValueError, "the UI resource " & uri & " has no HTML")
  let problem = metaProblem(meta)
  if problem.isSome:
    raise newException(ValueError, "the UI resource " & uri & ": " & problem.get)
  registry.resources[uri] = UiResource(
    uri: uri, name: name, description: description, meta: meta,
    text: (if asBlob: none(string) else: some(html)),
    blob: (if asBlob: some(base64.encode(html)) else: none(string)))

func hasUiResource*(registry: AppsRegistry, uri: string): bool =
  uri in registry.resources

func listUiResources*(registry: AppsRegistry): seq[JsonNode] =
  ## The `resources/list` entries of the UI resources.
  for resource in registry.resources.values:
    var entry = %*{"uri": resource.uri, "name": resource.name,
                   "mimeType": ResourceMimeType}
    if resource.description.len > 0:
      entry["description"] = %resource.description
    result.add entry

func contents(resource: UiResource): JsonNode =
  result = %*{"uri": resource.uri, "mimeType": ResourceMimeType}
  if resource.text.isSome:
    result["text"] = %resource.text.get
  if resource.blob.isSome:
    result["blob"] = %resource.blob.get
  let meta = resource.meta.toJson
  if meta.len > 0:
    result["_meta"] = %*{"ui": meta}

func readUiResource*(registry: AppsRegistry, uri: string): Option[seq[JsonNode]] =
  ## The `contents` of a `resources/read` of `uri`, or none for a URI that is
  ## not registered. The metadata travels on the content item.
  if uri in registry.resources:
    some(@[registry.resources[uri].contents])
  else:
    none(seq[JsonNode])

proc listHandler*(registry: AppsRegistry, others: seq[JsonNode] = @[]): ListHandler =
  ## A `resources/list` handler that lists `others` and then the UI
  ## resources, on one page.
  pagedList(proc(): Future[seq[JsonNode]] {.async.} =
    return others & registry.listUiResources(), 0)

proc readHandler*(registry: AppsRegistry,
                  fallback: ResourceReadHandler = nil): ResourceReadHandler =
  ## A `resources/read` handler that answers for the registered UI resources
  ## and passes every other URI to `fallback` (none: not found).
  let known = registry
  result = proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    let served = known.readUiResource(uri)
    if served.isSome:
      return served.get
    if fallback.isNil:
      raise newResourceNotFound(uri)
    return await fallback(ctx, uri)

# --- tools ---------------------------------------------------------------------

proc appToolInfo*(registry: AppsRegistry, name, description: string,
                  inputSchema: JsonNode, resourceUri: string,
                  visibility: set[ToolVisibility] = DefaultVisibility,
                  legacyKey = false, title = ""): JsonNode =
  ## A tool definition for `tools/list` that renders its result with the UI
  ## resource `resourceUri`. Raises ValueError when no such resource is
  ## registered (the resource MUST exist on the server). `legacyKey` adds the
  ## deprecated `_meta["ui/resourceUri"]` for hosts that only read that.
  if not registry.hasUiResource(resourceUri):
    raise newException(ValueError, "the tool " & name & " points at " & resourceUri &
      ", which is not a registered UI resource")
  result = createToolInfo(name, description, inputSchema, title = title)
  let ui = UiToolMeta(resourceUri: some(resourceUri), visibility: visibility)
  var meta = %*{"ui": ui.toJson}
  if legacyKey:
    meta[LegacyResourceUriKey] = %resourceUri
  result["_meta"] = meta

# --- the host's capability ----------------------------------------------------------

proc hostUiCapability*(ctx: McpRequestContext): Option[UiClientCapability] =
  ## What the client of this request declared for MCP Apps; none when it
  ## declared nothing usable.
  let settings = ctx.clientExtension(ExtensionId)
  if settings.isNone:
    return none(UiClientCapability)
  parseUiClientCapability(settings.get)

proc hostSupportsApps*(ctx: McpRequestContext): bool =
  ## True when the client declared MCP Apps with the HTML mime type.
  let capability = ctx.hostUiCapability
  capability.isSome and capability.get.supportsHtmlApps

func withoutUi(tool: JsonNode): JsonNode =
  result = tool.copy()
  let meta = result{"_meta"}
  if meta.isNil or meta.kind != JObject:
    return
  for key in ["ui", LegacyResourceUriKey]:
    if meta.hasKey(key):
      meta.delete(key)
  if meta.len == 0:
    result.delete("_meta")

proc degradeForPlainHosts*(server: McpServer) =
  ## From now on a tool is listed with its UI reference (`_meta.ui`, and the
  ## deprecated flat key) only to a client that declared MCP Apps; any other
  ## client sees a plain tool (the specification's graceful degradation).
  server.addToolListTransform(proc(ctx: McpRequestContext, tool: JsonNode): JsonNode =
    if ctx.hostSupportsApps: tool else: withoutUi(tool))
