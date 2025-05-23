## Stdio transport implementation for the Model Context Protocol (MCP).
##
## This module provides a transport that uses standard input and output for
## communication, suitable for local process communication.

import base
import ../protocol
import asyncdispatch
import asyncfile
import json
import strutils
import tables
import options
import system

type
  MockStream* = ref object of RootObj
    ## For testing

  StdioTransport* = ref object of Transport
    ## Transport implementation using standard input and output
    readStream: AsyncFile
    writeStream: AsyncFile
    pendingRequests: Table[string, Future[ResponseMessage]]
    # For testing
    testInputObj: RootRef  # Store reference to the input stream for testing
    testOutputObj: RootRef # Store reference to the output stream for testing
    isTestMode: bool

proc newStdioTransport*(): StdioTransport =
  ## Create a new stdio transport instance
  result = StdioTransport(
    state: NotStarted,
    readStream: nil,
    writeStream: nil,
    pendingRequests: initTable[string, Future[ResponseMessage]](),
    isTestMode: false
  )

proc newStdioTransport*[I, O](inputStream: I, outputStream: O): StdioTransport =
  ## Create a new stdio transport instance with custom streams for testing
  result = StdioTransport(
    state: NotStarted,
    readStream: nil,
    writeStream: nil,
    pendingRequests: initTable[string, Future[ResponseMessage]](),
    testInputObj: cast[RootRef](inputStream),
    testOutputObj: cast[RootRef](outputStream),
    isTestMode: true
  )

proc messageHandler(t: StdioTransport, jsonStr: string) {.async.} =
  ## Handle incoming messages from the stdio stream
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

proc readLoop(t: StdioTransport) {.async.} =
  ## Continuously read from stdin and process messages
  while t.state == Started:
    try:
      if not t.isTestMode:
        # For real usage, we use the async file
        let line = await t.readStream.readLine()
        if line.len > 0:
          asyncCheck t.messageHandler(line)
      else:
        # For testing, we'll just wait and let test inject messages
        await sleepAsync(50)
    except:
      if t.state == Started and t.onErrorCallback != nil:
        await t.onErrorCallback("Error reading from input: " & getCurrentExceptionMsg())
      if t.state == Started:
        t.state = Closing
        if t.onCloseCallback != nil:
          await t.onCloseCallback()
        t.state = Closed
      break

method start*(t: StdioTransport): Future[void] {.async.} =
  ## Start the stdio transport
  if t.state != NotStarted:
    raise newException(MCPTransportError, "Transport already started")

  t.state = Starting

  if not t.isTestMode:
    t.readStream = newAsyncFile(AsyncFD(0))  # stdin file descriptor is always 0
    t.writeStream = newAsyncFile(AsyncFD(1)) # stdout file descriptor is always 1

  t.state = Started

  asyncCheck t.readLoop()

method stop*(t: StdioTransport): Future[void] {.async.} =
  ## Stop the stdio transport
  if t.state != Started:
    return

  t.state = Closing
  # No need to close stdin/stdout, just mark as closed
  t.state = Closed
  
  if t.onCloseCallback != nil:
    await t.onCloseCallback()

method send*(t: StdioTransport, msg: string): Future[void] {.async.} =
  ## Send a raw message through the stdio transport
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")

  try:
    if not t.isTestMode:
      # For real usage, we use the async file
      await t.writeStream.write(msg & "\n")
      # No flush method available in AsyncFile
    else:
      # For testing mode, we'll use the test methods in test cases
      # This is simplified for now - test methods handle the output
      discard
  except:
    if t.onErrorCallback != nil:
      await t.onErrorCallback("Error writing to output: " & getCurrentExceptionMsg())
    raise newException(MCPTransportError, "Failed to send message: " & getCurrentExceptionMsg())

method sendRequestWithVersion*(t: StdioTransport, req: RequestMessage, version: MCPVersion): Future[ResponseMessage] {.async.} =
  ## Send a request with specific version formatting and wait for a response
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  let jsonStr = serializeWithVersion(req, version)
  var promise = newFuture[ResponseMessage]("sendRequestWithVersion")
  t.pendingRequests[req.id] = promise
  
  try:
    await t.send(jsonStr)
  except:
    t.pendingRequests.del(req.id)
    raise
    
  return await promise

method sendRequest*(t: StdioTransport, req: RequestMessage): Future[ResponseMessage] {.async.} =
  ## Send a request and wait for a response
  return await t.sendRequestWithVersion(req, t.version)

method sendNotificationWithVersion*(t: StdioTransport, notification: NotificationMessage, version: MCPVersion): Future[void] {.async.} =
  ## Send a notification with specific version formatting
  if t.state != Started:
    raise newException(MCPTransportError, "Transport not started")
    
  let jsonStr = serializeWithVersion(notification, version)
  await t.send(jsonStr)

method sendNotification*(t: StdioTransport, notification: NotificationMessage): Future[void] {.async.} =
  ## Send a notification
  # Call the version-specific method but handle the Future manually
  var fut = t.sendNotificationWithVersion(notification, t.version)
  # Wait for completion
  while not fut.finished:
    await sleepAsync(1)
  
  if fut.failed:
    raise fut.error
  
  return
