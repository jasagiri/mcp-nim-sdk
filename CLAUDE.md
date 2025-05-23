# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

The MCP Nim SDK implements the Model Context Protocol (MCP) specification in the Nim programming language. MCP is an open protocol for standardizing how applications provide context to Large Language Models (LLMs), acting as a "USB-C port for AI applications" that enables connections between AI models and various data sources and tools.

## Build & Development Commands

### Environment Setup

Ensure Nim 2.2.2+ is installed (current development uses 2.2.4):

```bash
# Check Nim version
nim --version
```

### Package Management

```bash
# Install dependencies
nimble install

# Install a specific dependency
nimble install jsony httpbeast ws uri3 uuids
```

### Building

```bash
# Build a specific file
nim c path/to/file.nim

# Build and run in one command
nim c -r path/to/file.nim

# Build with release optimization
nim c -d:release path/to/file.nim

# Build the library
nimble buildLib

# Full build process
nimble build
```

### Testing

```bash
# Run all tests
nimble test

# Run a specific test file
nim c -r tests/test_client.nim

# Run a test with more detailed output
nim c -r tests/test_client.nim --verbose

# Run a single test with environment variable
TEST_FILE=test_client.nim scripts/tests/test.sh
```

### Documentation

```bash
# Generate documentation
nimble docs
```

### Clean Build Artifacts

```bash
# Clean build artifacts
nimble clean
```

### Running Examples

```bash
# Run a simple client
nim c -r examples/base/simple_client.nim

# Run a simple server
nim c -r examples/base/simple_server.nim

# Run an HTTP server example
nim c -r examples/http/http_server.nim

# Run an HTTP client
nim c -r examples/http/http_client.nim

# Run a file resource example
nim c -r examples/fileresource/file_resource_server.nim

# Run a database example
nim c -r examples/database/database_server.nim
```

## Code Architecture

### Core Components

1. **Transport Layer** (`src/mcp/transport/`)
   - Abstracts communication mechanisms (HTTP, stdio, SSE, in-memory)
   - All transports implement the base Transport interface
   - Each transport handles serialization and message exchange

2. **Protocol Layer** (`src/mcp/protocol.nim`)
   - Implements JSON-RPC message formatting and parsing
   - Handles request-response lifecycle
   - Manages protocol versioning (2025-03-26)

3. **Client Implementation** (`src/mcp/client.nim`)
   - Connects to MCP servers
   - Discovers and interacts with server capabilities
   - Manages client-side capabilities (sampling)

4. **Server Implementation** (`src/mcp/server.nim`)
   - Hosts resources and tools
   - Handles incoming client requests
   - Manages server-side capabilities

5. **Resources System** (`src/mcp/resources.nim`)
   - Manages text and binary data access
   - Implements the resource URI scheme
   - Handles resource discovery and templating

6. **Tools System** (`src/mcp/tools.nim`)
   - Defines executable functions with JSON schema
   - Manages tool registration and execution
   - Handles parameter validation

7. **Roots System** (`src/mcp/roots.nim`)
   - Hierarchical organization of resources
   - Resource navigation and discovery
   - Tree-like structure for organizing data

8. **Sampling System** (`src/mcp/sampling.nim`)
   - LLM interaction capabilities
   - Handles completion requests and responses
   - Manages sampling parameters and controls

9. **Prompts System** (`src/mcp/prompts.nim`)
   - Predefined message templates
   - Parameter substitution in prompts
   - Structured prompt management

10. **Logger** (`src/mcp/logger.nim`)
    - Handles logging with different levels
    - Configurable logging output
    - Consistent logging format

### Key Architectural Patterns

1. **Capability-Based Design**
   - Features are organized into distinct capabilities
   - Clients and servers declare supported capabilities
   - Protocol handles capability negotiation

2. **Async-First Architecture**
   - Uses Nim's asyncdispatch for non-blocking operations
   - Most operations return Future objects
   - Follows async/await pattern for concurrency

3. **Pluggable Transports**
   - Transport mechanisms are interchangeable
   - Common interface for all transport types
   - Allows for flexible deployment options

4. **Resource-Oriented Architecture**
   - Resources identified by URIs
   - CRUD operations on resources
   - Template-based resource discovery

5. **Type-Safe JSON Handling**
   - Schema validation for tool parameters
   - Structured serialization/deserialization
   - Error handling for malformed data

## Integration Patterns

The typical pattern for integrating this SDK involves:

1. **Creating a Server**:
   ```nim
   let serverInfo = Implementation(
     name: "example-server",
     version: "1.0.0"
   )
   
   let capabilities = ServerCapabilities(
     resources: some(ResourcesCapability()),
     tools: some(ToolsCapability())
   )
   
   let server = newServer(serverInfo, capabilities)
   ```

2. **Registering Resources and Tools**:
   ```nim
   # Add text resource
   server.addTextResource(
     "example://hello",
     "Hello Resource",
     "Hello, world!",
     description = some("A simple hello world resource"),
     mimeType = some("text/plain")
   )
   
   # Register tool
   proc echoHandler(args: JsonNode): Future[JsonNode] {.async.} =
     let message = args["message"].getStr()
     return createToolSuccessResult("You said: " & message)
   
   server.registerToolHandler(
     "echo",
     some("Echo a message back"),
     %*{
       "type": "object",
       "properties": {
         "message": {"type": "string", "description": "Message to echo"}
       },
       "required": ["message"]
     },
     echoHandler
   )
   ```

3. **Setting up Transport**:
   ```nim
   # For stdio
   let transport = newStdioTransport()
   
   # For HTTP
   let transport = newHttpTransport("localhost", 8080)
   
   # For SSE
   let transport = newSseTransport("localhost", 8080)
   ```

4. **Connecting and Running**:
   ```nim
   # Connect transport
   waitFor server.connect(transport)
   
   # For HTTP/SSE, start the server
   waitFor transport.listen()
   
   # Keep server running
   while true:
     waitFor sleepAsync(1000)
   ```

5. **Client Connection**:
   ```nim
   let client = newClient()
   
   # Connect to server
   let transport = newStdioTransport()  # or other transport
   waitFor client.connect(transport)
   
   # Use server capabilities
   let resources = waitFor client.listResources()
   let result = waitFor client.callTool("echo", %*{"message": "Hello"})
   ```

## Testing Patterns

1. **Unit Testing**:
   ```nim
   import unittest
   
   test "Resource registration":
     let registry = newResourceRegistry()
     registry.registerResource("test://resource", "Test", "Test content")
     check(registry.hasResource("test://resource"))
   ```

2. **In-Memory Transport Testing**:
   ```nim
   test "Client-server communication":
     # Setup in-memory transport for testing
     let transport = newInMemoryTransport()
     
     # Setup server with the transport
     let server = newServer(...)
     waitFor server.connect(transport.serverSide)
     
     # Setup client with the transport
     let client = newClient()
     waitFor client.connect(transport.clientSide)
     
     # Test interaction
     let result = waitFor client.callTool("echo", %*{"message": "Hello"})
     check(result.isSuccess)
   ```

3. **Mock Server Testing**:
   ```nim
   test "Client behavior with mock server":
     # Create mock server that returns predefined responses
     let mockTransport = newMockTransport([
       (method: "mcp/resources/list", response: %*{"resources": [...]})
     ])
     
     let client = newClient()
     waitFor client.connect(mockTransport)
     
     # Test client with mock responses
     let resources = waitFor client.listResources()
     check(resources.len > 0)
   ```

## Common Patterns

1. **Error Handling**:
   ```nim
   try:
     let result = await client.callTool("tool", args)
     # Process result
   except TransportError:
     echo "Communication error: ", getCurrentExceptionMsg()
   except ProtocolError:
     echo "Protocol error: ", getCurrentExceptionMsg()
   except:
     echo "Unexpected error: ", getCurrentExceptionMsg()
   ```

2. **Resource URI Patterns**:
   - `file:///path/to/file` - File system resources
   - `http://host/path` - HTTP resources
   - `db://database/table?query=value` - Database resources
   - `custom://scheme/path` - Custom application resources