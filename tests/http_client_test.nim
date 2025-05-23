## HTTP Client Integration Test for MCP Server
##
## This script tests basic operations with the HTTP MCP server

import std/asyncdispatch
import std/httpclient
import std/json
import std/strformat
import std/strutils

proc testHttpClient() {.async.} =
  let client = newAsyncHttpClient()
  defer: client.close()

  echo "Testing MCP HTTP server..."

  # Test creating a session
  echo "Creating new session..."
  let createResponse = await client.post("http://localhost:8080/session")
  if createResponse.code != Http200:
    echo "Failed to create session: ", createResponse.code
    return

  let sessionData = parseJson(await createResponse.body)
  let sessionId = sessionData["sessionId"].getStr()
  echo &"Created session: {sessionId}"

  # Test sending a message
  echo "Sending echo message..."
  let message = %*{
    "id": "1",
    "method": "echo",
    "params": {"message": "Hello from test client"}
  }
  
  let sendResponse = await client.post(
    &"http://localhost:8080/message?sessionId={sessionId}",
    body = $message,
    headers = newHttpHeaders({"Content-Type": "application/json"})
  )
  
  if sendResponse.code != Http200:
    echo "Failed to send message: ", sendResponse.code
    return

  let responseData = parseJson(await sendResponse.body)
  echo "Server response: ", responseData.pretty()

  # Test polling for messages
  echo "Polling for messages..."
  let pollResponse = await client.get(
    &"http://localhost:8080/poll?sessionId={sessionId}"
  )
  
  if pollResponse.code == Http204:
    echo "No messages available (expected)"
  else:
    let pollData = parseJson(await pollResponse.body)
    echo "Polled message: ", pollData.pretty()

  echo "All tests completed successfully!"

when isMainModule:
  waitFor testHttpClient()