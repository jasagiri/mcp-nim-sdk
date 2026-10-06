# G2 変異検出: プロトコル版まわり

`nim-muter` による測定は、実装が落ち着いてから push の前に 1 回流す。
それまでは、変更したモジュールをここに「未測定」として足していく。

## 未測定

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/protocol/version.nim` | `tests/test_version.nim` | 2026-10-05 |
| `src/protocol/features.nim` | `tests/test_features.nim` | 2026-10-06 |
| `src/protocol/implementation_status.nim` | `tests/test_docs_version.nim` | 2026-10-06 |
| `tools/gen_docs.nim` | `tests/test_docs_version.nim` | 2026-10-06 |
| `src/protocol/modern.nim` | `tests/test_modern_protocol.nim` | 2026-10-05 |
| `src/protocol/lifecycle.nim` | `tests/test_legacy_handshake.nim` | 2026-10-05 |
| `src/server/server.nim` | `tests/test_legacy_handshake.nim`, `tests/test_era_matrix.nim` | 2026-10-05 |
| `src/client/client.nim` | `tests/test_legacy_handshake.nim`, `tests/test_era_matrix.nim` | 2026-10-05 |
| `src/client/{content,tools,resources,prompts,utilities}.nim` | `tests/test_client_operations.nim` | 2026-10-06 |
| `src/client/{roots,sampling}.nim` | `tests/test_client_server_requests.nim` | 2026-10-06 |
| `src/client/client.nim` (タイムアウト・キャンセル・進捗・接続終了・通知) | `tests/test_client_requests.nim`, `tests/test_client_server_requests.nim` | 2026-10-06 |
| `src/transport/transport.nim` | `tests/test_era_matrix.nim` | 2026-10-05 |
| `src/transport/event_stream.nim` | `tests/test_event_stream.nim` | 2026-10-05 |
| `src/transport/http.nim` | `tests/test_streamable_http.nim` | 2026-10-05 |
| `src/transport/http_server.nim` | `tests/test_streamable_http.nim` | 2026-10-05 |
| `src/transport/stdio.nim` | `tests/test_stdio.nim`, `tests/test_silent_dead.nim` | 2026-10-06 |
| `src/server/server.nim` (ページネーション、購読、ログ、進捗、キャンセル、サーバー発リクエスト、通知) | `tests/test_server_*.nim` | 2026-10-06 |
| `src/server/errors.nim` | `tests/test_server_errors.nim` | 2026-10-06 |
| `src/server/pagination.nim` | `tests/test_server_pagination.nim` | 2026-10-06 |
| `src/server/completion.nim` | `tests/test_server_completion.nim` | 2026-10-06 |
| `src/protocol/log_level.nim` | `tests/test_server_logging.nim` | 2026-10-06 |
| `src/transport/http.nim` (SSE の逐次読み取り、再開、GET ストリーム、DELETE、リダイレクト) | `tests/test_http_client_streams.nim` | 2026-10-06 |
| `src/transport/http_server.nim` (SSE 応答、GET ストリーム、再開、バッチ、版ヘッダ、期限切れ、HTTP+SSE) | `tests/test_http_streams.nim`, `tests/test_http_sse_legacy.nim` | 2026-10-06 |
| `src/transport/http_wire.nim` | `tests/test_http_client_streams.nim`, `tests/test_http_streams.nim` | 2026-10-06 |
| `src/transport/sse_stream.nim` | `tests/test_http_streams.nim`, `tests/test_http_sse_legacy.nim` | 2026-10-06 |
| `src/transport/sse_legacy.nim` | `tests/test_http_sse_legacy.nim` | 2026-10-06 |
| `src/transport/http_compat.nim` | `tests/test_http_sse_legacy.nim` | 2026-10-06 |
| `src/transport/event_stream.nim` (retry) | `tests/test_event_stream.nim` | 2026-10-06 |
| `src/auth/oauth/*.nim` | `tests/test_auth_sha256.nim`, `tests/test_auth_oauth_basics.nim`, `tests/test_auth_client_flow.nim` | 2026-10-06 |
| `src/auth/policy.nim`, `src/auth/client.nim` | `tests/test_auth_client_flow.nim` | 2026-10-06 |
| `src/auth/resource_server.nim` | `tests/test_auth_resource_server.nim` | 2026-10-06 |
| `src/transport/auth_hook.nim` | `tests/test_auth_client_flow.nim`, `tests/test_auth_resource_server.nim` | 2026-10-06 |
| `src/jsonschema/json_schema.nim`, `src/jsonschema/json_schema_regex.nim` | `tests/test_json_schema.nim` | 2026-10-06 |
| `src/protocol/content.nim` | `tests/test_tool_annotations.nim`, `tests/test_audio_content.nim`, `tests/test_structured_tool_output.nim`, `tests/test_resource_links.nim`, `tests/test_title_fields.nim`, `tests/test_icons.nim`, `tests/test_implementation_info.nim` | 2026-10-06 |
| `src/server/tool_output.nim` | (2026-10-06 に測定。2026-10-06 の後半で `server.nim` の tools/call に統合して削除した。統合後の検査は未測定) | 2026-10-06 |
| `src/client/tools.nim` (outputSchema の検査)、`src/client/content.nim` (アイコンの選別) | `tests/test_structured_tool_output.nim`, `tests/test_icons.nim` | 2026-10-06 |
| `src/protocol/elicitation.nim`, `src/protocol/payload.nim` | `tests/test_elicitation_payload.nim` | 2026-10-06 |
| `src/server/elicit.nim` | `tests/test_server_elicitation.nim` | 2026-10-06 |
| `src/client/elicitation.nim` | `tests/test_client_elicitation.nim` | 2026-10-06 |
| `src/protocol/sampling_tools.nim` | `tests/test_sampling_tools_payload.nim` | 2026-10-06 |
| `src/server/server.nim` (createMessage: tools と結果の検査) | `tests/test_server_sampling_tools.nim` | 2026-10-06 |
| `src/client/sampling.nim` (tools、複数ブロック、検査) | `tests/test_client_sampling_tools.nim` | 2026-10-06 |
| `src/protocol/tasks.nim` | `tests/test_tasks_store.nim` | 2026-10-06 |
| `src/protocol/task_methods.nim` | `tests/test_tasks_server.nim`, `tests/test_tasks_client.nim` | 2026-10-06 |
| `src/server/tasks.nim` | `tests/test_tasks_server.nim`, `tests/test_tasks_end_to_end.nim` | 2026-10-06 |
| `src/client/tasks.nim` | `tests/test_tasks_client.nim`, `tests/test_tasks_end_to_end.nim` | 2026-10-06 |
| `src/server/server.nim` (リクエスト傍受、`serveDetached`、タスクに属するサーバー発リクエスト) | `tests/test_tasks_server.nim` | 2026-10-06 |
| `src/protocol/lifecycle.nim` (`tasks` capability の入出力) | `tests/test_tasks_server.nim`, `tests/test_tasks_client.nim` | 2026-10-06 |

## 手で確かめたもの (nim-muter の測定ではない)

`src/protocol/modern.nim` は実装をテストより先に書いたため、2026-10-05 に規則を
1 つずつ壊した版を 20 通り作り、`tests/test_modern_protocol.nim` が落ちるかを確かめた。
19 通りは検出された。検出されなかった 1 通り (結果に既にあるサーバー識別を上書きする)
にはテストを足した。これは網羅的な変異検査の代わりにはならない。

## 未測定 (core-rest、第 3 波)

- `src/server/tasks.nim` (task の質問の保留と `tasks/result` での送出)、`src/server/server.nim` の `holdForTask` / `sendHeld` / task の通知の経路、`src/transport/http_server.nim` の `sendRequest` の経路選択、`src/server/elicit.nim` の task 連携。
- 認可の主体の経路: `src/auth/resource_server.nim` (principal)、`src/transport/auth_hook.nim` (check)、`src/transport/http_server.nim` (authenticate)、`src/server/tasks.nim` (ownerOf)。
- `src/server/server.nim` の tools/call の出力検査 (`outputProblems`、`toolDefinition`)。
- `src/client/content.nim` の `optionalString` (型違いを McpProtocolError にした)。
- `src/client/icons.nim` (取得時の検査: 資格情報なし、同一オリジン、サイズ上限、マジックバイトの照合)。
- `src/protocol/sampling_tools.nim` (sampling の messages の audio の版判定)。
| `src/jsonschema/json_schema_regex.nim` (Thompson NFA、上限) | `tests/test_security_schema.nim`、`tests/test_json_schema.nim` | 2026-10-06 |
| `src/jsonschema/json_schema.nim` (`SchemaLimits`、`$ref` の循環検出) | `tests/test_security_schema.nim`、`tests/test_json_schema.nim` | 2026-10-06 |

## 未測定 (セキュリティ修正: 外向きの HTTP、認可クライアント、Tasks、クライアントの上限)

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/transport/http_wire.nim` (TLS のホスト名照合、要求・応答ヘッダの検査、接続・ヘッダ待ちのタイムアウト) | `tests/test_security_wire_tls.nim` (`-d:ssl`)、`tests/test_security_wire_headers.nim`、`tests/test_security_wire_limits.nim` | 2026-10-06 |
| `src/transport/event_stream.nim` (行・イベントの上限)、`src/transport/{http,sse_legacy}.nim` (上限とタイムアウトの受け渡し) | `tests/test_security_wire_limits.nim` | 2026-10-06 |
| `src/transport/address_policy.nim`、`src/transport/guarded_wire.nim`、`src/auth/oauth/{urls,fetch}.nim`、`src/auth/client.nim` (`narrowedTo`) | `tests/test_security_address.nim` | 2026-10-06 |
| `src/client/icons.nim` (タイムアウト時の接続、アドレス判定) | `tests/test_security_icons.nim` | 2026-10-06 |
| `src/auth/client.nim` (secret と issuer の結び付け)、`src/auth/oauth/{tokens,authcode}.nim` (`tokenExpiry`) | `tests/test_security_auth.nim`、`tests/test_security_auth_tokens.nim` | 2026-10-06 |
| `src/protocol/tasks.nim` (ttl の上限・期限の飽和・件数の上限・`onExpire`) | `tests/test_security_tasks.nim`、`tests/test_security_expiry.nim` | 2026-10-06 |
| `src/protocol/task_methods.nim` (`pollPauseMs`) | `tests/test_security_poll.nim` | 2026-10-06 |
| `src/server/tasks.nim` (期限切れでの解放) | `tests/test_security_expiry.nim` | 2026-10-06 |
| `src/client/sampling.nim` (`numberField`) | `tests/test_security_sampling.nim` | 2026-10-06 |
| `src/client/content.nim` (`allPages` の上限) | `tests/test_security_pages.nim` | 2026-10-06 |

## 未測定 (適合性テストで見つけた修正)

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/transport/sse_stream.nim` (待機の前に `changed` を控える。書き込み中に積まれたイベントを待ち落とさない) | `tests/test_http_streams.nim` | 2026-10-06 |
| `src/protocol/modern.nim` (`decodeHeaderValue`: パディングの無い Base64 を拒否する) | `tests/test_modern_protocol.nim`, `tests/test_param_headers_http.nim` | 2026-10-06 |
| `src/auth/oauth/discovery.nim`、`src/auth/oauth/metadata.nim` (ルートの well-known URI から得た PRM は、オリジンを `resource` に名乗ってよい) | `tests/test_auth_client_flow.nim` | 2026-10-06 |
| `src/auth/client.nim` (`indicator`: `resource` は PRM が公表した識別子をそのまま送る) | `tests/test_auth_client_flow.nim` | 2026-10-06 |

## 未測定 (認可の失敗の型)

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/transport/transport.nim` (`McpAuthorizationError`)、`src/transport/http.nim` (401 / 403 を解消できないときに送出)、`src/client/client.nim` (`discover` が旧版への切り替えをしない) | `tests/test_auth_failure.nim` | 2026-10-06 |

## 未測定 (HTTP サーバーのセキュリティ修正。本線向け)

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/transport/http_server.nim` (認可の対象パス、セッションの所有者、cancelled の書き換え、資源上限、Host 検証) | `tests/test_security_http.nim` | 2026-10-06 |
| `src/transport/auth_hook.nim`、`src/auth/resource_server.nim` (`ownPaths`、`mcpPath` の廃止) | `tests/test_security_http.nim`、`tests/test_auth_resource_server.nim` | 2026-10-06 |
| `src/protocol/diagnostic.nim` (`peerText`) と、それを使う `src/server/server.nim`、`src/transport/{http,http_server,sse_legacy,stdio}.nim` の診断 | `tests/test_security_diagnostic.nim` | 2026-10-06 |
