## Base transport interface for the Model Context Protocol (MCP).
##
## This module defines the common interface for all transport implementations.

import ../protocol
import asyncdispatch
import json
import options

type
  TransportState* = enum
    ## Possible states for a transport
    NotStarted,   ## Transport is initialized but not started
    Starting,     ## Transport is in the process of starting
    Started,      ## Transport is started and ready for communication
    Closing,      ## Transport is in the process of closing
    Closed        ## Transport is closed

  Transport* = ref object of RootObj
    ## Abstract base transport class
    state*: TransportState
    version*: MCPVersion ## Protocol version to use
    onMessageCallback*: proc(msg: string) {.async, gcsafe.}
    onErrorCallback*: proc(err: string) {.async, gcsafe.}
    onCloseCallback*: proc() {.async, gcsafe.}

  MCPTransportError* = object of CatchableError
    ## Base exception for transport errors

method start*(t: Transport): Future[void] {.base, async.} =
  ## Start the transport
  raise newException(MCPTransportError, "start() method must be implemented by subclass")

method sendRequestWithVersion*(t: Transport, request: RequestMessage, version: MCPVersion): Future[ResponseMessage] {.base, async, gcsafe.} =
  ## Send a request message with specific version protocol formatting
  raise newException(MCPTransportError, "sendRequestWithVersion() method must be implemented by subclass")

method sendRequest*(t: Transport, request: RequestMessage): Future[ResponseMessage] {.base, async, gcsafe.} =
  ## Send a request message using transport's configured version
  # Implementation note: we don't use await directly here to avoid Future handling issues
  # Subclasses should override this method for proper implementation
  # This is a placeholder that raises an error if not implemented
  raise newException(MCPTransportError, "sendRequest() method must be implemented by subclass")

method stop*(t: Transport): Future[void] {.base, async.} =
  ## Stop the transport
  raise newException(MCPTransportError, "stop() method must be implemented by subclass")

method send*(t: Transport, msg: string): Future[void] {.base, async, gcsafe.} =
  ## Send a message through the transport
  raise newException(MCPTransportError, "send() method must be implemented by subclass")


method sendNotificationWithVersion*(t: Transport, notification: NotificationMessage, version: MCPVersion): Future[void] {.base, async, gcsafe.} =
  ## Send a notification with specific version protocol formatting
  raise newException(MCPTransportError, "sendNotificationWithVersion() method must be implemented by subclass")

method sendNotification*(t: Transport, notification: NotificationMessage): Future[void] {.base, async, gcsafe.} =
  ## Send a notification using transport's configured version
  # Implementation note: we don't use await directly here to avoid Future handling issues
  # Subclasses should override this method for proper implementation
  # This is a placeholder that raises an error if not implemented
  raise newException(MCPTransportError, "sendNotification() method must be implemented by subclass")

method setOnMessage*(t: Transport, callback: proc(msg: string) {.async, gcsafe.}) {.base.} =
  ## Set the callback for received messages
  t.onMessageCallback = callback

proc setOnError*(t: Transport, callback: proc(err: string) {.async, gcsafe.}) =
  ## Set the callback for errors
  t.onErrorCallback = callback

proc setOnClose*(t: Transport, callback: proc() {.async, gcsafe.}) =
  ## Set the callback for transport closure
  t.onCloseCallback = callback

proc requestToJson*(req: RequestMessage): string =
  ## Convert a request message to a JSON-RPC 2.0 string
  var jsonRpc = %{
    "jsonrpc": %"2.0",
    "id": %req.id,
    "method": %req.methodName,
    "params": req.params
  }
  return $jsonRpc

proc notificationToJson*(notification: NotificationMessage): string =
  ## Convert a notification message to a JSON-RPC 2.0 string
  var jsonRpc = %{
    "jsonrpc": %"2.0",
    "method": %notification.methodName,
    "params": notification.params
  }
  return $jsonRpc

proc responseToJson*(resp: ResponseMessage): string =
  ## Convert a response message to a JSON-RPC 2.0 string
  var jsonRpc = %{
    "jsonrpc": %"2.0",
    "id": %resp.id
  }
  
  if resp.result.isSome():
    jsonRpc["result"] = resp.result.get()
  elif resp.error.isSome():
    var errorObj = %{
      "code": %resp.error.get().code,
      "message": %resp.error.get().message
    }
    if resp.error.get().data.isSome():
      errorObj["data"] = resp.error.get().data.get()
    jsonRpc["error"] = errorObj
    
  return $jsonRpc

proc parseJsonRpc*(jsonStr: string): tuple[isRequest: bool, isNotification: bool, isResponse: bool, msg: JsonNode] =
  ## Parse a JSON-RPC 2.0 string and determine its type
  let jsonNode = parseJson(jsonStr)
  
  if not jsonNode.hasKey("jsonrpc") or jsonNode["jsonrpc"].getStr() != "2.0":
    raise newException(MCPTransportError, "Invalid JSON-RPC 2.0 message")
  
  let isRequest = jsonNode.hasKey("method") and jsonNode.hasKey("id")
  let isNotification = jsonNode.hasKey("method") and not jsonNode.hasKey("id")
  let isResponse = jsonNode.hasKey("id") and (jsonNode.hasKey("result") or jsonNode.hasKey("error"))
  
  return (isRequest, isNotification, isResponse, jsonNode)
