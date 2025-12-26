# Model Context Protocol (MCP) Server SDK for Nim
#
# Tests for the MCP server implementation.

import unittest, json, asyncdispatch, options, tables
import ../src/mcp/protocol
import ../src/mcp/types

suite "MCP Server Initialization Tests":
  test "Server initialization":
    let metadata = types.ServerMetadata(
      name: "test-server",
      version: "1.0.0"
    )

    let capabilities = ServerCapabilities(
      resources: some(ResourcesCapability()),
      tools: some(ToolsCapability())
    )

    let server = newServer(metadata, capabilities)

    check(server.name == "test-server")
    check(server.version == "1.0.0")
    check(server.capabilities.resources.isSome)
    check(server.capabilities.tools.isSome)

suite "MCP Server Resource Tests":
  test "Resource registration":
    let metadata = types.ServerMetadata(
      name: "test-server",
      version: "1.0.0"
    )

    let capabilities = ServerCapabilities(
      resources: some(ResourcesCapability())
    )

    let server = newServer(metadata, capabilities)

    server.registerResource(
      "test://resource1",
      "Test Resource 1",
      "A test resource",
      "text/plain"
    )

    check(server.resources.contains("test://resource1"))
    check(server.resources["test://resource1"].name == "Test Resource 1")
    check(server.resources["test://resource1"].description == "A test resource")
    check(server.resources["test://resource1"].mimeType == "text/plain")

suite "MCP Server Tool Tests":
  test "Tool registration":
    let metadata = types.ServerMetadata(
      name: "test-server",
      version: "1.0.0"
    )

    let capabilities = ServerCapabilities(
      tools: some(ToolsCapability())
    )

    let server = newServer(metadata, capabilities)

    server.registerTool(
      "test_tool",
      "A test tool",
      %*{
        "type": "object",
        "properties": {
          "arg1": {"type": "string"}
        }
      }
    )

    check(server.tools.contains("test_tool"))
    check(server.tools["test_tool"].name == "test_tool")
    check(server.tools["test_tool"].description == "A test tool")
    check(server.tools["test_tool"].inputSchema["type"].getStr() == "object")
