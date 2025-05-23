## Streamable HTTP transport for the Model Context Protocol (MCP) - 2025-03-26 version.
##
## This module implements the Streamable HTTP transport as defined in the MCP 2025-03-26 specification.
## It supports:
## - HTTP POST for sending messages to the server
## - Server-Sent Events (SSE) for receiving messages from the server
## - Session management with MCP-Session-Id header

import asyncdispatch
import httpclient
import json
import uri
import strutils
import tables
import options
import asyncstreams
import uuids
import ../protocol
import ../logger
import ./base

type
  MCPTransportError* = object of CatchableError
    ## Base exception for transport errors

  EventSource = ref object
    ## EventSource implementation for SSE
    url: string
    client: AsyncHttpClient
    onMessage: proc(msg: string) {.async.}
    active: bool
    lastEventId: string

  StreamableHttpTransport* = ref object of Transport
    ## Implementation of Streamable HTTP transport per 2025-03-26 specification
    client: AsyncHttpClient
    serverUrl: string          # The MCP endpoint URL
    sseClient: AsyncHttpClient # Separate client for SSE connections
    eventSources: seq[EventSource]  # Multiple SSE connections may be active
    pendingRequests: Table[string, Future[ResponseMessage]]
    isRunning: bool
    sessionId: string          # MCP-Session-Id for session tracking

proc newEventSource(url: string, onMessage: proc(msg: string) {.async.}): EventSource =
  ## Create a new EventSource for SSE
  result = EventSource(
    url: url,
    client: newAsyncHttpClient(),
    onMessage: onMessage,
    active: false,
    lastEventId: ""
  )

proc start(es: EventSource) {.async.} =
  ## Start the EventSource connection
  es.active = true
  
  while es.active:
    try:
      var headers = newHttpHeaders({
        "Accept": "text/event-stream"
      })
      
      # Include Last-Event-ID header if available for resuming
      if es.lastEventId.len > 0:
        headers.add("Last-Event-ID", es.lastEventId)

      let response = await es.client.request(es.url, httpMethod = HttpGet, headers = headers)
      var buffer = ""
      var eventId = ""
      
      # Process the SSE stream
      let bodyContent = await response.body
      let lines = bodyContent.split("\n")
      var lineIndex = 0
      
      while es.active and lineIndex < lines.len:
        let line = lines[lineIndex]
        inc(lineIndex)
        
        # Empty line indicates end of event
        if line.len == 0:
          if buffer.len > 0:
            await es.onMessage(buffer)
            buffer = ""
            # Update last event ID
            if eventId.len > 0:
              es.lastEventId = eventId
              eventId = ""
          continue
          
        # Handle event ID
        if line.startsWith("id:"):
          eventId = line[3..^1].strip()
          continue
          
        # Handle event data
        if line.startsWith("data:"):
          let data = line[5..^1].strip()
          if buffer.len > 0:
            buffer &= "\n"
          buffer &= data
    except:
      if not es.active:
        break
        
      # Wait before reconnecting
      await sleepAsync(1000)

proc stop(es: EventSource) {.async.} =
  ## Stop the EventSource connection
  es.active = false
  es.client.close()

proc newStreamableHttpTransport*(serverUrl: string): StreamableHttpTransport =
  ## Create a new transport that implements the Streamable HTTP transport (2025-03-26 spec)
  ## 
  ## Parameters:
  ## - serverUrl: The MCP endpoint URL
  
  # Ensure the URL is properly formatted
  var baseUrl = serverUrl
  if not baseUrl.endsWith("/"):
    baseUrl = baseUrl & "/"
  
  result = StreamableHttpTransport(
    state: NotStarted,
    client: newAsyncHttpClient(),
    serverUrl: baseUrl,
    sseClient: newAsyncHttpClient(),
    eventSources: @[],
    pendingRequests: initTable[string, Future[ResponseMessage]](),
    isRunning: false,
    sessionId: ""
  )

proc messageHandler(t: StreamableHttpTransport, jsonStr: string) {.async.} =
  ## Handle incoming messages from the SSE stream
  try:
    let parsed = base.parseJsonRpc(jsonStr)
    if parsed.isResponse:
      let jsonNode = parsed.msg
      let id = jsonNode["id"].getStr()
      
      if t.pendingRequests.hasKey(id):
        let response = parseResponse(jsonStr)
        let promise = t.pendingRequests[id]
        t.pendingRequests.del(id)
        promise.complete(response)
      else:
        if t.onErrorCallback != nil:
          await t.onErrorCallback("Received response for unknown request ID: " & id)
    elif parsed.isRequest or parsed.isNotification:
      if t.onMessageCallback != nil:
        await t.onMessageCallback(jsonStr)
  except:
    if t.onErrorCallback != nil:
      await t.onErrorCallback("Error processing message: " & getCurrentExceptionMsg())

proc openSseConnection(t: StreamableHttpTransport): Future[void] {.async.} =
  ## Open an SSE connection to listen for server messages
  let es = newEventSource(t.serverUrl, proc(msg: string) {.async.} =
    await t.messageHandler(msg)
  )
  
  # Add SSE connection to the list of active connections
  t.eventSources.add(es)
  
  # Start the SSE connection
  asyncCheck es.start()

method start*(t: StreamableHttpTransport): Future[void] {.async.} =
  ## Start the transport
  if t.state != NotStarted:
    raise newException(MCPTransportError, "Transport already started")
  
  t.state = Starting
  t.isRunning = true
  
  # Configure HTTP clients
  t.client = newAsyncHttpClient()
  t.client.headers = newHttpHeaders({
    "Accept": "application/json, text/event-stream"
  })
  
  # Open an SSE connection for server-to-client communications
  await t.openSseConnection()
  
  t.state = Started
  # info("Streamable HTTP transport started")  # Comment out for GC safety

method stop*(t: StreamableHttpTransport): Future[void] {.async.} =
  ## Stop the transport and clean up resources
  if t.state != Started:
    return
    
  t.state = Closing
  t.isRunning = false
  
  # Stop all active SSE connections
  for es in t.eventSources:
    await es.stop()
  t.eventSources = @[]
  
  # Close HTTP clients
  t.client.close()
  
  # If we have a session ID, try to explicitly terminate the session
  if t.sessionId.len > 0:
    try:
      discard await t.client.request(
        t.serverUrl,
        httpMethod = HttpDelete,
        headers = newHttpHeaders({
          "Mcp-Session-Id": t.sessionId
        })
      )
    except:
      # warning("Error closing session")  # Comment out for GC safety
      discard
  
  t.state = Closed
  
  if t.onCloseCallback != nil:
    await t.onCloseCallback()
  
  # info("Streamable HTTP transport stopped")  # Comment out for GC safety

method send*(t: StreamableHttpTransport, msg: string): Future[void] {.async, gcsafe.} =
  ## Send a raw message through the transport
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  try:
    var headers = newHttpHeaders({
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream"
    })
    
    # Add session ID if available
    if t.sessionId.len > 0:
      headers.add("Mcp-Session-Id", t.sessionId)
    
    let response = await t.client.request(
      t.serverUrl,
      httpMethod = HttpPost,
      body = msg,
      headers = headers
    )
    
    # Check for session ID in response headers
    if response.headers.hasKey("Mcp-Session-Id"):
      t.sessionId = response.headers["Mcp-Session-Id"]
    
    if response.code == Http200:
      # Check content type for SSE response
      if response.headers.hasKey("Content-Type") and 
         response.headers["Content-Type"].contains("text/event-stream"):
        # This is an SSE response, process it as a stream
        # TODO: Implement more sophisticated SSE handling here
        discard
    elif response.code != Http202:
      # Error for anything except 200 OK or 202 Accepted
      let errorMsg = "HTTP error: " & $response.code
      # error(errorMsg)  # Comment out for GC safety
      if t.onErrorCallback != nil:
        await t.onErrorCallback(errorMsg)
      raise newException(MCPTransportError, errorMsg)
  
  except Exception as e:
    # error("Error sending message: " & e.msg)  # Comment out for GC safety
    if t.onErrorCallback != nil:
      await t.onErrorCallback("Error sending message: " & e.msg)
    raise newException(MCPTransportError, "Error sending message: " & e.msg)

method sendRequest*(t: StreamableHttpTransport, req: RequestMessage): Future[ResponseMessage] {.async.} =
  ## Send a request and wait for a response
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  let jsonStr = requestToJson(req)
  var promise = newFuture[ResponseMessage]("sendRequest")
  t.pendingRequests[req.id] = promise
  
  try:
    await t.send(jsonStr)
  except:
    t.pendingRequests.del(req.id)
    raise
    
  return await promise

method sendNotification*(t: StreamableHttpTransport, notification: NotificationMessage): Future[void] {.async.} =
  ## Send a notification
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  let jsonStr = notificationToJson(notification)
  await t.send(jsonStr)
