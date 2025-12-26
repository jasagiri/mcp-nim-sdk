# Protocol Versioning in MCP Nim SDK

This document explains how protocol versioning is managed in the MCP Nim SDK, including support for multiple concurrent protocol versions.

## Overview

MCP (Model Context Protocol) evolves over time, with different versions being used. This SDK supports the following major versions:

1. **2024-11-05** - The original standard version (using semantic versioning format)
2. **2025-03-26** - Updated version (using date-based versioning)
3. **2025-06-18** - Added elicitation capabilities and audio content support
4. **2025-11-25** - Latest stable version with task augmentation and enhanced progress notifications

The SDK is designed to support multiple protocol versions simultaneously to maintain compatibility with clients and servers using different versions.

## Version Format Types

MCP versions can be represented in two formats:

1. **Semantic Versioning**: Used by the 2024-11-05 specification
   - Format: `major.minor.patch` (e.g., `1.0.0`)
   - Internally represented as `MCPVersion` with `kind: VersionSemver`

2. **Date-based Versioning**: Used by the 2025-03-26 specification
   - Format: `YYYY-MM-DD` (e.g., `2025-03-26`)
   - Internally represented as `MCPVersion` with `kind: VersionDate`

## Version Representation

The SDK uses a discriminated union `MCPVersion` to handle both version formats:

```nim
type
  MCPVersionSpec* = enum
    ## Supported MCP protocol versions
    VersionSemver, ## 2024-11-05 version (semantic versioning)
    VersionDate    ## 2025-03-26 version (date-based versioning)

  MCPVersion* = object
    ## MCP protocol version
    case kind*: MCPVersionSpec
    of VersionSemver:
      major*: int
      minor*: int
      patch*: int
    of VersionDate:
      version*: string  # Format: YYYY-MM-DD (e.g., "2025-03-26")
```

## Creating Versions

```nim
# Using constants
let v1 = CURRENT_VERSION        # 2025-03-26
let v2 = VERSION_20241105       # 1.0.0

# Create from string (automatically detects format)
let v3 = createVersion("2025-03-26")
let v4 = createVersion("1.0.0")

# Create directly
let v5 = MCPVersion(kind: VersionDate, version: "2025-03-26")
let v6 = MCPVersion(kind: VersionSemver, major: 1, minor: 0, patch: 0)
```

## Version Comparison

The SDK provides operators for comparing versions:

```nim
if v1 > v2:
  echo "v1 is newer than v2"

if v3 == v5:
  echo "v3 and v5 are the same version"

if v4 <= v6:
  echo "v4 is the same as or older than v6"
```

## Version Negotiation

Version negotiation happens during the `initialize` handshake:

1. Client sends an `initialize` request with its protocol version
2. Server determines the highest compatible version it supports
3. Server responds with the negotiated version
4. Both client and server use the negotiated version for all subsequent communication

```nim
# Server side (supporting multiple versions)
let supportedVersions = @[CURRENT_VERSION, VERSION_20241105]
let protocol = newProtocol(CURRENT_VERSION, supportedVersions)

# Client side
let client = newClient()
client.connect(transport) # Version negotiation happens during initialization
```

## Version-Specific Message Formatting

Different protocol versions may have different message formats or field names. The SDK handles this with version-specific serialization and parsing:

```nim
# Serialize with specific version format
let message = createRequest("someMethod", params, "req-1")
let jsonStr1 = serializeWithVersion(message, CURRENT_VERSION)
let jsonStr2 = serializeWithVersion(message, VERSION_20241105)

# Parse with specific version format
let msg1 = parseRequestWithVersion(jsonStr, CURRENT_VERSION)
let msg2 = parseRequestWithVersion(jsonStr, VERSION_20241105)
```

## Example: Notification Method Names

In the 2025-03-26 version, notification method names use a "$/prefix" format:

```
// 2025-03-26 format
{
  "jsonrpc": "2.0",
  "method": "$/initialized",
  "params": {}
}
```

While in the 2024-11-05 version, they use a plain name:

```
// 2024-11-05 format
{
  "jsonrpc": "2.0",
  "method": "initialized",
  "params": {}
}
```

The SDK handles these differences transparently by using version-specific code:

```nim
proc processMessage(msg: JsonNode, version: MCPVersion): JsonNode =
  case version.kind:
  of VersionDate:
    # Process 2025-03-26 format
    # Date-based version, method names with $/ prefix, etc.
    discard
  of VersionSemver:
    # Process 2024-11-05 format
    # Semantic version format, plain method names, etc.
    discard

  # Common processing
  return result
```

## Transport Support

Each transport implementation supports sending messages with specific protocol versions:

```nim
# Send with specific version
let response = await transport.sendRequestWithVersion(request, VERSION_20241105)

# Send with transport's default version
let response = await transport.sendRequest(request)
```

## Key Differences Between Versions

### 2024-11-05

- Uses semantic versioning format (major.minor.patch)
- Notification method names have no prefix (e.g., `initialized`)
- Standard JSON-RPC message format

### 2025-03-26

- Uses date-based versioning format (YYYY-MM-DD)
- Some notification method names have `$/` prefix (e.g., `$/initialized`)
- Support for Streamable HTTP extensions

## Code Examples

### Server Supporting Multiple Versions

```nim
proc main() {.async.} =
  # Create a server with 2025-03-26 as the default version
  let metadata = ServerMetadata(
    name: "multi-version-server",
    version: "1.0.0"
  )
  
  # Support both versions
  let supportedVersions = @[CURRENT_VERSION, VERSION_20241105]
  let protocol = newProtocol(CURRENT_VERSION, supportedVersions)
  
  let capabilities = ServerCapabilities(
    resources: some(ResourcesCapability())
  )
  
  let server = newServer(metadata, capabilities, protocol)
  
  # Set up version-specific handlers
  server.protocol.setRequestHandler("someMethod", 
    proc(req: RequestMessage): ResponseMessage {.gcsafe.} =
      # Implementation for 2025-03-26 protocol
      return createSuccessResponse(req.id, %*{"result": "2025-03-26 response"})
    , VersionDate
  )
  
  server.protocol.setRequestHandler("someMethod", 
    proc(req: RequestMessage): ResponseMessage {.gcsafe.} =
      # Implementation for 2024-11-05 protocol
      return createSuccessResponse(req.id, %*{"result": "2024-11-05 response"})
    , VersionSemver
  )
  
  # Start the server
  let transport = newStdioTransport()
  transport.version = CURRENT_VERSION  # Set default version
  await server.connect(transport)
  
  # Run the server
  while true:
    await sleepAsync(100)
```

### Client with Automatic Version Detection

```nim
proc main() {.async.} =
  # Create a client
  let client = newClient()
  
  # Create transport (version is automatically detected during initialization)
  let transport = newStdioTransport()
  
  # Connect to server
  await client.connect(transport)
  
  # At this point, version negotiation is complete and the appropriate version is set
  echo "Negotiated protocol version: ", client.protocol.version
  
  # Send request (automatically formatted using the negotiated version)
  let result = await client.callTool("someMethod", %*{"param": "value"})
  
  # Process the result
  echo "Result: ", result
```

## Testing Version Compatibility

To test compatibility between different versions:

```nim
import unittest
import mcp

test "Version compatibility":
  # Test 2025-03-26 server with 2024-11-05 client
  block:
    let serverProto = newProtocol(CURRENT_VERSION)
    let clientProto = newProtocol(VERSION_20241105)
    
    # Test implementation...
    
  # Test 2024-11-05 server with 2025-03-26 client
  block:
    let serverProto = newProtocol(VERSION_20241105)
    let clientProto = newProtocol(CURRENT_VERSION)
    
    # Test implementation...
```

## Version Compatibility Matrix

| Client \ Server | 2024-11-05 | 2025-03-26 |
|-----------------|------------|------------|
| **2024-11-05**  | Full compatibility | Compatible (downgrade) |
| **2025-03-26**  | Compatible (downgrade) | Full compatibility |

## Adding Support for New Versions

To add support for a new protocol version:

1. Add a new version constant
2. Add any version-specific message formatting logic
3. Update the version negotiation to handle the new version
4. Test with clients and servers using the new version

## Recommendations

- Always specify the protocol version when initializing a client or server
- For maximum compatibility, servers should support multiple protocol versions
- Use the version-specific serialization and parsing methods when working with messages
- When implementing handlers, consider version-specific behavior where necessary
- Test compatibility between all supported version combinations