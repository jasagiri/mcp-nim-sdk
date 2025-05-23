## HTTP Client example for MCP
##
## This example demonstrates a client that connects to the HTTP MCP server
## using the Streamable HTTP transport as defined in the MCP 2025-03-26 specification.

import std/asyncdispatch
import std/json
import std/options
import std/strutils
import std/os
import std/terminal

import ../../src/mcp
import ../../src/mcp/transport/http

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
proc runHttpClient() {.async.} =
  printColored("HTTP MCP Client Example (2025-03-26 Specification)", fgWhite, false)
  printColored(" (Connecting to http://localhost:8080)", fgGreen)
  
  # Create a client with capabilities
  let clientCapabilities = ClientCapabilities(
    sampling: some(true)
  )
  let client = newClient("http-client", "1.0.0", clientCapabilities)
  
  # Create a streamable HTTP transport
  let transport = newStreamableHttpTransport("http://localhost:8080")
  
  try:
    # Connect to server
    printColored("Connecting to server...", fgYellow)
    await client.connect(transport)
    printColored("Connected to HTTP MCP server.", fgGreen)
    
    # List available resources
    printHeader("Resources")
    let resources = await client.listResources()
    
    if resources.len == 0:
      printColored("No resources available.", fgRed)
    else:
      for resource in resources:
        printColored("Resource: " & resource.name & " (" & resource.uri & ")", fgWhite)
        if resource.description.len > 0:
          printColored("  Description: " & resource.description, fgWhite)
        if resource.mimeType.isSome:
          printColored("  MIME Type: " & resource.mimeType.get(), fgWhite)
    
    # Read a resource
    printHeader("Reading Resource")
    try:
      let resourceUri = "example://text"
      printColored("Reading resource: " & resourceUri, fgYellow)
      let textResource = await client.readResource(resourceUri)
      
      if textResource.len > 0:
        let content = textResource[0]
        if content.isText:
          printColored("Content: " & content.text, fgGreen)
        else:
          printColored("Content is binary data.", fgYellow)
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
        if tool.description.len > 0:
          printColored("  Description: " & tool.description, fgWhite)
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
      "message": "Hello from HTTP MCP client!"
    }
    printColored("Calling 'echo' tool with message: " & echoArgs["message"].getStr(), fgYellow)
    
    try:
      let echoResult = await client.callTool("echo", echoArgs)
      printColored("Result: " & $echoResult, fgGreen)
    except Exception as e:
      printColored("Error calling echo tool: " & e.msg, fgRed)
    
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
  printColored("Starting HTTP MCP Client example (2025-03-26 Specification)...", fgWhite)
  waitFor runHttpClient()
