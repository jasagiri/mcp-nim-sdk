## MCP client implementation

import asyncdispatch, json, options, tables, strutils, uuids
import ../protocol/types
import ../protocol/lifecycle
import ../transport/transport
import ../transport/stdio
import ../transport/http
import ../mcp/types as mcpTypes

type
  McpClient* = ref object
    transport*: McpTransport
    state*: McpLifecycleState
    protocolVersion*: McpProtocolVersion
    clientInfo*: McpClientInfo
    capabilities*: McpClientCapabilities
    serverCapabilities*: Option[McpServerCapabilities]
    pendingRequests*: Table[string, Future[JsonRpcResponse]]
    requestHandlers*: Table[string, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}]
    notificationHandlers*: Table[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]

proc newMcpClient*(
  clientInfo: McpClientInfo,
  protocolVersion: McpProtocolVersion = mpv20250326,
  capabilities: McpClientCapabilities = McpClientCapabilities()
): McpClient =
  result = McpClient(
    state: mlsUninitialized,
    protocolVersion: protocolVersion,
    clientInfo: clientInfo,
    capabilities: capabilities,
    serverCapabilities: none(McpServerCapabilities),
    pendingRequests: initTable[string, Future[JsonRpcResponse]](),
    requestHandlers: initTable[string, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}](),
    notificationHandlers: initTable[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]()
  )

proc registerRequestHandler*(client: McpClient, methodName: string,
    handler: proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}) =
  client.requestHandlers[methodName] = handler

proc registerNotificationHandler*(client: McpClient, methodName: string,
    handler: proc(notification: JsonRpcNotification): Future[void] {.async.}) =
  client.notificationHandlers[methodName] = handler

proc processRequest(client: McpClient, request: JsonRpcRequest): Future[void] {.async.} =
  if request.`method` in client.requestHandlers:
    let handler = client.requestHandlers[request.`method`]
    let response = await handler(request)
    await client.transport.sendResponse(response)
  else:
    # Unknown method
    let response = newJsonRpcErrorResponse(
      request.id,
      -32601,
      "Method not found: " & request.`method`
    )
    await client.transport.sendResponse(response)

proc processNotification(client: McpClient, notification: JsonRpcNotification): Future[void] {.async.} =
  if notification.`method` in client.notificationHandlers:
    let handler = client.notificationHandlers[notification.`method`]
    await handler(notification)
  # If no handler, silently ignore

proc processResponse(client: McpClient, response: JsonRpcResponse): Future[void] {.async.} =
  if response.id in client.pendingRequests:
    let promise = client.pendingRequests[response.id]
    promise.complete(response)
    client.pendingRequests.del(response.id)
  # If no pending request, silently ignore

proc processMessages*(client: McpClient): Future[void] {.async.} =
  try:
    while true:
      let json = await client.transport.receiveMessage()

      if isRequest(json):
        let request = decodeRequest(json)
        asyncCheck client.processRequest(request)
      elif isResponse(json):
        let response = decodeResponse(json)
        asyncCheck client.processResponse(response)
      elif isNotification(json):
        let notification = decodeNotification(json)
        asyncCheck client.processNotification(notification)
      else:
        echo "Invalid message received: ", json
  except:
    let e = getCurrentException()
    echo "Error processing messages: ", e.msg

proc sendRequest*(client: McpClient, methodName: string, params: JsonNode): Future[JsonRpcResponse] {.async.} =
  let id = $genUUID()
  let request = newJsonRpcRequest(id, methodName, params)

  var promise = newFuture[JsonRpcResponse]("sendRequest")
  client.pendingRequests[id] = promise

  await client.transport.sendRequest(request)
  return await promise

proc sendNotification*(client: McpClient, methodName: string, params: JsonNode): Future[void] {.async.} =
  let notification = newJsonRpcNotification(methodName, params)
  await client.transport.sendNotification(notification)

proc extractServerCapabilities(json: JsonNode): McpServerCapabilities =
  result = McpServerCapabilities()

  if json.hasKey("prompts"):
    let promptsJson = json["prompts"]
    result.prompts = some(McpPromptsCapability(
      listChanged: promptsJson.hasKey("listChanged") and promptsJson["listChanged"].getBool()
    ))

  if json.hasKey("resources"):
    let resourcesJson = json["resources"]
    result.resources = some(McpResourcesCapability(
      subscribe: resourcesJson.hasKey("subscribe") and resourcesJson["subscribe"].getBool(),
      listChanged: resourcesJson.hasKey("listChanged") and resourcesJson["listChanged"].getBool()
    ))

  if json.hasKey("tools"):
    let toolsJson = json["tools"]
    result.tools = some(McpToolsCapability(
      listChanged: toolsJson.hasKey("listChanged") and toolsJson["listChanged"].getBool()
    ))

  if json.hasKey("logging"):
    result.logging = some(McpLoggingCapability())

  if json.hasKey("experimental"):
    result.experimental = some(json["experimental"])

proc initialize*(client: McpClient): Future[McpServerCapabilities] {.async.} =
  if client.state != mlsUninitialized:
    raise newException(ValueError, "Client already initialized")

  let request = createInitializeRequest(
    client.clientInfo,
    client.protocolVersion,
    client.capabilities
  )

  let response = await client.sendRequest("initialize", request.params)

  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Initialization failed: " & error.message)

  let resultData = response.result.get

  # Check protocol version compatibility
  let serverProtocolVersion = parseEnum[McpProtocolVersion](
    resultData["protocolVersion"].getStr()
  )

  if serverProtocolVersion != client.protocolVersion:
    echo "Protocol version mismatch: client=", client.protocolVersion,
      " server=", serverProtocolVersion

    # Accept server's protocol version
    client.protocolVersion = serverProtocolVersion

  # Extract server capabilities
  let capabilities = extractServerCapabilities(resultData["capabilities"])
  client.serverCapabilities = some(capabilities)

  # Change state
  client.state = mlsInitializing

  # Send initialized notification
  await client.sendNotification("notifications/initialized", newJObject())

  # Change state
  client.state = mlsOperational

  return capabilities

proc connect*(client: McpClient, transport: McpTransport): Future[void] {.async.} =
  client.transport = transport

  # Start message processing
  asyncCheck client.processMessages()

  # Initialize the client
  discard await client.initialize()

proc close*(client: McpClient): Future[void] {.async.} =
  # Change state
  client.state = mlsShutdown

  # Close transport
  await client.transport.close()

# High-level Client interface for easier usage
type
  Client* = ref object
    ## High-level client object for MCP operations
    name*: string
    version*: string
    capabilities*: mcpTypes.ClientCapabilities
    transport*: McpTransport
    serverInfo*: Option[mcpTypes.ServerMetadata]
    isInitialized*: bool
    mcpClient*: McpClient

proc newClient*(name: string, version: string, capabilities: mcpTypes.ClientCapabilities): Client =
  ## Creates a new high-level MCP client
  let clientInfo = McpClientInfo(
    name: name,
    version: version
  )
  # Convert mcpTypes.ClientCapabilities to McpClientCapabilities
  var mcpCaps = McpClientCapabilities()
  if capabilities.roots.isSome and capabilities.roots.get:
    mcpCaps.roots = some(McpRootsCapability(listChanged: false))
  if capabilities.sampling.isSome and capabilities.sampling.get:
    mcpCaps.sampling = some(McpSamplingCapability())
  if capabilities.experimental.isSome:
    mcpCaps.experimental = capabilities.experimental

  result = Client(
    name: name,
    version: version,
    capabilities: capabilities,
    transport: nil,
    serverInfo: none(mcpTypes.ServerMetadata),
    isInitialized: false,
    mcpClient: newMcpClient(clientInfo, capabilities = mcpCaps)
  )
