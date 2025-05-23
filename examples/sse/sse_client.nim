## SSE Client example for MCP
##
## This example demonstrates a client that connects to the SSE MCP server
## using the SSE transport as defined in the MCP 2025-03-26 specification.

import std/asyncdispatch
import std/json
import std/options
import std/strutils
import std/os
import std/terminal

import ../../src/mcp
import ../../src/mcp/transport/sse

# Print colored output for better readability
proc printColored(text: string, color: ForegroundColor, newline: bool = true) =
  setForegroundColor(stdout, color)
  if newline:
    echo text
  else:
    stdout.write(text)
  resetAttributes(stdout)

# Print a header
proc printHeader(text: string) =
  echo ""
  printColored("=== " & text & " ===", fgCyan)

# Main client function
proc runSseClient() {.async.} =
  printColored("SSE MCP Client Example (2025-03-26 Specification)", fgWhite, false)
  printColored(" (Connecting to http://localhost:8085)", fgGreen)
  
  # Create a client
  let client = newClient()
  
  # Create a SSE transport
  let transport = newSSETransport("http://localhost:8085")
  
  try:
    # Connect to server
    printColored("Connecting to server...", fgYellow)
    await client.connect(transport)
    printColored("Connected to SSE MCP server.", fgGreen)
    
    # List available resources
    printHeader("Resources")
    let resources = await client.listResources()
    
    if resources.len == 0:
      printColored("No resources available.", fgRed)
    else:
      for resource in resources:
        printColored("Resource: " & resource.name & " (" & resource.uri & ")", fgWhite)
        if resource.description.isSome:
          printColored("  Description: " & resource.description.get(), fgWhite)
        if resource.mimeType.isSome:
          printColored("  MIME Type: " & resource.mimeType.get(), fgWhite)
    
    # Read a text resource
    printHeader("Reading Text Resource")
    try:
      let resourceUri = "example://text"
      printColored("Reading resource: " & resourceUri, fgYellow)
      let textResource = await client.readResource(resourceUri)
      
      if textResource.hasKey("contents") and textResource["contents"].len > 0:
        let content = textResource["contents"][0]
        printColored("Content: " & content["text"].getStr(), fgGreen)
      else:
        printColored("Failed to read resource content.", fgRed)
    except Exception as e:
      printColored("Error reading resource: " & e.msg, fgRed)
    
    # Read a binary resource
    printHeader("Reading Binary Resource")
    try:
      let resourceUri = "example://binary"
      printColored("Reading resource: " & resourceUri, fgYellow)
      let binaryResource = await client.readResource(resourceUri)
      
      if binaryResource.hasKey("contents") and binaryResource["contents"].len > 0:
        let content = binaryResource["contents"][0]
        if content.hasKey("binary"):
          let base64Data = content["binary"].getStr()
          printColored("Base64 Binary Content: " & base64Data[0..20] & "...", fgGreen)
        else:
          printColored("Resource is not in binary format.", fgRed)
      else:
        printColored("Failed to read resource content.", fgRed)
    except Exception as e:
      printColored("Error reading resource: " & e.msg, fgRed)
    
    # List available tools
    printHeader("Tools")
    let tools = await client.listTools()
    
    if tools.len == 0:
      printColored("No tools available.", fgRed)
    else:
      for tool in tools:
        printColored("Tool: " & tool.name, fgWhite)
        if tool.description.isSome:
          printColored("  Description: " & tool.description.get(), fgWhite)
        printColored("  Input Schema: " & $tool.inputSchema, fgWhite)
    
    # Call the time tool
    printHeader("Calling Time Tool")
    let timeArgs = %*{
      "format": "HH:mm:ss on yyyy-MM-dd"
    }
    printColored("Calling 'getCurrentTime' tool with format: " & timeArgs["format"].getStr(), fgYellow)
    
    try:
      let timeResult = await client.callTool("getCurrentTime", timeArgs)
      printColored("Result: " & $timeResult, fgGreen)
    except Exception as e:
      printColored("Error calling time tool: " & e.msg, fgRed)
    
    # Call the echo tool
    printHeader("Calling Echo Tool")
    let echoArgs = %*{
      "message": "Hello from SSE MCP client!"
    }
    printColored("Calling 'echo' tool with message: " & echoArgs["message"].getStr(), fgYellow)
    
    try:
      let echoResult = await client.callTool("echo", echoArgs)
      printColored("Result: " & $echoResult, fgGreen)
    except Exception as e:
      printColored("Error calling echo tool: " & e.msg, fgRed)
    
    # Subscribe to server events
    printHeader("Setting Up Event Handler")
    
    # Register message callback to receive server-initiated messages
    proc messageCallback(msg: string) {.async.} =
      printColored("Server message received: " & msg, fgMagenta)
    
    client.onMessage = messageCallback
    printColored("Event handler set up. Client will display server-initiated messages.", fgGreen)
    
    # Interactive mode
    printHeader("Interactive Mode")
    printColored("Enter messages to send to the echo tool (or 'exit' to quit):", fgCyan)
    
    var running = true
    while running:
      stdout.write("> ")
      let input = stdin.readLine()
      
      if input == "exit":
        running = false
      else:
        # Call the echo tool with user input
        let args = %*{
          "message": input
        }
        
        try:
          let result = await client.callTool("echo", args)
          printColored("Result: " & $result, fgGreen)
        except Exception as e:
          printColored("Error calling echo tool: " & e.msg, fgRed)
  
  except Exception as e:
    printColored("Error: " & e.msg, fgRed)
  
  finally:
    # Disconnect from server
    printHeader("Disconnecting")
    try:
      await client.disconnect()
      printColored("Disconnected from server.", fgGreen)
    except Exception as e:
      printColored("Error disconnecting: " & e.msg, fgRed)

# Run the client
when isMainModule:
  printColored("Starting SSE MCP Client example (2025-03-26 Specification)...", fgWhite)
  waitFor runSseClient()