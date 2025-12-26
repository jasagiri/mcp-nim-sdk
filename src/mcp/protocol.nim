## Protocol implementation for the Model Context Protocol (MCP).
##
## This module defines the core message types and protocol operations for MCP.

import json
import options
import strformat
import tables
import asyncdispatch
import strutils
import types

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

  MCPVersionSpec* = enum
    ## Supported MCP protocol versions
    VersionSemver, ## 2024-11-05 version (semantic versioning)
    VersionDate    ## 2025-03-26 version (date-based versioning)

  MCPVersion* = object
    ## MCP protocol version
    case kind*: MCPVersionSpec
    of VersionSemver:
      major*: int
      minor*: int
      patch*: int
    of VersionDate:
      version*: string  # Format: YYYY-MM-DD (e.g., "2025-03-26")

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

  HandlerCallback* = proc(request: RequestMessage): ResponseMessage {.gcsafe.}
  NotificationCallback* = proc(notification: NotificationMessage) {.gcsafe.}

  ProtocolMethods* = object
    ## Protocol methods for a specific version
    requestHandlers*: Table[string, HandlerCallback]
    notificationHandlers*: Table[string, NotificationCallback]
    
  Protocol* = ref object
    ## Main protocol object for handling MCP messages
    version*: MCPVersion
    supportedVersions*: seq[MCPVersion]
    versionMethods*: Table[MCPVersionSpec, ProtocolMethods]
    activeRequestHandlers*: Table[string, HandlerCallback]
    activeNotificationHandlers*: Table[string, NotificationCallback]

const
  CURRENT_VERSION* = MCPVersion(kind: VersionDate, version: "2025-11-25")  ## Current protocol version (2025-11-25)
  VERSION_20241105* = MCPVersion(kind: VersionSemver, major: 1, minor: 0, patch: 0)  ## Earlier version (2024-11-05)
  VERSION_20250326* = MCPVersion(kind: VersionDate, version: "2025-03-26")  ## Version 2025-03-26
  VERSION_20250618* = MCPVersion(kind: VersionDate, version: "2025-06-18")  ## Version 2025-06-18
  VERSION_20251125* = MCPVersion(kind: VersionDate, version: "2025-11-25")  ## Version 2025-11-25 (latest)

  # Standard JSON-RPC error codes
  ERR_PARSE* = -32700          ## Parse error
  ERR_INVALID_REQUEST* = -32600 ## Invalid request
  ERR_METHOD_NOT_FOUND* = -32601 ## Method not found
  ERR_INVALID_PARAMS* = -32602 ## Invalid params
  ERR_INTERNAL* = -32603       ## Internal error

proc createVersion*(versionStr: string): MCPVersion =
  ## Create MCPVersion from string (auto-detects format)
  if versionStr.find('-') >= 0:
    # YYYY-MM-DD format
    return MCPVersion(kind: VersionDate, version: versionStr)
  else:
    # Semantic version format (major.minor.patch)
    let parts = versionStr.split('.')
    if parts.len >= 3:
      return MCPVersion(
        kind: VersionSemver, 
        major: parseInt(parts[0]), 
        minor: parseInt(parts[1]), 
        patch: parseInt(parts[2])
      )
    else:
      raise newException(ValueError, "Invalid version format: " & versionStr)

proc activateVersion*(p: Protocol, version: MCPVersion) =
  ## Activate handlers for a specific version
  if version.kind notin p.versionMethods:
    raise newException(ValueError, "Unsupported protocol version: " & $version)
  
  p.version = version
  p.activeRequestHandlers = p.versionMethods[version.kind].requestHandlers
  p.activeNotificationHandlers = p.versionMethods[version.kind].notificationHandlers

proc newProtocol*(version = CURRENT_VERSION, supportedVersions: seq[MCPVersion] = @[CURRENT_VERSION, VERSION_20250618, VERSION_20250326, VERSION_20241105]): Protocol =
  ## Create a new Protocol instance
  # Initialize with empty tables
  var versionMethodsTable = initTable[MCPVersionSpec, ProtocolMethods]()
  
  # Initialize protocol methods for each supported version
  for sv in supportedVersions:
    versionMethodsTable[sv.kind] = ProtocolMethods(
      requestHandlers: initTable[string, HandlerCallback](),
      notificationHandlers: initTable[string, NotificationCallback]()
    )
  
  result = Protocol(
    version: version,
    supportedVersions: supportedVersions,
    versionMethods: versionMethodsTable,
    activeRequestHandlers: initTable[string, HandlerCallback](),
    activeNotificationHandlers: initTable[string, NotificationCallback]()
  )
  
  # Activate the current version
  activateVersion(result, version)

proc setRequestHandler*(p: Protocol, methodName: string, handler: HandlerCallback, versionSpec: MCPVersionSpec) =
  ## Register a handler for a specific request method and version
  if versionSpec notin p.versionMethods:
    raise newException(ValueError, "Unsupported protocol version: " & $versionSpec)
    
  p.versionMethods[versionSpec].requestHandlers[methodName] = handler
  
  # Update active handlers if this is for the current version
  if p.version.kind == versionSpec:
    p.activeRequestHandlers[methodName] = handler

proc setRequestHandler*(p: Protocol, methodName: string, handler: HandlerCallback) =
  ## Register a handler for a specific request method (for all supported versions)
  for versionSpec in p.versionMethods.keys:
    p.setRequestHandler(methodName, handler, versionSpec)

proc setNotificationHandler*(p: Protocol, methodName: string, handler: NotificationCallback, versionSpec: MCPVersionSpec) =
  ## Register a handler for a specific notification method and version
  if versionSpec notin p.versionMethods:
    raise newException(ValueError, "Unsupported protocol version: " & $versionSpec)
    
  p.versionMethods[versionSpec].notificationHandlers[methodName] = handler
  
  # Update active handlers if this is for the current version
  if p.version.kind == versionSpec:
    p.activeNotificationHandlers[methodName] = handler

proc setNotificationHandler*(p: Protocol, methodName: string, handler: NotificationCallback) =
  ## Register a handler for a specific notification method (for all supported versions)
  for versionSpec in p.versionMethods.keys:
    p.setNotificationHandler(methodName, handler, versionSpec)

proc handleInitializeRequest*(p: Protocol, request: RequestMessage): ResponseMessage {.gcsafe.}

proc handleRequest*(p: Protocol, request: RequestMessage): ResponseMessage {.gcsafe.} =
  ## Process an incoming request and route it to the appropriate handler
  if request.methodName == "initialize":
    # Special handling for initialize to support version negotiation
    return p.handleInitializeRequest(request)
    
  if request.methodName in p.activeRequestHandlers:
    return p.activeRequestHandlers[request.methodName](request)
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

proc handleInitializeRequest*(p: Protocol, request: RequestMessage): ResponseMessage {.gcsafe.} =
  ## Handle initialize request with version negotiation
  let params = request.params
  var clientVersion: MCPVersion
  
  # Extract client version from params
  if params.hasKey("protocolVersion"):
    let versionNode = params["protocolVersion"]
    if versionNode.kind == JString:
      # YYYY-MM-DD format (2025-03-26)
      clientVersion = createVersion(versionNode.getStr())
    elif versionNode.kind == JObject:
      # Semantic version format (2024-11-05)
      if versionNode.hasKey("major") and versionNode.hasKey("minor") and versionNode.hasKey("patch"):
        clientVersion = MCPVersion(
          kind: VersionSemver,
          major: versionNode["major"].getInt(),
          minor: versionNode["minor"].getInt(),
          patch: versionNode["patch"].getInt()
        )
      else:
        # Malformed version object
        return ResponseMessage(
          id: request.id,
          result: none(JsonNode),
          error: some(ErrorInfo(
            code: ERR_INVALID_PARAMS,
            message: "Invalid protocol version format",
            data: none(JsonNode)
          ))
        )
    else:
      # Unsupported version format
      return ResponseMessage(
        id: request.id,
        result: none(JsonNode),
        error: some(ErrorInfo(
          code: ERR_INVALID_PARAMS,
          message: "Invalid protocol version format",
          data: none(JsonNode)
        ))
      )
  else:
    # Client didn't specify version, assume oldest supported
    clientVersion = p.supportedVersions[p.supportedVersions.len - 1]
  
  # Negotiate version - find highest compatible version
  var negotiatedVersion = clientVersion
  for serverVer in p.supportedVersions:
    # Compare versions of same kind only
    if serverVer.kind == clientVersion.kind:
      # Check if server version is greater than or equal to client version
      if (serverVer.kind == VersionDate and serverVer.version >= clientVersion.version) or
         (serverVer.kind == VersionSemver and 
          (serverVer.major > clientVersion.major or 
           (serverVer.major == clientVersion.major and serverVer.minor > clientVersion.minor) or
           (serverVer.major == clientVersion.major and serverVer.minor == clientVersion.minor and serverVer.patch >= clientVersion.patch))):
        negotiatedVersion = serverVer
        break
  
  # Activate the negotiated version
  p.activateVersion(negotiatedVersion)
  
  # Call the actual initialize handler if it exists
  if "initialize" in p.activeRequestHandlers:
    var result = p.activeRequestHandlers["initialize"](request)
    # Ensure the response includes the negotiated version
    if result.result.isSome:
      var resultObj = result.result.get()
      
      # Add version information based on protocol version
      case p.version.kind:
      of VersionDate:
        resultObj["protocolVersion"] = %p.version.version
      of VersionSemver:
        resultObj["protocolVersion"] = %*{
          "major": p.version.major,
          "minor": p.version.minor,
          "patch": p.version.patch
        }
      
      result.result = some(resultObj)
    return result
  else:
    # No initialize handler registered, create a default response
    var resultObj = %*{"success": true}
    
    # Add version information based on protocol version
    case p.version.kind:
    of VersionDate:
      resultObj["protocolVersion"] = %p.version.version
    of VersionSemver:
      resultObj["protocolVersion"] = %*{
        "major": p.version.major,
        "minor": p.version.minor,
        "patch": p.version.patch
      }
    
    return ResponseMessage(
      id: request.id,
      result: some(resultObj),
      error: none(ErrorInfo)
    )

proc handleRequestAsync*(p: Protocol, request: RequestMessage): Future[ResponseMessage] {.async, gcsafe.} =
  ## Async version of handleRequest
  return p.handleRequest(request)

proc handleNotification*(p: Protocol, notification: NotificationMessage) {.gcsafe.} =
  ## Process an incoming notification and route it to the appropriate handler
  if notification.methodName in p.activeNotificationHandlers:
    p.activeNotificationHandlers[notification.methodName](notification)

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
  var methodName = jsonNode["method"].getStr()
  
  # Version-specific adjustments
  case version.kind:
  of VersionDate:
    # 2025-03-26 specific adjustments (if any)
    discard
  of VersionSemver:
    # 2024-11-05 specific adjustments (if any)
    discard
  
  result = RequestMessage(
    id: jsonNode["id"].getStr(),
    methodName: methodName,
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
  var methodName = jsonNode["method"].getStr()
  
  # Handle version-specific method name translations
  case version.kind:
  of VersionDate:
    # Handle 2025-03-26 specific method names
    if methodName == "$/initialized":
      methodName = "initialized"
  of VersionSemver:
    # Handle 2024-11-05 specific method names (if any)
    discard
  
  result = NotificationMessage(
    methodName: methodName,
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
    var resultNode = jsonNode["result"]
    
    # Version-specific result handling
    if resultNode.kind == JObject and resultNode.hasKey("protocolVersion"):
      let versionNode = resultNode["protocolVersion"]
      
      # Process protocol version based on format
      case version.kind:
      of VersionDate:
        # No transformation needed for string format
        discard
      of VersionSemver:
        # Transform semantic version if needed
        discard
    
    response.result = some(resultNode)
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

proc `$`*(ver: MCPVersion): string =
  ## Convert version to string
  case ver.kind:
  of VersionDate:
    return ver.version
  of VersionSemver:
    return $ver.major & "." & $ver.minor & "." & $ver.patch

proc isLaterThan*(a, b: MCPVersion): bool

proc isEqualTo*(a, b: MCPVersion): bool

proc isLaterThan*(a, b: MCPVersion): bool =
  ## Check if version a is later than version b
  if a.kind == b.kind:
    case a.kind:
    of VersionDate:
      return a.version > b.version
    of VersionSemver:
      if a.major != b.major:
        return a.major > b.major
      if a.minor != b.minor:
        return a.minor > b.minor
      return a.patch > b.patch
  else:
    # Different version types - date-based is considered newer than semver
    return a.kind == VersionDate

proc isEqualTo*(a, b: MCPVersion): bool =
  ## Check if versions are equal
  if a.kind != b.kind:
    return false
    
  case a.kind:
  of VersionDate:
    return a.version == b.version
  of VersionSemver:
    return a.major == b.major and a.minor == b.minor and a.patch == b.patch

proc `<`*(a, b: MCPVersion): bool =
  ## Version less than operator
  return not isEqualTo(a, b) and not isLaterThan(a, b)

proc `<=`*(a, b: MCPVersion): bool =
  ## Version less than or equal operator
  return isEqualTo(a, b) or not isLaterThan(a, b)

proc `>`*(a, b: MCPVersion): bool =
  ## Version greater than operator
  return isLaterThan(a, b)

proc `>=`*(a, b: MCPVersion): bool =
  ## Version greater than or equal operator
  return isEqualTo(a, b) or isLaterThan(a, b)

proc `==`*(a, b: MCPVersion): bool =
  ## Version equality operator
  return isEqualTo(a, b)

proc serializeWithVersion*(msg: RequestMessage, version: MCPVersion): string =
  ## Serialize RequestMessage to JSON string with specific version format
  var jsonObj = %*{
    "jsonrpc": "2.0",
    "id": msg.id,
    "method": msg.methodName,
    "params": msg.params
  }
  
  # Modify specific messages according to version
  if msg.methodName == "initialize":
    var params = msg.params
    case version.kind:
    of VersionDate:
      params["protocolVersion"] = %version.version
    of VersionSemver:
      params["protocolVersion"] = %*{
        "major": version.major,
        "minor": version.minor,
        "patch": version.patch
      }
    jsonObj["params"] = params
  
  result = $jsonObj

proc serialize*(msg: RequestMessage): string =
  ## Serialize RequestMessage to JSON string using current version
  result = serializeWithVersion(msg, CURRENT_VERSION)

proc serializeWithVersion*(msg: NotificationMessage, version: MCPVersion): string =
  ## Serialize NotificationMessage to JSON string with specific version format
  var jsonObj = %*{
    "jsonrpc": "2.0",
    "method": msg.methodName,
    "params": msg.params
  }
  
  # Version-specific modifications for notifications
  if msg.methodName == "initialized":
    case version.kind:
    of VersionDate:
      # 2025-03-26 spec uses "$/initialized" method name
      jsonObj["method"] = %"$/initialized"
    of VersionSemver:
      # 2024-11-05 spec uses "initialized" method name
      jsonObj["method"] = %"initialized"
  
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
