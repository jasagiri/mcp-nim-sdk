# Model Context Protocol (MCP) Server SDK for Nim
#
# Tests for the InMemoryTransport implementation.

import unittest
import asyncdispatch
import json
import options
import ../src/mcp/protocol
import ../src/mcp/transport/base
import ../src/mcp/transport/inmemory

suite "InMemoryTransport Tests":
  test "Transport pair creation":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Check that both sides were created
    check(pair.clientSide != nil)
    check(pair.serverSide != nil)
    
    # We can't directly access otherSide as it's private
    # But we can check that they can communicate with each other
    
    # Check initial state
    check(pair.clientSide.state == NotStarted)
    check(pair.serverSide.state == NotStarted)
    
    # Check version
    check(pair.clientSide.version == protocol.CURRENT_VERSION)
    check(pair.serverSide.version == protocol.CURRENT_VERSION)
  
  test "Starting and stopping transports":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Start both transports
    waitFor pair.clientSide.start()
    waitFor pair.serverSide.start()
    
    # Check state after starting
    check(pair.clientSide.state == Started)
    check(pair.serverSide.state == Started)
    
    # Stop both transports
    waitFor pair.clientSide.stop()
    waitFor pair.serverSide.stop()
    
    # Check state after stopping
    check(pair.clientSide.state == Closed)
    check(pair.serverSide.state == Closed)
  
  test "Message sending and receiving":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Variables to track received messages
    var clientReceivedMessage {.threadvar.}: string
    var serverReceivedMessage {.threadvar.}: string
    clientReceivedMessage = ""
    serverReceivedMessage = ""
    
    # Set up message handlers
    pair.clientSide.setOnMessage(proc(msg: string) {.async, gcsafe.} =
      clientReceivedMessage = msg
    )
    
    pair.serverSide.setOnMessage(proc(msg: string) {.async, gcsafe.} =
      serverReceivedMessage = msg
    )
    
    # Start both transports
    waitFor pair.clientSide.start()
    waitFor pair.serverSide.start()
    
    # Send messages in both directions
    waitFor pair.clientSide.send("hello from client")
    waitFor pair.serverSide.send("hello from server")
    
    # Check that messages were received
    check(serverReceivedMessage == "hello from client")
    check(clientReceivedMessage == "hello from server")
    
    # Check sent messages list
    let clientSent = pair.clientSide.getSentMessages()
    let serverSent = pair.serverSide.getSentMessages()
    
    check(clientSent.len == 1)
    check(clientSent[0] == "hello from client")
    
    check(serverSent.len == 1)
    check(serverSent[0] == "hello from server")
  
  test "Sending request and receiving response":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Set up server-side to handle requests
    pair.serverSide.setOnMessage(proc(msg: string) {.async, gcsafe.} =
      # Parse the message
      let parsed = base.parseJsonRpc(msg)
      if parsed.isRequest:
        let request = protocol.parseRequest(msg)
        # Create a response
        let response = ResponseMessage(
          id: request.id,
          result: some(%*{"success": true}),
          error: none(ErrorInfo)
        )
        # Send the response
        await pair.serverSide.send(protocol.serialize(response))
    )
    
    # Start both transports
    waitFor pair.clientSide.start()
    waitFor pair.serverSide.start()
    
    # Create and send a request
    let request = RequestMessage(
      id: "test-request-id",
      methodName: "test/method",
      params: %*{"param1": "value1"}
    )
    
    # Send the request and wait for response
    let response = waitFor pair.clientSide.sendRequest(request)
    
    # Check the response
    check(response.id == request.id)
    check(response.error.isNone)
    check(response.result.isSome)
    check(response.result.get()["success"].getBool() == true)
    
  test "Sending request with specific version":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Set up server-side to handle requests with version
    pair.serverSide.setOnMessage(proc(msg: string) {.async, gcsafe.} =
      # Parse the message
      let msgJson = parseJson(msg)
      if msgJson.hasKey("id") and msgJson.hasKey("method"):
        # Extract the request ID
        let requestId = msgJson["id"].getStr()
        
        # Create a response with the same version format used in protocol.nim
        let responseJson = %*{
          "jsonrpc": "2.0",
          "id": requestId,
          "result": {"success": true}
        }
        
        # Send the response
        await pair.serverSide.send($responseJson)
    )
    
    # Start both transports
    waitFor pair.clientSide.start()
    waitFor pair.serverSide.start()
    
    # Create a request
    let request = RequestMessage(
      id: "test-version-request-id",
      methodName: "test/method",
      params: %*{"param1": "value1"}
    )
    
    # Define a custom version
    let testVersion = MCPVersion(
      kind: VersionDate,
      version: "2024-01-15"
    )
    
    # Send the request with specific version and wait for response
    let response = waitFor pair.clientSide.sendRequestWithVersion(request, testVersion)
    
    # Check the response
    check(response.id == request.id)
    check(response.error.isNone)
    check(response.result.isSome)
    check(response.result.get()["success"].getBool() == true)
  
  test "Sending notification":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Variable to track received notifications
    var receivedNotification {.threadvar.}: NotificationMessage
    
    # Set up server-side to handle notifications
    pair.serverSide.setOnMessage(proc(msg: string) {.async, gcsafe.} =
      # Parse the message
      let parsed = base.parseJsonRpc(msg)
      if parsed.isNotification:
        receivedNotification = protocol.parseNotification(msg)
    )
    
    # Start both transports
    waitFor pair.clientSide.start()
    waitFor pair.serverSide.start()
    
    # Create and send a notification
    let notification = NotificationMessage(
      methodName: "test/notification",
      params: %*{"param1": "value1"}
    )
    
    # Send the notification
    waitFor pair.clientSide.sendNotification(notification)
    
    # Wait a bit for processing
    waitFor sleepAsync(10)
    
    # Check the received notification
    check(receivedNotification.methodName == notification.methodName)
    check($receivedNotification.params == $notification.params)
    
  test "Sending notification with specific version":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Variable to track received notifications
    var receivedNotification {.threadvar.}: string
    receivedNotification = ""
    
    # Set up server-side to handle notifications
    pair.serverSide.setOnMessage(proc(msg: string) {.async, gcsafe.} =
      receivedNotification = msg
    )
    
    # Start both transports
    waitFor pair.clientSide.start()
    waitFor pair.serverSide.start()
    
    # Create a notification
    let notification = NotificationMessage(
      methodName: "test/notification-with-version",
      params: %*{"param1": "value1"}
    )
    
    # Custom version for test
    let testVersion = MCPVersion(
      kind: VersionDate,
      version: "2023-06-30"
    )
    
    # Send the notification with specific version
    waitFor pair.clientSide.sendNotificationWithVersion(notification, testVersion)
    
    # Wait a bit for processing
    waitFor sleepAsync(10)
    
    # Check the received notification has expected format
    check(receivedNotification.len > 0)
    let parsedMsg = parseJson(receivedNotification)
    check(parsedMsg.hasKey("jsonrpc"))
    check(parsedMsg.hasKey("method"))
    check(parsedMsg.hasKey("params"))
    check(parsedMsg["jsonrpc"].getStr() == "2.0")
    check(parsedMsg["method"].getStr() == notification.methodName)
    # Version information isn't directly visible in the JSON anymore, 
    # it's handled internally by the protocol module
  
  test "Error handling for send before start":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Try to send without starting (should raise)
    expect MCPTransportError:
      waitFor pair.clientSide.send("test message")
  
  test "Error handling for send after stop":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Start and then stop
    waitFor pair.clientSide.start()
    waitFor pair.clientSide.stop()
    
    # Try to send after stopping (should raise)
    expect MCPTransportError:
      waitFor pair.clientSide.send("test message")
  
  test "OnClose callback":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Flag to track if callback was called
    var closeCalled {.threadvar.}: bool
    closeCalled = false
    
    # Set up close handler
    pair.clientSide.setOnClose(proc() {.async, gcsafe.} =
      closeCalled = true
    )
    
    # Start and then stop
    waitFor pair.clientSide.start()
    waitFor pair.clientSide.stop()
    
    # Check that close callback was called
    check(closeCalled == true)
    
  test "Error handling in message handler for sendRequestWithVersion":
    # Create a new transport pair
    let pair = newInMemoryTransport()
    
    # Start both transports
    waitFor pair.clientSide.start()
    waitFor pair.serverSide.start()
    
    # Set up server-side to handle messages with malformed responses
    pair.serverSide.setOnMessage(proc(msg: string) {.async, gcsafe.} =
      # Parse the message
      let msgJson = parseJson(msg)
      if msgJson.hasKey("id") and msgJson.hasKey("method"):
        # Send back a properly formed response with an error field
        let errorResponse = %*{
          "jsonrpc": "2.0",
          "id": msgJson["id"].getStr(),
          "error": {
            "code": -32000,
            "message": "Test error response"
          }
        }
        
        await pair.serverSide.send($errorResponse)
    )
    
    # Create a request
    let request = RequestMessage(
      id: "test-error-handling",
      methodName: "test/error",
      params: %*{}
    )
    
    # The response should include the error from our error response above
    let response = waitFor pair.clientSide.sendRequestWithVersion(request, protocol.CURRENT_VERSION)
    
    # Check the response contains the expected error
    check(response.id == request.id)
    check(response.result.isNone)
    check(response.error.isSome)
    check(response.error.get().code == -32000)
    check(response.error.get().message == "Test error response")