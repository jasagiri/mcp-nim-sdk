## Request rules of protocol version 2026-07-28 and later: there is no
## initialize handshake, every request carries its own protocol version and
## client capabilities in `params._meta`.
##
## Everything here is a pure function over JSON, shared by the server, the
## client and the HTTP transports.

import std/[json, options, base64, strutils]
import ./types
import ./content

const
  MetaProtocolVersion* = "io.modelcontextprotocol/protocolVersion"
  MetaClientInfo* = "io.modelcontextprotocol/clientInfo"
  MetaClientCapabilities* = "io.modelcontextprotocol/clientCapabilities"
  MetaLogLevel* = "io.modelcontextprotocol/logLevel"
  MetaServerInfo* = "io.modelcontextprotocol/serverInfo"
  MetaSubscriptionId* = "io.modelcontextprotocol/subscriptionId"

  ErrMethodNotFound* = -32601
  ErrInvalidParams* = -32602
  ErrInternal* = -32603
  ErrHeaderMismatch* = -32020
  ErrMissingRequiredClientCapability* = -32021
  ErrUnsupportedProtocolVersion* = -32022

  HeaderProtocolVersion* = "MCP-Protocol-Version"
  HeaderMethod* = "Mcp-Method"
  HeaderName* = "Mcp-Name"

  DiscoverMethod* = "server/discover"

  MethodsRemovedInModern* = [
    "initialize", "ping", "logging/setLevel",
    "resources/subscribe", "resources/unsubscribe",
    "tasks/get", "tasks/result", "tasks/cancel", "tasks/list"
  ]

  CacheableMethods* = [
    DiscoverMethod, "tools/list", "prompts/list", "resources/list",
    "resources/templates/list", "resources/read"
  ]

  Base64SentinelPrefix = "=?base64?"
  Base64SentinelSuffix = "?="

type
  CacheScope* = enum
    csPublic = "public"
    csPrivate = "private"

  CachePolicy* = object
    ## What a server tells clients about reusing a cacheable result.
    ttlMs*: Natural
    scope*: CacheScope

  ResultKind* = enum
    rkComplete       ## the final result of the request
    rkInputRequired  ## the server needs client input before it can finish
    rkUnknown        ## a resultType this SDK does not know

const
  UncachedPolicy* = CachePolicy(ttlMs: 0, scope: csPrivate)
    ## The conservative policy: do not reuse, do not share.

func rpcError(code: int, message: string, data: JsonNode = nil): JsonRpcError {.raises: [].} =
  JsonRpcError(code: code, message: message, data: data)

func metaOf(params: JsonNode): JsonNode {.raises: [].} =
  ## `params._meta` when it is an object, otherwise nil.
  if params.isNil or params.kind != JObject:
    return nil
  let meta = params{"_meta"}
  if meta.isNil or meta.kind != JObject: nil else: meta

func isModernRequest*(params: JsonNode): bool {.raises: [].} =
  ## A request is modern when it names its own protocol version; a legacy
  ## request may still carry `_meta` (for a progress token, say).
  let meta = metaOf(params)
  not meta.isNil and meta.hasKey(MetaProtocolVersion)

func versionList(versions: openArray[McpProtocolVersion]): JsonNode {.raises: [].} =
  ## Newest first, as the specification's examples list them.
  result = newJArray()
  for i in countdown(versions.high, versions.low):
    result.add %($versions[i])

func unsupportedVersionError*(requested: string,
                              supported: openArray[McpProtocolVersion]): JsonRpcError {.raises: [].} =
  rpcError(ErrUnsupportedProtocolVersion, "Unsupported protocol version",
           %*{"supported": versionList(supported), "requested": requested})

func validateModernRequest*(params: JsonNode,
                            supported: openArray[McpProtocolVersion]): Option[JsonRpcError] {.raises: [].} =
  ## Why a modern request cannot be served, or none when it can.
  ## `supported` must be in ascending order.
  let meta = metaOf(params)
  if meta.isNil:
    return some(rpcError(ErrInvalidParams, "params._meta is required"))

  let versionNode = meta{MetaProtocolVersion}
  if versionNode.isNil or versionNode.kind != JString:
    return some(rpcError(ErrInvalidParams,
      "_meta[\"" & MetaProtocolVersion & "\"] must be a string"))
  let requested = versionNode.getStr()
  let parsed = parseProtocolVersion(requested)
  if parsed.isNone or not isModern(parsed.get) or parsed.get notin supported:
    return some(unsupportedVersionError(requested, supported))

  let capabilities = meta{MetaClientCapabilities}
  if capabilities.isNil or capabilities.kind != JObject:
    return some(rpcError(ErrInvalidParams,
      "_meta[\"" & MetaClientCapabilities & "\"] must be an object"))

  let clientInfo = meta{MetaClientInfo}
  if not clientInfo.isNil and clientInfo.kind != JObject:
    return some(rpcError(ErrInvalidParams,
      "_meta[\"" & MetaClientInfo & "\"] must be an object"))

  none(JsonRpcError)

func isRemovedInModern*(methodName: string): bool {.raises: [].} =
  methodName in MethodsRemovedInModern

func isCacheable*(methodName: string): bool {.raises: [].} =
  methodName in CacheableMethods

func missingCapabilityError*(message: string, required: JsonNode): JsonRpcError {.raises: [].} =
  rpcError(ErrMissingRequiredClientCapability, message,
           %*{"requiredCapabilities": required})

func resultKind*(resultNode: JsonNode): ResultKind {.raises: [].} =
  ## A result without resultType comes from an older server and is complete.
  let kindNode =
    if resultNode.isNil or resultNode.kind != JObject: nil
    else: resultNode{"resultType"}
  if kindNode.isNil:
    return rkComplete
  if kindNode.kind != JString:
    return rkUnknown
  case kindNode.getStr()
  of "complete": rkComplete
  of "input_required": rkInputRequired
  else: rkUnknown

func completeResult*(methodName: string, payload: JsonNode,
                     serverInfo: McpServerInfo,
                     cache: CachePolicy = UncachedPolicy): JsonNode {.raises: [].} =
  ## The modern wire form of a handler's result object: a result type, the
  ## server's identity and, for cacheable methods, a cache policy. Fields the
  ## handler already set are kept. `payload` must be a JSON object.
  doAssert not payload.isNil and payload.kind == JObject,
    "a result must be a JSON object"
  result = payload.copy()
  if not result.hasKey("resultType"):
    result["resultType"] = %"complete"

  if isCacheable(methodName) and resultKind(result) == rkComplete:
    if not result.hasKey("ttlMs"):
      result["ttlMs"] = %cache.ttlMs.int
    if not result.hasKey("cacheScope"):
      result["cacheScope"] = %($cache.scope)

  var meta = result{"_meta"}
  if meta.isNil or meta.kind != JObject:
    meta = newJObject()
    result["_meta"] = meta
  if not meta.hasKey(MetaServerInfo):
    meta[MetaServerInfo] = mpv20260728.implementationFor(serverInfo)

func discoverPayload*(supported: openArray[McpProtocolVersion],
                      capabilities: JsonNode,
                      instructions: string = ""): JsonNode {.raises: [].} =
  ## The body of a `server/discover` result, before `completeResult`.
  result = %*{
    "supportedVersions": versionList(supported),
    "capabilities": capabilities
  }
  if instructions.len > 0:
    result["instructions"] = %instructions

func requestMeta*(version: McpProtocolVersion, clientInfo: McpClientInfo,
                  capabilities: JsonNode): JsonNode {.raises: [].} =
  %*{
    MetaProtocolVersion: $version,
    MetaClientInfo: version.implementationFor(clientInfo),
    MetaClientCapabilities: capabilities
  }

func withRequestMeta*(params: JsonNode, meta: JsonNode): JsonNode {.raises: [].} =
  ## A copy of `params` whose `_meta` gains every key of `meta`. Other keys
  ## the caller put in `_meta`, such as a progress token, are kept.
  result =
    if params.isNil or params.kind != JObject: newJObject()
    else: params.copy()
  var merged = result{"_meta"}
  if merged.isNil or merged.kind != JObject:
    merged = newJObject()
    result["_meta"] = merged
  for key, value in meta.pairs:
    merged[key] = value

# --- Streamable HTTP request headers -------------------------------------

func isSentinel(value: string): bool {.raises: [].} =
  value.startsWith(Base64SentinelPrefix) and
    value.endsWith(Base64SentinelSuffix) and
    value.len >= Base64SentinelPrefix.len + Base64SentinelSuffix.len

func isPlainHeaderValue(value: string): bool {.raises: [].} =
  ## Visible ASCII with inner spaces or tabs only (RFC 9110 field-value).
  if value.len == 0:
    return true
  if value[0] in {' ', '\t'} or value[^1] in {' ', '\t'}:
    return false
  for c in value:
    if c notin {'\x21'..'\x7E', ' ', '\t'}:
      return false
  true

func encodeHeaderValue*(value: string): string {.raises: [].} =
  ## A value that is not a safe plain header value, or that looks like the
  ## Base64 sentinel itself, is carried as `=?base64?...?=`.
  if isPlainHeaderValue(value) and not isSentinel(value):
    value
  else:
    Base64SentinelPrefix & base64.encode(value) & Base64SentinelSuffix

func decodeHeaderValue*(value: string): Option[string] {.raises: [].} =
  ## The value a header carries, or none when the header is malformed.
  if isSentinel(value):
    let encoded = value[Base64SentinelPrefix.len ..< value.len - Base64SentinelSuffix.len]
    try:
      return some(base64.decode(encoded))
    except ValueError:
      return none(string)
  if isPlainHeaderValue(value): some(value) else: none(string)

func headerNameSource*(methodName: string, params: JsonNode): Option[string] {.raises: [].} =
  ## The body value `Mcp-Name` mirrors, for the methods that require it.
  let key =
    case methodName
    of "tools/call", "prompts/get": "name"
    of "resources/read": "uri"
    of "tasks/get", "tasks/update", "tasks/cancel": "taskId"
    else: ""
  if key.len == 0 or params.isNil or params.kind != JObject:
    return none(string)
  let node = params{key}
  if node.isNil or node.kind != JString: none(string) else: some(node.getStr())

const ExtensionNamedMethods* = ["tasks/get", "tasks/update", "tasks/cancel"]
  ## Methods an extension defines whose requests carry `Mcp-Name` (the
  ## Tasks extension mirrors `taskId`). The rule exists only where the
  ## method is served.

func requiresNameHeader*(methodName: string,
                         extensionMethodServed = false): bool {.raises: [].} =
  ## Whether a request of `methodName` must carry `Mcp-Name`. A method of
  ## `ExtensionNamedMethods` needs it only on a server that serves it.
  methodName in ["tools/call", "prompts/get", "resources/read"] or
    (extensionMethodServed and methodName in ExtensionNamedMethods)

func modernRequestHeaders*(methodName: string,
                           params: JsonNode): seq[(string, string)] {.raises: [].} =
  ## The headers a Streamable HTTP POST of this modern request must carry.
  let meta = metaOf(params)
  if not meta.isNil:
    let version = meta{MetaProtocolVersion}
    if not version.isNil and version.kind == JString:
      result.add (HeaderProtocolVersion, version.getStr())
  result.add (HeaderMethod, methodName)
  let name = headerNameSource(methodName, params)
  if name.isSome:
    result.add (HeaderName, encodeHeaderValue(name.get))

func headerMismatch(message: string): Option[JsonRpcError] {.raises: [].} =
  some(rpcError(ErrHeaderMismatch, "Header mismatch: " & message))

func checkRequestHeaders*(protocolVersion, mcpMethod, mcpName: Option[string],
                          methodName: string, params: JsonNode,
                          extensionMethodServed = false): Option[JsonRpcError] {.raises: [].} =
  ## Why the headers of a modern Streamable HTTP request disagree with its
  ## body, or none when they agree. `extensionMethodServed`: the server
  ## serves `methodName` for an extension (see `requiresNameHeader`).
  if protocolVersion.isNone:
    return headerMismatch(HeaderProtocolVersion & " header is missing")
  let meta = metaOf(params)
  let bodyVersion =
    if meta.isNil: "" else: meta{MetaProtocolVersion}.getStr()
  if protocolVersion.get != bodyVersion:
    return headerMismatch(HeaderProtocolVersion & " header value '" &
      protocolVersion.get & "' does not match body value '" & bodyVersion & "'")

  if mcpMethod.isNone:
    return headerMismatch(HeaderMethod & " header is missing")
  if mcpMethod.get != methodName:
    return headerMismatch(HeaderMethod & " header value '" & mcpMethod.get &
      "' does not match body value '" & methodName & "'")

  if requiresNameHeader(methodName, extensionMethodServed):
    if mcpName.isNone:
      return headerMismatch(HeaderName & " header is missing")
    let decoded = decodeHeaderValue(mcpName.get)
    if decoded.isNone:
      return headerMismatch(HeaderName & " header value is malformed")
    let bodyName = headerNameSource(methodName, params)
    if bodyName.isNone or decoded.get != bodyName.get:
      return headerMismatch(HeaderName & " header value '" & decoded.get &
        "' does not match body value '" & bodyName.get("") & "'")

  none(JsonRpcError)
