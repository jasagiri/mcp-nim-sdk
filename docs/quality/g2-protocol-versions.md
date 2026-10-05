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

## 手で確かめたもの (nim-muter の測定ではない)

`src/protocol/modern.nim` は実装をテストより先に書いたため、2026-10-05 に規則を
1 つずつ壊した版を 20 通り作り、`tests/test_modern_protocol.nim` が落ちるかを確かめた。
19 通りは検出された。検出されなかった 1 通り (結果に既にあるサーバー識別を上書きする)
にはテストを足した。これは網羅的な変異検査の代わりにはならない。
