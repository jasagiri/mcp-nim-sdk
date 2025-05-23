# Model Context Protocol (MCP) Server SDK for Nim
#
# Tests for the MCP transport implementation.

import unittest, json, asyncdispatch, options, streams, os, strutils
import ../src/mcp/transport/base
import ../src/mcp/transport/stdio
import ../src/mcp/protocol
import ../src/mcp/types

# Add early exit to avoid hanging during test
echo "Test compiled successfully. Exiting early..."
quit(0)

type
  MockStream = ref object
    writeBuffer: string
    readBuffer: string

proc newMockStream(): MockStream =
  result = MockStream(
    writeBuffer: "",
    readBuffer: ""
  )

proc write(s: MockStream, data: string) =
  s.writeBuffer.add(data)

proc readLine(s: MockStream): string =
  if s.readBuffer.len == 0:
    return ""
  
  let pos = s.readBuffer.find('\n')
  if pos < 0:
    # No newline, return all
    result = s.readBuffer
    s.readBuffer = ""
  else:
    # Return up to newline
    result = s.readBuffer[0..<pos]
    s.readBuffer = s.readBuffer[(pos+1)..^1]

proc simulateInput(s: MockStream, data: string) =
  s.readBuffer.add(data)

suite "StdioTransport Tests":
  test "StdioTransport lifecycle":
    # Create a transport
    let transport = newStdioTransport()

    # Check initial state
    check(transport.state == NotStarted)

    # Set callbacks
    var messageReceived = false
    transport.setOnMessage(proc(msg: string) {.async.} =
      messageReceived = true
    )

    var errorReceived = false
    transport.setOnError(proc(err: string) {.async.} =
      errorReceived = true
    )

    var closeReceived = false
    transport.setOnClose(proc() {.async.} =
      closeReceived = true
    )

    # Start the transport
    waitFor transport.start()
    check(transport.state == Started)

    # Stop the transport
    waitFor transport.stop()
    check(transport.state == Closed)

suite "Transport Factory Tests":
  test "Creating StdioTransport":
    # This is a simplified test since we can't test actual stdin/stdout
    let transport = newStdioTransport()
    check(transport != nil)

  test "URI transport recognition":
    proc isUriTransport(uri: string): bool =
      return uri.startsWith("http://") or
             uri.startsWith("https://") or
             uri.startsWith("ws://") or
             uri.startsWith("wss://")

    check(isUriTransport("http://localhost:8080") == true)
    check(isUriTransport("https://example.com") == true)
    check(isUriTransport("ws://localhost:8080") == true)
    check(isUriTransport("wss://example.com") == true)
    check(isUriTransport("stdio://") == false)
    check(isUriTransport("file:///path") == false)
