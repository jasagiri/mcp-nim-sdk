## MCP Apps on the client, which is the host: declare support, read which
## tools carry a UI, fetch a UI resource and check it before anything
## renders it.
##
## Based on the stable MCP Apps specification 2026-01-26,
## modelcontextprotocol/ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f.
## Works in every protocol version this build speaks: specification section
## "Client (Host) Capabilities" has the host declare the extension in the
## `initialize` request, with an example for 2024-11-05, and the core schemas
## of the versions before 2026-07-28 do not forbid the extra capability.
##
##   client.declareApps()                       # before connect()
##   await client.connect(transport)
##   let tools = await client.listAppTools()    # keeps `_meta`, which listTools drops
##   for tool in tools.modelVisible:            # what the agent may be shown
##     ...
##   let ui = await client.fetchToolUi(tools[0])
##   # ui.html, ui.meta; contentSecurityPolicy(ui.meta.csp) is what to enforce
##
## The typed `listTools` and `readResource` of this SDK do not keep `_meta`,
## which is where MCP Apps lives, so these procs read the raw answers.
##
## The specification has no server-side declaration of the extension: whether
## a server offers UIs shows in its tools (`_meta.ui.resourceUri`), and the
## server only adds those to a host that declared the extension.

import std/[asyncdispatch, base64, json, options, strutils]
import ../../client/[client, content, extensions]
import ./model

const
  DefaultMaxHtmlBytes* = 5 * 1024 * 1024
    ## The largest UI document `fetchUiResource` accepts unless told otherwise.

type
  UiLimits* = object
    maxHtmlBytes*: int
      ## The most bytes of HTML (after base64 decoding) to accept.

  AppTool* = object
    ## A tool as `tools/list` gave it, with its UI reference read.
    name*: string
    definition*: JsonNode
      ## The whole tool object, `_meta` included.
    ui*: Option[UiToolMeta]
      ## none: the tool has no UI reference (or a malformed one, see `problem`).
    problem*: Option[string]
      ## Why the UI reference could not be used; the tool is then treated as a
      ## plain tool and the host can show this to its user or log it.

  FetchedUi* = object
    ## A UI resource that passed the checks.
    uri*: string
    html*: string
    meta*: UiResourceMeta
    metaFromListing*: bool
      ## True when the content item had no `_meta.ui` and the one of the
      ## `resources/list` entry was used.

func defaultLimits*(): UiLimits {.raises: [].} =
  UiLimits(maxHtmlBytes: DefaultMaxHtmlBytes)

proc declareApps*(client: McpClient, mimeTypes: seq[string] = @[ResourceMimeType]) =
  ## Declare MCP Apps support (`extensions["io.modelcontextprotocol/ui"] =
  ## {"mimeTypes": [...]}`): in the capabilities of every 2026-07-28 request
  ## and, since the specification has the host declare it in `initialize`
  ## (its example is protocol version 2024-11-05), in the `initialize` request
  ## of the earlier versions too. Apps is off unless this is called. Call
  ## before connect(). Raises ValueError for an empty or malformed `mimeTypes`,
  ## or after connect().
  if mimeTypes.len == 0:
    raise newException(ValueError, "declareApps: mimeTypes is required and may not be empty")
  for mimeType in mimeTypes:
    if mimeType.len == 0 or mimeType.strip() != mimeType:
      raise newException(ValueError, "declareApps: '" & mimeType & "' is not a MIME type")
  client.declareExtension(ExtensionId, %*{"mimeTypes": mimeTypes}, onLegacyHandshake = true)

proc declaredApps*(client: McpClient): bool =
  ## Whether `declareApps` was called.
  client.capabilities.extensions.isSome and
    client.capabilities.extensions.get.hasKey(ExtensionId)

# --- tools ---------------------------------------------------------------------

func toAppTool*(definition: JsonNode): AppTool =
  ## Read the UI reference of a tool object from `tools/list`. A malformed
  ## reference does not fail the listing: the tool is kept, without a UI,
  ## and the reason is in `problem`.
  result = AppTool(name: definition{"name"}.getStr(), definition: definition)
  try:
    result.ui = parseUiToolMeta(definition{"_meta"})
  except McpAppsError as e:
    result.problem = some(e.msg)

proc listAppTools*(client: McpClient,
                   options: McpRequestOptions = McpRequestOptions()): Future[seq[AppTool]] =
  ## Every tool the server lists, following the pages, with its UI reference.
  allPages("tools/list", proc(cursor: Option[string]): Future[tuple[items: seq[AppTool], next: Option[string]]] {.async.} =
    if client.serverCapabilities.isNone:
      raise newException(McpConnectionClosedError, "tools/list: the client is not connected")
    client.requireServerCapability(client.serverCapabilities.get.tools.isSome,
                                   "tools/list", "tools")
    let reply = await client.callMethod("tools/list", pageParams(cursor), options)
    var items: seq[AppTool]
    for definition in requiredArray(reply, "tools", "tools/list"):
      discard requiredString(definition, "name", "tools/list")
      items.add toAppTool(definition)
    return (items: items, next: parseNextCursor(reply, "tools/list")))

func visibleToModel*(tool: AppTool): bool {.raises: [].} =
  ## False for a tool whose `visibility` leaves out `"model"`: the host MUST
  ## NOT put it in the agent's tool list.
  tool.ui.isNone or tvModel in tool.ui.get.visibility

func callableByApp*(tool: AppTool): bool {.raises: [].} =
  ## False for a tool whose `visibility` leaves out `"app"`: a View's
  ## `tools/call` for it MUST be rejected.
  tool.ui.isNone or tvApp in tool.ui.get.visibility

func modelVisible*(tools: seq[AppTool]): seq[AppTool] {.raises: [].} =
  for tool in tools:
    if tool.visibleToModel:
      result.add tool

func appCallProblem*(tools: seq[AppTool], name: string): Option[string] {.raises: [].} =
  ## Why a View may not call tool `name` of this server, or none. A tool the
  ## server did not list cannot be shown to be callable by an app, so it is
  ## refused too. (Cross-server calls are the host's to block.)
  for tool in tools:
    if tool.name == name:
      if tool.callableByApp:
        return none(string)
      return some("the tool " & name & " is not callable by apps (visibility " &
                  "does not include \"app\")")
  some("the server lists no tool " & name)

# --- UI resources --------------------------------------------------------------

func decodedLimit(encodedLen: int): int {.raises: [].} =
  ## An upper bound of the bytes `encodedLen` base64 characters decode to.
  (encodedLen + 3) div 4 * 3

proc uiResourceFromContents*(uri: string, contents: JsonNode,
                             limits: UiLimits = defaultLimits(),
                             listingMeta: JsonNode = nil): FetchedUi {.raises: [McpAppsError].} =
  ## Check the `contents` of a `resources/read` answer for the UI resource
  ## `uri` and return it. Raises McpAppsError unless: `uri` is a `ui://` URI;
  ## `contents` has an item for `uri`; its mimeType is exactly
  ## `text/html;profile=mcp-app`; it has `text` or `blob` (not both, not
  ## neither), a `blob` being valid base64; the HTML is not empty and not
  ## larger than `limits.maxHtmlBytes`; its `_meta.ui` is well formed with
  ## plain origins. `listingMeta` is the `_meta.ui` of the `resources/list`
  ## entry, used only when the item has none (draft rule: the content item
  ## takes precedence).
  let uriProblem = uiUriProblem(uri)
  if uriProblem.isSome:
    raise newException(McpAppsError, uriProblem.get)
  if contents.isNil or contents.kind != JArray:
    raise newException(McpAppsError, "contents is not an array")
  var item: JsonNode
  for candidate in contents:
    if candidate.kind == JObject and candidate{"uri"}.getStr() == uri:
      item = candidate
      break
  if item.isNil:
    raise newException(McpAppsError, "the answer has no content item for " & uri)
  let mimeType = item{"mimeType"}.getStr()
  if mimeType != ResourceMimeType:
    raise newException(McpAppsError, uri & ": mimeType is '" & mimeType &
      "'; a UI resource is " & ResourceMimeType)
  let text = item{"text"}
  let blob = item{"blob"}
  if not text.isNil and not blob.isNil:
    raise newException(McpAppsError, uri & ": has both text and blob")
  if text.isNil and blob.isNil:
    raise newException(McpAppsError, uri & ": has neither text nor blob")
  if limits.maxHtmlBytes <= 0:
    raise newException(McpAppsError, "the size limit for UI resources must be positive")
  if not text.isNil:
    if text.kind != JString:
      raise newException(McpAppsError, uri & ": text is not a string")
    result.html = text.getStr()
    if result.html.len > limits.maxHtmlBytes:
      raise newException(McpAppsError, uri & ": " & $result.html.len &
        " bytes of HTML exceed the limit of " & $limits.maxHtmlBytes)
  else:
    if blob.kind != JString:
      raise newException(McpAppsError, uri & ": blob is not a string")
    if decodedLimit(blob.getStr().len) > limits.maxHtmlBytes + 2:
      raise newException(McpAppsError, uri & ": the blob exceeds the limit of " &
        $limits.maxHtmlBytes & " bytes")
    try:
      result.html = base64.decode(blob.getStr())
    except ValueError as e:
      raise newException(McpAppsError, uri & ": blob is not valid base64: " & e.msg)
    if result.html.len > limits.maxHtmlBytes:
      raise newException(McpAppsError, uri & ": " & $result.html.len &
        " bytes of HTML exceed the limit of " & $limits.maxHtmlBytes)
  if result.html.strip().len == 0:
    raise newException(McpAppsError, uri & ": the HTML is empty")
  result.uri = uri
  let meta = item{"_meta"}
  if not meta.isNil and meta.kind != JObject:
    raise newException(McpAppsError, uri & ": _meta is not an object")
  let contentUi = if meta.isNil: nil else: meta{"ui"}
  if not contentUi.isNil:
    result.meta = parseUiResourceMeta(contentUi)
  elif not listingMeta.isNil:
    result.meta = parseUiResourceMeta(listingMeta)
    result.metaFromListing = true

proc fetchUiResource*(client: McpClient, uri: string,
                      limits: UiLimits = defaultLimits(),
                      listingMeta: JsonNode = nil,
                      options: McpRequestOptions = McpRequestOptions()): Future[FetchedUi] {.async.} =
  ## Read the UI resource `uri` with `resources/read` and check it (see
  ## `uiResourceFromContents`). Raises ValueError, sending nothing, for a URI
  ## that is not a `ui://` URI; McpUnsupportedError, sending nothing, unless
  ## `declareApps` was called; McpProtocolError for a server answer that
  ## breaks the specification or the limits.
  let uriProblem = uiUriProblem(uri)
  if uriProblem.isSome:
    raise newException(ValueError, uriProblem.get)
  if not client.declaredApps:
    raise newException(McpUnsupportedError,
      "fetchUiResource: this client did not declare MCP Apps (declareApps)")
  if client.serverCapabilities.isNone:
    raise newException(McpConnectionClosedError, "resources/read: the client is not connected")
  client.requireServerCapability(client.serverCapabilities.get.resources.isSome,
                                 "resources/read", "resources")
  let reply = await client.callMethod("resources/read", %*{"uri": uri}, options)
  try:
    return uiResourceFromContents(uri, reply{"contents"}, limits, listingMeta)
  except McpAppsError as e:
    raise newException(McpProtocolError, "resources/read: " & e.msg)

proc fetchToolUi*(client: McpClient, tool: AppTool,
                  limits: UiLimits = defaultLimits(),
                  options: McpRequestOptions = McpRequestOptions()): Future[FetchedUi] =
  ## `fetchUiResource` for the UI resource a tool points at. Raises
  ## ValueError when the tool has no UI reference.
  if tool.ui.isNone or tool.ui.get.resourceUri.isNone:
    raise newException(ValueError, "the tool " & tool.name & " has no UI resource")
  fetchUiResource(client, tool.ui.get.resourceUri.get, limits, options = options)
