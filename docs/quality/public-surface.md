# 公開の範囲と、説明の無い公開シンボル (本線の系列)

2026-10-13。[test-classification.md](test-classification.md) の分類とは別の一覧で、分類は変えていない。
export を絞るか、説明を足すかは、別の判断として扱う。

テストの分類では「README の入口から `export` で届くもの」を公開とした。その範囲を機械的に数えると、
**入口から届くモジュールは 51 個、公開のシンボルは 1016 個で、うち 714 個は README にも `docs/*.md` にも名前が出てこない。**
README は使い方の説明で、型や手続きの一覧ではないので、この数は「誤って公開されている数」ではない。
継ぎ目のために `*` が付いただけのものと、利用者に使わせるつもりのものが混ざっている、という数である。

## 数え方と、その限り

- 入口: `import mcp`、`import auth/client`、`import auth/resource_server`、拡張ごとの `import ext/<名前>`。入口の `export` 行をたどって届くモジュールを集めた (`export a.b` の形は、そのシンボルだけ)。
- 公開のシンボル: 届いたモジュールの、`*` の付いた手続き・型・定数・フィールドを正規表現で拾った名前。同じ名前の多重定義は 1 個に数える。
- 「名前が出てこない」: その名前が README.md と `docs/*.md` (`docs/quality/` などの下位は見ない) に単語として 1 度も現れない。**名前が出ていることと、説明されていることは別で、そこは見ていない。**
- README・公開モジュールの doc が import を案内しているが `export` の鎖には無いもの (`server/request_state`、`transport/http_compat`・`sse_legacy`、`transport/auth_hook` の型) は、下の「入口から届かないモジュール」の側に出る。
- 1 個ずつの名前は [public-surface.tsv](public-surface.tsv) にある。

## 入口から届くモジュール

| モジュール | 公開のシンボル | README・docs に名前が無いもの | 例 |
|---|---:|---:|---|
| `auth/client` | 26 | 20 | `OAuthClient`、`OAuthClientConfig`、`UserAuthorizer`、`asHttpAuth`、`authorizationHeader` |
| `auth/oauth/errors` | 5 | 3 | `OAuthError`、`OAuthSecurityError`、`OAuthServerError` |
| `auth/oauth/tokens` | 20 | 18 | `ClientCredentials`、`CredentialStore`、`MaxTokenLifetimeSeconds`、`TokenSet`、`TokenStore` |
| `auth/resource_server` | 15 | 12 | `ResourceServerConfig`、`TokenVerdict`、`TokenVerdictKind`、`TokenVerifier`、`authorizationServers` |
| `client/client` | 81 | 52 | `DefaultMaxInputRounds`、`DefaultRequestTimeoutMs`、`McpCancelledError`、`McpClient`、`McpConnectionClosedError` |
| `client/content` | 32 | 27 | `McpContentKind`、`McpEmbeddedResource`、`allPages`、`audioData`、`audioMimeType` |
| `client/elicitation` | 9 | 3 | `McpElicitationHandler`、`raw`、`urlElicitationsRequired` |
| `client/extensions` | 4 | 1 | `serverCapability` |
| `client/icons` | 15 | 10 | `IconFetchOptions`、`IconGet`、`IconType`、`McpFetchedIcon`、`McpIconError` |
| `client/prompts` | 17 | 6 | `McpPrompt`、`McpPromptArgument`、`McpPromptMessage`、`McpPromptResult`、`displayName` |
| `client/resources` | 19 | 10 | `McpResource`、`McpResourceContent`、`McpResourceTemplate`、`displayName`、`listAllResourceTemplates` |
| `client/roots` | 6 | 2 | `McpRootsProvider`、`notifyRootsListChanged` |
| `client/sampling` | 31 | 19 | `McpModelHint`、`McpModelPreferences`、`McpSamplingHandler`、`McpSamplingMessage`、`blocks` |
| `client/subscriptions` | 3 | 1 | `unsupported` |
| `client/tasks` | 21 | 12 | `ClientTaskConfig`、`McpCreatedTask`、`augmentWithTasks`、`callToolWithTask`、`cancelTask` |
| `client/tools` | 28 | 15 | `McpSchemaError`、`McpTool`、`McpToolContent`、`McpToolContentItem`、`McpToolContentKind` |
| `client/utilities` | 3 | 1 | `setLoggingLevel` |
| `jsonschema/json_schema` | 18 | 13 | `DefaultDialect`、`DefaultSchemaLimits`、`InvalidSchemaError`、`SchemaDialect`、`SchemaViolation` |
| `mcp` | 2 | 2 | `VERSION`、`getMCPVersion` |
| `protocol/completion` | 10 | 8 | `McpCompletionRef`、`McpCompletionRefKind`、`hasMore`、`promptName`、`promptRef` |
| `protocol/content` | 28 | 27 | `McpShapeError`、`McpToolAnnotations`、`contentBlockFor`、`destructiveHint`、`iconsOf` |
| `protocol/elicitation` | 19 | 16 | `ElicitAction`、`ElicitMode`、`UrlElicitationRequiredCode`、`contentProblems`、`elicitationCompleteParams` |
| `protocol/extensions` | 10 | 10 | `CoreMethods`、`CoreResultTypes`、`TakenOverMethods`、`TasksExtensionId`、`extensionsOf` |
| `protocol/lifecycle` | 8 | 8 | `McpLifecycleState`、`createInitializeRequest`、`createInitializeResponse`、`createPingResponse`、`forVersion` |
| `protocol/log_level` | 2 | 2 | `McpLogLevel`、`parseLogLevel` |
| `protocol/modern` | 41 | 38 | `CacheScope`、`CacheableMethods`、`DiscoverMethod`、`ErrHeaderMismatch`、`ErrInternal` |
| `protocol/mrtr` | 22 | 22 | `ElicitationMethod`、`InputRequestMethods`、`InputRequestSpec`、`InputRequired`、`MrtrMethods` |
| `protocol/payload` | 4 | 4 | `McpPayloadError`、`newPayloadError`、`problems`、`raiseIfAny` |
| `protocol/sampling_tools` | 8 | 8 | `createMessageParamsProblems`、`createMessageResultProblems`、`samplingMessagesProblems`、`samplingToolsUnavailable`、`toolResultBlock` |
| `protocol/subscriptions` | 21 | 21 | `AcknowledgedMethod`、`ListenMethod`、`PromptsListChangedMethod`、`ResourceUpdatedMethod`、`ResourcesListChangedMethod` |
| `protocol/task_methods` | 11 | 11 | `DefaultPollIntervalMs`、`MaxPollIntervalMs`、`MinPollIntervalMs`、`TaskMethods`、`TaskWork` |
| `protocol/tasks` | 58 | 48 | `DefaultMaxActivePerOwner`、`DefaultMaxTasks`、`DefaultMaxTasksPerOwner`、`DefaultMaxTtlMs`、`McpTask` |
| `protocol/trace_context` | 16 | 16 | `MetaBaggage`、`MetaTraceparent`、`MetaTracestate`、`TraceContext`、`baggage` |
| `protocol/types` | 70 | 30 | `JsonRpcError`、`JsonRpcNotification`、`JsonRpcRequest`、`JsonRpcResponse`、`McpClientCapabilities` |
| `protocol/version` | 13 | 10 | `FirstModernProtocolVersion`、`McpProtocolVersion`、`isModern`、`isSupported`、`latestLegacyVersion` |
| `server/completion` | 7 | 5 | `argumentName`、`parseCompletionRequest`、`reference`、`resolved`、`toJson` |
| `server/elicit` | 4 | 2 | `notifyElicitationComplete`、`urlElicitationRequired` |
| `server/errors` | 21 | 15 | `ErrInvalidRequest`、`ErrResourceNotFoundLegacy`、`McpCancelled`、`McpCapabilityError`、`McpInputRequired` |
| `server/extensions` | 6 | 4 | `clientExtension`、`registerOpenMethod`、`registerTopLevelCapability`、`requireClientExtension` |
| `server/mrtr` | 4 | 3 | `inputResponse`、`newInputRequired`、`requireInputs` |
| `server/pagination` | 7 | 3 | `ListAll`、`ListHandler`、`pageOf` |
| `server/server` | 117 | 74 | `CompletionHandler`、`DefaultRequestTimeoutMs`、`ExtensionMethod`、`ExtensionMethodHandler`、`ListScope` |
| `server/tasks` | 15 | 10 | `TaskConfig`、`awaitClientTask`、`cancelClientTask`、`clientTaskResult`、`createMessageAsTask` |
| `transport/event_stream` | 12 | 9 | `DefaultSseLimitBytes`、`SseEvent`、`SseLimitError`、`SseParser`、`feed` |
| `transport/http` | 27 | 19 | `DefaultMaxReconnects`、`DefaultMaxResponseSize`、`DefaultReconnectDelayMs`、`DefaultStreamOpenTimeoutMs`、`ErrStreamClosed` |
| `transport/http_server` | 50 | 28 | `DefaultMaxBatchItems`、`DefaultMaxBodySize`、`DefaultMaxPendingRequests`、`DefaultMaxQueuedMessages`、`DefaultMaxSessions` |
| `transport/stdio` | 10 | 5 | `DefaultMaxLineSize`、`StdioTransport`、`receiveMessage`、`sendNotification`、`sendResponse` |
| `transport/transport` | 35 | 26 | `McpIncoming`、`McpTransport`、`McpTransportClosedError`、`McpTransportKind`、`MessageRoute` |
| `auth/oauth/urls (一部)` | 2 | 2 | `FetchPolicy`、`defaultFetchPolicy` |
| `client/cancel_token (一部)` | 2 | 2 | `McpCancelToken`、`newMcpCancelToken` |
| `protocol/diagnostic (一部)` | 1 | 1 | `plainMessage` |

## 入口から届かないモジュール

`export` の鎖では届かないもの。テストがこれを直接 import して確かめていると、そのテストは E にならない。

| モジュール | src の中で import しているモジュール | 直接 import しているテスト・道具 |
|---|---|---|
| `auth/oauth/authcode` | `auth/client` | `test_auth_oauth_basics.nim`、`test_security_auth_tokens.nim` |
| ~~`auth/oauth/challenge`~~ | (2026-10-15 に `foundation/nim-bearer-challenge` へ移した。いまは SDK の外の依存) | — |
| `auth/oauth/discovery` | `auth/client`、`auth/policy` | `test_auth_oauth_basics.nim` |
| `auth/oauth/fetch` | `auth/oauth/authcode`、`auth/oauth/discovery`、`auth/oauth/registration` | `test_auth_oauth_basics.nim`、`test_security_address.nim`、`test_security_auth_tokens.nim`、`test_security_diagnostic_auth.nim` |
| `auth/oauth/jsonfield` | `auth/oauth/authcode`、`auth/oauth/registration` | `test_auth_oauth_basics.nim` |
| `auth/oauth/metadata` | `auth/client`、`auth/oauth/discovery` | `test_auth_oauth_basics.nim` |
| `auth/oauth/pkce` | `auth/oauth/authcode` | `auth_fixtures.nim`、`test_auth_oauth_basics.nim` |
| `auth/oauth/registration` | `auth/client`、`auth/oauth/authcode` | `test_auth_oauth_basics.nim` |
| `auth/oauth/sha256` | `auth/oauth/pkce`、`protocol/hmac`、`server/request_state` | `test_auth_sha256.nim` |
| `auth/policy` | `auth/client` |  |
| `jsonschema/json_schema_regex` | `jsonschema/json_schema` | `test_json_schema.nim`、`test_security_schema.nim` |
| `protocol/base64_shape` | `client/icons`、`protocol/modern`、`server/pagination` | `test_base64_shape.nim` |
| `protocol/features` | `auth/policy`、`auth/resource_server`、`client/client`、`client/extensions` ほか 15 | `gen_docs.nim`、`server_harness.nim`、`test_auth_client_flow.nim`、`test_auth_resource_server.nim` ほか 12 |
| `protocol/hmac` | `server/request_state` | `test_mrtr.nim` |
| `protocol/implementation_status` | **無し** | `gen_docs.nim`、`test_docs_version.nim`、`test_spec_coverage.nim` |
| `protocol/param_headers` | `server/server`、`transport/http`、`transport/http_server` | `test_param_headers.nim` |
| `server/request_state` | **無し** | `test_mrtr.nim` |
| `server/subscriptions` | `server/server` |  |
| `server/tools` | `mcp` (2026-10-13 から。入口が export する) | `test_audio_content.nim`、`test_icons.nim`、`test_resource_links.nim`、`test_tool_annotations.nim` |
| `transport/address_policy` | `auth/oauth/urls`、`client/icons`、`transport/guarded_wire` | `test_security_address.nim`、`test_security_icons.nim` |
| `transport/auth_hook` | `auth/client`、`auth/resource_server`、`transport/http`、`transport/http_server` | `test_auth_failure.nim`、`test_auth_http_methods.nim`、`test_http_documents.nim`、`test_security_http.nim` |
| `transport/first_of` | `client/client`、`client/subscriptions`、`transport/http_server`、`transport/http_wire` ほか 1 | `test_first_of.nim` |
| `transport/guarded_wire` | `auth/oauth/fetch`、`client/icons` | `test_security_address.nim` |
| `transport/http_compat` | **無し** | `test_http_sse_legacy.nim` |
| `transport/http_wire` | `auth/oauth/fetch`、`client/icons`、`transport/guarded_wire`、`transport/http` ほか 1 | `sse_reader.nim`、`test_icon_fetch.nim`、`test_security_address.nim`、`test_security_icons.nim` ほか 4 |
| `transport/sse_legacy` | `transport/http_compat` | `test_http_sse_legacy.nim` |
| `transport/sse_stream` | `transport/http_server` | `test_http_streams.nim` |

`src` のどこからも import されていないのは `protocol/implementation_status`、`server/request_state`、`transport/http_compat` である (`server/tools` は 2026-10-13 に入口の `mcp` が export するようにした)。
`server/request_state` は `server/mrtr` の doc が、`transport/http_compat` は README が利用者に import を案内している。`protocol/implementation_status` は文書を生成する道具とそのテストが使う表である。
`server/tools` (`createToolInfo`、`createToolResult` など) は、この表を作った時点では入口から届かず、`src` からも呼ばれず、どの文書も案内していなかった。2026-10-13 に利用者の決定で公開にした: `import mcp` が export し、README が案内する。この文書のほかの数 (公開のシンボルの数、説明の無いシンボルの数) は数え直していない。
