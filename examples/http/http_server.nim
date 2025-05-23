## HTTP Server example for MCP
##
## This example demonstrates a streamable HTTP server implementation for the Model Context Protocol.
## It uses the Streamable HTTP transport as defined in the MCP 2025-03-26 specification.

import std/asyncdispatch
import std/asynchttpserver
import std/asyncnet
import std/json
import std/times
import std/options
import std/tables
import uuids

import ../../src/mcp
import ../../src/mcp/protocol
import ../../src/mcp/transport/base
import ../../src/mcp/logger

# HTTP server implementation based on the Streamable HTTP transport specification
type
  HttpSession* = ref object
    id: string
    created: DateTime
    lastAccess: DateTime
    messageQueue: seq[string]  # Queue of JSON-RPC messages
    sseConnections: seq[Request]  # Active SSE connections

  HttpMcpServer* = ref object
    server: AsyncHttpServer
    mcpServer: Server
    sessions: Table[string, HttpSession]
    port: int

# Create a new HTTP session
proc newHttpSession(id: string): HttpSession =
  result = HttpSession(
    id: id,
    created: now(),
    lastAccess: now(),
    messageQueue: @[],
    sseConnections: @[]
  )

# Create new HTTP MCP server instance
proc newHttpMcpServer(mcpServer: Server, port: int = 8080): HttpMcpServer =
  result = HttpMcpServer(
    server: newAsyncHttpServer(),
    mcpServer: mcpServer,
    sessions: initTable[string, HttpSession](),
    port: port
  )

# Get session or create a new one
proc getOrCreateSession(server: HttpMcpServer, sessionId: string = ""): HttpSession =
  var id = sessionId
  if id == "":
    id = $genUUID()
  
  if not server.sessions.hasKey(id):
    server.sessions[id] = newHttpSession(id)
  
  result = server.sessions[id]
  result.lastAccess = now()

# Clean up old sessions
proc cleanupSessions(server: HttpMcpServer) =
  let expireTime = now() - initDuration(hours = 1)
  var toRemove: seq[string] = @[]
  
  for id, session in server.sessions:
    if session.lastAccess.toTime < expireTime.toTime and session.sseConnections.len == 0:
      toRemove.add(id)
  
  for id in toRemove:
    server.sessions.del(id)
    # log(LogLevel.Info, "Session expired: " & id)  # Comment out for GC safety

# Send message to all SSE connections for a session
proc sendToSseConnections(session: HttpSession, message: string) {.async.} =
  for i in countdown(session.sseConnections.len - 1, 0):
    let req = session.sseConnections[i]
    try:
      # Format as SSE message
      await asyncnet.send(req.client, "data: " & message & "\n\n")
    except:
      # Remove failed connection
      session.sseConnections.delete(i)

# Queue message for delivery or send immediately if SSE connections are active
proc queueOrSendMessage(session: HttpSession, message: string) {.async.} =
  if session.sseConnections.len > 0:
    # Send immediately if there are active connections
    await sendToSseConnections(session, message)
  else:
    # Queue for later delivery
    session.messageQueue.add(message)

# Setup MCP Server with resources and tools
proc setupMcpServer(): Server =
  # Define server metadata
  let metadata = types.ServerMetadata(
    name: "http-mcp-server",
    version: "1.0.0"
  )
  
  # Define server capabilities
  let capabilities = types.ServerCapabilities(
    resources: some(types.ResourcesCapability()),
    tools: some(types.ToolsCapability())
  )
  
  # Create server
  result = newServer(metadata, capabilities)
  
  # Add a text resource
  result.registerResource(
    "example://text",
    "Example Text Resource",
    "A simple example resource",
    "text/plain"
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

# Process incoming JSON-RPC message and return response
proc processMessage(server: HttpMcpServer, jsonStr: string): Future[string] {.async.} =
  try:
    let messageType = base.parseJsonRpc(jsonStr)
    
    if messageType[0]: # isRequest
      # Handle request
      let request = protocol.parseRequest(jsonStr)
      let response = await server.mcpServer.protocol.handleRequestAsync(request)
      return protocol.serialize(response)
    elif messageType[1]: # isNotification
      # Handle notification
      let notification = protocol.parseNotification(jsonStr)
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
proc requestHandler(server: HttpMcpServer, req: Request) {.async.} =
  # Extract session ID from headers
  var sessionId = ""
  if req.headers.hasKey("Mcp-Session-Id"):
    sessionId = req.headers["Mcp-Session-Id"]
  
  # Process based on HTTP method and path
  try:
    case req.reqMethod
    of HttpPost:
      # Process incoming message (as per Streamable HTTP spec)
      let session = server.getOrCreateSession(sessionId)
      sessionId = session.id
      
      # Parse the request body
      let body = req.body
      if body.len == 0:
        await req.respond(Http400, "{\"error\": \"Empty request body\"}", 
          newHttpHeaders({"Content-Type": "application/json"}))
        return
      
      # Process the message
      let responseText = await server.processMessage(body)
      
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
      
    of HttpGet:
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
      session.sseConnections.add(req)
      
      # Send any queued messages
      for message in session.messageQueue:
        await asyncnet.send(req.client, "data: " & message & "\n\n")
      
      # Clear the queue
      session.messageQueue = @[]
      
      # The connection will remain open until the client disconnects
      # or the server closes the session
      
    of HttpDelete:
      # Terminate a session
      if sessionId.len == 0:
        await req.respond(Http400, "{\"error\": \"Missing Mcp-Session-Id header\"}", 
          newHttpHeaders({"Content-Type": "application/json"}))
        return
      
      if server.sessions.hasKey(sessionId):
        # Close all SSE connections
        let session = server.sessions[sessionId]
        for req in session.sseConnections:
          try:
            req.client.close()
          except:
            discard
        
        # Remove the session
        server.sessions.del(sessionId)
        await req.respond(Http200, "{\"status\": \"session terminated\"}", 
          newHttpHeaders({"Content-Type": "application/json"}))
      else:
        await req.respond(Http404, "{\"error\": \"Session not found\"}", 
          newHttpHeaders({"Content-Type": "application/json"}))
      
    else:
      # Method not allowed
      await req.respond(Http405, "{\"error\": \"Method not allowed\"}", 
        newHttpHeaders({
          "Content-Type": "application/json",
          "Allow": "GET, POST, DELETE"
        }))
  
  except Exception as e:
    # log(LogLevel.Error, "Error handling request: " & e.msg)  # Comment out for GC safety
    await req.respond(Http500, "{\"error\": \"Internal server error: " & e.msg & "\"}", 
      newHttpHeaders({"Content-Type": "application/json"}))

# Start the HTTP server
proc start(server: HttpMcpServer) {.async.} =
  # Create callback for request handling
  proc cb(req: Request) {.async.} =
    await server.requestHandler(req)
  
  # Start server
  server.server.listen(Port(server.port))
  
  # Log
  echo "Starting HTTP MCP server on port ", server.port
  echo "Server implements Streamable HTTP transport (MCP 2025-03-26)"
  echo "Server will be available at: http://localhost:", server.port
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

# Main entry point
when isMainModule:
  echo "Starting HTTP MCP Server example (Streamable HTTP - MCP 2025-03-26)..."
  
  # Create MCP server with tools and resources
  let mcpServer = setupMcpServer()
  
  # Create HTTP server for MCP
  let httpServer = newHttpMcpServer(mcpServer)
  
  # Start the server
  waitFor httpServer.start()
