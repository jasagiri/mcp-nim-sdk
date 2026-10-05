## MCP client implementation

import asyncdispatch, json, options, tables, strutils, uuids
import ../protocol/types
import ../protocol/lifecycle
import ../transport/transport
import ../mcp/types as mcpTypes

type
  McpClient* = ref object
    transport*: McpTransport
    state*: McpLifecycleState
    protocolVersion*: McpProtocolVersion
      ## The newest version this client speaks; it also speaks every
      ## earlier one.
    negotiatedVersion*: Option[McpProtocolVersion]
      ## The version in use with the connected server.
    clientInfo*: McpClientInfo
    capabilities*: McpClientCapabilities
    serverCapabilities*: Option[McpServerCapabilities]
    pendingRequests*: Table[string, Future[JsonRpcResponse]]
    requestHandlers*: Table[string, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}]
    notificationHandlers*: Table[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]
    lastTransportError*: ref CatchableError
      ## Set when the message-processing loop terminates due to a transport
      ## error. Mirrors McpServer.lastTransportError — see audit finding #5.

proc newMcpClient*(
  clientInfo: McpClientInfo,
  protocolVersion: McpProtocolVersion = DefaultProtocolVersion,
  capabilities: McpClientCapabilities = McpClientCapabilities()
): McpClient =
  requireSupported(protocolVersion)
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
  ## Run the receive loop until the transport raises. On termination, the
  ## raising error is stored on `client.lastTransportError` so callers can
  ## diagnose the silent-dead condition. Defects propagate.
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
        stderr.writeLine("[mcp-client] invalid message received: " & $json)
  except CatchableError as e:
    client.lastTransportError = e
    stderr.writeLine("[mcp-client] transport loop ended with " &
                      $e.name & ": " & e.msg)

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

  # A peer that sends null for a capability has not declared it.
  proc declared(name: string): JsonNode =
    let node = json{name}
    if not node.isNil and node.kind == JObject: node else: nil

  let promptsJson = declared("prompts")
  if not promptsJson.isNil:
    result.prompts = some(McpPromptsCapability(
      listChanged: promptsJson{"listChanged"}.getBool()
    ))

  let resourcesJson = declared("resources")
  if not resourcesJson.isNil:
    result.resources = some(McpResourcesCapability(
      subscribe: resourcesJson{"subscribe"}.getBool(),
      listChanged: resourcesJson{"listChanged"}.getBool()
    ))

  let toolsJson = declared("tools")
  if not toolsJson.isNil:
    result.tools = some(McpToolsCapability(
      listChanged: toolsJson{"listChanged"}.getBool()
    ))

  if not declared("logging").isNil:
    result.logging = some(McpLoggingCapability())

  let experimentalJson = declared("experimental")
  if not experimentalJson.isNil:
    result.experimental = some(experimentalJson)

proc initialize*(client: McpClient): Future[McpServerCapabilities] {.async.} =
  if client.state != mlsUninitialized:
    raise newException(ValueError, "Client already initialized")

  let supported = versionsUpTo(client.protocolVersion)
  let offered = latestLegacyVersion(supported)
  if offered.isNone:
    raise newException(ValueError,
      "initialize needs a protocol version before " & $FirstModernProtocolVersion)

  let request = createInitializeRequest(
    client.clientInfo,
    offered.get,
    client.capabilities
  )

  let response = await client.sendRequest("initialize", request.params)

  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Initialization failed: " & error.message)

  let resultData = response.result.get

  let serverVersionText = resultData{"protocolVersion"}.getStr()
  let serverVersion = parseProtocolVersion(serverVersionText)
  if serverVersion.isNone or isModern(serverVersion.get) or
     serverVersion.get notin supported:
    raise newException(ValueError,
      "Server chose protocol version '" & serverVersionText &
      "', which this client does not speak")
  client.negotiatedVersion = serverVersion

  # Extract server capabilities
  let capabilities = extractServerCapabilities(resultData{"capabilities"})
  client.serverCapabilities = some(capabilities)

  # Change state
  client.state = mlsInitializing

  # Send initialized notification
  await client.sendNotification("notifications/initialized", newJObject())

  # Change state
  client.state = mlsOperational

  return capabilities

proc capabilities*(client: McpClient): Option[McpServerCapabilities] =
  ## Server capabilities negotiated during `connect()` / `initialize()`.
  ## Returns `none` until the handshake completes successfully.
  client.serverCapabilities

proc connect*(client: McpClient, transport: McpTransport): Future[void] {.async.} =
  client.transport = transport

  # Start message processing
  asyncCheck client.processMessages()

  # Initialize the client. The returned capabilities are stored on
  # `client.serverCapabilities` (audit #9); callers can inspect them via
  # `client.capabilities()` after `connect()` resolves, so discarding the
  # local copy here is intentional rather than silent.
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
