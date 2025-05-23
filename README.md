# MCP Nim SDK

Model Context Protocol (MCP) implementation in Nim, conforming to the MCP specification version 2025-03-26.

## Overview

This SDK provides a complete Nim implementation of the Model Context Protocol, allowing applications to:

- Create MCP clients that connect to servers
- Create MCP servers that provide resources, tools, prompts, roots, and sampling
- Use different transport methods (stdio, HTTP/SSE, in-memory)
- Handle protocol lifecycle and capabilities
- Leverage Nim's async/await pattern for non-blocking operations

## Components

- **protocol**: Core protocol types and message handling
- **transport**: Transport implementations (stdio, HTTP/SSE, in-memory)
- **client**: Client-side implementation
- **server**: Server-side implementation
- **resources**: Resource management system
- **tools**: Tool registration and execution system
- **roots**: Hierarchical organization of resources
- **sampling**: LLM interaction capabilities
- **prompts**: Predefined message templates

## Transport Options

The SDK supports multiple transport mechanisms for different use cases:

1. **Streamable HTTP Transport**: 
   - HTTP transport with SSE (Server-Sent Events) for server-to-client streaming
   - Follows the 2025-03-26 specification for Streamable HTTP
   - Supports session management and bidirectional communication
   - Example: `examples/http/http_server.nim` and `examples/http/http_client.nim`

2. **SSE Transport**:
   - Uses HTTP with Server-Sent Events for server-to-client streaming
   - Provides efficient real-time updates from server to client
   - Example: `examples/sse/sse_server.nim` and `examples/sse/sse_client.nim`

3. **Stdio Transport**:
   - Uses standard input/output for local process communication
   - Ideal for embedding MCP in command-line tools or local applications
   - Simple synchronous message passing

4. **InMemory Transport**:
   - Completely in-process transport for testing and development
   - No network or I/O overhead
   - Perfect for unit testing or simulating client-server interactions
   - Example: `examples/inmemory/inmemory_test.nim`

## Usage

### Client Example

```nim
import asyncdispatch
import json
import mcp

# Create a client with specified capabilities
let clientCaps = ClientCapabilities(
  resources: some(true),
  tools: some(true)
)
let client = newClient("example-client", "1.0.0", clientCaps)

# Connect to a server using HTTP transport
let transport = newStreamableHttpTransport("http://localhost:8080")
waitFor client.connect(transport)

# List resources (async operation)
let resources = waitFor client.listResources()
for resource in resources:
  echo "Resource: ", resource.name, " (", resource.uri, ")"

# Call a tool (async operation)
let toolResult = waitFor client.callTool("echo", %*{"message": "Hello, MCP!"})
echo "Result: ", toolResult

# Disconnect when done
waitFor client.disconnect()
```

### Server Example

```nim
import asyncdispatch
import json
import options
import mcp

# Create a server with metadata and capabilities
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
  "This is a sample text resource",
  "text/plain"
)

# Define a tool handler function (async)
proc echoHandler(args: JsonNode): Future[JsonNode] {.async.} =
  let message = args["message"].getStr()
  result = %*{
    "isError": false,
    "content": [
      {"text": "Echo: " & message}
    ]
  }

# Register the tool
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

# Connect using HTTP transport
let transport = newStreamableHttpTransport("0.0.0.0", 8080)
waitFor server.connect(transport)

# Start listening
waitFor transport.listen()

# Keep the server running
while true:
  waitFor sleepAsync(1000)
```

### InMemory Transport Example (for Testing)

```nim
import asyncdispatch
import mcp
import mcp/transport/inmemory

# Create server and client
let server = newServer(...)
let client = newClient()

# Create an in-memory transport pair
let transportPair = newInMemoryTransportPair()

# Connect both sides
await server.connect(transportPair.serverSide)
await client.connect(transportPair.clientSide)

# Use client and server as normal - they communicate through memory
let resources = await client.listResources()
let toolResult = await client.callTool("echo", %*{"message": "Test"})

# No network or process I/O is involved
```

## Running Examples

```bash
# HTTP Server example
nim c -r examples/http/http_server.nim

# HTTP Client example
nim c -r examples/http/http_client.nim

# SSE Server example
nim c -r examples/sse/sse_server.nim

# SSE Client example
nim c -r examples/sse/sse_client.nim

# InMemory Transport example (client and server in same process)
nim c -r examples/inmemory/inmemory_test.nim
```

## Documentation

See the `docs/` directory for detailed documentation and the `examples/` directory for more usage examples.

## License

MIT