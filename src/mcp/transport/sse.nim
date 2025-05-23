## Server-Sent Events (SSE) transport implementation for the Model Context Protocol (MCP).
##
## This module provides a transport that uses HTTP with Server-Sent Events (SSE)
## for server-to-client streaming and HTTP POST for client-to-server communication.

import base
import ../protocol
import asyncdispatch
import json
import httpClient
import asynchttpserver
import uri
import strutils
import tables
import options

type
  SSETransport* = ref object of Transport
    ## Transport implementation using HTTP with Server-Sent Events (SSE)
    endpoint*: string
    httpClient: AsyncHttpClient
    eventSource: EventSource
    pendingRequests: Table[string, Future[ResponseMessage]]

  EventSource = ref object
    ## EventSource implementation for SSE
    url: string
    client: AsyncHttpClient
    onMessage: proc(msg: string) {.async.}
    active: bool

proc newEventSource(url: string, onMessage: proc(msg: string) {.async.}): EventSource =
  ## Create a new EventSource for SSE
  result = EventSource(
    url: url,
    client: newAsyncHttpClient(),
    onMessage: onMessage,
    active: false
  )

proc start(es: EventSource) {.async.} =
  ## Start the EventSource connection
  es.active = true
  
  while es.active:
    try:
      let response = await es.client.get(es.url)
      var buffer = ""
      
      # Process the SSE stream
      let content = await response.bodyStream.readAll()
      let lines = content.splitLines()
      
      for line in lines:
        if line.len == 0:
          # Empty line indicates the end of an event
          if buffer.len > 0:
            await es.onMessage(buffer)
            buffer = ""
          continue
          
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

proc newSSETransport*(endpoint: string): SSETransport =
  ## Create a new SSE transport instance
  result = SSETransport(
    state: NotStarted,
    endpoint: endpoint,
    httpClient: nil,
    eventSource: nil,
    pendingRequests: initTable[string, Future[ResponseMessage]]()
  )

proc messageHandler(t: SSETransport, jsonStr: string) {.async.} =
  ## Handle incoming messages from the SSE stream
  try:
    # Use base.parseJsonRpc to avoid ambiguity
    let parsed = base.parseJsonRpc(jsonStr)
    if parsed.isResponse:
      let jsonNode = parsed.msg
      let id = jsonNode["id"].getStr()
      
      if t.pendingRequests.hasKey(id):
        var resp = ResponseMessage(id: id)
        
        if jsonNode.hasKey("result"):
          resp.result = some(jsonNode["result"])
          resp.error = none(ErrorInfo)
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
            
          resp.result = none(JsonNode)
          resp.error = some(errInfo)
          
        let promise = t.pendingRequests[id]
        t.pendingRequests.del(id)
        promise.complete(resp)
      else:
        if t.onErrorCallback != nil:
          await t.onErrorCallback("Received response for unknown request ID: " & id)
    else:
      if t.onMessageCallback != nil:
        await t.onMessageCallback(jsonStr)
  except:
    if t.onErrorCallback != nil:
      await t.onErrorCallback("Error processing message: " & getCurrentExceptionMsg())

method start*(t: SSETransport): Future[void] {.async.} =
  ## Start the SSE transport
  if t.state != NotStarted:
    raise newException(MCPTransportError, "Transport already started")
    
  t.state = Starting
  t.httpClient = newAsyncHttpClient()
  
  # Setup the EventSource for server-to-client communication
  let sseUrl = t.endpoint & "/events"
  t.eventSource = newEventSource(sseUrl, proc(msg: string) {.async.} =
    await t.messageHandler(msg)
  )
  
  asyncCheck t.eventSource.start()
  t.state = Started

method stop*(t: SSETransport): Future[void] {.async.} =
  ## Stop the SSE transport
  if t.state != Started:
    return

  t.state = Closing
  await t.eventSource.stop()
  t.httpClient.close()
  t.state = Closed
  
  if t.onCloseCallback != nil:
    await t.onCloseCallback()

method send*(t: SSETransport, msg: string): Future[void] {.async.} =
  ## Send a raw message through the SSE transport
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  try:
    # Send the message using HTTP POST
    let postUrl = t.endpoint & "/message"
    t.httpClient.headers = newHttpHeaders({"Content-Type": "application/json"})
    let response = await t.httpClient.post(postUrl, body = msg)
    
    if response.code != Http200:
      raise newException(MCPTransportError, "HTTP error: " & $response.code & " " & response.status)
  except:
    if t.onErrorCallback != nil:
      await t.onErrorCallback("Error sending message: " & getCurrentExceptionMsg())
    raise newException(MCPTransportError, "Failed to send message: " & getCurrentExceptionMsg())

method sendRequestWithVersion*(t: SSETransport, req: RequestMessage, version: MCPVersion): Future[ResponseMessage] {.async.} =
  ## Send a request with specific version formatting and wait for a response
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  let jsonStr = protocol.serializeWithVersion(req, version)
  var promise = newFuture[ResponseMessage]("sendRequestWithVersion")
  t.pendingRequests[req.id] = promise
  
  try:
    await t.send(jsonStr)
  except:
    t.pendingRequests.del(req.id)
    raise
    
  return await promise
    
method sendRequest*(t: SSETransport, req: RequestMessage): Future[ResponseMessage] {.async.} =
  ## Send a request and wait for a response using transport's version
  # Call the version-specific method but handle the Future manually
  var fut = t.sendRequestWithVersion(req, t.version)
  # Wait for completion
  while not fut.finished:
    await sleepAsync(1)
  
  if fut.failed:
    raise fut.error
  
  return fut.read

method sendNotificationWithVersion*(t: SSETransport, notification: NotificationMessage, version: MCPVersion): Future[void] {.async.} =
  ## Send a notification with specific version formatting
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  let jsonStr = protocol.serializeWithVersion(notification, version)
  await t.send(jsonStr)

method sendNotification*(t: SSETransport, notification: NotificationMessage): Future[void] {.async.} =
  ## Send a notification using transport's version
  # Call the version-specific method but handle the Future manually
  var fut = t.sendNotificationWithVersion(notification, t.version)
  # Wait for completion
  while not fut.finished:
    await sleepAsync(1)
  
  if fut.failed:
    raise fut.error
  
  return
