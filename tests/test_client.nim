# Model Context Protocol (MCP) Server SDK for Nim
#
# Tests for the MCP client implementation.

import std/json
import std/options
import std/asyncdispatch
import unittest
import ../src/mcp/client
import ../src/mcp/types
import ../src/mcp/transport/inmemory

proc newTestClient(): Client =
  ## Create a test client with default values
  let capabilities = types.ClientCapabilities(
    resources: some(true),
    tools: some(true),
    sampling: some(true)
  )
  newClient("test-client", "1.0.0", capabilities)

# Create a test suite for client implementation
suite "MCP Client Tests":
  test "Client creation":
    let client = newTestClient()
    check(client != nil)
    check(client.isInitialized == false)
    check(client.transport == nil)
    check(client.serverInfo.isNone)
    check(client.name == "test-client")
    check(client.version == "1.0.0")
    check(client.capabilities.resources.isSome)
    check(client.capabilities.resources.get() == true)
    check(client.capabilities.tools.isSome)
    check(client.capabilities.tools.get() == true)
    check(client.capabilities.sampling.isSome)
    check(client.capabilities.sampling.get() == true)

  test "Resource type":
    let resource = types.Resource(
      uri: "test://resource",
      name: "Test Resource",
      description: some("A test resource"),
      mimeType: some("text/plain")
    )

    check(resource.uri == "test://resource")
    check(resource.name == "Test Resource")
    check(resource.description.isSome)
    check(resource.description.get() == "A test resource")
    check(resource.mimeType.isSome)
    check(resource.mimeType.get() == "text/plain")

  test "Tool type":
    let tool = types.Tool(
      name: "test-tool",
      description: some("A test tool"),
      inputSchema: %*{
        "type": "object",
        "properties": {
          "arg1": {"type": "string"}
        }
      }
    )

    check(tool.name == "test-tool")
    check(tool.description.isSome)
    check(tool.description.get() == "A test tool")
    check(tool.inputSchema.kind == JObject)
    check(tool.inputSchema["type"].getStr() == "object")
