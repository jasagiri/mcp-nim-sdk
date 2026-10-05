## MCP protocol lifecycle management

import json, options
import ./types
import ./features
import ./content

type
  McpLifecycleState* = enum
    mlsUninitialized,  # Before initialize request
    mlsInitializing,   # After initialize request, before initialized notification
    mlsOperational,    # After initialized notification
    mlsShutdown        # After shutdown request or transport close

proc toJson*(capability: McpTasksCapability): JsonNode =
  ## Wire form of `capabilities.tasks`: only what is supported is present.
  result = newJObject()
  if capability.list:
    result["list"] = newJObject()
  if capability.cancel:
    result["cancel"] = newJObject()
  let requests = newJObject()
  if capability.toolsCall:
    requests["tools"] = %*{"call": {}}
  if capability.samplingCreateMessage:
    requests["sampling"] = %*{"createMessage": {}}
  if capability.elicitationCreate:
    requests["elicitation"] = %*{"create": {}}
  if requests.len > 0:
    result["requests"] = requests

proc tasksCapabilityFromJson*(node: JsonNode): Option[McpTasksCapability] =
  ## What a peer declared as `capabilities.tasks`; none when it declared no
  ## object (null counts as not declared).
  if node.isNil or node.kind != JObject:
    return none(McpTasksCapability)
  func declared(parent: JsonNode, key: string): bool =
    not parent.isNil and parent.kind == JObject and
      not parent{key}.isNil and parent{key}.kind == JObject
  let requests = node{"requests"}
  some(McpTasksCapability(
    list: node.declared("list"),
    cancel: node.declared("cancel"),
    toolsCall: declared(requests{"tools"}, "call"),
    samplingCreateMessage: declared(requests{"sampling"}, "createMessage"),
    elicitationCreate: declared(requests{"elicitation"}, "create")))

proc toJson*(capabilities: McpClientCapabilities): JsonNode =
  ## Wire form: a capability the client did not declare is absent, not null.
  result = newJObject()
  if capabilities.roots.isSome:
    result["roots"] = %*{"listChanged": capabilities.roots.get.listChanged}
  if capabilities.sampling.isSome:
    let sampling = newJObject()
    if capabilities.sampling.get.tools: sampling["tools"] = newJObject()
    if capabilities.sampling.get.context: sampling["context"] = newJObject()
    result["sampling"] = sampling
  if capabilities.elicitation.isSome:
    let elicitation = newJObject()
    if capabilities.elicitation.get.form: elicitation["form"] = newJObject()
    if capabilities.elicitation.get.url: elicitation["url"] = newJObject()
    result["elicitation"] = elicitation
  if capabilities.tasks.isSome:
    result["tasks"] = capabilities.tasks.get.toJson()
  if capabilities.experimental.isSome:
    result["experimental"] = capabilities.experimental.get
  if capabilities.extensions.isSome:
    result["extensions"] = capabilities.extensions.get

proc fromJson*(node: JsonNode, T: typedesc[McpElicitationCapability]): McpElicitationCapability =
  ## An empty object is the form mode alone.
  let form = node{"form"}
  let url = node{"url"}
  result.url = not url.isNil and url.kind == JObject
  result.form = (not form.isNil and form.kind == JObject) or not result.url

proc toJson*(capabilities: McpServerCapabilities): JsonNode =
  ## Wire form: a capability the server did not declare is absent, not null.
  result = newJObject()
  if capabilities.prompts.isSome:
    result["prompts"] = %*{"listChanged": capabilities.prompts.get.listChanged}
  if capabilities.resources.isSome:
    result["resources"] = %*{
      "subscribe": capabilities.resources.get.subscribe,
      "listChanged": capabilities.resources.get.listChanged
    }
  if capabilities.tools.isSome:
    result["tools"] = %*{"listChanged": capabilities.tools.get.listChanged}
  if capabilities.logging.isSome:
    result["logging"] = newJObject()
  if capabilities.completions.isSome:
    result["completions"] = newJObject()
  if capabilities.tasks.isSome:
    result["tasks"] = capabilities.tasks.get.toJson()
  if capabilities.experimental.isSome:
    result["experimental"] = capabilities.experimental.get
  if capabilities.extensions.isSome:
    result["extensions"] = capabilities.extensions.get

func onlyNamed(extensions: Option[JsonNode],
               names: openArray[string]): Option[JsonNode] {.raises: [].} =
  ## The entries of `extensions` that are listed in `names`; none when no
  ## entry is left.
  if extensions.isNone or extensions.get.kind != JObject:
    return none(JsonNode)
  let kept = newJObject()
  for name in names:
    let entry = extensions.get{name}
    if not entry.isNil:
      kept[name] = entry
  if kept.len == 0: none(JsonNode) else: some(kept)

func forVersion*(capabilities: McpServerCapabilities,
                 version: McpProtocolVersion,
                 legacyExtensions: openArray[string] = []): McpServerCapabilities {.raises: [].} =
  ## What a server announces to a client that agreed on `version`: a
  ## capability that version's schema does not know is left out. Before
  ## 2026-07-28 the `extensions` that were registered for the legacy
  ## handshake (`legacyExtensions`) are kept, and only those.
  result = capabilities
  if not version.has(ftCompletionsCapability):
    result.completions = none(McpCompletionsCapability)
  if not version.has(ftExtensions):
    result.extensions = capabilities.extensions.onlyNamed(legacyExtensions)
  if not version.has(ftTasks):
    result.tasks = none(McpTasksCapability)

func forVersion*(capabilities: McpClientCapabilities,
                 version: McpProtocolVersion,
                 legacyExtensions: openArray[string] = []): McpClientCapabilities {.raises: [].} =
  ## What a client declares to a server of `version`: a capability that
  ## version's schema does not know is left out. Before 2026-07-28 the
  ## `extensions` that were declared for the legacy handshake
  ## (`legacyExtensions`) are kept, and only those.
  result = capabilities
  if not version.has(ftExtensions):
    result.extensions = capabilities.extensions.onlyNamed(legacyExtensions)
  if not version.has(ftTasks):
    result.tasks = none(McpTasksCapability)

proc createInitializeRequest*(
  clientInfo: McpClientInfo,
  protocolVersion: McpProtocolVersion,
  capabilities: McpClientCapabilities,
  legacyExtensions: openArray[string] = []
): JsonRpcRequest =
  let params = %*{
    "protocolVersion": $protocolVersion,
    "clientInfo": protocolVersion.implementationFor(clientInfo),
    "capabilities": capabilities.forVersion(protocolVersion, legacyExtensions).toJson()
  }
  
  result = newJsonRpcRequest("1", "initialize", params)

proc createInitializeResponse*(
  requestId: string,
  serverInfo: McpServerInfo,
  protocolVersion: McpProtocolVersion,
  capabilities: McpServerCapabilities
): JsonRpcResponse =
  let initializeResult = %*{
    "protocolVersion": $protocolVersion,
    "serverInfo": protocolVersion.implementationFor(serverInfo),
    "capabilities": capabilities.toJson()
  }

  return newJsonRpcResponse(requestId, initializeResult)

proc createInitializedNotification*(): JsonRpcNotification =
  return newJsonRpcNotification("notifications/initialized", newJObject())

proc isPingRequest*(request: JsonRpcRequest): bool =
  return request.method == "ping"

proc createPingResponse*(requestId: string): JsonRpcResponse =
  return newJsonRpcResponse(requestId, newJObject())

proc createCancelledNotification*(requestId: string, reason: string = ""): JsonRpcNotification =
  let params = %*{
    "requestId": requestId
  }
  
  if reason.len > 0:
    params["reason"] = %reason
  
  return newJsonRpcNotification("notifications/cancelled", params)

proc createProgressNotification*(token: string, progress: float, total: Option[float] = none(float), message: string = ""): JsonRpcNotification =
  var params = %*{
    "progressToken": token,
    "progress": progress
  }
  
  if total.isSome:
    params["total"] = %total.get()
  
  if message.len > 0:
    params["message"] = %message
  
  return newJsonRpcNotification("notifications/progress", params)
