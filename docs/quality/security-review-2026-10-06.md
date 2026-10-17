# 2026-10-06 のセキュリティレビュー: 指摘と、それを確かめるテスト

2026-10-06 のレビュー（読解のみ。Critical 1、High 4、Medium 6、Low 6）の指摘ごとに、直した規則（仕様 ID）と外部仕様テストを結んだ表。台帳の SEC-01 の根拠である。

## 確かさ

- **測った:**
  - 仕様 ID と外部仕様テストの列は、`specs/tests.map` から取った。2026-10-17 の時点で、どの仕様 ID にも外部仕様テストがある（`nimble specCoverage`）。
  - 表に出てくるテストファイルが存在することも確かめた。
- **推論した:**
  - 指摘と修正コミットの組み合わせは、コミットの題と指摘の範囲から推論した。
  - リポジトリの中で指摘の番号に直接結ばれているのは、H4（テストファイルの先頭）と、C1・M1・M2・M6・L5・L6（`specs/security.feature` とテストの先頭）だけである。

## 表

| 指摘 | 重さ | 内容 | 仕様 ID | 外部仕様テスト |
|---|---|---|---|---|
| C1 | Critical | 旧 HTTP+SSE の経路（`/sse`、`/messages`）で認可を迂回できた | MCP-SEC-HTTP-1、-9 | `test_security_http.nim` |
| H1 | High | https でホスト名を照合していなかった | MCP-SEC-WIRE-1、-20、-22 | `test_security_trusted_ca.nim` |
| H2 | High | 正規表現でスタックが尽き、ReDoS になり、`$ref` が循環した | MCP-SEC-SCHEMA-1〜5 | `test_security_schema.nim` |
| H3 | High | client secret が、信頼できないサーバーが指す認可サーバーへ送られた | MCP-SEC-AUTH-1、-2 | `test_security_auth.nim` |
| H4 | High | task の ttl があふれて、ストア全体が止まった | MCP-SEC-TASKS-1〜5 | `test_security_tasks.nim` |
| M1 | Medium | セッションが認可の主体に結び付いていなかった | MCP-SEC-HTTP-2 | `test_security_http.nim` |
| M2 | Medium | HTTP サーバーの資源を枯渇させられた（batch、待ち行列、セッション、読み取りタイムアウト） | MCP-SEC-HTTP-3、-10 | `test_security_http.nim`、`test_security_http_read_timeout.nim` |
| M3 | Medium | クライアントの SSE の解析に上限がなく、接続にタイムアウトがなかった | MCP-SEC-WIRE-3 | `test_security_wire_limits.nim` |
| M4 | Medium | SSRF の判定がリテラルしか見ていなかった | MCP-SEC-WIRE-4〜6、-11〜14、-21 | `test_security_address.nim` |
| M5 | Medium | Events の確認の頻度、poll の lease、誤りの分け方、同期の名前解決 | 下書きの系列の MCP-SEC-EVENTS-1〜14 | 下書きの系列の `test_draft_events_security.nim`、`test_draft_events_hub.nim`。Events は下書きなので、本線には無い |
| M6 | Medium | 他のクライアントの要求を取り消せた | MCP-SEC-HTTP-6 | `test_security_http.nim` |
| L1 | Low | `5.0` のような浮動小数の整数キーワードを 0 と読んでいた | MCP-SEC-SCHEMA-6 | `test_security_schema.nim` |
| L2 | Low | uniqueItems の検査が O(n²) だった | MCP-SEC-SCHEMA-7 | `test_security_schema.nim` |
| L3 | Low | 要求行とヘッダーに含まれる CR・LF を調べていなかった | MCP-SEC-WIRE-2、-15、-16 | `test_security_wire_headers.nim` |
| L4 | Low | expires_in に上限がなかった | MCP-SEC-AUTH-5 | `test_security_auth_tokens.nim` |
| L5 | Low | Host ヘッダーを確かめていなかった（DNS rebinding） | MCP-SEC-HTTP-5 | `test_security_http.nim` |
| L6 | Low | 相手が決めた文字列を、そのまま stderr に書いていた | MCP-SEC-HTTP-7 | `test_security_diagnostic.nim`、`test_security_diagnostic_client.nim` |

## 指摘ではなく報告として残っていた上限のない 4 か所

レビューのあとの点検（2026-10-06）で「報告のみ」とされ、利用者の判断待ちだったもの。2026-10-17 の利用者の決定（直す）を受けて、3 か所に上限を設けた。

| 箇所 | 仕様 ID | 外部仕様テスト |
|---|---|---|
| 1 セッションの購読の数と、`subscriptions/listen` の数 | MCP-SEC-SWEEP-7 | `test_security_subscription_limits.nim` |
| クライアントが同時に処理する、サーバーからの要求の数 | MCP-SEC-SWEEP-8 | `test_security_sampling_limits.nim` |
| sampling の `maxTokens` | MCP-SEC-SWEEP-9 | `test_security_sampling_limits.nim` |
| Events の一覧のページ送り | — | 下書きの系列にしかない。本線の公開の対象外で、下書きの系列で扱う |

## このレビューの外にあるもの

- **レビューの性質:** レビューは、実装したチームのエージェントが読解だけで行った。実装した者以外によるレビュー（台帳の SEC-02）は、まだ行っていない。
- **扱っていない小さな報告（判断待ち）:**
  - 型の誤った capability の bool が false になる（安全側に倒れる）
  - クライアントのハンドラーが例外を上げたときの経路を確かめていない
  - リモートのインターセプターが、`failOpen` を自分で名乗れる
