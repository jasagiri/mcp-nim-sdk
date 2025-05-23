## SSE Server example for MCP
##
## This example demonstrates a server implementation that uses Server-Sent Events (SSE)
## as the transport mechanism for the Model Context Protocol.

import std/asyncdispatch
import std/asynchttpserver
import std/json
import std/times
import std/options
import std/tables
import std/strutils
import uuids

import ../../src/mcp
import ../../src/mcp/protocol
import ../../src/mcp/transport/base
import ../../src/mcp/logger

# SSE server implementation for MCP
type
  SseSession* = ref object
    id: string
    created: DateTime
    lastAccess: DateTime
    eventQueue: seq[string]  # Queue of SSE events (JSON-RPC messages)
    connections: seq[Request]  # Active SSE connections

  SseMcpServer* = ref object
    server: AsyncHttpServer
    mcpServer: Server
    sessions: Table[string, SseSession]
    port: int

# Create a new SSE session
proc newSseSession(id: string): SseSession =
  result = SseSession(
    id: id,
    created: now(),
    lastAccess: now(),
    eventQueue: @[],
    connections: @[]
  )

# Create new SSE MCP server instance
proc newSseMcpServer(mcpServer: Server, port: int = 8085): SseMcpServer =
  result = SseMcpServer(
    server: newAsyncHttpServer(),
    mcpServer: mcpServer,
    sessions: initTable[string, SseSession](),
    port: port
  )

# Get session or create a new one
proc getOrCreateSession(server: SseMcpServer, sessionId: string = ""): SseSession =
  var id = sessionId
  if id == "":
    id = $genUUID()
  
  if not server.sessions.hasKey(id):
    server.sessions[id] = newSseSession(id)
  
  result = server.sessions[id]
  result.lastAccess = now()

# Clean up old sessions
proc cleanupSessions(server: SseMcpServer) =
  let expireTime = now() - initDuration(hours = 1)
  var toRemove: seq[string] = @[]
  
  for id, session in server.sessions:
    if session.lastAccess.toTime < expireTime.toTime and session.connections.len == 0:
      toRemove.add(id)
  
  for id in toRemove:
    server.sessions.del(id)
    log(LogLevel.Info, "Session expired: " & id)

# Send message to all SSE connections for a session
proc sendToConnections(session: SseSession, message: string) {.async.} =
  for i in countdown(session.connections.len - 1, 0):
    let req = session.connections[i]
    try:
      # Format as SSE message
      await req.client.send("data: " & message & "\n\n")
    except:
      # Remove failed connection
      session.connections.delete(i)

# Queue message for delivery or send immediately if SSE connections are active
proc queueOrSendMessage(session: SseSession, message: string) {.async.} =
  if session.connections.len > 0:
    # Send immediately if there are active connections
    await sendToConnections(session, message)
  else:
    # Queue for later delivery
    session.eventQueue.add(message)

# Setup MCP Server with resources and tools
proc setupMcpServer(): Server =
  # Define server metadata
  let metadata = ServerMetadata(
    name: "sse-mcp-server",
    version: "1.0.0"
  )
  
  # Define server capabilities
  let capabilities = ServerCapabilities(
    resources: some(ResourcesCapability()),
    tools: some(ToolsCapability())
  )
  
  # Create server
  result = newServer(metadata, capabilities)
  
  # Add a text resource
  result.registerResource(
    "example://text",
    "Example Text Resource",
    "This is a sample resource provided by the SSE MCP server example.",
    "text/plain"
  )
  
  # Add a binary resource
  let binaryData = @[byte(0x48), 0x65, 0x6C, 0x6C, 0x6F]  # "Hello" in ASCII
  result.registerBinaryResource(
    "example://binary",
    "Example Binary Resource",
    binaryData,
    "application/octet-stream"
  )
  
  # Add a tool that returns current time
  proc timeToolHandler(args: JsonNode): Future[JsonNode] {.async.} =
    # Generate current time
    let format = if args.hasKey("format"): args["format"].getStr else: "HH:mm:ss"
    let currentTime = now().format(format)
    
    # Return formatted result
    result = %*{"result": "Current time is: " & currentTime}
  
  # Register tool metadata first
  result.registerTool(
    "getCurrentTime",
    "Get the current server time",
    %*{
      "type": "object",
      "properties": {
        "format": {"type": "string", "description": "Time format (default: HH:mm:ss)"}
      }
    }
  )
  
  # Then register the handler
  result.registerToolHandler("getCurrentTime", timeToolHandler)
  
  # Add a tool that echoes input
  proc echoToolHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let message = args["message"].getStr
    result = %*{"result": "Echo: " & message}
  
  # Register tool metadata first
  result.registerTool(
    "echo",
    "Echo a message back",
    %*{
      "type": "object",
      "properties": {
        "message": {"type": "string", "description": "Message to echo"}
      },
      "required": ["message"]
    }
  )
  
  # Then register the handler
  result.registerToolHandler("echo", echoToolHandler)
  
  # Add a server message passing handler
  proc callbackHandler(msg: string) {.async.} =
    # This handler is used for server-initiated messages
    # (such as notifications to clients)
    log(LogLevel.Info, "Server callback triggered: " & msg)

  # Register the callback handler for server messages
  result.onMessage = callbackHandler

# Process incoming JSON-RPC message and return response
proc processMessage(server: SseMcpServer, jsonStr: string, sessionId: string): Future[string] {.async.} =
  try:
    let messageType = parseJsonRpc(jsonStr)
    let session = server.getOrCreateSession(sessionId)
    
    if messageType.isRequest:
      # Handle request
      let request = parseRequest(jsonStr)
      let response = await server.mcpServer.protocol.handleRequestAsync(request)
      return serialize(response)
    elif messageType.isNotification:
      # Handle notification
      let notification = parseNotification(jsonStr)
      server.mcpServer.protocol.handleNotification(notification)
      return "" # No response for notifications
    else:
      # Invalid message
      return $(%*{
        "jsonrpc": "2.0",
        "error": {
          "code": ERR_INVALID_REQUEST,
          "message": "Invalid request"
        }
      })
  except:
    # Error parsing or processing message
    return $(%*{
      "jsonrpc": "2.0",
      "error": {
        "code": ERR_PARSE,
        "message": "Invalid JSON-RPC message: " & getCurrentExceptionMsg()
      }
    })

# Main request handler
proc requestHandler(server: SseMcpServer, req: Request) {.async.} =
  # Extract session ID from headers
  var sessionId = ""
  if req.headers.hasKey("Mcp-Session-Id"):
    sessionId = req.headers["Mcp-Session-Id"]
  
  # Process based on HTTP method and path
  let urlPath = req.url.path
  
  try:
    case req.reqMethod
    of HttpPost:
      if urlPath == "/message":
        # Process incoming JSON-RPC message
        let session = server.getOrCreateSession(sessionId)
        sessionId = session.id
        
        # Parse the request body
        let body = await req.body
        if body.len == 0:
          await req.respond(Http400, "{\"error\": \"Empty request body\"}", 
            newHttpHeaders({"Content-Type": "application/json"}))
          return
        
        # Process the message
        let responseText = await server.processMessage(body, sessionId)
        
        # Set response headers with session ID
        var headers = newHttpHeaders({
          "Content-Type": "application/json",
          "Mcp-Session-Id": sessionId
        })
        
        # Send response if we have one
        if responseText.len > 0:
          await req.respond(Http200, responseText, headers)
        else:
          await req.respond(Http202, "", headers) # Accepted, no content
      else:
        # Unknown path
        await req.respond(Http404, "{\"error\": \"Not found\"}", 
          newHttpHeaders({"Content-Type": "application/json"}))
        
    of HttpGet:
      if urlPath == "/events":
        # Create or resume an SSE connection
        let session = server.getOrCreateSession(sessionId)
        sessionId = session.id
        
        # Set SSE headers
        var headers = newHttpHeaders({
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache, no-transform",
          "Connection": "keep-alive",
          "Mcp-Session-Id": sessionId,
          "X-Accel-Buffering": "no"  # For NGINX
        })
        
        # Start SSE response
        await req.respond(Http200, "", headers)
        
        # Add this connection to the session
        session.connections.add(req)
        
        # Send any queued messages
        for message in session.eventQueue:
          await req.client.send("data: " & message & "\n\n")
        
        # Clear the queue
        session.eventQueue = @[]
        
        log(LogLevel.Info, "New SSE connection established for session: " & sessionId)
        
      else:
        # Unknown path
        await req.respond(Http404, "{\"error\": \"Not found\"}", 
          newHttpHeaders({"Content-Type": "application/json"}))
        
    of HttpDelete:
      if urlPath == "/session":
        # Terminate a session
        if sessionId.len == 0:
          await req.respond(Http400, "{\"error\": \"Missing Mcp-Session-Id header\"}", 
            newHttpHeaders({"Content-Type": "application/json"}))
          return
        
        if server.sessions.hasKey(sessionId):
          # Close all SSE connections
          let session = server.sessions[sessionId]
          for req in session.connections:
            try:
              req.client.close()
            except:
              discard
          
          # Remove the session
          server.sessions.del(sessionId)
          await req.respond(Http200, "{\"status\": \"session terminated\"}", 
            newHttpHeaders({"Content-Type": "application/json"}))
          
          log(LogLevel.Info, "Session terminated: " & sessionId)
        else:
          await req.respond(Http404, "{\"error\": \"Session not found\"}", 
            newHttpHeaders({"Content-Type": "application/json"}))
      else:
        # Unknown path
        await req.respond(Http404, "{\"error\": \"Not found\"}", 
          newHttpHeaders({"Content-Type": "application/json"}))
        
    else:
      # Method not allowed
      await req.respond(Http405, "{\"error\": \"Method not allowed\"}", 
        newHttpHeaders({
          "Content-Type": "application/json",
          "Allow": "GET, POST, DELETE"
        }))
  
  except Exception as e:
    log(LogLevel.Error, "Error handling request: " & e.msg)
    await req.respond(Http500, "{\"error\": \"Internal server error: " & e.msg & "\"}", 
      newHttpHeaders({"Content-Type": "application/json"}))

# Start the SSE server
proc start(server: SseMcpServer) {.async.} =
  # Create callback for request handling
  proc cb(req: Request) {.async.} =
    await server.requestHandler(req)
  
  # Start server
  server.server.listen(Port(server.port))
  
  # Log
  echo "Starting SSE MCP server on port ", server.port
  echo "Server implements SSE transport (MCP 2025-03-26)"
  echo "Server will be available at: http://localhost:", server.port
  echo "  - SSE events endpoint: http://localhost:", server.port, "/events"
  echo "  - Message endpoint: http://localhost:", server.port, "/message"
  echo "  - Session endpoint: http://localhost:", server.port, "/session"
  echo "Press Ctrl+C to stop the server"
  
  # Setup session cleanup timer
  proc cleanupTimer() {.async.} =
    while true:
      await sleepAsync(5 * 60 * 1000)  # 5 minutes
      server.cleanupSessions()
  
  asyncCheck cleanupTimer()
  
  # Main server loop
  while true:
    try:
      await server.server.acceptRequest(cb)
    except:
      echo "Error accepting request: ", getCurrentExceptionMsg()
      await sleepAsync(100)

# Broadcast a message to all connected sessions
proc broadcast(server: SseMcpServer, message: string) {.async.} =
  for id, session in server.sessions:
    await queueOrSendMessage(session, message)

# Main entry point
when isMainModule:
  echo "Starting SSE MCP Server example (MCP 2025-03-26)..."
  
  # Create MCP server with tools and resources
  let mcpServer = setupMcpServer()
  
  # Create SSE server for MCP
  let sseServer = newSseMcpServer(mcpServer)
  
  # Start the server
  waitFor sseServer.start()