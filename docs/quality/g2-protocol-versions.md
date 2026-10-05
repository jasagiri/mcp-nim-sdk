# G2 変異検出: プロトコル版まわり

`nim-muter` による測定は、実装が落ち着いてから push の前に 1 回流す。
それまでは、変更したモジュールをここに「未測定」として足していく。

## 未測定

| モジュール | 対応する外部仕様テスト | 追加・変更した日 |
|---|---|---|
| `src/protocol/version.nim` | `tests/test_version.nim` | 2026-10-05 |
| `src/protocol/modern.nim` | `tests/test_modern_protocol.nim` | 2026-10-05 |
| `src/protocol/lifecycle.nim` | `tests/test_legacy_handshake.nim` | 2026-10-05 |
| `src/server/server.nim` | `tests/test_legacy_handshake.nim`, `tests/test_era_matrix.nim` | 2026-10-05 |
| `src/client/client.nim` | `tests/test_legacy_handshake.nim`, `tests/test_era_matrix.nim` | 2026-10-05 |
| `src/transport/transport.nim` | `tests/test_era_matrix.nim` | 2026-10-05 |
| `src/transport/event_stream.nim` | `tests/test_event_stream.nim` | 2026-10-05 |
| `src/transport/http.nim` | `tests/test_streamable_http.nim` | 2026-10-05 |
| `src/transport/http_server.nim` | `tests/test_streamable_http.nim` | 2026-10-05 |
| `src/transport/stdio.nim` | `tests/test_silent_dead.nim` | 2026-10-05 |
| `src/mcp/protocol.nim` | `tests/test_protocol_versions.nim` | 2026-10-05 |

## 手で確かめたもの (nim-muter の測定ではない)

`src/protocol/modern.nim` は実装をテストより先に書いたため、2026-10-05 に規則を
1 つずつ壊した版を 20 通り作り、`tests/test_modern_protocol.nim` が落ちるかを確かめた。
19 通りは検出された。検出されなかった 1 通り (結果に既にあるサーバー識別を上書きする)
にはテストを足した。これは網羅的な変異検査の代わりにはならない。
