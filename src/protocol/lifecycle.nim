## MCP protocol lifecycle management

import json, options, asyncdispatch
import ./types

type
  McpLifecycleState* = enum
    mlsUninitialized,  # Before initialize request
    mlsInitializing,   # After initialize request, before initialized notification
    mlsOperational,    # After initialized notification
    mlsShutdown        # After shutdown request or transport close

proc createInitializeRequest*(
  clientInfo: McpClientInfo,
  protocolVersion: McpProtocolVersion,
  capabilities: McpClientCapabilities
): JsonRpcRequest =
  let params = %*{
    "protocolVersion": $protocolVersion,
    "clientInfo": {
      "name": clientInfo.name,
      "version": clientInfo.version
    },
    "capabilities": %capabilities
  }
  
  result = newJsonRpcRequest("1", "initialize", params)

proc createInitializeResponse*(
  requestId: string,
  serverInfo: McpServerInfo,
  protocolVersion: McpProtocolVersion,
  capabilities: McpServerCapabilities
): JsonRpcResponse =
  let result = %*{
    "protocolVersion": $protocolVersion,
    "serverInfo": {
      "name": serverInfo.name,
      "version": serverInfo.version
    },
    "capabilities": %capabilities
  }
  
  return newJsonRpcResponse(requestId, result)

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
