# Model Context Protocol (MCP) SDK for Nim

This is a complete Nim implementation of the Model Context Protocol (MCP), an open protocol that enables secure, controlled interactions between AI applications and local or remote resources. MCP acts as a standardized interface ("USB-C port for AI applications") that connects AI models with various data sources and tools. This implementation conforms to the MCP specification version 2025-11-25 (latest stable).

## Overview

The Model Context Protocol (MCP) is built around a client-server architecture:

- **MCP Hosts**: Programs like Claude Desktop, IDEs, or AI tools that access resources through MCP
- **MCP Clients**: Protocol clients that maintain 1:1 connections with servers
- **MCP Servers**: Lightweight programs that expose specific capabilities through the protocol
- **Local Resources**: Computer resources (databases, files, services) that MCP servers can securely access
- **Remote Resources**: Resources available over the internet that MCP servers can connect to

This SDK provides both client and server implementations of the MCP, allowing Nim applications to:

- Create MCP servers that expose resources, tools, prompts, roots and sampling
- Create MCP clients that connect to servers and use their capabilities
- Implement custom transport mechanisms for communication
- Request and process sampling/completions from LLMs
- Utilize the asynchronous programming model for non-blocking operations

## Features

- Full implementation of the MCP protocol (versions 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25)
- Support for resources (text and binary)
- Support for tools (executable functions)
- Support for sampling (LLM completions)
- Support for roots (hierarchical organization of resources)
- Support for prompts (predefined message templates)
- Multiple transport mechanisms:
  - Streamable HTTP transport with Server-Sent Events (SSE)
  - Stdio transport for local process communication
  - In-memory transport for testing
- Fully asynchronous design using Nim's asyncdispatch
- Type-safe JSON handling with schema validation

## Installation

```bash
nimble install mcp_nim_sdk
```

## Getting Started

### Creating a Server

```nim
import std/asyncdispatch
import std/json
import std/options
import mcp

# Create server with metadata and capabilities
let serverInfo = ServerMetadata(
  name: "example-server",
  version: "1.0.0"
)

let capabilities = ServerCapabilities(
  resources: some(ResourcesCapability()),
  tools: some(ToolsCapability())
)

let server = newServer(serverInfo, capabilities)

# Register a text resource
server.registerResource(
  "example://hello",
  "Hello Resource",
  "Hello, world!",
  description = "A simple hello world resource",
  mimeType = "text/plain"
)

# Register tools with async handler
proc echoHandler(args: JsonNode): Future[JsonNode] {.async.} =
  let message = args["message"].getStr()
  return %*{
    "isError": false,
    "content": [
      {"text": "Echo: " & message}
    ]
  }

server.registerTool(
  "echo",
  "Echo a message back",
  %*{
    "type": "object",
    "properties": {
      "message": {"type": "string", "description": "Message to echo"}
    },
    "required": ["message"]
  }
)
server.registerToolHandler("echo", echoHandler)

# Setup transport - either stdio or HTTP
# Option 1: Stdio transport
let stdioTransport = newStdioTransport()
waitFor server.connect(stdioTransport)

# Option 2: HTTP transport with SSE
let httpTransport = newStreamableHttpTransport("0.0.0.0", 8080)
waitFor server.connect(httpTransport)
waitFor httpTransport.listen()

# Keep server running
while true:
  waitFor sleepAsync(1000)
```

### Creating a Client

```nim
import std/asyncdispatch
import std/json
import std/options
import mcp

# Create client with capabilities
let clientCaps = ClientCapabilities(
  resources: some(true),
  tools: some(true),
  sampling: some(false)
)
let client = newClient("example-client", "1.0.0", clientCaps)

# Connect to server
# Option 1: Stdio transport for local processes
let stdioTransport = newStdioTransport()
waitFor client.connect(stdioTransport)

# Option 2: HTTP transport for remote servers
let httpTransport = newStreamableHttpTransport("http://localhost:8080")
waitFor client.connect(httpTransport)

# List resources (async)
let resources = waitFor client.listResources()
for resource in resources:
  echo "Resource: ", resource.name, " (", resource.uri, ")"

# Read a resource (async)
let textResource = waitFor client.readResource("example://hello")
echo "Content: ", textResource

# Call a tool (async)
let result = waitFor client.callTool("echo", %*{"message": "Hello, MCP!"})
echo "Tool result: ", result

# Disconnect when done
waitFor client.disconnect()
```

## Architecture

The MCP Nim SDK has a layered architecture:

1. **Transport Layer**
   - Abstracts communication mechanisms (HTTP, stdio, in-memory)
   - All transports implement the base Transport interface
   - Handles serialization, message exchange, and connections

2. **Protocol Layer**
   - Implements JSON-RPC message formatting and parsing
   - Handles request-response lifecycle
   - Manages protocol versioning

3. **Capability Layers**
   - Resources: Text and binary data access
   - Tools: Executable functions with JSON schema
   - Roots: Hierarchical organization of resources
   - Sampling: LLM interaction capabilities
   - Prompts: Predefined message templates

4. **Client/Server Implementation**
   - Client: Connects to servers, discovers capabilities
   - Server: Hosts capabilities, handles requests

## Asynchronous Programming

The MCP Nim SDK is designed with asynchronous programming as a core principle, using Nim's `asyncdispatch` module:

- Most API methods return `Future[T]` types
- Async/await pattern is used throughout the codebase
- Non-blocking I/O operations for efficient communication
- Event-driven callbacks for handling messages and events
- Proper error handling for async operations

Example of async usage:

```nim
# Async function
proc processRequest(client: Client): Future[void] {.async.} =
  # Parallel operations
  let resourcesFuture = client.listResources()
  let toolsFuture = client.listTools()
  
  # Wait for both to complete
  let resources = await resourcesFuture
  let tools = await toolsFuture
  
  # Process results
  for resource in resources:
    echo "Resource: ", resource.name
  
  for tool in tools:
    echo "Tool: ", tool.name
    
  # Error handling with try/except
  try:
    let result = await client.callTool("example", %*{})
    echo "Success: ", result
  except:
    echo "Error: ", getCurrentExceptionMsg()

# Execute the async function
waitFor processRequest(client)
```

## Documentation

- [API Reference](api.md): Detailed API documentation
- [Streamable HTTP Best Practices](streamable_http_best_practices.md): Guidelines for implementing HTTP-based transports
- [Roots Management](roots_best_practices.md): Information about using the roots capability
- [Prompts Usage](prompts_best_practices.md): Information about using the prompts capability
- [Tools Implementation](tools_best_practices.md): Guidelines for implementing tools
- [Resources Management](resources_best_practices.md): Information about managing resources
- [Transport Mechanisms](transports_best_practices.md): Overview of transport implementations

## Examples

Check out the examples directory for more complete examples:

- [Simple Server](../examples/base/simple_server.nim): A basic MCP server that exposes resources and tools
- [Simple Client](../examples/base/simple_client.nim): A basic MCP client that connects to a server
- [Database Server](../examples/database/database_server.nim): An MCP server that provides access to a database
- [File Resource Server](../examples/fileresource/file_resource_server.nim): Server that exposes local file system resources
- [HTTP Server](../examples/http/http_server.nim): Example of HTTP/SSE-based transport implementation
- [HTTP Client](../examples/http/http_client.nim): Client using the Streamable HTTP transport

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

For more information about MCP, visit the [official MCP documentation](https://modelcontextprotocol.ai/).
