## Core MCP protocol types

import json, options
import ./version

export version

type
  # Basic JSON-RPC types
  JsonRpcRequest* = object
    jsonrpc*: string
    id*: string
      ## The id as text; requests and responses are matched on it.
    idNode*: JsonNode
      ## The id as the peer sent it (a string or a number), so that the
      ## response echoes the same JSON type. nil for messages built here.
    `method`*: string
    params*: JsonNode
    session*: string
      ## Which of the transport's connections the request arrived on; empty
      ## for a transport with a single peer. Not part of the wire format.
    paramHeaders*: Option[seq[(string, string)]]
      ## The `Mcp-Param-*` headers the HTTP request carried; none on a
      ## transport without headers. Not part of the wire format.
    relatedRequestId*: string
      ## For a request the server sends while it handles a client request:
      ## the id of that client request, so that an HTTP transport can put it on
      ## the stream that carries the client request's response. Not part of
      ## the wire format.

  JsonRpcResponse* = object
    jsonrpc*: string
    id*: string
    idNode*: JsonNode
    result*: Option[JsonNode]
    error*: Option[JsonRpcError]

  JsonRpcNotification* = object
    jsonrpc*: string
    `method`*: string
    params*: JsonNode
    session*: string
      ## The connection a received notification arrived on; for one that is
      ## sent, the connection it is addressed to. Not part of the wire format.
    relatedRequestId*: string
      ## For a request-scoped notification (progress, log message): the id of
      ## the client request it belongs to. Not part of the wire format.

  JsonRpcError* = object
    code*: int
    message*: string
    data*: JsonNode

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
    completions*: Option[McpCompletionsCapability]
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

  McpCompletionsCapability* = object
    # Currently empty in the protocol

  # Icons (2025-11-25 and later) on implementations, tools, resources,
  # resource templates, prompts and resource links
  McpIconTheme* = enum
    itLight = "light"
    itDark = "dark"

  McpIcon* = object
    src*: string
      ## An https URL or a base64 `data:` URI. A consumer MUST NOT fetch or
      ## show one it has not screened (client/content.nim `safeIcons`).
    mimeType*: Option[string]
    sizes*: seq[string]
      ## `["48x48"]`, `["any"]` for a scalable format.
    theme*: Option[McpIconTheme]
      ## The background the icon is meant for.

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
proc newJsonRpcRequest*(id: string, methodName: string, params: JsonNode): JsonRpcRequest =
  result = JsonRpcRequest(
    jsonrpc: "2.0",
    id: id,
    `method`: methodName,
    params: params
  )

proc newJsonRpcResponse*(id: string, resultData: JsonNode): JsonRpcResponse =
  result = JsonRpcResponse(
    jsonrpc: "2.0",
    id: id,
    result: some(resultData),
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

proc newJsonRpcNotification*(methodName: string, params: JsonNode): JsonRpcNotification =
  result = JsonRpcNotification(
    jsonrpc: "2.0",
    `method`: methodName,
    params: params
  )
