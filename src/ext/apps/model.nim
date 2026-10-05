## MCP Apps: the data the extension defines, as typed values over JSON, and
## the rules that make that data safe to act on. Pure functions; no I/O.
##
## Based on the stable MCP Apps specification 2026-01-26,
## modelcontextprotocol/ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f
## (specification/2026-01-26/apps.mdx, src/spec.types.ts).
##
## A UI resource comes from a server the host does not trust: every value
## that reaches a CSP header, an iframe attribute or a size decision is
## checked here before it is used.

import std/[json, options, strutils]

const
  ExtensionId* = "io.modelcontextprotocol/ui"
    ## The extension identifier; `io.modelcontextprotocol/ui` is reserved.
  ResourceMimeType* = "text/html;profile=mcp-app"
    ## The one content type of a UI resource in this specification.
  UiScheme* = "ui://"
    ## Reserved for MCP Apps.
  AppsProtocolVersion* = "2026-01-26"
    ## The version of the Apps messages (`ui/initialize`), not of MCP.
  LegacyResourceUriKey* = "ui/resourceUri"
    ## Deprecated flat form of `_meta.ui.resourceUri`.

type
  McpAppsError* = object of ValueError
    ## A value that breaks the MCP Apps specification.

  UiCsp* = object
    ## The origins a UI declares it needs; anything not listed is blocked.
    connectDomains*: seq[string]   ## fetch / XHR / WebSocket (`connect-src`)
    resourceDomains*: seq[string]  ## scripts, styles, images, fonts, media
    frameDomains*: seq[string]     ## nested iframes (`frame-src`)
    baseUriDomains*: seq[string]   ## `base-uri`

  UiPermission* = enum
    upCamera = "camera"
    upMicrophone = "microphone"
    upGeolocation = "geolocation"
    upClipboardWrite = "clipboardWrite"

  UiResourceMeta* = object
    ## `_meta.ui` of a UI resource.
    csp*: Option[UiCsp]
      ## None: the host applies the restrictive default.
    permissions*: set[UiPermission]
    domain*: Option[string]
      ## Host-dependent format; only checked to be a plain token.
    prefersBorder*: Option[bool]

  ToolVisibility* = enum
    tvModel = "model"  ## visible to and callable by the agent
    tvApp = "app"      ## callable by the app of the same server

  UiToolMeta* = object
    ## `_meta.ui` of a tool.
    resourceUri*: Option[string]
    visibility*: set[ToolVisibility]
      ## `{tvModel, tvApp}` when the tool did not say.

  UiClientCapability* = object
    ## What the host declares under `extensions["io.modelcontextprotocol/ui"]`.
    mimeTypes*: seq[string]

  UiDisplayMode* = enum
    udInline = "inline"
    udFullscreen = "fullscreen"
    udPip = "pip"

const
  DefaultVisibility* = {tvModel, tvApp}

func appsError(message: string): ref McpAppsError =
  newException(McpAppsError, message)

# --- identifiers -----------------------------------------------------------

func uiUriProblem*(uri: string): Option[string] {.raises: [].} =
  ## Why `uri` is not the URI of a UI resource, or none when it is: it must
  ## start with `ui://`, name something after it, and hold no whitespace or
  ## control characters.
  if not uri.startsWith(UiScheme):
    return some("the URI '" & uri & "' of a UI resource must start with " & UiScheme)
  if uri.len == UiScheme.len:
    return some("the URI '" & uri & "' names nothing after " & UiScheme)
  for c in uri:
    if c <= ' ' or c == '\x7f':
      return some("the URI of a UI resource holds a whitespace or control character")
  none(string)

func isCspSource(source: string): bool {.raises: [].} =
  ## An origin the way the specification writes them (`https://api.example.com`,
  ## `wss://rt.example.com:8443`, `https://*.example.com`): http, https, ws or
  ## wss, a host with an optional leading `*.`, an optional port. A host builds
  ## its CSP by joining these, so nothing that could end a directive (space,
  ## `;`, `,`, quotes) may pass.
  let schemeEnd = source.find("://")
  if schemeEnd < 0 or source[0 ..< schemeEnd] notin ["http", "https", "ws", "wss"]:
    return false
  var rest = source[schemeEnd + 3 .. ^1]
  var port = ""
  let colon = rest.rfind(':')
  if colon >= 0:
    port = rest[colon + 1 .. ^1]
    rest = rest[0 ..< colon]
    if port.len == 0 or not (port == "*" or port.allCharsInSet(Digits)):
      return false
  if rest.startsWith("*."):
    rest = rest[2 .. ^1]
  rest.len > 0 and rest[0] in Letters + Digits and rest[^1] in Letters + Digits and
    rest.allCharsInSet(Letters + Digits + {'-', '.'}) and ".." notin rest

func cspProblem*(csp: UiCsp): Option[string] {.raises: [].} =
  ## The first origin in `csp` that is not a plain origin, or none.
  for (name, domains) in [("connectDomains", csp.connectDomains),
                          ("resourceDomains", csp.resourceDomains),
                          ("frameDomains", csp.frameDomains),
                          ("baseUriDomains", csp.baseUriDomains)]:
    for domain in domains:
      if not isCspSource(domain):
        return some(name & ": '" & domain & "' is not an origin such as " &
                    "https://example.com or https://*.example.com")
  none(string)

func domainProblem(domain: string): Option[string] {.raises: [].} =
  if domain.len == 0:
    return some("domain is empty")
  for c in domain:
    if c <= ' ' or c == '\x7f':
      return some("domain holds a whitespace or control character")
  none(string)

func metaProblem*(meta: UiResourceMeta): Option[string] {.raises: [].} =
  ## Why `meta` cannot be served or enforced, or none.
  if meta.csp.isSome:
    let problem = cspProblem(meta.csp.get)
    if problem.isSome:
      return some("csp." & problem.get)
  if meta.domain.isSome:
    let problem = domainProblem(meta.domain.get)
    if problem.isSome:
      return problem
  none(string)

# --- JSON ------------------------------------------------------------------

func toJson*(csp: UiCsp): JsonNode {.raises: [].} =
  ## Only the lists that are not empty: an omitted list means "none allowed".
  result = newJObject()
  for (name, domains) in [("connectDomains", csp.connectDomains),
                          ("resourceDomains", csp.resourceDomains),
                          ("frameDomains", csp.frameDomains),
                          ("baseUriDomains", csp.baseUriDomains)]:
    if domains.len > 0:
      result[name] = %domains

func permissionsToJson*(permissions: set[UiPermission]): JsonNode {.raises: [].} =
  result = newJObject()
  for permission in permissions:
    result[$permission] = newJObject()

func toJson*(meta: UiResourceMeta): JsonNode {.raises: [].} =
  result = newJObject()
  if meta.csp.isSome:
    result["csp"] = meta.csp.get.toJson
  if meta.permissions != {}:
    result["permissions"] = permissionsToJson(meta.permissions)
  if meta.domain.isSome:
    result["domain"] = %meta.domain.get
  if meta.prefersBorder.isSome:
    result["prefersBorder"] = %meta.prefersBorder.get

func toJson*(meta: UiToolMeta): JsonNode {.raises: [].} =
  result = newJObject()
  if meta.resourceUri.isSome:
    result["resourceUri"] = %meta.resourceUri.get
  let visibility = newJArray()
  for each in meta.visibility:
    visibility.add %($each)
  result["visibility"] = visibility

proc stringList(node: JsonNode, where: string): seq[string] {.raises: [McpAppsError].} =
  if node.isNil:
    return @[]
  if node.kind != JArray:
    raise appsError(where & " must be an array of strings")
  for item in node:
    if item.kind != JString:
      raise appsError(where & " must be an array of strings")
    result.add item.getStr()

proc parseCsp(node: JsonNode): UiCsp {.raises: [McpAppsError].} =
  if node.kind != JObject:
    raise appsError("_meta.ui.csp must be an object")
  result = UiCsp(
    connectDomains: stringList(node{"connectDomains"}, "csp.connectDomains"),
    resourceDomains: stringList(node{"resourceDomains"}, "csp.resourceDomains"),
    frameDomains: stringList(node{"frameDomains"}, "csp.frameDomains"),
    baseUriDomains: stringList(node{"baseUriDomains"}, "csp.baseUriDomains"))
  let problem = cspProblem(result)
  if problem.isSome:
    raise appsError("csp." & problem.get)

proc parsePermissions(node: JsonNode): set[UiPermission] {.raises: [McpAppsError].} =
  ## Permissions this SDK knows; a key it does not know is ignored, since the
  ## host cannot grant what it does not know.
  if node.kind != JObject:
    raise appsError("_meta.ui.permissions must be an object")
  for permission in UiPermission:
    let entry = node{$permission}
    if entry.isNil:
      continue
    if entry.kind != JObject:
      raise appsError("permissions." & $permission & " must be an object")
    result.incl permission

proc parseUiResourceMeta*(node: JsonNode): UiResourceMeta {.raises: [McpAppsError].} =
  ## The `_meta.ui` object of a UI resource (nil: nothing declared). Raises
  ## McpAppsError for a field of the wrong type or an origin that is not a
  ## plain origin; keys the specification does not define are ignored.
  if node.isNil:
    return UiResourceMeta()
  if node.kind != JObject:
    raise appsError("_meta.ui must be an object")
  if node.hasKey("csp"):
    result.csp = some(parseCsp(node{"csp"}))
  if node.hasKey("permissions"):
    result.permissions = parsePermissions(node{"permissions"})
  if node.hasKey("domain"):
    if node{"domain"}.kind != JString:
      raise appsError("_meta.ui.domain must be a string")
    let problem = domainProblem(node{"domain"}.getStr())
    if problem.isSome:
      raise appsError("_meta.ui." & problem.get)
    result.domain = some(node{"domain"}.getStr())
  if node.hasKey("prefersBorder"):
    if node{"prefersBorder"}.kind != JBool:
      raise appsError("_meta.ui.prefersBorder must be a boolean")
    result.prefersBorder = some(node{"prefersBorder"}.getBool())

proc parseUiToolMeta*(meta: JsonNode): Option[UiToolMeta] {.raises: [McpAppsError].} =
  ## The UI reference in the `_meta` of a tool, or none when it has none.
  ## `_meta.ui.resourceUri` is read first, the deprecated `_meta["ui/resourceUri"]`
  ## when that is absent. Raises McpAppsError for a malformed reference, a
  ## `resourceUri` that is not a `ui://` URI, or a `csp` / `permissions` on a
  ## tool (spec.types.ts: they belong to the resource).
  if meta.isNil or meta.kind != JObject:
    return none(UiToolMeta)
  var found = UiToolMeta(visibility: DefaultVisibility)
  var any = false
  let ui = meta{"ui"}
  if not ui.isNil:
    if ui.kind != JObject:
      raise appsError("_meta.ui must be an object")
    any = true
    for forbidden in ["csp", "permissions"]:
      if ui.hasKey(forbidden):
        raise appsError("_meta.ui." & forbidden & " belongs to the UI resource, not to the tool")
    if ui.hasKey("resourceUri"):
      if ui{"resourceUri"}.kind != JString:
        raise appsError("_meta.ui.resourceUri must be a string")
      found.resourceUri = some(ui{"resourceUri"}.getStr())
    if ui.hasKey("visibility"):
      if ui{"visibility"}.kind != JArray:
        raise appsError("_meta.ui.visibility must be an array")
      found.visibility = {}
      for item in ui{"visibility"}:
        var known = false
        if item.kind == JString:
          for candidate in ToolVisibility:
            if $candidate == item.getStr():
              found.visibility.incl candidate
              known = true
        if not known:
          raise appsError("_meta.ui.visibility holds '" & $item &
                          "'; the values are \"model\" and \"app\"")
  if found.resourceUri.isNone and meta.hasKey(LegacyResourceUriKey):
    if meta{LegacyResourceUriKey}.kind != JString:
      raise appsError("_meta[\"" & LegacyResourceUriKey & "\"] must be a string")
    found.resourceUri = some(meta{LegacyResourceUriKey}.getStr())
    any = true
  if not any:
    return none(UiToolMeta)
  if found.resourceUri.isSome:
    let problem = uiUriProblem(found.resourceUri.get)
    if problem.isSome:
      raise appsError(problem.get)
  some(found)

func parseUiClientCapability*(settings: JsonNode): Option[UiClientCapability] {.raises: [].} =
  ## What a host declared for the extension: none when `mimeTypes` (REQUIRED)
  ## is missing or is not a list of strings.
  if settings.isNil or settings.kind != JObject:
    return none(UiClientCapability)
  let mimeTypes = settings{"mimeTypes"}
  if mimeTypes.isNil or mimeTypes.kind != JArray:
    return none(UiClientCapability)
  var capability = UiClientCapability()
  for item in mimeTypes:
    if item.kind != JString:
      return none(UiClientCapability)
    capability.mimeTypes.add item.getStr()
  some(capability)

func supportsHtmlApps*(capability: UiClientCapability): bool {.raises: [].} =
  ResourceMimeType in capability.mimeTypes

# --- CSP and permission policy ---------------------------------------------

func joined(domains: seq[string]): string {.raises: [].} =
  domains.join(" ")

func contentSecurityPolicy*(csp: Option[UiCsp]): string {.raises: [McpAppsError].} =
  ## The CSP a host enforces for a UI that declared `csp` (security
  ## implications, "CSP Construction from Metadata"); with none declared, the
  ## restrictive default of "Host Behavior". Origins are checked again here: a
  ## host does not depend on whoever parsed the metadata. Never allows an
  ## origin the UI did not declare.
  ##
  ## The default also carries `frame-src 'none'`, `object-src 'none'` and
  ## `base-uri 'self'` (sandbox proxy rule 5 asks for them whenever no
  ## metadata is provided); they only tighten the list the specification
  ## gives for that case.
  if csp.isNone:
    return "default-src 'none'; script-src 'self' 'unsafe-inline'; " &
           "style-src 'self' 'unsafe-inline'; img-src 'self' data:; " &
           "media-src 'self' data:; connect-src 'none'; frame-src 'none'; " &
           "object-src 'none'; base-uri 'self'"
  let declared = csp.get
  let problem = cspProblem(declared)
  if problem.isSome:
    raise appsError(problem.get)
  let resources = if declared.resourceDomains.len > 0: " " & joined(declared.resourceDomains) else: ""
  let connect = if declared.connectDomains.len > 0: " " & joined(declared.connectDomains) else: ""
  let frames = if declared.frameDomains.len > 0: joined(declared.frameDomains) else: "'none'"
  let base = if declared.baseUriDomains.len > 0: joined(declared.baseUriDomains) else: "'self'"
  "default-src 'none'; " &
    "script-src 'self' 'unsafe-inline'" & resources & "; " &
    "style-src 'self' 'unsafe-inline'" & resources & "; " &
    "connect-src 'self'" & connect & "; " &
    "img-src 'self' data:" & resources & "; " &
    "font-src 'self'" & resources & "; " &
    "media-src 'self' data:" & resources & "; " &
    "frame-src " & frames & "; " &
    "object-src 'none'; " &
    "base-uri " & base

func permissionPolicy*(permissions: set[UiPermission]): string {.raises: [].} =
  ## The value of the inner iframe's `allow` attribute: the Permission Policy
  ## features of the permissions the UI declared. `clipboardWrite` maps to
  ## `clipboard-write` (the specification's prose; its sample code leaves it out).
  var features: seq[string]
  for permission in permissions:
    features.add case permission
      of upCamera: "camera"
      of upMicrophone: "microphone"
      of upGeolocation: "geolocation"
      of upClipboardWrite: "clipboard-write"
  features.join(" ")
