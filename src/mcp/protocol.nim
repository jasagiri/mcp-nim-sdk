## Protocol implementation for the Model Context Protocol (MCP).
##
## This module defines the core message types and protocol operations for MCP.

import json
import options
import strformat
import tables
import asyncdispatch
import types
import ../protocol/version as protocolVersion

export protocolVersion

type
  RequestType* = enum
    ## Types of requests in the MCP protocol
    Initialize,
    ListResources,
    ReadResource,
    ListTools,
    CallTool,
    CreateMessage

  ServerMetadata* = types.ServerMetadata

  MCPVersion* = McpProtocolVersion

  RequestMessage* = object
    ## Base request message structure
    id*: string
    methodName*: string
    params*: JsonNode

  NotificationMessage* = object
    ## Base notification message structure
    methodName*: string
    params*: JsonNode

  ResponseMessage* = object
    ## Base response message structure
    id*: string
    result*: Option[JsonNode]
    error*: Option[ErrorInfo]

  ErrorInfo* = object
    ## Error information for responses
    code*: int
    message*: string
    data*: Option[JsonNode]

  HandlerCallback* = proc(request: RequestMessage): Future[ResponseMessage] {.gcsafe.}
  NotificationCallback* = proc(notification: NotificationMessage): Future[void] {.gcsafe.}

  Protocol* = ref object
    ## Main protocol object for handling MCP messages
    version*: MCPVersion
    supportedVersions*: seq[MCPVersion]
    activeRequestHandlers*: Table[string, HandlerCallback]
    activeNotificationHandlers*: Table[string, NotificationCallback]

const
  CURRENT_VERSION* = DefaultProtocolVersion  ## The newest version this build speaks
  VERSION_20241105* = mpv20241105
  VERSION_20250326* = mpv20250326
  VERSION_20250618* = mpv20250618
  VERSION_20251125* = mpv20251125
  VERSION_20260728* = mpv20260728

  # Standard JSON-RPC error codes
  ERR_PARSE* = -32700          ## Parse error
  ERR_INVALID_REQUEST* = -32600 ## Invalid request
  ERR_METHOD_NOT_FOUND* = -32601 ## Method not found
  ERR_INVALID_PARAMS* = -32602 ## Invalid params
  ERR_INTERNAL* = -32603       ## Internal error
  ERR_UNSUPPORTED_PROTOCOL_VERSION* = -32022 ## Unsupported protocol version

proc createVersion*(versionStr: string): MCPVersion =
  ## Parse a released protocol version string such as "2025-06-18".
  let parsed = parseProtocolVersion(versionStr)
  if parsed.isNone:
    raise newException(ValueError, "Unknown protocol version: " & versionStr)
  parsed.get

proc activateVersion*(p: Protocol, version: MCPVersion) =
  ## Switch the protocol to one of its supported versions.
  if version notin p.supportedVersions:
    raise newException(ValueError, "Unsupported protocol version: " & $version)
  p.version = version

proc newProtocol*(version: MCPVersion, supportedVersions: seq[MCPVersion]): Protocol =
  ## Create a Protocol that speaks exactly `supportedVersions`.
  for supported in supportedVersions:
    requireSupported(supported)
  result = Protocol(
    version: version,
    supportedVersions: supportedVersions,
    activeRequestHandlers: initTable[string, HandlerCallback](),
    activeNotificationHandlers: initTable[string, NotificationCallback]()
  )
  activateVersion(result, version)

proc newProtocol*(version = CURRENT_VERSION): Protocol =
  ## Create a Protocol that speaks `version` and every earlier version.
  newProtocol(version, versionsUpTo(version))

proc setRequestHandler*(p: Protocol, methodName: string, handler: HandlerCallback) =
  ## Register a handler for a request method
  p.activeRequestHandlers[methodName] = handler

proc setNotificationHandler*(p: Protocol, methodName: string, handler: NotificationCallback) =
  ## Register a handler for a notification method
  p.activeNotificationHandlers[methodName] = handler

proc handleInitializeRequest*(p: Protocol, request: RequestMessage): Future[ResponseMessage] {.async, gcsafe.}

proc handleRequest*(p: Protocol, request: RequestMessage): Future[ResponseMessage] {.async, gcsafe.} =
  ## Process an incoming request and route it to the appropriate handler
  if request.methodName == "initialize":
    # Special handling for initialize to support version negotiation.
    # `handleInitializeRequest` is async because it awaits a registered
    # async initialize handler (audit #8): nesting `waitFor` from a sync
    # proc inside an async caller would assert / deadlock the dispatcher.
    return await p.handleInitializeRequest(request)

  if request.methodName in p.activeRequestHandlers:
    return await p.activeRequestHandlers[request.methodName](request)
  else:
    return ResponseMessage(
      id: request.id,
      result: none(JsonNode),
      error: some(ErrorInfo(
        code: ERR_METHOD_NOT_FOUND,
        message: fmt"Method '{request.methodName}' not found",
        data: none(JsonNode)
      ))
    )

proc handleInitializeRequest*(p: Protocol, request: RequestMessage): Future[ResponseMessage] {.async, gcsafe.} =
  ## Handle initialize request with version negotiation
  let params = request.params
  if params.isNil or params.kind != JObject or
     not params.hasKey("protocolVersion") or
     params["protocolVersion"].kind != JString:
    return ResponseMessage(
      id: request.id,
      result: none(JsonNode),
      error: some(ErrorInfo(
        code: ERR_INVALID_PARAMS,
        message: "initialize requires a string protocolVersion",
        data: none(JsonNode)
      ))
    )

  let requested = params["protocolVersion"].getStr()
  let negotiated = negotiateLegacyVersion(requested, p.supportedVersions)
  if negotiated.isNone:
    var supported = newJArray()
    for v in p.supportedVersions:
      supported.add %($v)
    return ResponseMessage(
      id: request.id,
      result: none(JsonNode),
      error: some(ErrorInfo(
        code: ERR_UNSUPPORTED_PROTOCOL_VERSION,
        message: "Unsupported protocol version",
        data: some(%*{"supported": supported, "requested": requested})
      ))
    )

  p.activateVersion(negotiated.get)

  # Call the actual initialize handler if it exists. Use `await` (not the
  # original `waitFor`) so we cooperate with whatever async dispatcher the
  # caller is running on instead of trying to drive a nested event loop.
  if "initialize" in p.activeRequestHandlers:
    var response = await p.activeRequestHandlers["initialize"](request)
    if response.result.isSome:
      let resultObj = response.result.get()
      resultObj["protocolVersion"] = %($p.version)
      response.result = some(resultObj)
    return response
  else:
    return ResponseMessage(
      id: request.id,
      result: some(%*{"success": true, "protocolVersion": $p.version}),
      error: none(ErrorInfo)
    )

proc handleNotification*(p: Protocol, notification: NotificationMessage): Future[void] {.async, gcsafe.} =
  ## Process an incoming notification and route it to the appropriate handler
  if notification.methodName in p.activeNotificationHandlers:
    await p.activeNotificationHandlers[notification.methodName](notification)

proc createRequest*(methodName: string, params: JsonNode, id: string): RequestMessage =
  ## Create a new request message
  return RequestMessage(
    id: id,
    methodName: methodName,
    params: params
  )

proc createNotification*(methodName: string, params: JsonNode): NotificationMessage =
  ## Create a new notification message
  return NotificationMessage(
    methodName: methodName,
    params: params
  )

proc createErrorResponse*(requestId: string, code: int, message: string, data: Option[JsonNode] = none(JsonNode)): ResponseMessage =
  ## Create an error response
  return ResponseMessage(
    id: requestId,
    result: none(JsonNode),
    error: some(ErrorInfo(
      code: code,
      message: message,
      data: data
    ))
  )

proc createSuccessResponse*(requestId: string, res: JsonNode): ResponseMessage =
  ## Create a success response
  return ResponseMessage(
    id: requestId,
    result: some(res),
    error: none(ErrorInfo)
  )

type
  JsonRpcMessageType* = enum
    ## Types of JSON-RPC messages
    Unknown, RequestMsg, NotificationMsg, ResponseMsg

# Helper structure to determine message type
type JsonRpcMessage = object
  isRequest: bool
  isNotification: bool
  isResponse: bool
  msg: JsonNode

proc parseJsonRpc*(jsonStr: string): JsonRpcMessage =
  ## Parse JSON-RPC message and determine its type
  let jsonNode = parseJson(jsonStr)
  
  if not jsonNode.hasKey("jsonrpc") or jsonNode["jsonrpc"].getStr() != "2.0":
    raise newException(ValueError, "Invalid JSON-RPC message: missing or invalid jsonrpc version")
  
  result.msg = jsonNode
  result.isRequest = jsonNode.hasKey("id") and jsonNode.hasKey("method")
  result.isNotification = jsonNode.hasKey("method") and not jsonNode.hasKey("id")
  result.isResponse = jsonNode.hasKey("id") and (jsonNode.hasKey("result") or jsonNode.hasKey("error"))

proc parseRequestWithVersion*(jsonStr: string, version: MCPVersion): RequestMessage =
  ## Parse a JSON string into a request message with specific version handling
  let jsonRpc = parseJsonRpc(jsonStr)
  
  if not jsonRpc.isRequest:
    raise newException(ValueError, "Not a valid JSON-RPC request message")
  
  let jsonNode = jsonRpc.msg

  result = RequestMessage(
    id: jsonNode["id"].getStr(),
    methodName: jsonNode["method"].getStr(),
    params: if jsonNode.hasKey("params"): jsonNode["params"] else: newJObject()
  )

proc parseRequest*(jsonStr: string): RequestMessage =
  ## Parse a JSON string into a request message
  return parseRequestWithVersion(jsonStr, CURRENT_VERSION)

proc parseNotificationWithVersion*(jsonStr: string, version: MCPVersion): NotificationMessage =
  ## Parse a JSON string into a notification message with specific version handling
  let jsonRpc = parseJsonRpc(jsonStr)
  
  if not jsonRpc.isNotification:
    raise newException(ValueError, "Not a valid JSON-RPC notification message")
  
  let jsonNode = jsonRpc.msg

  result = NotificationMessage(
    methodName: jsonNode["method"].getStr(),
    params: if jsonNode.hasKey("params"): jsonNode["params"] else: newJObject()
  )

proc parseNotification*(jsonStr: string): NotificationMessage =
  ## Parse a JSON string into a notification message
  return parseNotificationWithVersion(jsonStr, CURRENT_VERSION)

proc parseResponseWithVersion*(jsonStr: string, version: MCPVersion): ResponseMessage =
  ## Parse a JSON string into a response message with specific version handling
  let jsonRpc = parseJsonRpc(jsonStr)
  
  if not jsonRpc.isResponse:
    raise newException(ValueError, "Not a valid JSON-RPC response message")
  
  let jsonNode = jsonRpc.msg
  var response = ResponseMessage(
    id: jsonNode["id"].getStr()
  )
  
  if jsonNode.hasKey("result"):
    response.result = some(jsonNode["result"])
    response.error = none(ErrorInfo)
  elif jsonNode.hasKey("error"):
    let errNode = jsonNode["error"]
    var errInfo = ErrorInfo(
      code: errNode["code"].getInt(),
      message: errNode["message"].getStr()
    )
    if errNode.hasKey("data"):
      errInfo.data = some(errNode["data"])
    else:
      errInfo.data = none(JsonNode)
      
    response.result = none(JsonNode)
    response.error = some(errInfo)
  else:
    response.result = none(JsonNode)
    response.error = none(ErrorInfo)
  
  return response

proc parseResponse*(jsonStr: string): ResponseMessage =
  ## Parse a JSON string into a response message
  return parseResponseWithVersion(jsonStr, CURRENT_VERSION)

proc serializeWithVersion*(msg: RequestMessage, version: MCPVersion): string =
  ## Serialize RequestMessage to JSON string with specific version format
  var jsonObj = %*{
    "jsonrpc": "2.0",
    "id": msg.id,
    "method": msg.methodName,
    "params": msg.params
  }
  
  if msg.methodName == "initialize":
    let params = msg.params
    params["protocolVersion"] = %($version)
    jsonObj["params"] = params
  
  result = $jsonObj

proc serialize*(msg: RequestMessage): string =
  ## Serialize RequestMessage to JSON string using current version
  result = serializeWithVersion(msg, CURRENT_VERSION)

proc serializeWithVersion*(msg: NotificationMessage, version: MCPVersion): string =
  ## Serialize NotificationMessage to JSON string with specific version format
  let jsonObj = %*{
    "jsonrpc": "2.0",
    "method": msg.methodName,
    "params": msg.params
  }

  result = $jsonObj

proc serialize*(msg: NotificationMessage): string =
  ## Serialize NotificationMessage to JSON string using current version
  result = serializeWithVersion(msg, CURRENT_VERSION)

proc serializeWithVersion*(msg: ResponseMessage, version: MCPVersion): string =
  ## Serialize ResponseMessage to JSON string with specific version format
  var jsonObj = %*{
    "jsonrpc": "2.0",
    "id": msg.id
  }
  
  if msg.result.isSome:
    jsonObj["result"] = msg.result.get()
  elif msg.error.isSome:
    let err = msg.error.get()
    var errObj = %*{
      "code": err.code,
      "message": err.message
    }
    if err.data.isSome:
      errObj["data"] = err.data.get()
    jsonObj["error"] = errObj
  
  result = $jsonObj

proc serialize*(msg: ResponseMessage): string =
  ## Serialize ResponseMessage to JSON string using current version
  result = serializeWithVersion(msg, CURRENT_VERSION)

# Server type for high-level API
type
  ToolHandler* = proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.}

  ToolDefinition* = object
    name*: string
    description*: string
    inputSchema*: JsonNode
    handler*: Option[ToolHandler]

  ResourceDefinition* = object
    uri*: string
    name*: string
    description*: string
    mimeType*: string

  Server* = ref object
    ## High-level server object for MCP operations
    name*: string
    version*: string
    capabilities*: types.ServerCapabilities
    protocol*: Protocol
    tools*: Table[string, ToolDefinition]
    resources*: Table[string, ResourceDefinition]
    transport*: RootRef

proc newServer*(metadata: ServerMetadata, capabilities: types.ServerCapabilities): Server =
  ## Creates a new MCP server with the given metadata and capabilities
  result = Server(
    name: metadata.name,
    version: metadata.version,
    capabilities: capabilities,
    protocol: newProtocol(CURRENT_VERSION),
    tools: initTable[string, ToolDefinition](),
    resources: initTable[string, ResourceDefinition]()
  )

proc registerTool*(server: Server, name: string, description: string, inputSchema: JsonNode) =
  ## Registers a tool with the server
  server.tools[name] = ToolDefinition(
    name: name,
    description: description,
    inputSchema: inputSchema,
    handler: none(ToolHandler)
  )

proc registerToolHandler*(server: Server, name: string, handler: ToolHandler) =
  ## Registers a handler for a tool
  if server.tools.hasKey(name):
    var tool = server.tools[name]
    tool.handler = some(handler)
    server.tools[name] = tool
  else:
    server.tools[name] = ToolDefinition(
      name: name,
      description: "",
      inputSchema: newJObject(),
      handler: some(handler)
    )

proc connect*(server: Server, transport: RootRef): Future[void] {.async.} =
  ## Connects the server to a transport
  server.transport = transport
  # Note: transport.start() should be called by the transport layer itself

proc disconnect*(server: Server): Future[void] {.async.} =
  ## Disconnects the server
  server.transport = nil

proc registerResource*(server: Server, uri: string, name: string, description: string, mimeType: string) =
  ## Registers a resource with the server
  server.resources[uri] = ResourceDefinition(
    uri: uri,
    name: name,
    description: description,
    mimeType: mimeType
  )

# Client type for high-level API
type
  ToolResult* = object
    isError*: bool
    content*: seq[JsonNode]

  Client* = ref object
    ## High-level client object for MCP operations
    name*: string
    version*: string
    capabilities*: types.ClientCapabilities
    transport*: RootRef
    serverTools*: seq[types.Tool]

proc newClient*(name: string, version: string, capabilities: types.ClientCapabilities): Client =
  ## Creates a new MCP client
  result = Client(
    name: name,
    version: version,
    capabilities: capabilities,
    serverTools: @[]
  )

proc connect*(client: Client, transport: RootRef): Future[void] {.async.} =
  ## Connects the client to a transport
  client.transport = transport

proc disconnect*(client: Client): Future[void] {.async.} =
  ## Disconnects the client
  client.transport = nil

proc listTools*(client: Client): Future[seq[types.Tool]] {.async.} =
  ## Lists available tools from the server
  # In a real implementation, this would send a request to the server
  # For now, return the cached tools
  return client.serverTools

proc callTool*(client: Client, name: string, arguments: JsonNode): Future[ToolResult] {.async.} =
  ## Calls a tool on the server
  # In a real implementation, this would send a request to the server
  # For now, return a placeholder result
  result = ToolResult(
    isError: false,
    content: @[%*{"text": "placeholder"}]
  )
