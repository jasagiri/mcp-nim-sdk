# MCP Nim SDK

{{#if ftStreamableHttp}}
A Nim implementation of the [Model Context Protocol](https://modelcontextprotocol.io) (MCP): a client, a server, and the stdio and Streamable HTTP transports.
{{/if}}
{{#if !ftStreamableHttp}}
A Nim implementation of the [Model Context Protocol](https://modelcontextprotocol.io) (MCP): a client, a server, and the stdio transport.
{{/if}}

This checkout speaks MCP **{{version}}** and every earlier version: {{spoken_versions}}. A client and a server settle on the newest version both speak; see [docs/versions.md](docs/versions.md).

## Features of {{version}}

{{implemented_summary}} The table lists every feature the specification of `{{version}}` defines; "not implemented" means this SDK does not do it yet.

{{feature_table}}

## Install

Nim 2.2.2 or newer. In your `.nimble` file:

```nim
requires "{{repository}}#mcp-{{version}}"
```

Then `import mcp`.

## A server

Serves one tool, `echo`, on stdin and stdout ([examples/stdio_server.nim](examples/stdio_server.nim)):

```nim
{{include examples/stdio_server.nim}}
```

## A client

Starts that server as a child process, lists its tools and calls `echo` ([examples/stdio_client.nim](examples/stdio_client.nim)):

```nim
{{include examples/stdio_client.nim}}
```

```sh
nim c examples/stdio_server.nim
nim c -r examples/stdio_client.nim examples/stdio_server
```

{{#if ftStreamableHttp}}
The same pair over Streamable HTTP is in [examples/http_server.nim](examples/http_server.nim) and [examples/http_client.nim](examples/http_client.nim).

{{/if}}
## Turning features on

There are two switches. **Which protocol versions** a program speaks is decided when it is compiled. **Which features** it offers is decided in its code: a feature is on when the program declares it and registers what answers it. Nothing is on by default except the protocol itself.

### 1. Protocol versions, at compile time

A build speaks a range of versions, from its oldest to its default. This checkout's default is `{{version}}`.

| Define | Meaning | Default here |
|---|---|---|
| `-d:mcpDefaultProtocolVersion=<version>` | the newest version the build speaks | `{{version}}` |
{{#if modern}}
| `-d:mcpOldestProtocolVersion=<version>` | the oldest version the build speaks | `2024-11-05` |
{{/if}}
| `-d:ssl` | `https://` URLs in the HTTP client and in authorization | off |

```sh
# Everything up to {{version}} (what this checkout does without any define)
nim c yourprogram.nim

# Speak nothing newer than 2025-06-18
nim c -d:mcpDefaultProtocolVersion=2025-06-18 yourprogram.nim
{{#if modern}}

# Speak 2026-07-28 alone: no initialize handshake, no sessions, no HTTP+SSE
nim c -d:mcpOldestProtocolVersion=2026-07-28 yourprogram.nim
{{/if}}

# Connect to https:// servers
nim c -d:ssl yourprogram.nim
```

To make a define permanent, put it in your project's `config.nims`:

```nim
switch("define", "mcpDefaultProtocolVersion=2025-06-18")
switch("define", "ssl")
```

or in its `nim.cfg`:

```
-d:mcpDefaultProtocolVersion=2025-06-18
-d:ssl
```

A version that is not a released one, or an oldest version newer than the default, stops the compilation with a message that names the define. A server or client created for a version outside the range raises `ValueError`.

Within the range, one server can be held to an older ceiling at run time, for example to serve only up to `2025-03-26`:

```nim
let server = newMcpServer(info, protocolVersion = mpv20250326, capabilities = caps)
```

When this SDK is a dependency, name the branch of the version you want in your `.nimble` file (see [Install](#install)); the branch sets the default, and the defines above still apply. When working in a checkout of this repository, `nim.cfg` already adds `src` to the path; elsewhere pass `--path:<checkout>/src`.

Requirements: Nim 2.2.2 or newer, the default memory management (`--mm:orc`), and the `uuids` package. No other define is needed; there is none per feature.

### 2. Features, at run time

A server declares a capability in `newMcpServer` and registers the handlers that answer it. A client registers a handler before `connect`, which declares the capability for it. Each side is then offered only what the version the two settled on has, so the same program serves old and new peers.

[examples/features_server.nim](examples/features_server.nim) turns on everything a server has in the core protocol:

```nim
{{include examples/features_server.nim}}
```

[examples/features_client.nim](examples/features_client.nim) does the same for a client:

```nim
{{include examples/features_client.nim}}
```

```sh
nim c examples/features_server.nim
nim c -r examples/features_client.nim examples/features_server
```

#### Server features

| Feature | Declare in `McpServerCapabilities` | Register or call |
|---|---|---|
| Tools | `tools: some(McpToolsCapability(listChanged: ...))` | `onToolsList`, `onToolCall`; `notifyToolListChanged` |
| Tool input validation | nothing: always on | the `inputSchema` of each tool in the list |
{{#if spoken:ftStructuredToolOutput}}
| Structured tool output | nothing: a result is always checked | `outputSchema` in the tool, `structuredContent` in the result |
{{/if}}
| Resources | `resources: some(McpResourcesCapability(subscribe: ..., listChanged: ...))` | `onResourcesList`, `onResourceTemplatesList`, `onResourceRead`; `notifyResourceListChanged` |
{{#if spoken:ftResourceSubscribe}}
| Resource subscriptions | `subscribe: true` in the resources capability | `notifyResourceUpdated(uri)`; optionally `onResourceSubscribe`, `onResourceUnsubscribe` |
{{/if}}
| Prompts | `prompts: some(McpPromptsCapability(listChanged: ...))` | `onPromptsList`, `onPromptGet`; `notifyPromptListChanged` |
{{#if spoken:ftCompletionsCapability}}
| Completion | `completions: some(McpCompletionsCapability())` | `onComplete` |
{{/if}}
{{#if !spoken:ftCompletionsCapability}}
| Completion | nothing in this version | `onComplete` |
{{/if}}
| Logging | `logging: some(McpLoggingCapability())` | `ctx.log(level, data)` in a handler, `server.log(...)` outside one |
| Pagination | nothing | return `nextCursor` in `McpPage`, or wrap a whole list with `pagedList(all, pageSize)` |
| Progress | nothing | `ctx.reportProgress(...)`; sent only when the request asked for progress |
| Cancellation | nothing | read `ctx.cancelled` in a long handler |
{{#if spoken:ftServerInitiatedRequests}}
| Asking the client (before 2026-07-28) | nothing; the client must have declared the capability | `ctx.createMessage` (sampling), `ctx.listRoots`, `ctx.ping` |
{{/if}}
{{#if spoken:ftElicitation}}
| Asking the user (before 2026-07-28) | nothing; the client must have declared `elicitation` | `ctx.elicit(message, requestedSchema)` |
{{/if}}
{{#if spoken:ftUrlElicitation}}
| Sending the user to a page (2025-11-25) | nothing; the client must have declared `elicitation.url` | `ctx.elicitUrl(message, elicitationId, url)` |
{{/if}}
{{#if spoken:ftMultiRoundTripRequests}}
| Asking the client (2026-07-28: multi round-trip) | nothing; the client must have declared the capability | `ctx.requireInput(key, method, params)` in a tool, prompt or resource handler |
{{/if}}
{{#if spoken:ftTasks}}
| Tasks (2025-11-25 only) | `server.enableTasks()` declares it | `execution.taskSupport` in the tool; `enableTasks` returns the store |
{{/if}}
{{#if spoken:ftSubscriptionsListen}}
| `subscriptions/listen` (2026-07-28) | the `listChanged` and `subscribe` flags above | the same `notify...` calls; `endSubscriptions` to close them |
{{/if}}
{{#if spoken:ftParameterHeaders}}
| Parameter headers (2026-07-28, HTTP) | nothing | `"x-mcp-header": "Name"` on a property of a tool's `inputSchema` |
{{/if}}
{{#if spoken:ftExtensions}}
| Extensions (2026-07-28) | `server.registerExtension(id, settings)` declares it | `registerExtensionMethod` for the methods the extension defines |
{{/if}}

#### Client features

| Feature | Register before `connect` | Notes |
|---|---|---|
| Roots | `client.setRootsProvider(provider)` | declares `roots` |
| Sampling | `client.setSamplingHandler(handler)` | declares `sampling` |
{{#if spoken:ftSamplingTools}}
| Tool use in sampling (2025-11-25) | `client.setSamplingHandler(handler, tools = true)` | declares `sampling.tools` as well |
{{/if}}
{{#if spoken:ftElicitation}}
| Elicitation | `client.setElicitationHandler(handler)` | declares `elicitation` (form mode) |
{{/if}}
{{#if spoken:ftUrlElicitation}}
| URL elicitation (2025-11-25) | `client.setElicitationHandler(handler, modes = {emForm, emUrl})` | declares `elicitation.url` as well |
{{/if}}
{{#if spoken:ftTasks}}
| Tasks (2025-11-25 only) | `client.enableClientTasks(config)` | after the handlers of the requests to run as tasks are set; `callToolAsTask` and `waitForTask` to use a server's tasks |
{{/if}}
{{#if spoken:ftMultiRoundTripRequests}}
| Multi round-trip requests (2026-07-28) | the handlers above | the client answers a server's input requests from them and retries, up to `maxInputRounds` |
{{/if}}
{{#if spoken:ftSubscriptionsListen}}
| `subscriptions/listen` (2026-07-28) | nothing | `client.listen(...)` returns a subscription; `cancel` ends it |
{{/if}}
{{#if spoken:ftExtensions}}
| Extensions (2026-07-28) | `client.declareExtension(id, settings)` | `serverExtension(id)` tells whether the server has it; `callExtension` calls its methods |
{{/if}}
| Timeouts, cancellation, progress | nothing | per request, in `McpRequestOptions`: `timeoutMs`, `cancel`, `onProgress` |
{{#if spoken:ftTraceContext}}
| Trace context (2026-07-28) | nothing | `traceContext` in `McpRequestOptions`; a server handler reads `ctx.traceContext` |
{{/if}}

Using a server's tools, resources and prompts needs no registration: `listTools`, `callTool`, `listResources`, `readResource`, `listPrompts`, `getPrompt` and `complete` raise `McpUnsupportedError` when the server did not declare the capability.

#### Transports

| Transport | Server | Client |
|---|---|---|
| stdio | `server.transport = newStdioTransport()` then `processMessages()` | `newProcessTransport(command, args)` starts the server as a child process |
{{#if spoken:ftStreamableHttp}}
| Streamable HTTP | `newHttpServerTransport(host, port, path)`, `listen()`, `server.attachTransport(...)` | `newStreamableHttpTransport(url)` |
{{/if}}
{{#if spoken:ftHttpSse}}
| HTTP+SSE (2024-11-05, deprecated) | `newHttpServerTransport(host, port, path)` serves it on `legacySsePath` (`/sse`); set that to `""` to turn it off | `newSseLegacyTransport(url)` |
{{/if}}
{{#if spoken:ftStreamableHttp}}
| Either HTTP transport | the same server transport serves both | `newAutoHttpTransport(url)` tries Streamable HTTP first and falls back to HTTP+SSE |
{{/if}}

{{#if spoken:ftHttpSse}}
The HTTP server accepts requests from loopback origins only; add others to `transport.allowedOrigins`. See [docs/transports.md](docs/transports.md).

{{/if}}
{{#if spoken:ftAuthorization}}
#### Authorization

Authorization is off until it is attached to an HTTP transport. A server sets `transport.auth = newResourceServerAuth(config, mcpPath)` with a token verifier of its own; a client sets `transport.auth` to an OAuth client made with `newOAuthClient`. Both live in `auth/` and are imported separately (`import auth/resource_server`, `import auth/client`). Build with `-d:ssl`: authorization servers are reached over `https://`.

{{/if}}
{{#if spoken:ftExtensions}}
### 3. Extensions

Extensions are optional additions to MCP that the two sides agree on by name. They are off unless a program registers them, as in the tables above; this checkout carries the registration mechanism and no extension of its own.

{{/if}}
### Checking a build

```sh
nimble test                # every test with this checkout's default version
nimble testAllVersions     # the same, once per released version as the default
nim c -r -d:mcpDefaultProtocolVersion=2025-06-18 tests/test_legacy_handshake.nim
```

`DefaultProtocolVersion`, `OldestProtocolVersion` and `SupportedProtocolVersions` (in `protocol/version`, exported by `mcp`) tell a program what it was built to speak.

## Other versions

Each protocol version has a branch and a tag named `mcp-<version>`. Check one out, or name it in your `.nimble` file as above, and the SDK speaks that version and the earlier ones; its README, docs and examples describe exactly that version.

{{version_table}}

## Working with other implementations

How this SDK does against the official Python and TypeScript SDKs, by version, is recorded in [docs/quality/](docs/quality/).

## Documentation

[docs/index.md](docs/index.md). README.md and docs/*.md are generated by `nimble genDocs` from `templates/`; edit the templates.
