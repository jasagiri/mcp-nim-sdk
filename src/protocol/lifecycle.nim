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
  if capabilities.experimental.isSome:
    result["experimental"] = capabilities.experimental.get

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
  if capabilities.experimental.isSome:
    result["experimental"] = capabilities.experimental.get

func forVersion*(capabilities: McpServerCapabilities,
                 version: McpProtocolVersion): McpServerCapabilities {.raises: [].} =
  ## What a server announces to a client that agreed on `version`: a
  ## capability that version's schema does not know is left out.
  result = capabilities
  if not version.has(ftCompletionsCapability):
    result.completions = none(McpCompletionsCapability)

proc createInitializeRequest*(
  clientInfo: McpClientInfo,
  protocolVersion: McpProtocolVersion,
  capabilities: McpClientCapabilities
): JsonRpcRequest =
  let params = %*{
    "protocolVersion": $protocolVersion,
    "clientInfo": protocolVersion.implementationFor(clientInfo),
    "capabilities": capabilities.toJson()
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
