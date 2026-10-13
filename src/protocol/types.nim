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
    principal*: Option[string]
      ## Who the transport's authorization says sent the request (the subject
      ## of the access token); none without authorization. Not part of the
      ## wire format.
    peer*: string
      ## The network address the request came from, for a transport that has
      ## one (Streamable HTTP, HTTP+SSE); empty otherwise. Not part of the
      ## wire format.
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
    elicitation*: Option[McpElicitationCapability]
    tasks*: Option[McpTasksCapability]
    experimental*: Option[JsonNode]
    extensions*: Option[JsonNode]
      ## 2026-07-28: extension identifier -> settings object.

  McpServerCapabilities* = object
    prompts*: Option[McpPromptsCapability]
    resources*: Option[McpResourcesCapability]
    tools*: Option[McpToolsCapability]
    logging*: Option[McpLoggingCapability]
    completions*: Option[McpCompletionsCapability]
    tasks*: Option[McpTasksCapability]
    experimental*: Option[JsonNode]
    extensions*: Option[JsonNode]
      ## 2026-07-28: extension identifier -> settings object.
    additional*: Option[JsonNode]
      ## Top-level capabilities the core does not define, name -> settings
      ## object: what a specification outside the core (a draft that names
      ## its own capability) asks a server to declare. Sent and read for
      ## 2026-07-28 only; none for a server that registered nothing, and then
      ## nothing is added to the wire form.

  McpTasksCapability* = object
    ## 2025-11-25: which task operations a party supports and which of its
    ## requests may be augmented with a task. The set of `requests` is
    ## exhaustive: a request type that is not here does not support tasks.
    list*: bool
    cancel*: bool
    toolsCall*: bool
      ## Server: `requests.tools.call`.
    samplingCreateMessage*: bool
      ## Client: `requests.sampling.createMessage`.
    elicitationCreate*: bool
      ## Client: `requests.elicitation.create`.

  McpRootsCapability* = object
    listChanged*: bool

  McpSamplingCapability* = object
    tools*: bool
      ## 2025-11-25: the client accepts `tools` and `toolChoice` in
      ## sampling/createMessage.
    context*: bool
      ## 2025-11-25: the client honours includeContext "thisServer" and
      ## "allServers".

  McpElicitationCapability* = object
    ## `elicitation: {}` on the wire means form mode only; that is `form`
    ## here, so an object of this type always names at least one mode.
    form*: bool
    url*: bool
      ## 2025-11-25: URL mode.

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
    ## An `Implementation`: name and version are always sent; the rest only
    ## to a protocol version that has the field (title: 2025-06-18;
    ## description, websiteUrl, icons: 2025-11-25).
    name*: string
    version*: string
    title*: Option[string]
    description*: Option[string]
    websiteUrl*: Option[string]
    icons*: seq[McpIcon]

  McpServerInfo* = object
    ## The same fields, for the server.
    name*: string
    version*: string
    title*: Option[string]
    description*: Option[string]
    websiteUrl*: Option[string]
    icons*: seq[McpIcon]

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
