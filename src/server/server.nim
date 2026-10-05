## MCP server implementation

import asyncdispatch, json, options, tables
import ../protocol/types
import ../protocol/lifecycle
import ../protocol/modern
import ../transport/transport

type
  McpServer* = ref object
    state*: McpLifecycleState
    protocolVersion*: McpProtocolVersion
      ## The newest version this server speaks; it also speaks every
      ## earlier one.
    negotiatedVersion*: Option[McpProtocolVersion]
      ## The version agreed in the initialize handshake.
    serverInfo*: McpServerInfo
    instructions*: string
      ## How to use this server; sent with server/discover when not empty.
    cachePolicy*: CachePolicy
      ## What 2026-07-28 clients are told about reusing list and read
      ## results. The default tells them not to.
    capabilities*: McpServerCapabilities
    clientCapabilities*: Option[McpClientCapabilities]
    transport*: McpTransport
    resourceHandlers*: McpResourceHandlers
    toolHandlers*: McpToolHandlers
    promptHandlers*: McpPromptHandlers
    requestHandlers*: Table[string, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}]
    notificationHandlers*: Table[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]
    lastTransportError*: ref CatchableError
      ## Set when the message-processing loop terminates due to a transport
      ## error. `nil` if the loop has not yet ended (or ended cleanly). Lets
      ## callers detect "silent dead" conditions instead of relying on an
      ## asyncCheck'd future that completes with no signal.

  McpResourceHandlers* = object
    listHandler*: Option[proc(): Future[seq[JsonNode]] {.async.}]
    readHandler*: Option[proc(uri: string): Future[JsonNode] {.async.}]
    listTemplatesHandler*: Option[proc(): Future[seq[JsonNode]] {.async.}]
    subscribeHandler*: Option[proc(uri: string): Future[void] {.async.}]
    unsubscribeHandler*: Option[proc(uri: string): Future[void] {.async.}]

  McpToolHandlers* = object
    listHandler*: Option[proc(): Future[seq[JsonNode]] {.async.}]
    callHandler*: Option[proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.}]

  McpPromptHandlers* = object
    listHandler*: Option[proc(): Future[seq[JsonNode]] {.async.}]
    getHandler*: Option[proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.}]

# Forward declarations
proc registerRequestHandler*(server: McpServer, methodName: string,
    handler: proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.})
proc registerNotificationHandler*(server: McpServer, methodName: string,
    handler: proc(notification: JsonRpcNotification): Future[void] {.async.})
proc handleInitialize(server: McpServer, request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}
proc handleInitialized(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.}
proc handleCancelled(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.}
proc extractClientCapabilities(json: JsonNode): McpClientCapabilities

proc newMcpServer*(
  serverInfo: McpServerInfo,
  protocolVersion: McpProtocolVersion = DefaultProtocolVersion,
  capabilities: McpServerCapabilities = McpServerCapabilities()
): McpServer =
  requireSupported(protocolVersion)
  let server = McpServer(
    state: mlsUninitialized,
    protocolVersion: protocolVersion,
    serverInfo: serverInfo,
    cachePolicy: UncachedPolicy,
    capabilities: capabilities,
    clientCapabilities: none(McpClientCapabilities),
    requestHandlers: initTable[string, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}](),
    notificationHandlers: initTable[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]()
  )

  # Register built-in request handlers
  server.registerRequestHandler("initialize", proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
    return await server.handleInitialize(request)
  )

  server.registerRequestHandler("ping", proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
    return createPingResponse(request.id)
  )

  # Register built-in notification handlers
  server.registerNotificationHandler("notifications/initialized", proc(notification: JsonRpcNotification): Future[void] {.async.} =
    await server.handleInitialized(notification)
  )

  server.registerNotificationHandler("notifications/cancelled", proc(notification: JsonRpcNotification): Future[void] {.async.} =
    await server.handleCancelled(notification)
  )

  return server

proc registerRequestHandler*(server: McpServer, methodName: string,
    handler: proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}) =
  server.requestHandlers[methodName] = handler

proc registerNotificationHandler*(server: McpServer, methodName: string,
    handler: proc(notification: JsonRpcNotification): Future[void] {.async.}) =
  server.notificationHandlers[methodName] = handler

proc handleInitialize(server: McpServer, request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
  if server.state != mlsUninitialized:
    return newJsonRpcErrorResponse(
      request.id,
      -32600,
      "Server already initialized"
    )
  
  let params = request.params
  if params.isNil or params.kind != JObject or
     not params.hasKey("protocolVersion") or
     params["protocolVersion"].kind != JString:
    return newJsonRpcErrorResponse(
      request.id,
      -32602,
      "initialize requires a string protocolVersion"
    )

  let requested = params["protocolVersion"].getStr()
  let supported = versionsUpTo(server.protocolVersion)
  let negotiated = negotiateLegacyVersion(requested, supported)
  if negotiated.isNone:
    var supportedJson = newJArray()
    for v in supported:
      supportedJson.add %($v)
    return newJsonRpcErrorResponse(
      request.id,
      -32022,
      "Unsupported protocol version",
      %*{"supported": supportedJson, "requested": requested}
    )
  server.negotiatedVersion = negotiated

  let clientCapabilities =
    if params.hasKey("capabilities") and params["capabilities"].kind == JObject:
      extractClientCapabilities(params["capabilities"])
    else:
      McpClientCapabilities()
  server.clientCapabilities = some(clientCapabilities)

  # Change state
  server.state = mlsInitializing
  
  # Create response
  return createInitializeResponse(
    request.id,
    server.serverInfo,
    negotiated.get,
    server.capabilities
  )

proc handleInitialized(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.} =
  if server.state != mlsInitializing:
    stderr.writeLine("[mcp-server] initialized notification in state " &
                      $server.state & " ignored")
    return

  server.state = mlsOperational

proc handleCancelled(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.} =
  # TODO: cancel the pending operation named by params.requestId.
  discard

proc extractClientCapabilities(json: JsonNode): McpClientCapabilities =
  result = McpClientCapabilities()
  
  # A peer that sends null for a capability has not declared it.
  let rootsJson = json{"roots"}
  if not rootsJson.isNil and rootsJson.kind == JObject:
    result.roots = some(McpRootsCapability(
      listChanged: rootsJson{"listChanged"}.getBool()
    ))

  let samplingJson = json{"sampling"}
  if not samplingJson.isNil and samplingJson.kind == JObject:
    result.sampling = some(McpSamplingCapability())

  let experimentalJson = json{"experimental"}
  if not experimentalJson.isNil and experimentalJson.kind == JObject:
    result.experimental = some(experimentalJson)

proc notSupported(request: JsonRpcRequest): JsonRpcResponse =
  newJsonRpcErrorResponse(request.id, ErrMethodNotFound, "Method not supported")

proc stringParam(request: JsonRpcRequest, name: string): Option[string] =
  let node = request.params{name}
  if node.isNil or node.kind != JString: none(string) else: some(node.getStr())

proc missingParam(request: JsonRpcRequest, name: string): JsonRpcResponse =
  newJsonRpcErrorResponse(request.id, ErrInvalidParams,
    request.`method` & " requires a string " & name)

proc handleStandardRequest(server: McpServer, request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
  ## What a method does, independent of the protocol era it arrived in.
  if request.`method` in server.requestHandlers:
    return await server.requestHandlers[request.`method`](request)

  case request.`method`
  of "resources/list":
    if server.capabilities.resources.isNone or server.resourceHandlers.listHandler.isNone:
      return notSupported(request)
    # TODO: pagination (cursor / nextCursor).
    let resources = await server.resourceHandlers.listHandler.get()()
    return newJsonRpcResponse(request.id, %*{"resources": resources})

  of "resources/read":
    if server.capabilities.resources.isNone or server.resourceHandlers.readHandler.isNone:
      return notSupported(request)
    let uri = stringParam(request, "uri")
    if uri.isNone:
      return missingParam(request, "uri")
    try:
      let content = await server.resourceHandlers.readHandler.get()(uri.get)
      return newJsonRpcResponse(request.id, %*{"contents": [content]})
    except CatchableError as e:
      return newJsonRpcErrorResponse(request.id, ErrInvalidParams,
        "Failed to read resource: " & e.msg)

  of "tools/list":
    if server.capabilities.tools.isNone or server.toolHandlers.listHandler.isNone:
      return notSupported(request)
    # TODO: pagination (cursor / nextCursor).
    let tools = await server.toolHandlers.listHandler.get()()
    return newJsonRpcResponse(request.id, %*{"tools": tools})

  of "tools/call":
    if server.capabilities.tools.isNone or server.toolHandlers.callHandler.isNone:
      return notSupported(request)
    let name = stringParam(request, "name")
    if name.isNone:
      return missingParam(request, "name")
    let arguments = request.params{"arguments"}
    try:
      let callResult = await server.toolHandlers.callHandler.get()(
        name.get, if arguments.isNil: newJObject() else: arguments)
      return newJsonRpcResponse(request.id, callResult)
    except CatchableError as e:
      return newJsonRpcErrorResponse(request.id, ErrInvalidParams,
        "Failed to call tool: " & e.msg)

  of "prompts/list":
    if server.capabilities.prompts.isNone or server.promptHandlers.listHandler.isNone:
      return notSupported(request)
    # TODO: pagination (cursor / nextCursor).
    let prompts = await server.promptHandlers.listHandler.get()()
    return newJsonRpcResponse(request.id, %*{"prompts": prompts})

  of "prompts/get":
    if server.capabilities.prompts.isNone or server.promptHandlers.getHandler.isNone:
      return notSupported(request)
    let name = stringParam(request, "name")
    if name.isNone:
      return missingParam(request, "name")
    let arguments = request.params{"arguments"}
    try:
      let prompt = await server.promptHandlers.getHandler.get()(
        name.get, if arguments.isNil: newJObject() else: arguments)
      return newJsonRpcResponse(request.id, prompt)
    except CatchableError as e:
      return newJsonRpcErrorResponse(request.id, ErrInvalidParams,
        "Failed to get prompt: " & e.msg)

  else:
    return newJsonRpcErrorResponse(request.id, ErrMethodNotFound,
      "Method not found: " & request.`method`)

proc handleModernRequest(server: McpServer, request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
  ## A 2026-07-28 request: validated on its own metadata, served without
  ## any handshake state.
  let supported = versionsUpTo(server.protocolVersion)
  let rejection = validateModernRequest(request.params, supported)
  if rejection.isSome:
    return newJsonRpcErrorResponse(request.id, rejection.get.code,
      rejection.get.message, rejection.get.data)
  if isRemovedInModern(request.`method`):
    return newJsonRpcErrorResponse(request.id, ErrMethodNotFound,
      "Method not found: " & request.`method`)

  var response =
    if request.`method` == DiscoverMethod:
      newJsonRpcResponse(request.id, discoverPayload(
        supported, server.capabilities.toJson(), server.instructions))
    else:
      await server.handleStandardRequest(request)

  if response.result.isSome:
    let payload = response.result.get
    if payload.isNil or payload.kind != JObject:
      return newJsonRpcErrorResponse(request.id, ErrInternal,
        "Handler for " & request.`method` & " returned a result that is not an object")
    response.result = some(completeResult(
      request.`method`, payload, server.serverInfo, server.cachePolicy))
  return response

proc handleRequest*(server: McpServer, request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
  ## The response to `request`. A server that speaks 2026-07-28 serves a
  ## request in that era when the request names its own protocol version;
  ## a server limited to earlier versions does not know that era at all.
  var response =
    if isModern(server.protocolVersion) and isModernRequest(request.params):
      await server.handleModernRequest(request)
    else:
      await server.handleStandardRequest(request)
  response.idNode = request.idNode
  return response

proc processRequest(server: McpServer, request: JsonRpcRequest): Future[void] {.async.} =
  var response: JsonRpcResponse
  try:
    response = await server.handleRequest(request)
  except CatchableError as e:
    # The cause stays on this side; a peer gets no internal detail.
    stderr.writeLine("[mcp-server] " & request.`method` & " failed with " &
                      $e.name & ": " & e.msg)
    response = newJsonRpcErrorResponse(request.id, ErrInternal, "Internal error")
    response.idNode = request.idNode
  await server.transport.sendResponse(response)

proc processNotification(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.} =
  if notification.`method` in server.notificationHandlers:
    let handler = server.notificationHandlers[notification.`method`]
    await handler(notification)
  # If no handler, silently ignore

proc processMessages*(server: McpServer): Future[void] {.async.} =
  ## Run the receive loop until the transport raises. On termination, the
  ## raising error is stored on `server.lastTransportError` so callers can
  ## diagnose; we do not silently swallow it. Defects (programmer errors)
  ## are not caught and propagate normally — we only handle CatchableError.
  try:
    while true:
      let json = await server.transport.receiveMessage()

      if isRequest(json):
        let request = decodeRequest(json)
        asyncCheck server.processRequest(request)
      elif isNotification(json):
        let notification = decodeNotification(json)
        asyncCheck server.processNotification(notification)
      else:
        stderr.writeLine("[mcp-server] invalid message received: " & $json)
  except CatchableError as e:
    server.lastTransportError = e
    stderr.writeLine("[mcp-server] transport loop ended with " &
                      $e.name & ": " & e.msg)

proc sendNotification*(server: McpServer, methodName: string, params: JsonNode): Future[void] {.async.} =
  let notification = newJsonRpcNotification(methodName, params)
  await server.transport.sendNotification(notification)

proc attachTransport*(server: McpServer, transport: McpTransport): Future[void] {.async.} =
  server.transport = transport
  
  # Start message processing
  asyncCheck server.processMessages()

proc notifyResourceListChanged*(server: McpServer): Future[void] {.async.} =
  if server.state != mlsOperational:
    return
    
  if server.capabilities.resources.isSome and 
     server.capabilities.resources.get.listChanged:
    await server.sendNotification("notifications/resources/list_changed", newJObject())

proc notifyResourceUpdated*(server: McpServer, uri: string): Future[void] {.async.} =
  if server.state != mlsOperational:
    return
    
  if server.capabilities.resources.isSome and 
     server.capabilities.resources.get.subscribe:
    let params = %*{
      "uri": uri
    }
    await server.sendNotification("notifications/resources/updated", params)

proc notifyToolListChanged*(server: McpServer): Future[void] {.async.} =
  if server.state != mlsOperational:
    return
    
  if server.capabilities.tools.isSome and 
     server.capabilities.tools.get.listChanged:
    await server.sendNotification("notifications/tools/list_changed", newJObject())

proc notifyPromptListChanged*(server: McpServer): Future[void] {.async.} =
  if server.state != mlsOperational:
    return
    
  if server.capabilities.prompts.isSome and 
     server.capabilities.prompts.get.listChanged:
    await server.sendNotification("notifications/prompts/list_changed", newJObject())

proc setResourceHandlers*(server: McpServer, handlers: McpResourceHandlers) =
  server.resourceHandlers = handlers

proc setToolHandlers*(server: McpServer, handlers: McpToolHandlers) =
  server.toolHandlers = handlers

proc setPromptHandlers*(server: McpServer, handlers: McpPromptHandlers) =
  server.promptHandlers = handlers

proc sendLogMessage*(server: McpServer, level: string, message: string, logger: string = "", data: JsonNode = nil): Future[void] {.async.} =
  if server.state != mlsOperational:
    return
    
  if server.capabilities.logging.isNone:
    return
    
  var params = %*{
    "level": level,
    "message": message
  }
  
  if logger.len > 0:
    params["logger"] = %logger
    
  if not data.isNil:
    params["data"] = data
    
  await server.sendNotification("notifications/message", params)
