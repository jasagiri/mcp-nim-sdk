# G2 変異検査: subscriptions ジョブ (g2f-subs)

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/subscriptions.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 86 | 64 | 9 | 3 | 0 | 10 |

仕分けはコードとテストを読んで行った。変異を手で当てて流してはいない。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/client/subscriptions.nim:SDL:7b6c11cca30461fe:0` | client/subscriptions.nim:112 | `options.cancel.unwatchCancellation(cancelled)` → `discard` | spec_question | 変異後は、承認まで進んだ `listen` の待ち手が 1 本ずつトークンの `waiters` に残る。公開の入口から呼べる操作の結果は変わらない (後で `cancel` すると残った待ち手が完了するが、`firstOf` の呼び鈴は待つ人がいなければ何もしない。`src/transport/first_of.nim` の `watch`)。変わるのは、長く使うトークンが `listen` の回数だけメモリを持ち続けることだけで、それを読める `heldWaiters` は doc が「for tests」と言う非公開のもの。これを確かめるテスト (「token holds nothing of them」) は 2026-10-13 に内部側 (`tests/internal/test_subscriptions_internal.nim`) へ移り、`specs/tests.map` では MCP-SUBSCRIBE-11 に結ばれているが、その Scenario の文面 (断る・購読を持たない) は待ち手のことを言っていない | 問い: 「共有の取り消しトークンが、終わった `listen` の待ち手を持ち続けない」ことを仕様 (Scenario) にして公開の入口から測れる形 (公開の数え口) を作りますか、それとも外から見えない実装の性質として内部テストに任せ、この変異を同値として扱いますか。`client` ジョブの `sendRequest` 側 (`src/client/client.nim` の同じ呼び出し、MCP-CANCEL-4 に結ばれた内部テスト) も同じ問いになる |
| `src/protocol/subscriptions.nim:RVR:0c511227513989c7:0` | protocol/subscriptions.nim:83 | `return none(string)` → `return default` | equivalent | 戻り値の型は `Option[string]` で、`default(Option[string])` は `none(string)` と同じ値 (has = false)。変異の前後で `subscriptionIdOf` は同じ値を返す。前の仕分け (id 81) と同じ判断 | なし |
| `src/protocol/subscriptions.nim:RVR:0c511227513989c7:1` | protocol/subscriptions.nim:86 | `return none(string)` → `return default` | equivalent | 同上 (前の仕分けの id 82) | なし |

### 時間切れの見立て

9 件とも、テストが待ち続けることで検出している変異と読んだ。負荷による偽の時間切れを疑うものは無い (どれも、変異後は完了しない future か、既定の 60 秒 (`DefaultRequestTimeoutMs`) の待ちに入る経路が、コードから決まる)。時間切れの件数は前の 2 回の測定 (36a4c8a5 は 12、76a08c6a は 9) とも続いている。

| 指紋 | file:line | 変異 | 見立て | 止まる理由 |
|---|---|---|---|---|
| `src/client/subscriptions.nim:SDL:5974eb006904ee2c:0` | client/subscriptions.nim:66 | `client.requireFeature(ftSubscriptionsListen, ListenMethod)` → `discard` | テストが止まることで検出 | 「Given a version without subscriptions/listen, when the client listens ...」で、旧版の接続でも要求が送られ、答えないピアの承認を既定の 60 秒待つ (版ごとに繰り返す)。待ちが明けても `McpTimeoutError` で、期待の `McpUnsupportedError` ではないので落ちる |
| `src/client/subscriptions.nim:SDL:10ace171c90013f8:0` | client/subscriptions.nim:89 | 応答の `addCallback(...)` → `discard` | テストが止まることで検出 | 応答が来ても接続が切れても購読が終わらない。`waitFor sub.ended` (「the stream ended gracefully」「it ended lost」、端から端の 2 本) が完了しない。断られた `listen` も 60 秒待つ |
| `src/client/subscriptions.nim:SDL:8260da5362b1157c:0` | client/subscriptions.nim:94 | `client.endSubscription(id, sbLost)` → `discard` | テストが止まることで検出 | 「Given the transport fails while listening ...」の `waitFor sub.ended` が完了しない |
| `src/client/subscriptions.nim:SDL:29c009532715a1f4:0` | client/subscriptions.nim:99 | `client.endSubscription(id, sbFailed)` → `discard` | テストが止まることで検出 | 「Given a server that rejects the listen request ...」で `ended` が完了せず、`listen` が既定の 60 秒を待つ (版ごと)。明けても `McpTimeoutError` で、期待の `McpRequestError` ではない |
| `src/client/subscriptions.nim:SDL:cd57665d81f5171c:0` | client/subscriptions.nim:101 | `client.endSubscription(id, sbGraceful)` → `discard` | テストが止まることで検出 | 「Given the server answers the listen request ...」と HTTP の端から端のテストの `waitFor sub.ended` が完了しない |
| `src/protocol/subscriptions.nim:ROR:1caec0ad73df46ba:0` | protocol/subscriptions.nim:82 | `params.kind != JObject` → `==` | テストが止まることで検出 | オブジェクトの params から購読 id が読めなくなり、承認の通知がどの購読にも届かない (`src/client/client.nim` の `routeToSubscription`)。クライアント側のほぼすべての `listen` が承認を 60 秒待つ。その前に「Given notification params, when the subscription id is read ...」の `check` も落ちるが、実行は続いて待ちに入る |
| `src/protocol/subscriptions.nim:ROR:b531d79e05a86afc:0` | protocol/subscriptions.nim:85 | `meta.kind != JObject` → `==` | テストが止まることで検出 | 同上 (オブジェクトの `_meta` で none を返す) |
| `src/protocol/subscriptions.nim:ROR:07e150ac7451e45e:0` | protocol/subscriptions.nim:89 | `id.kind == JString` → `!=` | テストが止まることで検出 | 文字列の購読 id (クライアントの id は UUID の文字列) が none になり、同上 |
| `src/server/subscriptions.nim:SDL:845d73a07055de02:0` | server/subscriptions.nim:49 | `result.add subscription` → `discard` | テストが止まることで検出 | `all` が空になり、`endSubscriptions` (`src/server/server.nim`) が何も閉じない。端から端のテストの `waitFor server.endSubscriptions()` の後の `waitFor sub.ended` が完了しない |

時間切れに頼らずに落とすなら、待ちに上限のある形 (`listen` に `timeoutMs` を渡す、`sub.ended` を `untilTrue` で待つ) にテストを直すことになるが、検出はできているので、ここでは求めない。

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

## 測り直し (本線 76a08c6a、2026-10-10)

36a4c8a5 の測定のあとに足したテストと修正を入れたコミットで、同じジョブを測り直した。変異 84、検出 63、時間切れ 9、コンパイル不能 10、**生き残り 2** (前回 30)。

前回の生き残りとの突き合わせは変異の指紋で行った (指紋が変わった行は、ファイル・変異の文面・3 行以内の行番号で合わせた)。生き残りの 2 件はどちらも前回も生き残っていて、この文書に分類と理由がある。時間切れの 9 件はすべて前回も時間切れだった変異で、新しいものは無い。

この測定のあとに足したテスト (MCP-SUBSCRIBE-11、送信の途中で取り消された `listen`) は、`client` ジョブの生き残りに対するもので、このジョブの結果には入っていない。
