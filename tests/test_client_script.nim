import unittest
import asyncdispatch, json, options, tables
import ../src/mcp/protocol
import ../src/mcp/types

# Use Nim's built-in unittest framework
suite "MCP Client Tests":
  test "Client creation":
    let clientCapabilities = types.ClientCapabilities(
      tools: some(true)
    )
    let client = newClient("TestClient", "1.0.0", clientCapabilities)

    check(client.name == "TestClient")
    check(client.version == "1.0.0")

  test "Server creation with tools":
    let serverInfo = types.ServerMetadata(
      name: "TestServer",
      version: "1.0.0"
    )

    let capabilities = ServerCapabilities(
      tools: some(ToolsCapability())
    )

    let server = newServer(serverInfo, capabilities)

    check(server.name == "TestServer")
    check(server.version == "1.0.0")

    # Register a tool
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

    check(server.tools.hasKey("echo"))
    check(server.tools["echo"].name == "echo")
    check(server.tools["echo"].description == "Echoes back the input")

# For command line running
when isMainModule:
  # Default unittest behavior when run directly
  discard
