# MCP Nim SDK

Model Context Protocol (MCP) の Nim 実装。LLM にコンテキストを提供するオープンプロトコル。

## Build & Test

```bash
nimble install          # Install dependencies
nimble build            # Build library
nimble test             # Run all tests
nim c -r tests/test_client.nim  # Run specific test
nimble docs             # Generate documentation
nimble clean            # Clean build artifacts
```

Nim >= 2.2.2 required.

## Architecture

### Core Components (src/mcp/)

| Component | File | Purpose |
|-----------|------|---------|
| Transport | transport/ | Communication layer (HTTP, stdio, SSE, in-memory) |
| Protocol | protocol.nim | JSON-RPC messaging, request-response lifecycle |
| Client | client.nim | Connects to MCP servers, discovers capabilities |
| Server | server.nim | Hosts resources/tools, handles client requests |
| Resources | resources.nim | URI-based text/binary data access |
| Tools | tools.nim | Executable functions with JSON schema validation |
| Roots | roots.nim | Hierarchical resource organization |
| Sampling | sampling.nim | LLM interaction (completions, parameters) |
| Prompts | prompts.nim | Message templates with parameter substitution |
| Logger | logger.nim | Configurable logging |

### Key Patterns

- **Capability-based**: clients and servers declare/negotiate capabilities
- **Async-first**: asyncdispatch, Future, async/await throughout
- **Pluggable transports**: common Transport interface, swappable implementations
- **Resource URIs**: `file:///path`, `http://host/path`, `db://database/table`, `custom://scheme/path`
- **Type-safe JSON**: schema validation for tool parameters

### Examples

```bash
nim c -r examples/base/simple_server.nim
nim c -r examples/base/simple_client.nim
nim c -r examples/http/http_server.nim
nim c -r examples/http/http_client.nim
```

## API Reference

For detailed API signatures: `/context7local mcp-nim-sdk`
