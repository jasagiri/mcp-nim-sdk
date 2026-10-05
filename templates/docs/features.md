# Features

How to use what this tree implements. Which features `{{version}}` has, and the status of each, is in the [README](../README.md); features not listed here are not implemented yet.

{{#if ftTools}}
## tools

Status: {{status:ftTools}}.

A server declares the `tools` capability and gives two handlers: one lists the tools, one calls a tool by name with its arguments. The call handler returns the `tools/call` result as JSON; an exception it raises is answered as a JSON-RPC error.

```nim
let server = newMcpServer(
  McpServerInfo(name: "echo-server", version: "0.1.0"),
  capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
server.setToolHandlers(McpToolHandlers(
  listHandler: some(listTools), callHandler: some(callTool)))
```

A client sends `tools/list` and `tools/call` with `sendRequest`, which returns the response with either `result` or `error` set. The complete server and client are in [examples/stdio_server.nim](../examples/stdio_server.nim) and [examples/stdio_client.nim](../examples/stdio_client.nim).

{{/if}}
{{#if ftPing}}
## ping

Status: {{status:ftPing}}.

A server answers `ping` with an empty result. Only the versions before `2026-07-28` have it.

{{/if}}
{{#if ftInitializeHandshake}}
## initialize handshake

Status: {{status:ftInitializeHandshake}}.

`client.connect` sends `initialize` and `notifications/initialized`; the server keeps the state of each client (`server.session(id)`), so one server serves several clients on one transport that issues session ids. [Protocol versions](versions.md) describes the negotiation.

{{/if}}
{{#if ftDiscover}}
## server/discover

Status: {{status:ftDiscover}}.

A server answers `server/discover` with the versions it speaks, its capabilities, its identity and, when `server.instructions` is not empty, instructions for using it. `client.connect` sends it first; `client.serverInfo`, `client.serverCapabilities` and `client.serverInstructions` hold the answer.

{{/if}}
{{#if ftCacheHints}}
## cache hints (ttlMs, cacheScope)

Status: {{status:ftCacheHints}}.

Results of `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list` and `resources/read` tell the client how long it may reuse them. By default a server says not at all; set `server.cachePolicy` to change it:

```nim
server.cachePolicy = CachePolicy(ttlMs: 3_600_000, scope: csPublic)
```

{{/if}}
