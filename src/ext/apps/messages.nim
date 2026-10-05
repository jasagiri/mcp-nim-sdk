## MCP Apps: the messages between the host and a View (the UI in its
## iframe), as pure functions over JSON.
##
## Based on the stable MCP Apps specification 2026-01-26,
## modelcontextprotocol/ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f.
##
## The SDK does not deliver these messages: postMessage, the iframe and the
## sandbox proxy are the host application's. Everything here takes a
## `JsonNode` (what arrived) or returns one (what to send) and keeps the
## rules the specification puts on the host: what a View may ask for, in what
## order the host may speak, and what is never forwarded.
##
## Everything a View sends is untrusted input: the `parse*` procs raise
## McpAppsError for a message that breaks the specification, and the host
## answers it with `uiErrorResponse`.

import std/[json, math, options, strutils, uri]
import ./model

const
  MethodInitialize* = "ui/initialize"
  MethodInitialized* = "ui/notifications/initialized"
  MethodOpenLink* = "ui/open-link"
  MethodMessage* = "ui/message"
  MethodRequestDisplayMode* = "ui/request-display-mode"
  MethodUpdateModelContext* = "ui/update-model-context"
  MethodSizeChanged* = "ui/notifications/size-changed"
  MethodToolInput* = "ui/notifications/tool-input"
  MethodToolInputPartial* = "ui/notifications/tool-input-partial"
  MethodToolResult* = "ui/notifications/tool-result"
  MethodToolCancelled* = "ui/notifications/tool-cancelled"
  MethodResourceTeardown* = "ui/resource-teardown"
  MethodHostContextChanged* = "ui/notifications/host-context-changed"
  MethodSandboxProxyReady* = "ui/notifications/sandbox-proxy-ready"
  MethodSandboxResourceReady* = "ui/notifications/sandbox-resource-ready"

  ImplementationDefinedError* = -32000
    ## The code the specification gives to a denied or failed View request.
  InvalidParamsError* = -32602

  StyleVariableKeys* = [
    "--color-background-primary", "--color-background-secondary",
    "--color-background-tertiary", "--color-background-inverse",
    "--color-background-ghost", "--color-background-info",
    "--color-background-danger", "--color-background-success",
    "--color-background-warning", "--color-background-disabled",
    "--color-text-primary", "--color-text-secondary", "--color-text-tertiary",
    "--color-text-inverse", "--color-text-info", "--color-text-danger",
    "--color-text-success", "--color-text-warning", "--color-text-disabled",
    "--color-text-ghost",
    "--color-border-primary", "--color-border-secondary", "--color-border-tertiary",
    "--color-border-inverse", "--color-border-ghost", "--color-border-info",
    "--color-border-danger", "--color-border-success", "--color-border-warning",
    "--color-border-disabled",
    "--color-ring-primary", "--color-ring-secondary", "--color-ring-inverse",
    "--color-ring-info", "--color-ring-danger", "--color-ring-success",
    "--color-ring-warning",
    "--font-sans", "--font-mono",
    "--font-weight-normal", "--font-weight-medium", "--font-weight-semibold",
    "--font-weight-bold",
    "--font-text-xs-size", "--font-text-sm-size", "--font-text-md-size",
    "--font-text-lg-size",
    "--font-heading-xs-size", "--font-heading-sm-size", "--font-heading-md-size",
    "--font-heading-lg-size", "--font-heading-xl-size", "--font-heading-2xl-size",
    "--font-heading-3xl-size",
    "--font-text-xs-line-height", "--font-text-sm-line-height",
    "--font-text-md-line-height", "--font-text-lg-line-height",
    "--font-heading-xs-line-height", "--font-heading-sm-line-height",
    "--font-heading-md-line-height", "--font-heading-lg-line-height",
    "--font-heading-xl-line-height", "--font-heading-2xl-line-height",
    "--font-heading-3xl-line-height",
    "--border-radius-xs", "--border-radius-sm", "--border-radius-md",
    "--border-radius-lg", "--border-radius-xl", "--border-radius-full",
    "--border-width-regular",
    "--shadow-hairline", "--shadow-sm", "--shadow-md", "--shadow-lg"]
    ## The standardized theming variables (McpUiStyleVariableKey).

type
  ViewInit* = object
    ## What a View said about itself in `ui/initialize`.
    appName*, appVersion*, protocolVersion*: string
    availableDisplayModes*: seq[UiDisplayMode]
      ## What the View declared it supports; empty: it declared none.
    toolsListChanged*: bool

  ModelContextUpdate* = object
    content*: seq[JsonNode]
    structuredContent*: Option[JsonNode]

  ViewPhase* = enum
    vpAwaitInitialize    ## nothing from the View yet
    vpAwaitInitialized   ## `ui/initialize` answered, `initialized` not yet received
    vpReady              ## the host may speak

  ViewSession* = ref object
    ## The host's side of one View's lifecycle. It holds the order the
    ## specification imposes on the host (see `outgoing`).
    phase*: ViewPhase
    init*: Option[ViewInit]
    toolInputSent: bool

func appsError(message: string): ref McpAppsError =
  newException(McpAppsError, message)

# --- JSON-RPC envelopes ----------------------------------------------------

func uiRequest*(id: JsonNode, methodName: string,
              params: JsonNode = nil): JsonNode {.raises: [].} =
  result = %*{"jsonrpc": "2.0", "id": id, "method": methodName}
  if not params.isNil:
    result["params"] = params

func uiNotification*(methodName: string, params: JsonNode = nil): JsonNode {.raises: [].} =
  result = %*{"jsonrpc": "2.0", "method": methodName}
  if not params.isNil:
    result["params"] = params

func uiResponse*(id: JsonNode, resultNode: JsonNode = nil): JsonNode {.raises: [].} =
  ## A success response; the result is `{}` when none is given (the
  ## specification's "empty result on success").
  %*{"jsonrpc": "2.0", "id": id,
     "result": if resultNode.isNil: newJObject() else: resultNode}

func uiErrorResponse*(id: JsonNode, message: string,
                    code = ImplementationDefinedError): JsonNode {.raises: [].} =
  ## What the host answers a View request it denies or cannot serve.
  %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}

# --- routing rules ---------------------------------------------------------

func isSandboxReserved*(methodName: string): bool {.raises: [].} =
  ## `ui/notifications/sandbox-*` belongs to the sandbox proxy and the host.
  methodName.startsWith("ui/notifications/sandbox-")

func mayCrossSandbox*(methodName: string): bool {.raises: [].} =
  ## The sandbox forwards, in both directions, every method that is not
  ## sandbox-reserved (sandbox proxy rule 6).
  not isSandboxReserved(methodName)

func mayForwardToServer*(methodName: string): bool {.raises: [].} =
  ## The host may pass a View's message on to the MCP server only when its
  ## method does not start with `ui/` (sandbox proxy rule 8). It may still
  ## refuse, or ask the user first.
  not methodName.startsWith("ui/")

# --- host context ----------------------------------------------------------

proc isNumber(node: JsonNode): bool {.raises: [].} =
  not node.isNil and node.kind in {JInt, JFloat} and
    (node.kind == JInt or node.getFloat().classify in {fcNormal, fcZero, fcSubnormal})

proc isDisplayMode(node: JsonNode): bool {.raises: [].} =
  if node.isNil or node.kind != JString:
    return false
  for mode in UiDisplayMode:
    if $mode == node.getStr():
      return true
  false

func hostContextProblem*(context: JsonNode): Option[string] {.raises: [].} =
  ## Why `context` is not a valid (possibly partial) HostContext, or none.
  ## Keys the specification does not define pass: HostContext is open.
  if context.isNil or context.kind != JObject:
    return some("hostContext must be an object")
  let theme = context{"theme"}
  if not theme.isNil and not (theme.kind == JString and theme.getStr() in ["light", "dark"]):
    return some("hostContext.theme must be \"light\" or \"dark\"")
  let mode = context{"displayMode"}
  if not mode.isNil and not isDisplayMode(mode):
    return some("hostContext.displayMode must be inline, fullscreen or pip")
  let modes = context{"availableDisplayModes"}
  if not modes.isNil:
    if modes.kind != JArray:
      return some("hostContext.availableDisplayModes must be an array")
    for item in modes:
      if not isDisplayMode(item):
        return some("hostContext.availableDisplayModes holds " & $item)
  let platform = context{"platform"}
  if not platform.isNil and
     not (platform.kind == JString and platform.getStr() in ["web", "desktop", "mobile"]):
    return some("hostContext.platform must be web, desktop or mobile")
  for key in ["locale", "timeZone", "userAgent"]:
    let value = context{key}
    if not value.isNil and value.kind != JString:
      return some("hostContext." & key & " must be a string")
  let dimensions = context{"containerDimensions"}
  if not dimensions.isNil:
    if dimensions.kind != JObject:
      return some("hostContext.containerDimensions must be an object")
    for key in ["height", "maxHeight", "width", "maxWidth"]:
      let value = dimensions{key}
      if not value.isNil and (not isNumber(value) or value.getFloat() < 0):
        return some("hostContext.containerDimensions." & key & " must be a number of pixels")
    if dimensions.hasKey("height") and dimensions.hasKey("maxHeight"):
      return some("containerDimensions: height (fixed) and maxHeight (flexible) exclude each other")
    if dimensions.hasKey("width") and dimensions.hasKey("maxWidth"):
      return some("containerDimensions: width (fixed) and maxWidth (flexible) exclude each other")
  let insets = context{"safeAreaInsets"}
  if not insets.isNil:
    if insets.kind != JObject:
      return some("hostContext.safeAreaInsets must be an object")
    for key in ["top", "right", "bottom", "left"]:
      if not isNumber(insets{key}):
        return some("hostContext.safeAreaInsets." & key & " must be a number")
  let capabilities = context{"deviceCapabilities"}
  if not capabilities.isNil:
    if capabilities.kind != JObject:
      return some("hostContext.deviceCapabilities must be an object")
    for key in ["touch", "hover"]:
      let value = capabilities{key}
      if not value.isNil and value.kind != JBool:
        return some("hostContext.deviceCapabilities." & key & " must be a boolean")
  let styles = context{"styles"}
  if not styles.isNil:
    if styles.kind != JObject:
      return some("hostContext.styles must be an object")
    let variables = styles{"variables"}
    if not variables.isNil:
      if variables.kind != JObject:
        return some("hostContext.styles.variables must be an object")
      for key, value in variables:
        if key notin StyleVariableKeys:
          return some("hostContext.styles.variables: '" & key & "' is not a standardized variable")
        if value.kind != JString:
          return some("hostContext.styles.variables['" & key & "'] must be a string")
    let css = styles{"css"}
    if not css.isNil:
      if css.kind != JObject or (css.hasKey("fonts") and css{"fonts"}.kind != JString):
        return some("hostContext.styles.css.fonts must be a string")
  let toolInfo = context{"toolInfo"}
  if not toolInfo.isNil:
    if toolInfo.kind != JObject or toolInfo{"tool"}.isNil or toolInfo{"tool"}.kind != JObject:
      return some("hostContext.toolInfo needs a tool object")
  none(string)

proc requireValidContext(context: JsonNode) {.raises: [McpAppsError].} =
  let problem = hostContextProblem(context)
  if problem.isSome:
    raise appsError(problem.get)

# --- host -> View -----------------------------------------------------------

proc initializeResult*(hostName, hostVersion: string, hostCapabilities: JsonNode,
                       hostContext: JsonNode,
                       protocolVersion = AppsProtocolVersion): JsonNode {.raises: [McpAppsError].} =
  ## The result of `ui/initialize` (McpUiInitializeResult). Raises
  ## McpAppsError for a hostContext that is not valid.
  requireValidContext(hostContext)
  if hostCapabilities.isNil or hostCapabilities.kind != JObject:
    raise appsError("hostCapabilities must be an object")
  %*{"protocolVersion": protocolVersion,
     "hostInfo": {"name": hostName, "version": hostVersion},
     "hostCapabilities": hostCapabilities,
     "hostContext": hostContext}

proc toolInputNotification*(arguments: JsonNode): JsonNode {.raises: [McpAppsError].} =
  ## The complete tool arguments; sent once, after the View initialized.
  if arguments.isNil or arguments.kind != JObject:
    raise appsError("tool-input arguments must be an object")
  uiNotification(MethodToolInput, %*{"arguments": arguments})

proc toolInputPartialNotification*(arguments: JsonNode): JsonNode {.raises: [McpAppsError].} =
  ## Best-effort arguments while the agent is still streaming them.
  if arguments.isNil or arguments.kind != JObject:
    raise appsError("tool-input-partial arguments must be an object")
  uiNotification(MethodToolInputPartial, %*{"arguments": arguments})

proc toolResultNotification*(callToolResult: JsonNode): JsonNode {.raises: [McpAppsError].} =
  ## The CallToolResult of the tool call, as the server answered it.
  if callToolResult.isNil or callToolResult.kind != JObject:
    raise appsError("a tool result must be an object")
  uiNotification(MethodToolResult, callToolResult)

func toolCancelledNotification*(reason = ""): JsonNode {.raises: [].} =
  uiNotification(MethodToolCancelled,
               if reason.len > 0: %*{"reason": reason} else: newJObject())

func resourceTeardownRequest*(id: JsonNode, reason = ""): JsonNode {.raises: [].} =
  ## Sent before the host tears the View down; the host should wait for the
  ## response.
  uiRequest(id, MethodResourceTeardown,
          if reason.len > 0: %*{"reason": reason} else: newJObject())

proc hostContextChangedNotification*(changed: JsonNode): JsonNode {.raises: [McpAppsError].} =
  ## Only the fields that changed; the View merges them.
  requireValidContext(changed)
  uiNotification(MethodHostContextChanged, changed)

func sandboxProxyReadyNotification*(): JsonNode {.raises: [].} =
  ## Sandbox proxy -> host.
  uiNotification(MethodSandboxProxyReady, newJObject())

proc sandboxResourceReadyNotification*(html: string, csp: Option[UiCsp] = none(UiCsp),
                                       permissions: set[UiPermission] = {},
                                       sandbox = ""): JsonNode {.raises: [McpAppsError].} =
  ## Host -> sandbox proxy: the HTML to load and the declarations it is to be
  ## enforced with. The origins are checked; a UI that declared an origin
  ## that is not a plain origin does not reach the proxy.
  if csp.isSome:
    let problem = cspProblem(csp.get)
    if problem.isSome:
      raise appsError(problem.get)
  result = %*{"html": html}
  if sandbox.len > 0:
    result["sandbox"] = %sandbox
  if csp.isSome:
    result["csp"] = csp.get.toJson
  if permissions != {}:
    result["permissions"] = permissionsToJson(permissions)
  result = uiNotification(MethodSandboxResourceReady, result)

# --- View -> host -----------------------------------------------------------

proc requireObject(params: JsonNode, methodName: string): JsonNode {.raises: [McpAppsError].} =
  if params.isNil or params.kind != JObject:
    raise appsError(methodName & ": params must be an object")
  params

proc stringField(params: JsonNode, key, methodName: string): string {.raises: [McpAppsError].} =
  let value = params{key}
  if value.isNil or value.kind != JString:
    raise appsError(methodName & ": " & key & " must be a string")
  value.getStr()

proc displayModesOf(node: JsonNode, where: string): seq[UiDisplayMode] {.raises: [McpAppsError].} =
  if node.isNil:
    return @[]
  if node.kind != JArray:
    raise appsError(where & " must be an array")
  for item in node:
    var matched = false
    if item.kind == JString:
      for mode in UiDisplayMode:
        if $mode == item.getStr():
          result.add mode
          matched = true
    if not matched:
      raise appsError(where & " holds " & $item & "; the modes are inline, fullscreen and pip")

proc parseInitializeRequest*(params: JsonNode): ViewInit {.raises: [McpAppsError].} =
  ## `ui/initialize`: who the View is, what it supports (`appCapabilities` is
  ## required) and which Apps version it speaks.
  let p = requireObject(params, MethodInitialize)
  let info = p{"appInfo"}
  if info.isNil or info.kind != JObject:
    raise appsError("ui/initialize: appInfo must be an object")
  result.appName = stringField(info, "name", "ui/initialize appInfo")
  result.appVersion = stringField(info, "version", "ui/initialize appInfo")
  result.protocolVersion = stringField(p, "protocolVersion", MethodInitialize)
  let capabilities = p{"appCapabilities"}
  if capabilities.isNil or capabilities.kind != JObject:
    raise appsError("ui/initialize: appCapabilities is required and must be an object")
  result.availableDisplayModes =
    displayModesOf(capabilities{"availableDisplayModes"}, "appCapabilities.availableDisplayModes")
  let tools = capabilities{"tools"}
  if not tools.isNil:
    if tools.kind != JObject:
      raise appsError("appCapabilities.tools must be an object")
    result.toolsListChanged = tools{"listChanged"}.getBool(false)

proc parseOpenLink*(params: JsonNode): string {.raises: [McpAppsError].} =
  ## `ui/open-link`: the URL to open. Only an absolute http or https URL
  ## passes; the host opens it in the user's browser, and `javascript:`,
  ## `file:` and the like are not what the specification means by a link
  ## (SDK policy: the specification only says the host may answer
  ## "Invalid URL").
  let url = stringField(requireObject(params, MethodOpenLink), "url", MethodOpenLink)
  for c in url:
    if c <= ' ' or c == '\x7f':
      raise appsError("ui/open-link: the URL holds a whitespace or control character")
  var parsed: Uri
  try:
    parsed = parseUri(url)
  except ValueError as e:
    raise appsError("ui/open-link: invalid URL: " & e.msg)
  if parsed.scheme.toLowerAscii notin ["http", "https"] or parsed.hostname.len == 0:
    raise appsError("ui/open-link: only absolute http and https URLs are opened")
  url

proc checkContentBlock(block0: JsonNode, where: string) {.raises: [McpAppsError].} =
  if block0.kind != JObject or block0{"type"}.isNil or block0{"type"}.kind != JString:
    raise appsError(where & ": a content block needs a string type")
  let kind = block0{"type"}.getStr()
  case kind
  of "text":
    discard stringField(block0, "text", where & " text block")
  of "image", "audio":
    discard stringField(block0, "data", where & " " & kind & " block")
    discard stringField(block0, "mimeType", where & " " & kind & " block")
  of "resource":
    if block0{"resource"}.isNil or block0{"resource"}.kind != JObject:
      raise appsError(where & ": a resource block needs a resource object")
  of "resource_link":
    discard stringField(block0, "uri", where & " resource_link block")
    discard stringField(block0, "name", where & " resource_link block")
  else:
    raise appsError(where & ": unknown content block type '" & kind & "'")

proc contentBlocks(node: JsonNode, where: string): seq[JsonNode] {.raises: [McpAppsError].} =
  ## A single block (the specification's prose) or an array of blocks
  ## (spec.types.ts): both occur, so both are read.
  if node.isNil:
    raise appsError(where & ": content is required")
  if node.kind == JObject:
    checkContentBlock(node, where)
    return @[node]
  if node.kind != JArray:
    raise appsError(where & ": content must be a content block or an array of them")
  for item in node:
    checkContentBlock(item, where)
    result.add item

proc parseUiMessage*(params: JsonNode): seq[JsonNode] {.raises: [McpAppsError].} =
  ## `ui/message`: the content blocks to add to the conversation. The role is
  ## `user`, the only one the specification defines.
  let p = requireObject(params, MethodMessage)
  if stringField(p, "role", MethodMessage) != "user":
    raise appsError("ui/message: role must be \"user\"")
  contentBlocks(p{"content"}, MethodMessage)

proc parseUpdateModelContext*(params: JsonNode): ModelContextUpdate {.raises: [McpAppsError].} =
  ## `ui/update-model-context`: content blocks and/or structured content that
  ## replace what this View sent before.
  let p = requireObject(params, MethodUpdateModelContext)
  let content = p{"content"}
  if not content.isNil:
    if content.kind != JArray:
      raise appsError("ui/update-model-context: content must be an array of content blocks")
    for item in content:
      checkContentBlock(item, MethodUpdateModelContext)
      result.content.add item
  let structured = p{"structuredContent"}
  if not structured.isNil:
    if structured.kind != JObject:
      raise appsError("ui/update-model-context: structuredContent must be an object")
    result.structuredContent = some(structured)

proc parseRequestDisplayMode*(params: JsonNode): UiDisplayMode {.raises: [McpAppsError].} =
  let mode = stringField(requireObject(params, MethodRequestDisplayMode), "mode",
                         MethodRequestDisplayMode)
  for candidate in UiDisplayMode:
    if $candidate == mode:
      return candidate
  raise appsError("ui/request-display-mode: mode must be inline, fullscreen or pip")

func resolveDisplayMode*(requested: UiDisplayMode, hostModes: openArray[UiDisplayMode],
                         view: ViewInit, current: UiDisplayMode): UiDisplayMode {.raises: [].} =
  ## The mode the host reports for `ui/request-display-mode`: the requested
  ## one only when the host supports it and, if the View declared the modes
  ## it supports, the View declared it; otherwise the current mode.
  if requested notin hostModes:
    return current
  if view.availableDisplayModes.len > 0 and requested notin view.availableDisplayModes:
    return current
  requested

func displayModeResult*(mode: UiDisplayMode): JsonNode {.raises: [].} =
  %*{"mode": $mode}

proc parseSizeChanged*(params: JsonNode): tuple[width, height: Option[float]] {.raises: [McpAppsError].} =
  ## `ui/notifications/size-changed`: pixels, each optional, never negative.
  let p = requireObject(params, MethodSizeChanged)
  let width = p{"width"}
  let height = p{"height"}
  for (key, value) in [("width", width), ("height", height)]:
    if not value.isNil and (not isNumber(value) or value.getFloat() < 0):
      raise appsError("ui/notifications/size-changed: " & key & " must be a non-negative number")
  if not width.isNil:
    result.width = some(width.getFloat())
  if not height.isNil:
    result.height = some(height.getFloat())

# --- lifecycle --------------------------------------------------------------

func newViewSession*(): ViewSession {.raises: [].} =
  ViewSession(phase: vpAwaitInitialize)

proc handleInitialize*(session: ViewSession, params: JsonNode, hostName, hostVersion: string,
                       hostCapabilities, hostContext: JsonNode): JsonNode {.raises: [McpAppsError].} =
  ## Answer the View's `ui/initialize`: validate it, remember what the View
  ## supports, return the result. Raises McpAppsError for a request that
  ## breaks the specification, or a second `ui/initialize`.
  if session.phase != vpAwaitInitialize:
    raise appsError("ui/initialize was already received on this View")
  let init = parseInitializeRequest(params)
  result = initializeResult(hostName, hostVersion, hostCapabilities, hostContext)
  session.init = some(init)
  session.phase = vpAwaitInitialized

proc noteInitialized*(session: ViewSession) {.raises: [McpAppsError].} =
  ## The View sent `ui/notifications/initialized`; only now may the host
  ## send it anything. Raises McpAppsError out of order.
  if session.phase != vpAwaitInitialized:
    raise appsError("ui/notifications/initialized came " &
      (if session.phase == vpReady: "twice" else: "before ui/initialize"))
  session.phase = vpReady

proc outgoing*(session: ViewSession, message: JsonNode): JsonNode {.raises: [McpAppsError].} =
  ## Let a host -> View message through, or raise McpAppsError when the
  ## specification forbids sending it now: no request or notification before
  ## `initialized`; `tool-input` at most once; `tool-input-partial` only
  ## before `tool-input`; `tool-result` only after `tool-input`. A response
  ## (no `method`) always passes. Returns `message`.
  let methodName = message{"method"}.getStr()
  if methodName.len == 0:
    return message
  if isSandboxReserved(methodName):
    raise appsError(methodName & " is for the sandbox proxy, not for the View")
  if session.phase != vpReady:
    raise appsError("the host must not send " & methodName &
                    " before the View's ui/notifications/initialized")
  case methodName
  of MethodToolInput:
    if session.toolInputSent:
      raise appsError("ui/notifications/tool-input is sent at most once")
    session.toolInputSent = true
  of MethodToolInputPartial:
    if session.toolInputSent:
      raise appsError("tool-input-partial must stop once tool-input was sent")
  of MethodToolResult:
    if not session.toolInputSent:
      raise appsError("ui/notifications/tool-input is required before tool-result")
  else:
    discard
  message
