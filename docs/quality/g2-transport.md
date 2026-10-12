# G2 変異検出: `src/transport/transport.nim`

測定: `nim-muter`、ジョブ `tests/mutation/transport.json`、mainline の 36a4c8a5 (2026-10-07)。
2026-10-12 に `transport.nim` を変えた。次の測定で測り直す。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 21 | 6 | 6 | 6 | 0 | 3 |

timeout 6 件は個別に調べていない (検出として数える)。

## survived 6 件

分類は、3 = 穴 (新しい外部仕様テストを足した)。
すべて 3 で、変異を手で当てて `tests/test_transport.nim` が落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは戻した)。
このテストファイルは、ジョブの `testCommand` に足した。

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 16 | transport.nim:80 | SDL | `await t.sendNotification(notification)` → `discard` | 3 | 経路 (route) を指定した通知が、経路を無視する移送の通常の送信に渡らず失われる。`Given a transport that ignores routes, when a notification is sent with one, then the plain send gets it` (`MCP-TRANSPORT-1`) |
| 17 | transport.nim:85 | SDL | `await t.sendRequest(request)` → `discard` | 3 | 同じく要求が失われる。`Given a transport that ignores routes, when a request is sent with one, then the plain send gets it` (`MCP-TRANSPORT-1`) |
| 12 | transport.nim:208 | LOR | `isResponse`: `kind == JObject and hasKey("id")` の `and` → `or` | 3 | オブジェクトでない JSON で `hasKey` が AssertionDefect を出す。`id` のない result も応答になる。`Given JSON that is not an object, ...`、`Given a result without an id, ...` (`MCP-TRANSPORT-2`) |
| 11 | transport.nim:208 | LOR | `isResponse`: `A and B and C` の 2 つ目の `and` → `or` (`(A and B) or C`) | 3 | id のない result が応答になり、要求 (id と method) も応答になる。`Given a request, ...`、`Given a result without an id, ...`、`Given JSON that is not an object, ...` |
| 15 | transport.nim:212 | LOR | `isNotification`: `kind == JObject and (not hasKey("id"))` の `and` → `or` | 3 | オブジェクトでない JSON で AssertionDefect。`Given JSON that is not an object, ...`。要求が通知になることも `Given a request, ...` が見る。 |
| 14 | transport.nim:212 | LOR | `isNotification`: 2 つ目の `and` → `or` (`(A and not B) or C`) | 3 | method を持つ要求が通知になる。`Given a request, when classified, then it is a request only` ほか 2 件 |

## 残っているもの

なし。
