# G2 変異検査: subscriptions ジョブ (g2f-subs)

対象は `src/protocol/subscriptions.nim`、`src/server/subscriptions.nim`、`src/client/subscriptions.nim` (`tests/mutation/subscriptions.json`)。
測定は 36a4c8a5 (change `owwryuxn`) で行った。ジョブ全体の数字は 85 件中 killed 34 / timeout 12 / survived 30 / compileError 9 / runError 0。

`src/protocol/subscriptions.nim` は測定後に変わっていない。`src/client/subscriptions.nim` は変わった (`listen` の待ちが `or` から `firstOf` になり、共有の取り消しトークンを扱うようになった)。
そのため client の 6 件は、行ではなく文面で探した。現在の行は測定時より 2 行後ろにある。文が置き換わって消えたものは無かった。

基点 `yylxkxvu` に対する結果を次に示す。

| 区分 | 件数 |
|---|---|
| 1 同値 | 2 |
| 3 隙間 (テストを書き、変異を手で当てて落ちることを確認した) | 28 |
| 2 / 2b / 4 / 5 / 6 | 0 |
| 3 隙間 (未確認) | 0 |

ジョブの `testCommand` は `tests/test_subscriptions.nim` で、新しいテストは同じファイルにあるため、ジョブは変えていない。

## 生き残りの一覧

テストの略称は次のとおり (すべて `tests/test_subscriptions.nim`)。

- 書式: 「Given a filter naming every type, when it is written as JSON ...」
- taskIds 解析: 「Given task ids in a filter, when it is parsed ...」
- 空判定: 「Given a filter that names one type or uri or task, when asked whether it is empty ...」
- タスク通知: 「Given a filter with task ids, when a task status notification arrives ...」
- 不正 params: 「Given malformed notification params, when asked whether they are wanted ...」
- 購読 id なし: 「Given params that cannot hold a subscription id, when it is read ...」
- _meta 保持: 「Given params with a _meta of their own, when tagged with a subscription id ...」
- 全部受理: 「Given an acknowledgment that honors everything asked for ...」
- 一部受理: 「Given an acknowledgment that honors only part of the filter ...」
- 送れない listen: 「Given a request that cannot be sent, when the client listens ...」
- timeout 0: 「Given a zero timeout, when the server acknowledges after the client's default ...」

「落ちた」は、その変異だけを手で当てて名前のテストが失敗するのを見たこと。
`nil` の参照を外す変異 (52, 56, 58, 59, 61) は、テストの失敗ではなく SIGSEGV でテストの実行が止まった。スタックはテストから変異した行へ入っていた。

### protocol/subscriptions.nim

| id | file:line | mutator | original → replacement | 区分 | 理由 | 検出するテスト |
|---|---|---|---|---|---|---|
| 63 | protocol/subscriptions.nim:37 | BLR | `%true` → `%false` (promptsListChanged) | 3 | 仕様の filter は購読する型を `true` で書く。tools 以外の型を書いたテストが無かった | 書式 (落ちた) |
| 64 | protocol/subscriptions.nim:38 | BLR | `%true` → `%false` (resourcesListChanged) | 3 | 同上 | 書式 (落ちた) |
| 49 | protocol/subscriptions.nim:45 | LOR | `(not t and not p)` の `and` → `or` | 3 | 空判定の各項は、1 つだけ名指しした filter でしか区別できない | 空判定 (落ちた) |
| 48 | protocol/subscriptions.nim:45 | LOR | `((not t and not p) and not r)` の外側 `and` → `or` | 3 | 同上 | 空判定 (落ちた) |
| 47 | protocol/subscriptions.nim:46 | LOR | 3 型の連言と uri 項の間の `and` → `or` | 3 | 同上 | 空判定 (落ちた) |
| 28 | protocol/subscriptions.nim:46 | ROR | `resourceSubscriptions.len == 0` → `!= 0` | 3 | uri だけを名指しした filter は空でない | 空判定 (落ちた。全部受理も落ちた) |
| 46 | protocol/subscriptions.nim:46 | LOR | uri 項と taskIds 項の間の `and` → `or` | 3 | 同上 | 空判定 (落ちた) |
| 29 | protocol/subscriptions.nim:47 | ROR | `taskIds.len == 0` → `!= 0` | 3 | taskIds だけを名指しした filter は空でない | 空判定 (落ちた。全部受理も落ちた) |
| 34 | protocol/subscriptions.nim:72 | ROR | `taskIds.kind != JArray` → `==` | 3 | taskIds の解析を試すテストが無かった | taskIds 解析 (落ちた) |
| 79 | protocol/subscriptions.nim:73 | RVR | 「taskIds must be an array」を返す `return` → 既定値 | 3 | 問題を返すことが仕様 (不正な filter は -32602 になる) | taskIds 解析 (落ちた) |
| 35 | protocol/subscriptions.nim:75 | ROR | `id.kind != JString` → `==` | 3 | 文字列の id を読めること | taskIds 解析 (落ちた) |
| 80 | protocol/subscriptions.nim:76 | RVR | 「taskIds must hold strings」を返す `return` → 既定値 | 3 | 79 と同じ | taskIds 解析 (落ちた) |
| 67 | protocol/subscriptions.nim:77 | SDL | `result.filter.taskIds.add id.getStr()` → `discard` | 3 | 読んだ id が filter に入ること | taskIds 解析 (落ちた。全部受理も一部受理も落ちた) |
| 52 | protocol/subscriptions.nim:82 | LOR | `params.isNil or params.kind != JObject` の `or` → `and` | 3 | params が無い通知から id を読んでも壊れない | 購読 id なし (SIGSEGV) |
| 81 | protocol/subscriptions.nim:83 | RVR | `return none(string)` → 既定値 | 1 | `Option[string]` の既定値は `none(string)` で、変異は同じ値を返す | なし |
| 82 | protocol/subscriptions.nim:86 | RVR | `return none(string)` → 既定値 | 1 | 81 と同じ | なし |
| 41 | protocol/subscriptions.nim:100 | ROR | `meta.kind != JObject` → `==` | 3 | 通知がすでに持つ `_meta` の他の鍵を保つこと。オブジェクトでない `_meta` は置き換える | _meta 保持 (落ちた) |
| 56 | protocol/subscriptions.nim:121 | LOR | `params.isNil or params.kind != JObject` の `or` → `and` | 3 | params の無い resources/updated は配送しない | 不正 params (SIGSEGV) |
| 58 | protocol/subscriptions.nim:122 | LOR | `not uri.isNil and uri.kind == JString` の `and` → `or` | 3 | uri の無い resources/updated は配送しない | 不正 params (SIGSEGV) |
| 59 | protocol/subscriptions.nim:124 | LOR | `params.isNil or params.kind != JObject` の `or` → `and` | 3 | params の無い task 通知は配送しない | タスク通知 (SIGSEGV) |
| 44 | protocol/subscriptions.nim:124 | ROR | `params.kind != JObject` → `==` | 3 | 名指しした task の通知は配送する | タスク通知 (落ちた) |
| 61 | protocol/subscriptions.nim:125 | LOR | `not id.isNil and id.kind == JString` の `and` → `or` | 3 | taskId の無い task 通知は配送しない | タスク通知 (SIGSEGV) |
| 45 | protocol/subscriptions.nim:125 | ROR | `id.kind == JString` → `!=` | 3 | 名指しした task の通知は配送する | タスク通知 (落ちた。不正 params も落ちた) |
| 60 | protocol/subscriptions.nim:125 | LOR | `(not id.isNil and id.kind == JString) and id.getStr() in taskIds` の外側 `and` → `or` | 3 | 名指ししていない task の通知は配送しない | タスク通知 (落ちた。不正 params も落ちた) |

### client/subscriptions.nim

現在の行は測定時より 2 行後ろ。

| id | file:line | mutator | original → replacement | 区分 | 理由 | 検出するテスト |
|---|---|---|---|---|---|---|
| 2 | client/subscriptions.nim:47 | LOR | `requested.tools and not honored.tools` の `and` → `or` | 3 | 全部受理された filter では、受理されなかったものは空 | 全部受理 (落ちた) |
| 3 | client/subscriptions.nim:48 | LOR | prompts の同じ式 | 3 | 同上 | 全部受理 (落ちた。一部受理も落ちた) |
| 4 | client/subscriptions.nim:49 | LOR | resources の同じ式 | 3 | 同上 | 全部受理 (落ちた) |
| 12 | client/subscriptions.nim:55 | SDL | `result.taskIds.add id` → `discard` | 3 | 受理されなかった taskIds を知らせること | 一部受理 (落ちた) |
| 17 | client/subscriptions.nim:87 | SDL | `client.subscriptions.del(id)` → `discard` | 3 | 送れなかった listen は購読を残さない | 送れない listen (落ちた) |
| 1 | client/subscriptions.nim:104 | ROR | `timeoutMs > 0` → `>= 0` | 3 | `some(0)` は「待ちに限りを付けない」 (`McpRequestOptions.timeoutMs` の文書どおり)。変異では待ちがすぐ切れる | timeout 0 (落ちた) |

## 確認したこと

- `nim c -r tests/test_subscriptions.nim` は、既定版 2026-07-28 と `-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25` のどれでも 55 件が合格。コンパイラの警告は 0。
- `tests/test_spec_coverage.nim` は合格。新しい Scenario は `MCP-SUBSCRIBE-14` と `-2` (`specs/subscriptions.feature`、`specs/tests.map`)。

## 残っているもの

- 81 と 82 は同値で、テストを足していない。
- ほかに残っているものは無い。
