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
  
  test "Client creation with transport":
    # Create a proper transport using the inmemory transport
    let transportPair = newInMemoryTransport()
    let client = newClient(transportPair.clientSide)
    check(client != nil)
    check(client.isInitialized == false)
    check(client.transport == transportPair.clientSide)
    check(client.serverInfo.isNone)
    # Values from test-client are used by default
    check(client.name == "test-client")
    check(client.version == "1.0.0")
  
  test "ResourceInfo object":
    var resInfo = ResourceInfo(
      uri: "test://resource",
      name: "Test Resource",
      description: "A test resource"
    )
    resInfo.mimeType = some("text/plain")
    
    check(resInfo.uri == "test://resource")
    check(resInfo.name == "Test Resource")
    check(resInfo.description == "A test resource")
    check(resInfo.mimeType.isSome)
    check(resInfo.mimeType.get() == "text/plain")
  
  test "ResourceContent text object":
    var content = ResourceContent(
      uri: "test://resource",
      mimeType: some("text/plain"),
      isText: true,
      text: "Hello, world!"
    )
    
    check(content.uri == "test://resource")
    check(content.mimeType.isSome)
    check(content.mimeType.get() == "text/plain")
    check(content.isText == true)
    check(content.text == "Hello, world!")
  
  test "ResourceContent binary object":
    var content = ResourceContent(
      uri: "test://resource",
      mimeType: some("application/octet-stream"),
      isText: false,
      blob: "SGVsbG8sIHdvcmxkIQ=="  # base64 for "Hello, world!"
    )
    
    check(content.uri == "test://resource")
    check(content.mimeType.isSome)
    check(content.mimeType.get() == "application/octet-stream")
    check(content.isText == false)
    check(content.blob == "SGVsbG8sIHdvcmxkIQ==")
  
  test "ToolInfo object":
    var toolInfo = ToolInfo(
      name: "test-tool",
      description: "A test tool",
      inputSchema: %*{
        "type": "object",
        "properties": {
          "arg1": {"type": "string"}
        }
      }
    )
    
    check(toolInfo.name == "test-tool")
    check(toolInfo.description == "A test tool")
    check(toolInfo.inputSchema.kind == JObject)
    check(toolInfo.inputSchema["type"].getStr() == "object")
  
  test "ToolResult success object":
    var result = types.ToolResult(
      isError: false,
      content: @[%*{"result": "success"}]
    )
    
    check(result.isError == false)
    check(result.content.len == 1)
    check(result.content[0]["result"].getStr() == "success")
  
  test "ToolResult error object":
    var result = types.ToolResult(
      isError: true,
      content: @[]
    )
    
    check(result.isError == true)
    check(result.content.len == 0)
