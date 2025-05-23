## In-memory transport implementation for testing
##
## This module provides an in-memory transport for testing client-server
## communication without network dependencies.

import asyncdispatch
import uuids
import base
import ../protocol

type
  InMemoryTransportPair* = object
    ## A paired client and server transports that can communicate with each other
    clientSide*: InMemoryTransport  ## The client side of the transport
    serverSide*: InMemoryTransport  ## The server side of the transport
    
  InMemoryTransport* = ref object of Transport
    ## Transport implementation that works in-memory for testing
    pairId: string  # Identifier for the transport pair
    direction: TransportDirection  # Direction of the transport (client or server)
    otherSide: InMemoryTransport  # Reference to the other side of the transport
    sentMessages: seq[string]  # All messages sent through this transport

  TransportDirection = enum
    ## Direction of the transport
    Client, Server

proc newInMemoryTransportPair(): InMemoryTransportPair =
  ## Create a new pair of in-memory transports for client-server testing
  let pairId = $genUUID()
  
  var clientSide = InMemoryTransport(
    state: NotStarted,
    pairId: pairId,
    direction: Client,
    sentMessages: @[]
  )
  
  var serverSide = InMemoryTransport(
    state: NotStarted,
    pairId: pairId,
    direction: Server,
    sentMessages: @[]
  )
  
  # Connect the two sides
  clientSide.otherSide = serverSide
  serverSide.otherSide = clientSide
  
  result.clientSide = clientSide
  result.serverSide = serverSide

proc newInMemoryTransport*(): InMemoryTransportPair =
  ## Create a new in-memory transport pair for testing
  result = newInMemoryTransportPair()
  
  # Set default version
  result.clientSide.version = protocol.CURRENT_VERSION
  result.serverSide.version = protocol.CURRENT_VERSION

method start*(t: InMemoryTransport): Future[void] {.async.} =
  ## Start the in-memory transport
  t.state = Started

method stop*(t: InMemoryTransport): Future[void] {.async.} =
  ## Stop the in-memory transport
  t.state = Closing
  t.state = Closed
  if t.onCloseCallback != nil:
    await t.onCloseCallback()

method send*(t: InMemoryTransport, msg: string): Future[void] {.async.} =
  ## Send a message to the other side of the transport
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  # Record the message
  t.sentMessages.add(msg)
  
  # Forward it to the other side if available
  if t.otherSide != nil and t.otherSide.onMessageCallback != nil:
    await t.otherSide.onMessageCallback(msg)

method sendRequestWithVersion*(t: InMemoryTransport, req: RequestMessage, version: MCPVersion): Future[ResponseMessage] {.async, gcsafe.} =
  ## Send a request with specific version formatting and wait for a response
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  let jsonStr = protocol.serializeWithVersion(req, version)
  var responsePromise = newFuture[ResponseMessage]("sendRequestWithVersion")
  
  # Create a handler to receive the response
  proc handleResponse(responseId: string, response: ResponseMessage) {.closure.} =
    if responseId == req.id:
      responsePromise.complete(response)
  
  # Register a temporary handler
  proc messageHandler(msg: string) {.async.} =
    try:
      # Use base.parseJsonRpc to avoid ambiguity
      let parsed = base.parseJsonRpc(msg)
      if parsed.isResponse:
        let response = protocol.parseResponseWithVersion(msg, version)
        if response.id == req.id:
          responsePromise.complete(response)
    except:
      echo "Error handling response: " & getCurrentExceptionMsg()
  
  # Register temporary handler on ourself
  let oldHandler = t.onMessageCallback
  proc combinedHandler(msg: string) {.async.} =
    # Process through our temporary handler
    await messageHandler(msg)
    # Forward to the original handler if any
    if oldHandler != nil:
      await oldHandler(msg)
  
  t.onMessageCallback = combinedHandler
  
  # Send the request
  await t.send(jsonStr)
  
  # Wait for the response with timeout
  try:
    return await responsePromise
  finally:
    # Restore the original handler
    t.onMessageCallback = oldHandler

method sendRequest*(t: InMemoryTransport, req: RequestMessage): Future[ResponseMessage] {.async, gcsafe.} =
  ## Send a request and wait for a response using the transport's version
  # Call the version-specific method but handle the Future manually
  var fut = t.sendRequestWithVersion(req, t.version)
  # Wait for completion
  while not fut.finished:
    await sleepAsync(1)
  
  if fut.failed:
    raise fut.error
  
  return fut.read

method sendNotificationWithVersion*(t: InMemoryTransport, notification: NotificationMessage, version: MCPVersion): Future[void] {.async.} =
  ## Send a notification with specific version formatting
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  let jsonStr = protocol.serializeWithVersion(notification, version)
  await t.send(jsonStr)

method sendNotification*(t: InMemoryTransport, notification: NotificationMessage): Future[void] {.async.} =
  ## Send a notification using the transport's version
  # Call the version-specific method but without directly using await
  var fut = t.sendNotificationWithVersion(notification, t.version)
  # Wait for completion and return a new Future
  while not fut.finished:
    await sleepAsync(1)
  
  if fut.failed:
    raise fut.error
  
  return

proc getSentMessages*(t: InMemoryTransport): seq[string] =
  ## Get all messages sent through this transport (for testing)
  t.sentMessages