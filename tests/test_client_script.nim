import unittest
import asyncdispatch, json, options, tables
import ../src/mcp/client
import ../src/mcp/transport/inmemory
import ../src/mcp/protocol
import ../src/mcp/types
import ../src/mcp/server

# Use Nim's built-in unittest framework
suite "MCP Client Tests":
  test "Client initialization and tool calling":
    proc testClientScript() {.async.} =
      # Create a test server
      let serverInfo = types.ServerMetadata(
        name: "TestServer",
        version: "1.0.0"
      )
      
      let capabilities = ServerCapabilities(
        tools: some(ToolsCapability())
      )
      
      let server = newServer(serverInfo, capabilities)
      
      # Register a simple echo tool
      proc echoHandler(args: JsonNode): Future[JsonNode] {.async.} =
        let message = args["message"].getStr()
        result = %*{
          "isError": false,
          "content": [
            {"text": message}
          ]
        }
      
      server.registerTool(
        "echo",
        "Echoes back the input",
        %*{
          "type": "object",
          "properties": {
            "message": {"type": "string"}
          },
          "required": ["message"]
        }
      )
      
      server.registerToolHandler("echo", echoHandler)
      
      # Create in-memory transport
      let transport = newInMemoryTransport()
      
      # Connect server to transport
      await server.connect(transport.serverSide)
      
      # Create and connect client
      let clientCapabilities = types.ClientCapabilities(
        tools: some(true)
      )
      let client = newClient("TestClient", "1.0.0", clientCapabilities)
      await client.connect(transport.clientSide)
      
      # List tools and verify
      let tools = await client.listTools()
      check(tools.len == 1)
      check(tools[0].name == "echo")
      
      # Call the echo tool
      let response = await client.callTool("echo", %*{"message": "test"})
      
      # Verify response
      check(not response.isError)
      check(response.content.len > 0)
      check(response.content[0]["text"].getStr() == "test")
      
      # Clean up
      await client.disconnect()
      await server.disconnect()
    
    waitFor testClientScript()

# For command line running
when isMainModule:
  # Default unittest behavior when run directly
  discard