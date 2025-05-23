# Model Context Protocol (MCP) Server SDK for Nim
#
# Basic tests for the MCP SDK.

import unittest, json, options, asyncdispatch
import ../src/mcp
import ../src/mcp/types
import ../src/mcp/protocol

suite "MCP Protocol Tests":
  test "JSON-RPC message serialization":
    let request = createRequest("test/method", %*{"foo": "bar"}, "123")
    let serialized = serialize(request)
    let expected = """{"jsonrpc":"2.0","id":"123","method":"test/method","params":{"foo":"bar"}}"""
    check(serialized.parseJson() == expected.parseJson())
    
  test "JSON-RPC response serialization":
    let response = createSuccessResponse("123", %*{"result": "success"})
    let serialized = serialize(response)
    let expected = """{"jsonrpc":"2.0","id":"123","result":{"result":"success"}}"""
    check(serialized.parseJson() == expected.parseJson())
    
  test "JSON-RPC error response serialization":
    let response = createErrorResponse("123", -32602, "Invalid parameters")
    let serialized = serialize(response)
    let expected = """{"jsonrpc":"2.0","id":"123","error":{"code":-32602,"message":"Invalid parameters"}}"""
    check(serialized.parseJson() == expected.parseJson())
    
  test "Request message parsing":
    let jsonStr = """{"jsonrpc":"2.0","id":"123","method":"test/method","params":{"foo":"bar"}}"""
    let request = parseRequest(jsonStr)
    
    check(request.id == "123")
    check(request.methodName == "test/method")
    check(request.params["foo"].getStr() == "bar")

suite "MCP Resource Tests":
  test "Resource URI validation":
    check(validateResourceUri("file:///path/to/file.txt") == true)
    check(validateResourceUri("custom://resource/path") == true)
    check(validateResourceUri("://invalid") == false)
    check(validateResourceUri("invalid") == false)
    check(validateResourceUri("protocol://") == false)

  test "Resource creation":
    let resource = newResource(
      "file:///example.txt",
      "Example Text File",
      some("A text file example"),
      some("text/plain")
    )
    
    check(resource["uri"].getStr() == "file:///example.txt")
    check(resource["name"].getStr() == "Example Text File")
    check(resource["description"].getStr() == "A text file example")
    check(resource["mimeType"].getStr() == "text/plain")

suite "MCP Server Tests":
  test "Server initialization":
    let metadata = protocol.ServerMetadata(
      name: "test-server",
      version: "1.0.0"
    )
    
    let capabilities = ServerCapabilities(
      resources: some(ResourcesCapability(listChanged: some(true))),
      tools: some(ToolsCapability(listChanged: some(true)))
    )
    
    let server = newServer(metadata, capabilities)
    
    check(server.name == "test-server")
    check(server.version == "1.0.0")
    check(server.capabilities.resources.isSome)
    check(server.capabilities.tools.isSome)

