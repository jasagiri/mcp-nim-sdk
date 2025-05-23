# Model Context Protocol (MCP) Server SDK for Nim
#
# Tests for the MCP server implementation.

import unittest, json, asyncdispatch, options
import ../src/mcp/server
import ../src/mcp/protocol
import ../src/mcp/types
import ../src/mcp/resources
import ../src/mcp/tools

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
    
    check(server.config.metadata.name == "test-server")
    check(server.config.metadata.version == "1.0.0")
    check(server.config.capabilities.resources.isSome)
    check(server.config.capabilities.tools.isSome)
    
    # Check that the server has the expected supported methods
    check(METHOD_INITIALIZE in server.supportedRequestMethods)
    check(METHOD_LIST_RESOURCES in server.supportedRequestMethods)
    check(METHOD_READ_RESOURCE in server.supportedRequestMethods)
    check(METHOD_LIST_TOOLS in server.supportedRequestMethods)
    check(METHOD_CALL_TOOL in server.supportedRequestMethods)

suite "MCP Server Resource Tests":
  test "Resource registration":
    let metadata = types.ServerMetadata(
      name: "resource-server",
      version: "1.0.0"
    )
    
    let capabilities = ServerCapabilities(
      resources: some(ResourcesCapability())
    )
    
    let server = newServer(metadata, capabilities)
    
    # Register a resource
    server.resourceRegistry.registerResource(
      "file:///test.txt",
      "Test File",
      some("A test file"),
      some("text/plain"),
      proc(): JsonNode =
        return %*{
          "contents": [
            {
              "uri": "file:///test.txt",
              "mimeType": "text/plain",
              "text": "This is a test file content."
            }
          ]
        }
    )
    
    # Get resources list
    let resources = server.resourceRegistry.getResources()
    
    check(resources.len == 1)
    check(resources[0]["uri"].getStr() == "file:///test.txt")
    check(resources[0]["name"].getStr() == "Test File")
    check(resources[0]["description"].getStr() == "A test file")
    check(resources[0]["mimeType"].getStr() == "text/plain")
    
    # Test resource content retrieval
    let content = server.resourceRegistry.getResource("file:///test.txt")
    check(content.isSome)
    check(content.get()["contents"][0]["text"].getStr() == "This is a test file content.")

suite "MCP Server Tools Tests":
  test "Tool registration":
    let metadata = types.ServerMetadata(
      name: "tool-server",
      version: "1.0.0"
    )
    
    let capabilities = ServerCapabilities(
      tools: some(ToolsCapability())
    )
    
    let server = newServer(metadata, capabilities)
    
    # Register a tool
    server.toolRegistry.registerTool(
      "add",
      "Add two numbers",
      %*{
        "type": "object",
        "properties": {
          "a": {"type": "number"},
          "b": {"type": "number"}
        },
        "required": ["a", "b"]
      },
      proc(args: JsonNode): Future[JsonNode] {.async.} =
        let a = args["a"].getFloat()
        let b = args["b"].getFloat()
        
        return %*{
          "result": a + b
        }
    )
    
    # Get tools list
    let tools = server.toolRegistry.getToolDefinitions()
    
    check(tools.len == 1)
    check(tools[0]["name"].getStr() == "add")
    check(tools[0]["description"].getStr() == "Add two numbers")
    check(tools[0]["inputSchema"].kind == JObject)
    
    # Test tool execution
    let args = %*{"a": 2, "b": 3}
    let result = waitFor server.toolRegistry.executeTool("add", args)
    
    check(result.isSome)
    check(result.get()["result"].getFloat() == 5.0)
    
    # Test unknown tool
    let unknownResult = waitFor server.toolRegistry.executeTool("unknown", %*{})
    check(unknownResult.isNone)
