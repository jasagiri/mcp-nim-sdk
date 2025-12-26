# Model Context Protocol (MCP) Server SDK for Nim
#
# Echo Server Example - A simple server that echoes back messages.

import unittest, asyncdispatch, json, options, tables
import ../src/mcp/types
import ../src/mcp/tools
import ../src/mcp/protocol

suite "Echo Server Tests":
  test "Server creation and tool registration":
    # Create server metadata
    let metadata = types.ServerMetadata(
      name: "echo-server",
      version: "1.0.0"
    )

    # Create server capabilities
    let capabilities = types.ServerCapabilities(
      resources: some(types.ResourcesCapability(listChanged: some(true))),
      tools: some(types.ToolsCapability(listChanged: some(true)))
    )

    # Create server instance
    var server = newServer(metadata, capabilities)

    check(server.name == "echo-server")
    check(server.version == "1.0.0")

    # Register an echo tool directly with the server
    server.registerTool(
      "echo",
      "Echoes back the input text",
      %*{
        "type": "object",
        "properties": {
          "text": {
            "type": "string",
            "description": "The text to echo back"
          }
        },
        "required": ["text"]
      }
    )

    check(server.tools.contains("echo"))
    check(server.tools["echo"].description == "Echoes back the input text")

  test "Tool handler registration":
    let metadata = types.ServerMetadata(name: "echo-server", version: "1.0.0")
    let capabilities = types.ServerCapabilities(
      tools: some(types.ToolsCapability())
    )
    var server = newServer(metadata, capabilities)

    server.registerTool("echo", "Echo tool", %*{"type": "object"})

    server.registerToolHandler("echo", proc(args: JsonNode): Future[JsonNode] {.async.} =
      if not args.hasKey("text"):
        return tools.newToolError("Missing required parameter: text")
      let text = args["text"].getStr()
      return tools.newToolSuccess("Echo: " & text)
    )

    check(server.tools["echo"].handler.isSome)

  test "Resource registration":
    let metadata = types.ServerMetadata(name: "echo-server", version: "1.0.0")
    let capabilities = types.ServerCapabilities(
      resources: some(types.ResourcesCapability())
    )
    var server = newServer(metadata, capabilities)

    # Add a sample resource
    server.registerResource(
      "echo://examples/hello",
      "Hello World Example",
      "A simple hello world resource",
      "text/plain"
    )

    check(server.resources.contains("echo://examples/hello"))
    check(server.resources["echo://examples/hello"].name == "Hello World Example")
    check(server.resources["echo://examples/hello"].mimeType == "text/plain")

  test "Server disconnect":
    proc testDisconnect() {.async.} =
      let metadata = types.ServerMetadata(name: "echo-server", version: "1.0.0")
      let capabilities = types.ServerCapabilities()
      var server = newServer(metadata, capabilities)

      await server.disconnect()
      check(server.transport == nil)

    waitFor testDisconnect()
