## MCP server implementation

import asyncdispatch, json, options, tables, strutils, chronicles, uuid
import ../protocol/types
import ../protocol/lifecycle
import ../transport/transport

type
  McpServer* = ref object
    state*: McpLifecycleState
    protocolVersion*: McpProtocolVersion
    serverInfo*: McpServerInfo
    capabilities*: McpServerCapabilities
    clientCapabilities*: Option[McpClientCapabilities]
    transport*: McpTransport
    resourceHandlers*: McpResourceHandlers
    toolHandlers*: McpToolHandlers
    promptHandlers*: McpPromptHandlers
    requestHandlers*: Table[string, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}]
    notificationHandlers*: Table[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]
    
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

proc newMcpServer*(
  serverInfo: McpServerInfo,
  protocolVersion: McpProtocolVersion = mpv20250326,
  capabilities: McpServerCapabilities = McpServerCapabilities()
): McpServer =
  result = McpServer(
    state: mlsUninitialized,
    protocolVersion: protocolVersion,
    serverInfo: serverInfo,
    capabilities: capabilities,
    clientCapabilities: none(McpClientCapabilities),
    requestHandlers: initTable[string, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}](),
    notificationHandlers: initTable[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]()
  )
  
  # Register built-in request handlers
  result.registerRequestHandler("initialize", proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
    return await result.handleInitialize(request)
  )
  
  result.registerRequestHandler("ping", proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
    return createPingResponse(request.id)
  )
  
  # Register built-in notification handlers
  result.registerNotificationHandler("notifications/initialized", proc(notification: JsonRpcNotification): Future[void] {.async.} =
    await result.handleInitialized(notification)
  )
  
  result.registerNotificationHandler("notifications/cancelled", proc(notification: JsonRpcNotification): Future[void] {.async.} =
    await result.handleCancelled(notification)
  )

proc registerRequestHandler*(server: McpServer, method: string, 
    handler: proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}) =
  server.requestHandlers[method] = handler

proc registerNotificationHandler*(server: McpServer, method: string,
    handler: proc(notification: JsonRpcNotification): Future[void] {.async.}) =
  server.notificationHandlers[method] = handler

proc handleInitialize(server: McpServer, request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
  if server.state \!= mlsUninitialized:
    return newJsonRpcErrorResponse(
      request.id,
      -32600,
      "Server already initialized"
    )
  
  # Extract client info and capabilities
  let params = request.params
  let clientProtocolVersion = parseEnum[McpProtocolVersion](
    params["protocolVersion"].getStr()
  )
  
  # Check protocol version compatibility
  if clientProtocolVersion \!= server.protocolVersion:
    echo "Protocol version mismatch: client=", clientProtocolVersion, 
      " server=", server.protocolVersion
      
    # We'll still accept the client's connection, but use our protocol version
  
  # Extract client capabilities
  let clientCapabilities = extractClientCapabilities(params["capabilities"])
  server.clientCapabilities = some(clientCapabilities)
  
  # Change state
  server.state = mlsInitializing
  
  # Create response
  return createInitializeResponse(
    request.id,
    server.serverInfo,
    server.protocolVersion,
    server.capabilities
  )

proc handleInitialized(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.} =
  if server.state \!= mlsInitializing:
    echo "Received initialized notification in wrong state: ", server.state
    return
    
  # Change state
  server.state = mlsOperational
  echo "Server initialized successfully"

proc handleCancelled(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.} =
  let params = notification.params
  let requestId = params["requestId"].getStr()
  
  echo "Request cancelled: ", requestId
  
  # In a real implementation, we would cancel the pending operation
  # For now, we just log it

proc extractClientCapabilities(json: JsonNode): McpClientCapabilities =
  result = McpClientCapabilities()
  
  if json.hasKey("roots"):
    let rootsJson = json["roots"]
    result.roots = some(McpRootsCapability(
      listChanged: rootsJson.hasKey("listChanged") and rootsJson["listChanged"].getBool()
    ))
  
  if json.hasKey("sampling"):
    result.sampling = some(McpSamplingCapability())
  
  if json.hasKey("experimental"):
    result.experimental = some(json["experimental"])

proc processRequest(server: McpServer, request: JsonRpcRequest): Future[void] {.async.} =
  if request.method in server.requestHandlers:
    let handler = server.requestHandlers[request.method]
    let response = await handler(request)
    await server.transport.sendResponse(response)
  else:
    # Handle standard MCP methods based on capabilities
    case request.method:
    of "resources/list":
      if server.capabilities.resources.isSome and server.resourceHandlers.listHandler.isSome:
        let handler = server.resourceHandlers.listHandler.get
        let resources = await handler()
        
        let cursor = if request.params.hasKey("cursor"): 
          request.params["cursor"].getStr() 
        else: 
          ""
          
        let result = %*{
          "resources": %resources,
        }
        
        # In a real implementation, we would handle pagination
        
        let response = newJsonRpcResponse(request.id, result)
        await server.transport.sendResponse(response)
      else:
        let response = newJsonRpcErrorResponse(
          request.id,
          -32601,
          "Method not supported"
        )
        await server.transport.sendResponse(response)
    
    of "resources/read":
      if server.capabilities.resources.isSome and server.resourceHandlers.readHandler.isSome:
        let handler = server.resourceHandlers.readHandler.get
        let uri = request.params["uri"].getStr()
        
        try:
          let content = await handler(uri)
          let result = %*{
            "contents": [content]
          }
          
          let response = newJsonRpcResponse(request.id, result)
          await server.transport.sendResponse(response)
        except:
          let e = getCurrentException()
          let response = newJsonRpcErrorResponse(
            request.id,
            -32602,
            "Failed to read resource: " & e.msg
          )
          await server.transport.sendResponse(response)
      else:
        let response = newJsonRpcErrorResponse(
          request.id,
          -32601,
          "Method not supported"
        )
        await server.transport.sendResponse(response)
    
    of "tools/list":
      if server.capabilities.tools.isSome and server.toolHandlers.listHandler.isSome:
        let handler = server.toolHandlers.listHandler.get
        let tools = await handler()
        
        let cursor = if request.params.hasKey("cursor"): 
          request.params["cursor"].getStr() 
        else: 
          ""
          
        let result = %*{
          "tools": %tools,
        }
        
        # In a real implementation, we would handle pagination
        
        let response = newJsonRpcResponse(request.id, result)
        await server.transport.sendResponse(response)
      else:
        let response = newJsonRpcErrorResponse(
          request.id,
          -32601,
          "Method not supported"
        )
        await server.transport.sendResponse(response)
    
    of "tools/call":
      if server.capabilities.tools.isSome and server.toolHandlers.callHandler.isSome:
        let handler = server.toolHandlers.callHandler.get
        let name = request.params["name"].getStr()
        let arguments = request.params["arguments"]
        
        try:
          let result = await handler(name, arguments)
          let response = newJsonRpcResponse(request.id, result)
          await server.transport.sendResponse(response)
        except:
          let e = getCurrentException()
          let response = newJsonRpcErrorResponse(
            request.id,
            -32602,
            "Failed to call tool: " & e.msg
          )
          await server.transport.sendResponse(response)
      else:
        let response = newJsonRpcErrorResponse(
          request.id,
          -32601,
          "Method not supported"
        )
        await server.transport.sendResponse(response)
    
    of "prompts/list":
      if server.capabilities.prompts.isSome and server.promptHandlers.listHandler.isSome:
        let handler = server.promptHandlers.listHandler.get
        let prompts = await handler()
        
        let cursor = if request.params.hasKey("cursor"): 
          request.params["cursor"].getStr() 
        else: 
          ""
          
        let result = %*{
          "prompts": %prompts,
        }
        
        # In a real implementation, we would handle pagination
        
        let response = newJsonRpcResponse(request.id, result)
        await server.transport.sendResponse(response)
      else:
        let response = newJsonRpcErrorResponse(
          request.id,
          -32601,
          "Method not supported"
        )
        await server.transport.sendResponse(response)
    
    of "prompts/get":
      if server.capabilities.prompts.isSome and server.promptHandlers.getHandler.isSome:
        let handler = server.promptHandlers.getHandler.get
        let name = request.params["name"].getStr()
        let arguments = if request.params.hasKey("arguments"): 
          request.params["arguments"] 
        else: 
          newJObject()
        
        try:
          let result = await handler(name, arguments)
          let response = newJsonRpcResponse(request.id, result)
          await server.transport.sendResponse(response)
        except:
          let e = getCurrentException()
          let response = newJsonRpcErrorResponse(
            request.id,
            -32602,
            "Failed to get prompt: " & e.msg
          )
          await server.transport.sendResponse(response)
      else:
        let response = newJsonRpcErrorResponse(
          request.id,
          -32601,
          "Method not supported"
        )
        await server.transport.sendResponse(response)
    
    else:
      # Unknown method
      let response = newJsonRpcErrorResponse(
        request.id, 
        -32601, 
        "Method not found: " & request.method
      )
      await server.transport.sendResponse(response)

proc processNotification(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.} =
  if notification.method in server.notificationHandlers:
    let handler = server.notificationHandlers[notification.method]
    await handler(notification)
  # If no handler, silently ignore

proc processMessages*(server: McpServer): Future[void] {.async.} =
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
        echo "Invalid message received: ", json
  except:
    let e = getCurrentException()
    echo "Error processing messages: ", e.msg

proc sendNotification*(server: McpServer, method: string, params: JsonNode): Future[void] {.async.} =
  let notification = newJsonRpcNotification(method, params)
  await server.transport.sendNotification(notification)

proc attachTransport*(server: McpServer, transport: McpTransport): Future[void] {.async.} =
  server.transport = transport
  
  # Start message processing
  asyncCheck server.processMessages()

proc notifyResourceListChanged*(server: McpServer): Future[void] {.async.} =
  if server.state \!= mlsOperational:
    return
    
  if server.capabilities.resources.isSome and 
     server.capabilities.resources.get.listChanged:
    await server.sendNotification("notifications/resources/list_changed", newJObject())

proc notifyResourceUpdated*(server: McpServer, uri: string): Future[void] {.async.} =
  if server.state \!= mlsOperational:
    return
    
  if server.capabilities.resources.isSome and 
     server.capabilities.resources.get.subscribe:
    let params = %*{
      "uri": uri
    }
    await server.sendNotification("notifications/resources/updated", params)

proc notifyToolListChanged*(server: McpServer): Future[void] {.async.} =
  if server.state \!= mlsOperational:
    return
    
  if server.capabilities.tools.isSome and 
     server.capabilities.tools.get.listChanged:
    await server.sendNotification("notifications/tools/list_changed", newJObject())

proc notifyPromptListChanged*(server: McpServer): Future[void] {.async.} =
  if server.state \!= mlsOperational:
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
  if server.state \!= mlsOperational:
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
