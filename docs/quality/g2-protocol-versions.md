# G2 変異検出: プロトコル版まわり

`nim-muter` による測定は、実装が落ち着いてから push の前に 1 回流す。
それまでは、変更したモジュールをここに「未測定」として足していく。

## 記録の訂正: リテラルを返す `return` の変異 (2026-10-10)

nim-muter 0.2.5 の RVR は、戻り値がリテラルのとき `default(typeof(X))` ではなく別の値にする: `true` と `false` は入れ替え、整数と小数は 0 なら 1・ほかは 0、文字列は `""`。報告の `replacement` はどの場合も `<return default>` と表示される (`foundation/nim-muter/src/nim_muter/mutators/return_value.nim`)。

2026-10-07 の分類は、`return false` の生き残りを「`bool` の既定値は `false` だから同値」としていた。これは誤りで、実際の変異は `return true` である。該当は 10 文書の 29 行で、それぞれの行を訂正した。

| ジョブ | 行数 | 訂正後 |
|---|---:|---|
| client、server、tasks | 9 | 76a08c6a の測り直しで検出 (同じ行の BLR のために足したテストが落ちる) |
| elicitation、stdio、auth_client | 12 | 測り直しの対象外。`return true` を手で当て、ジョブのテストが落ちることを 1 件ずつ確かめた |
| param_headers | 1 | 分類 4。`isToken` の空の名前の検査は、呼び出し元が先に断るので届かない |
| http_client、http_server、jsonschema | 7 | 76a08c6a (http_client 1、http_server 2) と e79ebbd8 (jsonschema 4) の測り直しで検出 |

`return none(T)`、`return ""`、列挙値や構築子を返す `return` の「同値」は、この誤りに当たらない (`default(typeof(X))` になる)。各文書の冒頭にある分類ごとの件数の表は、2026-10-07 の時点のままにしてある。

## 測定の現状 (2026-10-11)

本線の 27 ジョブはすべて測定済みで、どのジョブも、最後に測ったコミットから本線の先端までに対象のソース (`tests/mutation/<ジョブ>.json` の `sources`) が変わっていない (`git diff --name-only <測ったコミット> <先端> -- <sources>` が空であることを、ジョブごとに確かめた)。下の「未測定」の各節に挙げたモジュールは、どれもこの 27 ジョブのどれかの対象に入っている (`src/server/prompts.nim`、`src/server/resources.nim`、`src/server/tool_output.nim` は `server.nim` に統合して削除済み)。節は経緯として残してある。

| ジョブ | 最後に測ったコミット | 日付 | 変異 | 生き残り |
|---|---|---|---:|---:|
| address_policy | 76a08c6a | 2026-10-10 | 212 | 18 |
| auth_client | 36a4c8a5 | 2026-10-07 | 77 | 21 |
| auth_oauth | 76a08c6a | 2026-10-10 | 326 | 19 |
| auth_resource_server | 36a4c8a5 | 2026-10-07 | 42 | 12 |
| base64_shape | 7d32c165 | 2026-10-07 | 14 | 0 |
| client | 76a08c6a | 2026-10-09 | 346 | 9 |
| content | 36a4c8a5 | 2026-10-07 | 101 | 26 |
| diagnostic | 76a08c6a | 2026-10-10 | 37 | 2 |
| elicitation | 36a4c8a5 | 2026-10-07 | 324 | 103 |
| event_stream | 36a4c8a5 | 2026-10-07 | 35 | 5 |
| extensions | 36a4c8a5 | 2026-10-07 | 86 | 25 |
| features | 76a08c6a | 2026-10-10 | 57 | 0 |
| http_client | 76a08c6a | 2026-10-10 | 386 | 33 |
| http_server | 76a08c6a | 2026-10-10 | 391 | 20 |
| jsonschema | e79ebbd8 | 2026-10-11 | 483 | 17 |
| lifecycle | 76a08c6a | 2026-10-09 | 24 | 2 |
| modern | 76a08c6a | 2026-10-10 | 94 | 6 |
| mrtr | 76a08c6a | 2026-10-10 | 105 | 8 |
| param_headers | 36a4c8a5 | 2026-10-07 | 84 | 13 |
| sampling_tools | 76a08c6a | 2026-10-10 | 168 | 2 |
| server | 76a08c6a | 2026-10-09 | 442 | 39 |
| stdio | 36a4c8a5 | 2026-10-07 | 64 | 26 |
| subscriptions | 76a08c6a | 2026-10-10 | 84 | 2 |
| tasks | 76a08c6a | 2026-10-10 | 297 | 21 |
| trace_context | 76a08c6a | 2026-10-10 | 96 | 11 |
| transport | 36a4c8a5 | 2026-10-07 | 21 | 6 |
| version | 36a4c8a5 | 2026-10-07 | 23 | 5 |

生き残りの分類と理由は各ジョブの `g2-<ジョブ>.md` にある。理由の無い生き残りと未判定の行は残っていない。利用者の判断を待っている行 (到達しないコード、仕様が決めていない挙動) は、各文書の「残っているもの」にある。

拡張 (`mcp-2026-07-28-ext` になる系列) と下書き (`mcp-draft` になる系列) のジョブは、それぞれの系列の `g2-ext_*.md` と `g2-draft_*.md` に記録がある。どちらも初回の測定のあとに欠陥を 1 件ずつ直しているので、`ext_skills` (`frontmatter.nim`) と `draft_events` (`client.nim`) は測り直しが要る。`ext_skills` は 60cbfdb5 で測り直した (2026-10-19、`test_ext_targets.nim` を含む。Skills の登録の版の確かめもここで測った)。

## 2026-10-14 の状態

上の表の測定は古くなっている。本線の先端 bb6744101764 と、表の「最後に測ったコミット」の間で、27 ジョブのうち 13 の対象のソースが変わった。同じやり方 (`git diff --name-only <測ったコミット> <先端> -- <sources>`) で確かめた。

| ジョブ | 変わった対象のソース |
|---|---|
| address_policy | `src/client/icons.nim`、`src/transport/address_policy.nim` |
| auth_client | `src/auth/client.nim` |
| auth_oauth | `src/auth/oauth/metadata.nim`、`src/auth/oauth/tokens.nim` |
| client | `src/client/client.nim`、`src/client/roots.nim`、`src/client/utilities.nim` |
| content | `src/server/tools.nim` |
| http_client | `src/transport/http.nim`、`src/transport/http_compat.nim` |
| http_server | `src/transport/http_server.nim`、`src/transport/sse_stream.nim` |
| jsonschema | `src/jsonschema/json_schema.nim`、`src/jsonschema/json_schema_regex.nim` |
| lifecycle | `src/protocol/types.nim` |
| mrtr | `src/protocol/mrtr.nim`、`src/server/mrtr.nim` |
| param_headers | `src/protocol/param_headers.nim` |
| server | `src/server/errors.nim`、`src/server/server.nim` |
| transport | `src/transport/transport.nim` |

残りの 14 ジョブ (auth_resource_server、base64_shape、diagnostic、elicitation、event_stream、extensions、features、modern、sampling_tools、stdio、subscriptions、tasks、trace_context、version) は対象のソースが変わっていない。ただしテストは全ジョブで変わっている (外部と内部への分け直し、性質のテストへの置き換え、代表値のテスト 20 本の削除)。消したテストが殺していた変異が、いまも殺されるかは測っていない。

測り直しは利用者の指示を待つ (2026-10-14 の時点で、変異検査は投入しない)。push の前の判定はその結果による。

## 未測定

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `tools/gen_docs.nim` | `tests/test_docs_version.nim` | 2026-10-06 |
| `src/protocol/version.nim` (`requireVersionSpoken`) | `tests/external/test_version.nim` | 2026-10-15 |
| `src/protocol/lifecycle.nim` | `tests/test_legacy_handshake.nim` | 2026-10-05 |
| `src/server/server.nim` | `tests/test_legacy_handshake.nim`, `tests/test_era_matrix.nim` | 2026-10-05 |
| `src/transport/http.nim`、`src/transport/sse_legacy.nim` (`caFile`) | `tests/external/test_security_trusted_ca.nim` (ジョブ http_client に足した) | 2026-10-17 |
| `src/client/icons.nim` (`IconFetchOptions.caFile`) | `tests/external/test_security_trusted_ca.nim` (ジョブ address_policy に足した) | 2026-10-17 |
| `src/auth/oauth/urls.nim`、`src/auth/oauth/fetch.nim` (`FetchPolicy.caFile`) | `tests/external/test_security_trusted_ca.nim` (ジョブ auth_oauth に足した) | 2026-10-17 |
| `src/transport/http_server.nim`、`src/transport/sse_stream.nim` (`readTimeoutMs`、`asynchttpserver_compat` に替えた) | `tests/external/test_security_http_read_timeout.nim` (ジョブ http_server に足した)。`src/transport/vendor/asynchttpserver.nim` は Nim の写しなので測らない | 2026-10-17 |
| `src/server/server.nim`、`src/server/subscriptions.nim` (`maxSubscriptionsPerSession`、`maxListenStreamsPerSession`) | `tests/external/test_security_subscription_limits.nim` (ジョブ server、subscriptions に足した) | 2026-10-17 |
| `src/transport/http_wire.nim` (状態コードの範囲、チャンクの大きさ、チャンクの後ろの余分なバイト) | `tests/external/test_security_wire_shapes.nim` (ジョブ http_client) | 2026-10-18 |
| `src/protocol/content.nim` (`iconsOf` がオブジェクトでない項目を断る) | `tests/external/test_security_wire_shapes.nim` (ジョブ content) | 2026-10-18 |
| `src/protocol/tasks.nim` (`parseIsoTimestamp` が RFC 3339 の形を先に確かめる)、`src/protocol/rfc3339.nim` (新規。elicitation から移した `isDate`・`isDateTime`)、`src/protocol/elicitation.nim` | `tests/external/test_tasks_store.nim` (ジョブ tasks)、`tests/external/test_elicitation_payload.nim` (ジョブ elicitation)。`rfc3339.nim` はまだどのジョブの `sources` にも入っていない: 測る前に tasks か elicitation のジョブに足す | 2026-10-19 |
| `src/client/client.nim` (`maxServerRequestsInProgress`)、`src/client/sampling.nim` (`maxTokens`) | `tests/external/test_security_sampling_limits.nim` (ジョブ client に足した) | 2026-10-17 |
| `src/client/client.nim` | `tests/test_legacy_handshake.nim`, `tests/test_era_matrix.nim` | 2026-10-05 |
| `src/client/{content,tools,resources,prompts,utilities}.nim` | `tests/test_client_operations.nim` | 2026-10-06 |
| `src/client/{roots,sampling}.nim` | `tests/test_client_server_requests.nim` | 2026-10-06 |
| `src/client/client.nim` | タイムアウト・キャンセル・進捗・接続終了・通知 | `tests/test_client_requests.nim`, `tests/test_client_server_requests.nim` | 2026-10-06 |
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
| `src/transport/http_server.nim` | SSE 応答、GET ストリーム、再開、バッチ、版ヘッダ、期限切れ、HTTP+SSE | `tests/test_http_streams.nim`, `tests/test_http_sse_legacy.nim` | 2026-10-06 |
| `src/transport/http_wire.nim` | `tests/test_http_client_streams.nim`, `tests/test_http_streams.nim` | 2026-10-06 |
| `src/transport/sse_stream.nim` | `tests/test_http_streams.nim`, `tests/test_http_sse_legacy.nim` | 2026-10-06 |
| `src/transport/sse_legacy.nim` | `tests/test_http_sse_legacy.nim` | 2026-10-06 |
| `src/transport/http_compat.nim` | `tests/test_http_sse_legacy.nim` | 2026-10-06 |
| `src/transport/event_stream.nim` (retry) | `tests/test_event_stream.nim` | 2026-10-06 |
| `src/auth/oauth/*.nim` | `tests/test_auth_sha256.nim`, `tests/test_auth_oauth_basics.nim`, `tests/test_auth_client_flow.nim` | 2026-10-06 |
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
| `src/server/server.nim` (リクエスト傍受、`serveDetached`、タスクに属するサーバー発リクエスト) | `tests/test_tasks_server.nim` | 2026-10-06 |
| `src/protocol/lifecycle.nim` (`tasks` capability の入出力) | `tests/test_tasks_server.nim`, `tests/test_tasks_client.nim` | 2026-10-06 |
| `src/ext/apps/model.nim` | `tests/test_ext_apps_model.nim` | 2026-10-06 |
| `src/ext/apps/messages.nim` | `tests/test_ext_apps_messages.nim` | 2026-10-06 |
| `src/ext/apps/provider.nim` | `tests/test_ext_apps_server.nim`, `tests/test_ext_apps_end_to_end.nim` | 2026-10-06 |
| `src/ext/apps/host.nim` | `tests/test_ext_apps_host.nim`, `tests/test_ext_apps_end_to_end.nim` | 2026-10-06 |
| `src/server/server.nim` (`addToolListTransform`) | `tests/test_ext_apps_server.nim` | 2026-10-06 |
| `src/ext/tasks/wire.nim`, `src/ext/tasks/server.nim`, `src/ext/tasks/client.nim` (拡張 Tasks) | `tests/test_ext_tasks.nim`, `tests/test_ext_tasks_client.nim`, `tests/test_ext_tasks_dual.nim` | 2026-10-06 |
| `src/protocol/tasks.nim` (`finish` の toolErrorsFail)、`src/protocol/task_methods.nim` (`runAsTask`) | `tests/test_ext_tasks.nim` | 2026-10-06 |
| `src/protocol/extensions.nim` (`takesOver`)、`src/server/extensions.nim`、`src/server/server.nim` (取り戻されたメソッド、`ListenFilterHook`、`notifySubscribers`) | `tests/test_ext_tasks.nim` | 2026-10-06 |
| `src/protocol/subscriptions.nim` (`taskIds`)、`src/client/subscriptions.nim` (`unsupported`)、`src/protocol/modern.nim` (Mcp-Name の taskId) | `tests/test_ext_tasks.nim`, `tests/test_ext_tasks_client.nim` | 2026-10-06 |

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
| `src/transport/http_wire.nim` | TLS のホスト名照合、要求・応答ヘッダの検査、接続・ヘッダ待ちのタイムアウト | `tests/test_security_wire_tls.nim` (`-d:ssl`)、`tests/test_security_wire_headers.nim`、`tests/test_security_wire_limits.nim` | 2026-10-06 |
| `src/transport/event_stream.nim` (行・イベントの上限)、`src/transport/{http,sse_legacy}.nim` (上限とタイムアウトの受け渡し) | `tests/test_security_wire_limits.nim` | 2026-10-06 |
| `src/transport/address_policy.nim`、`src/transport/guarded_wire.nim`、`src/auth/oauth/{urls,fetch}.nim`、`src/auth/client.nim` (`narrowedTo`) | `tests/test_security_address.nim` | 2026-10-06 |
| `src/client/icons.nim` (タイムアウト時の接続、アドレス判定) | `tests/test_security_icons.nim` | 2026-10-06 |
| `src/auth/client.nim` (secret と issuer の結び付け)、`src/auth/oauth/{tokens,authcode}.nim` (`tokenExpiry`) | `tests/test_security_auth.nim`、`tests/test_security_auth_tokens.nim` | 2026-10-06 |
| `src/protocol/tasks.nim` (ttl の上限・期限の飽和・件数の上限・`onExpire`) | `tests/test_security_tasks.nim`、`tests/test_security_expiry.nim` | 2026-10-06 |
| `src/protocol/task_methods.nim` (`pollPauseMs`) | `tests/test_security_poll.nim` | 2026-10-06 |
| `src/server/tasks.nim` (期限切れでの解放) | `tests/test_security_expiry.nim` | 2026-10-06 |
| `src/client/sampling.nim` (`numberField`) | `tests/test_security_sampling.nim` | 2026-10-06 |
| `src/client/content.nim` (`allPages` の上限) | `tests/test_security_pages.nim` | 2026-10-06 |
| `src/ext/tasks/client.nim` (`pollPauseMs`)、`src/ext/tasks/server.nim` (期限切れでの解放) | `tests/test_security_ext_tasks.nim` | 2026-10-06 |
| `src/ext/auth_shared.nim`、`src/ext/auth_client_credentials.nim`、`src/ext/auth_enterprise_managed.nim` (issuer との結び付け、数値の読み取り) | `tests/test_security_ext_auth.nim` | 2026-10-06 |

## 未測定 (適合性テストで見つけた修正)

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/transport/sse_stream.nim` | 待機の前に `changed` を控える。書き込み中に積まれたイベントを待ち落とさない | `tests/test_http_streams.nim` | 2026-10-06 |
| `src/protocol/modern.nim` (`decodeHeaderValue`: パディングの無い Base64 を拒否する) | `tests/test_modern_protocol.nim`, `tests/test_param_headers_http.nim` | 2026-10-06 |
| `src/auth/oauth/discovery.nim`、`src/auth/oauth/metadata.nim` (ルートの well-known URI から得た PRM は、オリジンを `resource` に名乗ってよい) | `tests/test_auth_client_flow.nim` | 2026-10-06 |
| `src/auth/client.nim` (`indicator`: `resource` は PRM が公表した識別子をそのまま送る) | `tests/test_auth_client_flow.nim` | 2026-10-06 |

## 未測定 (認可の失敗の型)

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/transport/transport.nim` (`McpAuthorizationError`)、`src/transport/http.nim` (401 / 403 を解消できないときに送出)、`src/client/client.nim` (`discover` が旧版への切り替えをしない) | `tests/test_auth_failure.nim` | 2026-10-06 |

## 測定後に変わったモジュール (2026-10-07 の測定 36a4c8a5 より後。push の前に測り直す)

| モジュール | 変えた内容 | 対応する外部仕様テスト |
|---|---|---|
| `src/protocol/trace_context.nim` | `tracestate` の空の値を拒否 (W3C: 1 文字以上) | `tests/test_trace_context.nim` |
| `src/server/tasks.nim` | `listClientTasks` が `nextCursor` の無い最後のページで落ちていたのを修正 | `tests/test_tasks_server.nim` |
| `src/protocol/features.nim` | `ftHttpSse` の `specPage` の冗長な枝を削除 | `tests/test_features.nim` |
| `src/server/server.nim` | `handleInitialize` の届かない枝を `doAssert` に | `tests/test_legacy_handshake.nim`、`tests/test_version_floor.nim` |
| `src/server/resources.nim`、`src/server/prompts.nim` | 削除 (どこからも使われていなかった) | (なし) |
| `src/client/client.nim` | 送信に失敗した要求を待ちの表から外す (`startRequest`)。到達しない文 2 つを削除、`discover` の末尾を `raiseAssert` に | `tests/test_client_requests.nim` |
| `src/protocol/lifecycle.nim` | 呼び出し元の無い補助関数 4 つを削除 | `tests/test_legacy_handshake.nim` |
| `src/transport/first_of.nim` | 新規。`firstOf`、`Doorbell`。future の既存コールバックを消さずに最初の 1 つを待つ | `tests/test_first_of.nim` (内部実装テスト)。外部仕様テストは下の各モジュールの行。変異検査は `http_client` ジョブで測る (未測定) |
| `src/client/client.nim` | `sendOnce`、`startRequest` の待ちを `or` から `firstOf` に。取り消しトークンを共有する複数の要求が全部取り消される。`startRequest` の `try/except` は不要になり削除 | `tests/test_client_requests.nim` (MCP-CANCEL-4。待ち手が残らないことは内部実装テスト) |
| `src/client/subscriptions.nim` | `listen` の待ちを `firstOf` に。トークン共有 | `tests/test_subscriptions.nim` (MCP-SUBSCRIBE-11) |
| `src/transport/http_wire.nim` | 読み取りと `close`、接続と応答ヘッダーのタイムアウトの待ちを `firstOf` に。`leftOpen` を読み取りごとの `interrupt` に | `tests/test_http_unresponsive.nim`、`tests/test_http_client_streams.nim`、`tests/test_http_sse_legacy.nim`、`tests/test_security_wire_limits.nim` |
| `src/transport/sse_stream.nim` | `serveStream` の待ちを `Doorbell` に。`gone` と `idle` は 1 回だけ監視 | `tests/test_http_streams.nim`、`tests/test_streamable_http.nim` |
| `src/transport/http_server.nim` | 交換の完了と切断の待ちを `firstOf` に。HTTP+SSE のセッションで効果の無かった 2 文 (`touch()`、`used = true`) を削除 | `tests/test_streamable_http.nim`、`tests/test_security_http.nim` |
| `src/protocol/base64_shape.nim` | 新規。base64 の形 (`isPaddedBase64`、`isBase64Text`) を復号の前に確かめる。ジョブ `base64_shape` を新設、未測定 | `tests/test_base64_shape.nim` (MCP-SEC-WIRE-9) |
| `src/server/pagination.nim` | 形が base64 でない cursor を復号の前に断る (Nim 2.2.8 までの `base64.decode` が `IndexDefect` を出す。nim-lang/Nim#25530) | `tests/test_server_pagination.nim` (MCP-SEC-WIRE-9) |
| `src/client/icons.nim` | data URI の中身が base64 でなければ復号の前に断る | `tests/test_icon_fetch.nim` (MCP-SEC-WIRE-9) |
| `src/protocol/modern.nim` | 自前の `isPaddedBase64` を消し、`base64_shape` のものを使う (内容は同じ) | `tests/test_modern_protocol.nim`、`tests/test_param_headers.nim` |
| `src/jsonschema/json_schema_regex.nim` | U+00FF を超える文字を文字クラスの外に持つパターンが `RangeDefect` になっていたのを修正 (ファジングで発見)。`\b` の読み取りを普通の `if` に (nim-muter の書き直しがコンパイル不能にしていた。36a4c8a5 の測定ではこのジョブは 1 件も試せていない) | `tests/test_security_schema.nim` (MCP-SEC-SCHEMA-9)、`tests/test_fuzz_regressions.nim` (MCP-SEC-SWEEP-6) |
| `src/auth/oauth/discovery.nim` | 探索の失敗を並べるとき、例外の文面から async の追跡を外す (2 番目以降の失敗が消えていた) | `tests/test_auth_oauth_basics.nim` |
| `src/protocol/diagnostic.nim` | `plainMessage` をここへ移した (`server/errors.nim` は再 export) | `tests/test_server_errors.nim`、`tests/test_auth_oauth_basics.nim` |
| `src/auth/oauth/jsonfield.nim` | 呼び出し元の無い `intField` を削除 | (なし) |
| `src/transport/sse_legacy.nim` | 呼び出し元の無い `port` を削除。`sameOrigin` は URL に書かれたポートをそのまま比べる (下の注) | `tests/test_http_sse_legacy.nim` |
| `src/protocol/implementation_status.nim`、`src/protocol/sampling_tools.nim` | 使われていない `notYet` と定数 `ContentTypes` を削除 | `tests/test_docs_version.nim`、`tests/test_sampling_tools_payload.nim` |
| `src/transport/http.nim` | ストリームが終わった要求を `inflight` から消す。`close()` の後に開き終わったストリームを閉じる。通知に答えたストリームの終了で落ちない。取り消した要求を再開しない | `tests/test_http_client_streams.nim` |
| `src/transport/http_wire.nim` | `close()` で起こされた読み取りは静かに終わる。`readAll` は途中で閉じられた本文を返さない。負の `Content-Length` を拒否 | `tests/test_http_client_streams.nim`、`tests/test_security_wire_limits.nim`、`tests/test_security_wire_headers.nim` |
| `src/jsonschema/json_schema_regex.nim` | 7d32c165 の測定の後: `[]` と `[^]` を ECMA-262 どおりに読む。読まれない `lazy` を削除 | `tests/test_json_schema.nim`、`tests/test_security_schema.nim` |
| `src/jsonschema/json_schema.nim` | 7d32c165 の測定の後: `$ref` の先頭が 0 の添字を拒否 | `tests/test_security_schema.nim` |

注 (2026-10-12 に今のままと決めた): `sse_legacy.nim` と `http_wire.nim` の `sameOrigin` は、既定のポートを書いた URL と省いた URL
(`https://h/` と `https://h:443/`) を別のオリジンと見る。HTTP+SSE の `endpoint` イベントは拒否され、リダイレクトでは
資格情報が外れる。どちらも安全側の誤りで、既定のポートで待つサーバーを立てないとテストできないため、直していない。
削除した `port` は、この比較に使うつもりで書かれて使われていなかった関数。

## 未測定 (HTTP サーバーのセキュリティ修正。本線向け)

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/transport/http_server.nim` | 認可の対象パス、セッションの所有者、cancelled の書き換え、資源上限、Host 検証 | `tests/test_security_http.nim` | 2026-10-06 |
| `src/transport/auth_hook.nim`、`src/auth/resource_server.nim` (`ownPaths`、`mcpPath` の廃止) | `tests/test_security_http.nim`、`tests/test_auth_resource_server.nim` | 2026-10-06 |
| `src/protocol/diagnostic.nim` (`peerText`) と、それを使う `src/server/server.nim`、`src/transport/{http,http_server,sse_legacy,stdio}.nim` の診断 | `tests/test_security_diagnostic.nim` | 2026-10-06 |

## 認可の拡張 (ext-auth): 未測定

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/auth/oauth/authcode.nim` (`parseTokenResponse` の公開のみ)、`src/auth/oauth/metadata.nim` (`document` フィールドのみ) | `tests/test_auth_oauth_basics.nim`, `tests/test_auth_client_flow.nim` | 2026-10-06 |
| `src/auth/oauth/jwt.nim`, `src/auth/oauth/grants.nim` | `tests/test_ext_auth_grants.nim` | 2026-10-06 |
| `src/ext/auth_client_credentials.nim`, `src/ext/auth_shared.nim`, `src/auth/oauth/metadata_fields.nim` | `tests/test_ext_auth_client_credentials.nim` | 2026-10-06 |
| `src/ext/auth_enterprise_managed.nim` | `tests/test_ext_auth_enterprise_managed.nim` | 2026-10-06 |

`src/ext/auth_enterprise_managed.nim` は 2026-10-06 に、規則を 1 つずつ壊した版を 7 通り作り
(プロファイル確認の省略、`aud` / `client_id` / `typ` / `token_type` の検査の省略、
ID-JAG の再利用の無効化、リフレッシュトークンの保持)、`tests/test_ext_auth_enterprise_managed.nim`
が落ちるかを確かめた。7 通りとも検出された。これは網羅的な変異検査の代わりにはならない。
`auth_client_credentials.nim` と `jwt.nim` / `grants.nim` は手でも測っていない。

## 未測定 (公式拡張の対象の版)

2026-10-15: 公式拡張 (Tasks、Skills、OAuth client credentials、enterprise-managed authorization) ごとに対象の版を `src/ext/official_common.nim` の表 (`OfficialExtension`、`targetVersion`) に書き、登録はどれも `requireTargetSpoken` (本線の `requireVersionSpoken` を使う) を通るようにした。認可の 2 つはビルドの既定の版ではなく側 (server / client) の上限の版で確かめるようになり、`auth_shared.requireExtensionsCapability` は消えた。Skills の client の `declareSkills` にも版の確かめが入った。どのジョブでも測っていない (Skills の `catalog.nim` `consumer.nim` は後に `ext_skills` の 2 回目の測定で測った。`g2-ext_skills.md`)。

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/ext/official_common.nim` (表と `requireTargetSpoken`) | `tests/external/test_ext_targets.nim` | 2026-10-15 |
| `src/ext/tasks/{server,client}.nim`、`src/ext/auth_client_credentials.nim`、`src/ext/auth_enterprise_managed.nim`、`src/ext/auth_shared.nim` (登録の版の確かめ) | `tests/external/test_ext_targets.nim` | 2026-10-15 |
