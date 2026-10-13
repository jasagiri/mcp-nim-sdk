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

Nim 2.2.12 or newer. In your `.nimble` file:

```nim
requires "{{repository}}#mcp-{{version}}"
```

Then `import mcp`. A program file of your own cannot be called `mcp.nim`: the import would find that file instead of the SDK.

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

Requirements: Nim 2.2.12 or newer, the default memory management (`--mm:orc`), and the `uuids` package. No other define is needed; there is none per feature.

### 2. Features, at run time

A server declares a capability in `newMcpServer` and registers the handlers that answer it. A client registers a handler before `connect`, which declares the capability for it. Each side is then offered only what the version the two settled on has, so the same program serves old and new peers.

[examples/features_server.nim](examples/features_server.nim) turns on everything a server has in the core protocol:

```nim
{{include examples/features_server.nim}}
```

The example writes its tool definition and its result as JSON. A server can build them with procedures instead: `createToolInfo` with `createInputSchema` and the `create…Property` procedures for an item of `tools/list`, and `createToolResult` with `createTextToolContent` and the other `create…ToolContent` procedures for the answer of a call ([src/server/tools.nim](src/server/tools.nim)). They produce the same JSON and leave out the fields that were not given.

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

Authorization is off until it is attached to an HTTP transport. A server sets `transport.auth = newResourceServerAuth(config)` with a token verifier of its own, and every MCP endpoint the transport serves then needs a token; a client sets `transport.auth` to an OAuth client made with `newOAuthClient`; a client secret is configured together with the issuer of the authorization server it belongs to, and is sent to no other. Both live in `auth/` and are imported separately (`import auth/resource_server`, `import auth/client`). Build with `-d:ssl`: authorization servers are reached over `https://`. When a server keeps answering 401 or 403 and nothing more can be done about it, the request fails with `McpAuthorizationError`, a `McpTransportError` that carries the HTTP `status`; `connect` fails with it too, without trying the handshake of another protocol version.

{{/if}}
{{#if spoken:ftExtensions}}
### 3. Extensions

Extensions are optional additions to MCP that the two sides agree on by name. Each is a module of its own under `src/ext/`, and none of them is part of `import mcp`. An extension is on only in a program that imports its module **and** calls what turns it on; there is no define for any of them, and a module that is not imported is not compiled in.

{{#if !ext:tasks}}
This checkout carries the mechanism (`registerExtension`, `registerExtensionMethod`, `declareExtension`, in the tables above) and no extension of its own. The official extensions are on the branch `mcp-2026-07-28-ext`, and the draft ones on `mcp-draft`.

{{/if}}
{{#if ext:tasks}}
```nim
import mcp
import ext/tasks        # one import per extension the program uses
```

Extensions of the `extensions` capability are agreed in protocol version `2026-07-28`; turning one on in a build that does not speak that version raises `ValueError` rather than doing nothing. Where an extension has both sides declare it, a peer that did not is answered `-32021` when it calls one of its methods; Skills is declared by the server alone. MCP Apps is the exception its specification makes: a host declares it in the `initialize` handshake of earlier versions as well.

#### Official extensions

| Extension | Module | Server | Client |
|---|---|---|---|
| Tasks (`io.modelcontextprotocol/tasks`) | `ext/tasks` | `server.enableTasksExtension(config)`; `config.decide` says which calls become tasks | `client.enableTasksExtension()`, then `startToolCall`, `getTask`, `awaitTask`, `cancelTask` |
| MCP Apps (`io.modelcontextprotocol/ui`) | `ext/apps` | `newAppsRegistry()` for the `ui://` resources, `appToolInfo` for tools that show one, `degradeForPlainHosts` | `client.declareApps()` before `connect`, then `listAppTools`, `fetchUiResource` |
| Skills (`io.modelcontextprotocol/skills`) | `ext/skills` | `newSkillCatalog()`, `server.registerSkills(catalog)` | nothing to declare: `listAllSkills`, `getSkill`, `openSkill` |
| Enterprise-managed authorization | `ext/auth_enterprise_managed` | nothing: it is between the client and the authorization servers | `client.enableEnterpriseManaged(transport, config)` |
| OAuth client credentials (upstream text is a draft) | `ext/auth_client_credentials` | nothing | `client.enableClientCredentials(transport, config)` |

The Tasks extension is not the tasks of `2025-11-25`. A server may have both, on one store: `server.enableTasks()` serves clients of `2025-11-25`, `server.enableTasksExtension(...)` those of `2026-07-28`, and neither sees the other's tasks.

The authorization extensions sign with a key the application holds: it passes the signing function, and the SDK does no asymmetric cryptography of its own. Build with `-d:ssl`.

A server with the Tasks extension ([examples/ext_tasks_server.nim](examples/ext_tasks_server.nim)):

```nim
{{include examples/ext_tasks_server.nim}}
```

A server with MCP Apps is in [examples/ext_apps_server.nim](examples/ext_apps_server.nim).

{{/if}}
{{#if ext:events}}
#### Drafts

These follow texts that are not accepted specifications and that change upstream. Each module names, in its first lines, the repository and commit it follows and what that text leaves open. Expect them to change with it.

| Draft | Module | Server | Client |
|---|---|---|---|
| MCP Events | `ext/events` | `server.enableEvents(config)`, `registerEventType`, `emitEvent` | nothing to declare: `listEvents`, `pollEvents`, `openEventStream`, `subscribeWebhook` |
| Interceptors (SEP-2624) | `ext/interceptors` | `newInterceptorHost()`, `host.install(server)` | `client.declareInterceptors()` |
| Server variants (SEP-2053; the proposal was closed upstream without being merged) | `ext/variants` | `newVariantSet()`, `variants.install(server)` | `client.declareVariants()` |
| Trust annotations, action metadata | `ext/tool_annotations` | `server.installTrustAnnotations()`, `server.installActionMetadata()` | `client.declareTrustAnnotations()`, `client.declareActionMetadata()` |
| Server Card | `ext/server_card` | `publishServerCard(transport, card)` | fetch and check it with the procs of `ext/server_card` |

The Server Card is published with `Access-Control-Allow-Origin: *`, as its text requires of a card: it is public, read-only metadata, and the header is on that one document, not on the MCP endpoint. Pass `corsOrigin` to `publishServerCard` to name one origin, or `""` to send no CORS headers.

MCP Events declares itself the way its design sketch says, as `capabilities.events`, and asks no declaration of the client. It delivers three ways: the client polls with a cursor, holds a stream open, or names a webhook the server posts to. Webhooks need an authenticated principal (the transport's authorization, or `principalOf` in the config) and are sent to `https://` addresses outside private networks only.

A server that emits events ([examples/draft_events_server.nim](examples/draft_events_server.nim)):

```nim
{{include examples/draft_events_server.nim}}
```

and a client that polls and listens: [examples/draft_events_client.nim](examples/draft_events_client.nim).

{{/if}}
{{/if}}
### Checking a build

```sh
nimble test                # every test with this checkout's default version
nimble testAllVersions     # the same, once per released version as the default
nim c -r -d:mcpDefaultProtocolVersion=2025-06-18 tests/test_legacy_handshake.nim
```

On a branch that adds to another, `MCP_TEST_BASE=<commit> nimble testAllVersions` runs this checkout's default version in full and, for the other versions, only the tests built from a file that differs from that commit; `MCP_TEST_BASE=<commit> nimble affectedTests` lists them. It reads what the compiler recorded when it last built each test, so a file that only an older version compiles in is not seen: run without `MCP_TEST_BASE` before a release.

`DefaultProtocolVersion`, `OldestProtocolVersion` and `SupportedProtocolVersions` (in `protocol/version`, exported by `mcp`) tell a program what it was built to speak.

## Running a server on a network

A server on the HTTP transport refuses, by default, what one caller could use against the others. The limits are fields of the transport; set them after `newHttpServerTransport`.

| What | Default | Field |
|---|---|---|
| The `Host` header names this server | bound to loopback: loopback names only; bound elsewhere: not checked until names are listed | `allowedHosts` |
| The `Origin` header, when a browser sends one | loopback origins only | `allowedOrigins` |
| Size of a request body | 4 MiB | `maxBodySize` (argument of `newHttpServerTransport`) |
| Sessions, in all and per client address | limited; a full transport gives up a session that was never used before it refuses | `maxSessions`, `maxSessionsPerPeer` |
| Requests in progress and messages waiting | limited; more are refused with 503 and `Retry-After` | `maxPendingRequests`, `maxQueuedMessages` |

Behind a reverse proxy that passes the public name on, list that name: `transport.allowedHosts = @["mcp.example.com"]`. A header such as `X-Forwarded-For` is not trusted; the client address is the peer of the TCP connection, which behind a proxy is the proxy.

**Put a reverse proxy with request timeouts in front of a server that untrusted clients can reach.** The HTTP server of Nim's standard library, which this SDK uses, does not limit how long a client may take to send a request, so a client that sends nothing keeps its connection. A change that adds such a limit is proposed to Nim ([nim-lang/Nim#26352](https://github.com/nim-lang/Nim/pull/26352)); the SDK cannot set one until a released Nim has it.

A client is guarded the other way round: what it fetches because a server said so (authorization metadata, icons) is refused when the address is loopback, link-local or reserved, and when it is private unless `allowPrivateNetworks` is set; a response is limited in size (`maxResponseSize`) and a connection in time (`connectTimeoutMs`).

## Changes that break code written for earlier commits

These came with the security review of 2026-10-06. Each refuses something that used to be accepted.

| Was | Is now |
|---|---|
| A transport bound to a loopback address answered any `Host` | It answers loopback names and those in `allowedHosts`; others get 403 |
| A JSON Schema of any depth and a `pattern` of any cost were checked | Checking stops with `SchemaLimitError` or `RegexLimitError` beyond the limits (`SchemaLimits`, `RegexLimits`); patterns are matched without backtracking, so a hostile one costs time in proportion to the text |
{{#if spoken:ftAuthorization}}
| `newResourceServerAuth(config, mcpPath)` protected one path | `newResourceServerAuth(config)`: the transport protects every MCP endpoint it serves |
| A pre-registered client's secret went to whichever authorization server the MCP server named | `PreRegisteredClient` with a `clientSecret` needs `issuer`; the secret is sent to that authorization server only |
{{/if}}
{{#if spoken:ftTasks}}
| `newTaskStore()` kept any number of tasks for any time | A `ttl` above 24 hours is lowered to it; one owner has 16 active and 256 kept tasks, the store 4096. Pass `maxTtlMs = none(int64)` and 0 for a count to lift a limit |
{{/if}}
{{#if ext:auth_client_credentials}}
| `newClientCredentialsConfig(url, clientId)` and `newEnterpriseManagedConfig(url, idpIssuer, ...)` | Both take the issuer of the authorization server the credentials belong to: `newClientCredentialsConfig(url, clientId, issuer)`, `newEnterpriseManagedConfig(url, idpIssuer, resourceIssuer, ...)` |
{{/if}}

## Other versions

Each protocol version has a branch and a tag named `mcp-<version>`. Check one out, or name it in your `.nimble` file as above, and the SDK speaks that version and the earlier ones; its README, docs and examples describe exactly that version.

{{version_table}}

## Working with other implementations

How this SDK does against the official Python and TypeScript SDKs, by version, is recorded in [docs/quality/](docs/quality/).

## Documentation

[docs/index.md](docs/index.md). README.md and docs/*.md are generated by `nimble genDocs` from `templates/`; edit the templates.
