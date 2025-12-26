## Core MCP protocol types

import json, options

type
  # Basic JSON-RPC types
  JsonRpcRequest* = object
    jsonrpc*: string
    id*: string
    method*: string
    params*: JsonNode

  JsonRpcResponse* = object
    jsonrpc*: string
    id*: string
    result*: Option[JsonNode]
    error*: Option[JsonRpcError]

  JsonRpcNotification* = object
    jsonrpc*: string
    method*: string
    params*: JsonNode

  JsonRpcError* = object
    code*: int
    message*: string
    data*: JsonNode

  # MCP protocol version
  McpProtocolVersion* = enum
    mpv20241105 = "2024-11-05",
    mpv20250326 = "2025-03-26",
    mpv20250618 = "2025-06-18",
    mpv20251125 = "2025-11-25"

  # MCP capabilities
  McpClientCapabilities* = object
    roots*: Option[McpRootsCapability]
    sampling*: Option[McpSamplingCapability]
    experimental*: Option[JsonNode]

  McpServerCapabilities* = object
    prompts*: Option[McpPromptsCapability]
    resources*: Option[McpResourcesCapability]
    tools*: Option[McpToolsCapability]
    logging*: Option[McpLoggingCapability]
    experimental*: Option[JsonNode]

  McpRootsCapability* = object
    listChanged*: bool

  McpSamplingCapability* = object
    # Currently empty in the protocol

  McpPromptsCapability* = object
    listChanged*: bool

  McpResourcesCapability* = object
    subscribe*: bool
    listChanged*: bool

  McpToolsCapability* = object
    listChanged*: bool

  McpLoggingCapability* = object
    # Currently empty in the protocol

  # MCP initialization
  McpClientInfo* = object
    name*: string
    version*: string

  McpServerInfo* = object
    name*: string
    version*: string

  # MCP message meta-data
  McpRequestMeta* = object
    progressToken*: Option[string]
    # Other future meta fields

# Constructor functions
proc newJsonRpcRequest*(id: string, method: string, params: JsonNode): JsonRpcRequest =
  result = JsonRpcRequest(
    jsonrpc: "2.0",
    id: id,
    method: method,
    params: params
  )

proc newJsonRpcResponse*(id: string, result: JsonNode): JsonRpcResponse =
  result = JsonRpcResponse(
    jsonrpc: "2.0",
    id: id,
    result: some(result),
    error: none(JsonRpcError)
  )

proc newJsonRpcErrorResponse*(id: string, code: int, message: string, data: JsonNode = nil): JsonRpcResponse =
  result = JsonRpcResponse(
    jsonrpc: "2.0",
    id: id,
    result: none(JsonNode),
    error: some(JsonRpcError(
      code: code,
      message: message,
      data: if data.isNil: newJNull() else: data
    ))
  )

proc newJsonRpcNotification*(method: string, params: JsonNode): JsonRpcNotification =
  result = JsonRpcNotification(
    jsonrpc: "2.0",
    method: method,
    params: params
  )
