# G2 変異検出: tasks ジョブ

## 2 回目の測定 (拡張ブランチの 654cb11a、2026-11-14)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/tasks.json`。状態: 測定済み。全体 300、killed 238、timeout 12、survived 28、runError 0、compileError 22。

ここに書くのは、台帳にまだ無い指紋 18 件 (すべて `src/protocol/task_store.nim`)。store のコードが `src/protocol/tasks.nim` から `task_store.nim` に移り、`protocol/tasks` は公開する名前だけを export する形になった (`finish`・`setResultStream`・`onResultStream=` は公開から外れた)。仕分けは式と呼び出し元を読んで行った (変異を当てて流してはいない)。「引き継ぎ」は、下の節「測り直し (拡張ブランチの b04fcb9c、2026-11-11)」の同じ変異の判定を、今のコードで理由が成り立つことを確かめて引いたもの。

件数: equivalent 14、accepted 1、test_owed 1、spec_question 2。

| 指紋 | 場所 | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/protocol/task_store.nim:RVR:115a88da64ad7c9b:0` | task_store.nim:168 | `return none(int64)` → 既定値 | equivalent | 引き継ぎ。`Option[int64]` の既定値は none | — |
| `src/protocol/task_store.nim:ROR:b6ebb744f6bc2d02:0` | task_store.nim:172 | `dot >= 0` → `>` | equivalent | 引き継ぎ。違いが出るのは文字列が `.` で始まるときだけ。直前の `isDateTime` (`rfc3339.nim`) が先頭 10 文字に日付の形を求めるので、そこを通った文字列の先頭は数字 | — |
| `src/protocol/task_store.nim:ROR:b901314701bfd0a5:0` | task_store.nim:174 | `stop < base.len` → `<=` | equivalent | 引き継ぎ。違いが出るのは小数部の数字が文字列の末尾まで続くときだけ。`isDateTime` が小数部の後ろに `Z` か時差を求めるので、循環は数字でない文字で止まり `stop == base.len` にならない | — |
| `src/protocol/task_store.nim:RVR:115a88da64ad7c9b:1` | task_store.nim:178 | `return none(int64)` → 既定値 | equivalent | 引き継ぎ。`Option[int64]` の既定値は none | — |
| `src/protocol/task_store.nim:RVR:b667109c9117097f:0` | task_store.nim:193 | `return none(McpTask)` → 既定値 | equivalent | 引き継ぎ。`Option[McpTask]` の既定値は none | — |
| `src/protocol/task_store.nim:RVR:b667109c9117097f:1` | task_store.nim:199 | 同上 | equivalent | 引き継ぎ。同上 | — |
| `src/protocol/task_store.nim:RVR:b667109c9117097f:2` | task_store.nim:210 | 同上 | equivalent | 引き継ぎ。同上 | — |
| `src/protocol/task_store.nim:RVR:de4a76bc9ca7094b:0` | task_store.nim:252 | `return none(Option[int64])` → 既定値 | equivalent | 引き継ぎ。`Option[Option[int64]]` の既定値は none | — |
| `src/protocol/task_store.nim:ROR:394635f51fa4c60e:0` | task_store.nim:272 | `value >= 9.223372036854775807e18` → `>` | accepted | 引き継ぎ (下の節の「x86-64 での確かめ (2026-11-12)」、代表の決定 2026-11-12)。違いが出るのはちょうど 2^63 の ttl だけで、測定機 (arm64) では変換が飽和して同値、Linux x86_64 では既存の E テスト (test_tasks_store「Given a ttl of 2^63 milliseconds, ...」、ジョブに入っている) が落ちることを実測済み。機種による差 | — |
| `src/protocol/task_store.nim:ROR:68c9d096fcb44c25:0` | task_store.nim:314 | `ttl > 0` → `>=` | equivalent | 引き継ぎ。違いが出るのは `ttl == 0` だけで、そのとき右の項 `createdAtMs > int64.high - 0` は int64 のどの値でも偽 | — |
| `src/protocol/task_store.nim:ROR:69f45c6ba00f7bdd:0` | task_store.nim:314 | `createdAtMs > int64.high - ttl` → `>=` | equivalent | 引き継ぎ。等しいとき、飽和の値 `int64.high` と飽和しない和 `createdAtMs + ttl` は同じ値で、和は溢れない | — |
| `src/protocol/task_store.nim:ROR:35b5daa1003aca56:0` | task_store.nim:383 | `ttl.get > store.maxTtlMs.get` → `>=` | equivalent | 引き継ぎ。等しいとき、代入される `maxTtlMs` は今の `ttl` と同じ値 | — |
| `src/protocol/task_store.nim:ROR:dcfa67284c51d5fe:0` | task_store.nim:419 | `setResultStream` の `requestId.len > 0` → `>=` | equivalent | 判定し直し (前は `ROR:bad777869457471a:0` として spec_question)。前の問いの答えで `setResultStream` と `onResultStream=` が公開から外れ、呼ぶのは `task_methods.nim` の `tasks/result` (結ぶ・解く) だけ、hook を置くのは `server/tasks.nim` の `enableTasks` だけになった。変異で増えるのは、解くとき (`""`) の hook の呼び出し。解くのは `awaitOutcome` が返った後 (task は終端で、`onStatusChange` が `held` からその task を消し終えている) か、例外の後 (期限切れで項目が消えていて `setResultStream` は何もしない) なので、hook の `taskId in held` が偽で何も送られない。client 側の store には hook が無い。なお、使い手が `enableTasks` の後で公開の欄 `onStatusChange` を置き換えると `held` が消えず違いが出るが、その構成は元のコードでも保留の掃除 (MCP-TASKS-23) が働かない | — |
| `src/protocol/task_store.nim:SDL:2413a04126052c00:0` | task_store.nim:467 | `failureMessage` の末尾の `none(string)` → `discard` | equivalent | 引き継ぎ。`result` は `Option[string]` で、代入しなければ none | — |
| `src/protocol/task_store.nim:BLR:bad2a67f8198d0aa:0` | task_store.nim:473 | `finish` の引数の既定値 `toolErrorsFail = true` → `false` | equivalent | 新しい変異。`finish` は `protocol/tasks` が export しておらず、呼ぶのは `task_methods.nim` の `finishWhenDone` だけで、`toolErrorsFail` を必ず渡す。`tests/external/` に `task_store` を import するファイルは無い。既定値はどこからも使われない | — |
| `src/protocol/task_store.nim:RVR:f09e9e232af8b35b:2` | task_store.nim:482 | `finish` の、task がもう無いときの `return false` → `return true` | spec_question | 新しい変異 (`finish` を直接呼ぶテストが無くなって残った)。呼び手の `finishWhenDone` は `store.finish(...) and raised.len > 0` で stderr に書くので、期限切れで消えた task の仕事が後から例外で終わると、元は何も書かず、変異は「the request of task … raised …」を 1 行書く。期限切れは `cancelWork` で仕事を止めるので、止められた仕事が例外で終わるたびに出る。取り消しの後は何も書かないことを E テスト (MCP-TASKS-10「Given work that raises after its task was cancelled, ... nothing is logged ...」) が確かめているが、期限切れの後についてはどの Scenario も述べていない (MCP-TASKS-12 は「消える」「止めるよう伝える」まで) | 問い: 期限切れで止められた仕事が後から例外で終わったとき、stderr に何も書かないことを仕様 (MCP-TASKS-12 に 1 文) にするか。推奨: 仕様にする (取り消しの後と同じ扱い。`task_methods.nim` のコメントも「止めるよう言われて止まった仕事は報告する失敗ではない」と書いている)。その場合のテストの案: test_tasks_store の suite「running the request a task stands for」に、`FakeTime` の store で `runAsTask(store, "a", some(1_000'i64), ...)`、時刻を 2_000 に進めて `discard store.sweep()`、`loggedWhile` の中で `work.fail(newException(ValueError, "stopped"))` と `sleepAsync(20)`、`check log == ""`。変異だと「raised stopped」の行が出る |
| `src/protocol/task_store.nim:BLR:6ec2d660335697fb:2` | task_store.nim:482 | 同じ行の `false` → `true` | spec_question | 上の行と同じ変異 (RVR と BLR が同じ結果になる) | 上の行と同じ問い。同じテストで両方殺せる |
| `src/protocol/task_store.nim:SDL:131324adae4bf5f7:0` | task_store.nim:490 | `stderr.writeLine("[mcp-tasks] the request of task " & id & " ended with neither a result nor an error")` → `discard` | test_owed | 新しいコード (2026-11-12 に足した置き換え)。結果も誤りも無い outcome を内部エラーに置き換えるとき、相手には「Internal error」としか伝えないので、原因はこの 1 行にしか残らない。握った失敗の原因を stderr の 1 行に書くことは仕様 (代表の決定 2026-11-13、MCP-ERRORS-3)。既存の E テストは状態と符号だけを確かめ、stderr を見ていない | MCP-ERRORS-3 (置き換えそのものは MCP-TASKS-8)。既存の test_tasks_store「Given work that answers with neither a result nor an error, when it ends, then the task failed with an internal error, whatever toolErrorsFail is」の `work.complete(...)` と `settle()` を `loggedWhile` で包み、`check "the request of task " & task.taskId & " ended with neither a result nor an error" in log` を足す。変異だと log が空で落ちる。MCP-ERRORS-3 の Given の列挙に task のこの場合は名指されていないので、tests.map に結ぶときに Scenario へ 1 句足すかは司会の判断 |

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/tasks.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。状態: 測定済み。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 298 | 236 | 12 | 28 | 0 | 22 |

仕分けは式と呼び出し元を読んで行った (変異を当てて流してはいない)。件数: equivalent 21、spec_question 4、test_owed 1、accepted 1、undecided 1。

### x86-64 での確かめ (2026-11-12)

`src/protocol/tasks.nim:ROR:394635f51fa4c60e:0` (ttl の境界の `>=` → `>`) は、測定機 (arm64) では同値で、表では undecided とした。Linux x86_64・Nim 2.2.12 で b04fcb9c の `tests/external/test_tasks_store.nim` を流すと、変異なしは通り、変異ありは「Given a ttl of 2^63 milliseconds, ...」が落ちた。台帳では、機種による差として accepted にした (代表の決定 2026-11-12)。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/client/tasks.nim:RVR:0676a9310a0c6761:1` | client/tasks.nim:220 | store が断ったときの `return newJsonRpcErrorResponse(request.id, e.code, e.msg)` → 既定値 | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。ここに届く `McpTaskError` は `create` の上限超過だけで、符号は -32603。結果も誤りも無い応答は `transport.toJson` が -32603 "Internal error" にして送るので、断ることと符号は保たれ、変わるのは文面 ("Too many tasks" → "Internal error") と stderr の 1 行だけ。既存の E テスト (test_tasks_client「Given a store that holds one task at most, ...」) は符号を確かめていて、通る | — |
| `src/protocol/task_methods.nim:ROR:3bea8587e57fcb1d:0` | task_methods.nim:48 | `store.resultStream(id) == request.id` → `!=` | spec_question | `tasks/result` が答えた後も、task がその要求を stream として指したままになる。外から見えるのは (1) 公開の `store.resultStream` の値 (2) 終端になった後も動く道具の質問が、保留されずに、終わった要求の stream へ送られること。(1) を確かめるテストは内部側 (test_tasks_server_internal) にあり、(2) はどの Scenario も定めていない | 問い: 終端・期限切れの task の道具が出す質問を「送らずにその場で断る」と仕様 (MCP-TASKS-23 に 1 文) にするか。あわせて `resultStream`・`setResultStream`・`onResultStream` を公開から外すか。使い手は src で task_methods.nim (結ぶ・解く) と server/tasks.nim (hook と読み出し) だけ。E テストは `resultStream` を待ちの合図に 2 ファイル (test_tasks_http・test_tasks_http_g0e) で使う |
| `src/protocol/task_methods.nim:SDL:6567f7aacb4bbabc:0` | task_methods.nim:49 | `store.setResultStream(id, "")` → `discard` | spec_question | 上の行と同じ (解かれないまま残る) | 上の行と同じ問い |
| `src/protocol/tasks.nim:RVR:115a88da64ad7c9b:0` | protocol/tasks.nim:165 | `return none(int64)` → 既定値 | equivalent | `Option[int64]` の既定値は none | — |
| `src/protocol/tasks.nim:ROR:b6ebb744f6bc2d02:0` | protocol/tasks.nim:169 | `dot >= 0` → `>` | equivalent | 違いが出るのは `dot == 0` (文字列が `.` で始まる) だけ。直前の `isDateTime` が 10 文字目の `T` と日付の形を求めるので、そこを通った文字列の先頭は `.` にならない | — |
| `src/protocol/tasks.nim:ROR:b901314701bfd0a5:0` | protocol/tasks.nim:171 | `stop < base.len` → `<=` | equivalent | 違いが出るのは小数部の数字が文字列の末尾まで続くときだけ。`isDateTime` が小数部の後ろに `Z` か時差を求めるので、循環は必ず数字でない文字で止まり、`stop == base.len` にならない (前回これを殺した「Given a time whose fraction ends the text」は、今は `isDateTime` が先に断る) | — |
| `src/protocol/tasks.nim:RVR:115a88da64ad7c9b:1` | protocol/tasks.nim:175 | `return none(int64)` → 既定値 | equivalent | `Option[int64]` の既定値は none | — |
| `src/protocol/tasks.nim:RVR:b667109c9117097f:0` | protocol/tasks.nim:190 | `return none(McpTask)` → 既定値 | equivalent | `Option[McpTask]` の既定値は none | — |
| `src/protocol/tasks.nim:RVR:b667109c9117097f:1` | protocol/tasks.nim:196 | 同上 | equivalent | 同上 | — |
| `src/protocol/tasks.nim:RVR:b667109c9117097f:2` | protocol/tasks.nim:207 | 同上 | equivalent | 同上 | — |
| `src/protocol/tasks.nim:RVR:de4a76bc9ca7094b:0` | protocol/tasks.nim:252 | `return none(Option[int64])` → 既定値 | equivalent | `Option[Option[int64]]` の既定値は none | — |
| `src/protocol/tasks.nim:ROR:394635f51fa4c60e:0` | protocol/tasks.nim:272 | `value >= 9.223372036854775807e18` → `>` | undecided | 違いが出るのはちょうど 2^63 の ttl だけで、変異後は範囲の外の float を int64 に変換する (C の未定義動作)。測った機 (arm64) は飽和して `int64.high` になり元と同じ、x86-64 は `int64.low` になり、既存の E テスト (test_tasks_store「Given a ttl of 2^63 milliseconds, ...」、ジョブに入っている) が落ちるはず。機種で結果が分かれ、6 つの語のどれにも収まらない。前回は「許容」としたが、代表が受け入れた記録は無い | 問い: 測る機では同値になる変異を、機種によるものとして受け入れるか、x86-64 で 1 回測って殺されることを確かめるか |
| `src/protocol/tasks.nim:ROR:68c9d096fcb44c25:0` | protocol/tasks.nim:314 | `ttl > 0` → `>=` | equivalent | 違いが出るのは `ttl == 0` だけで、そのとき右の項 `createdAtMs > int64.high - 0` は int64 のどの値でも偽 | — |
| `src/protocol/tasks.nim:ROR:69f45c6ba00f7bdd:0` | protocol/tasks.nim:314 | `createdAtMs > int64.high - ttl` → `>=` | equivalent | 等しいとき、飽和の値 `int64.high` と、飽和しない和 `createdAtMs + ttl` は同じ値で、和は溢れない | — |
| `src/protocol/tasks.nim:ROR:35b5daa1003aca56:0` | protocol/tasks.nim:383 | `ttl.get > store.maxTtlMs.get` → `>=` | equivalent | 等しいとき、代入される `maxTtlMs` は今の `ttl` と同じ値 | — |
| `src/protocol/tasks.nim:ROR:bad777869457471a:0` | protocol/tasks.nim:413 | `requestId.len > 0` → `>=` | spec_question | stream を解くとき (`""`) にも `onResultStream` が呼ばれる。SDK のサーバーの hook は保留の質問を取り出して送るが、解く時点 (終端の後) では `onStatusChange` が保留を消し終えているので、サーバーの入口からは違いが出ない。違いが見えるのは、公開の `setResultStream` と `onResultStream` を使い手が直接使ったときだけで、それを確かめるテストは内部側 (test_tasks_store_internal「Given a hook for result streams, ...」) にある | task_methods.nim:48 の行と同じ問い (この 3 つを公開から外せば、この変異は同値になる。公開に残すなら、内部の 2 本を外部へ戻せば 3 件とも殺せる) |
| `src/protocol/tasks.nim:SDL:2413a04126052c00:0` | protocol/tasks.nim:455 | 末尾の `none(string)` → `discard` | equivalent | `result` は `Option[string]` で、代入しなければ none | — |
| `src/server/tasks.nim:RVR:3ac2bd94b4efe6f7:0` | server/tasks.nim:50 | `return none(JsonNode)` → 既定値 | equivalent | `Option[JsonNode]` の既定値は none | — |
| `src/server/tasks.nim:RVR:3ac2bd94b4efe6f7:1` | server/tasks.nim:57 | 同上 | equivalent | 同上 | — |
| `src/server/tasks.nim:SDL:fb532cd7a80e0870:0` | server/tasks.nim:118 | 終端で `sessionOf.del(task.taskId)` → `discard` | equivalent | `sessionOf` を読むのは `onStatusChange` だけで、終端の後はその task に状態の変化が起きない (`transition`・`finish`・`cancel` が終端を先に断る)。残った項目は読まれず、差はメモリだけ (表は `enableTasks` の局所変数で、外から数えられない) | — |
| `src/server/tasks.nim:SDL:178b5575b6d128b0:0` | server/tasks.nim:124 | 期限切れで `held.del(task.taskId)` → `discard` | spec_question | 残った保留は送られない (期限切れの task には `tasks/result` が届かず、hook が呼ばれない) が、上限の勘定には残る。期限切れの後も動き続ける道具が質問を出すと、元は空の列から数え直して保留し、変異後は前の保留を数えて早く断る (`maxQueuedMessages` が 1 なら次の 1 件目で `ctx.elicit` が例外)。期限切れの task の質問の扱いはどの Scenario も定めていない (前回は「読まれない」としたが、`holdForTask` が長さを読む) | task_methods.nim:48 の行と同じ問い (「その場で断る」と決めれば、この掃除は勘定に関わらなくなる) |
| `src/server/tasks.nim:SDL:fb532cd7a80e0870:1` | server/tasks.nim:125 | 期限切れで `sessionOf.del(task.taskId)` → `discard` | equivalent | 期限切れの task は store から消えていて状態の変化が起きないので、`sessionOf` の項目は読まれない。差はメモリだけ | — |
| `src/server/tasks.nim:RVR:9bd38dfae0fced9f:0` | server/tasks.nim:130 | `return none(JsonRpcResponse)` → 既定値 | equivalent | `Option[JsonRpcResponse]` の既定値は none | — |
| `src/server/tasks.nim:RVR:9bd38dfae0fced9f:1` | server/tasks.nim:135 | 同上 | equivalent | 同上 | — |
| `src/server/tasks.nim:RVR:4e102445986c6351:0` | server/tasks.nim:138 | 同上 | equivalent | 同上 | — |
| `src/server/tasks.nim:RVR:9bd38dfae0fced9f:2` | server/tasks.nim:146 | 同上 | equivalent | 同上 | — |
| `src/server/tasks.nim:RVR:9bd38dfae0fced9f:3` | server/tasks.nim:152 | 同上 | equivalent | 同上 | — |
| `src/server/tasks.nim:RVR:686aca932944807c:0` | server/tasks.nim:242 | `cancelClientTask` の `return taskOf(resultOf(await server.request(...)))` → 既定値 | test_owed | 変異後は `tasks/cancel` を送らず、空の `McpTask` (id が空、`working`) を返す。E テストは capability が無くて断る場合しか確かめていない | MCP-TASKS-18 (隣の `listClientTasks` のテストと同じ置き場。取り消しそのものは MCP-TASKS-10)。test_tasks_server の「as the requestor」の suite に: `samplingTasks` (cancel を宣言) の client に `fx.server.cancelClientTask(peer.session, "c-1")` を呼び、`fx.answerNext("", "tasks/cancel", 0, clientTask("c-1", "cancelled"))` で答え、送った要求の `params.taskId == "c-1"` と、返った task の `taskId == "c-1"`・`status == tsCancelled` を確かめる。変異だと要求が出ず (`answerNext` の待ちが尽きる)、返る task も空 |

### timeout 12 件 (検出に数える)

12 件とも、ただ遅いのではなく、終わらない待ち・循環になる変異。測り直しは要らない。

| 指紋 | file:line | 変異 | 終わらない理由 |
|---|---|---|---|
| `src/client/tasks.nim:RVR:71a44e014d93d55d:0` | client/tasks.nim:87 | `getTask` の return → 既定値 | 既定の `McpTask` は `working` で `pollInterval` も無く、`waitForTask` の poll が終わらない (無限の循環) |
| `src/protocol/task_methods.nim:SDL:21cca76d35529ab4:0` | task_methods.nim:122 | `await sleepAsync(pause)` → `discard` | `pollTask` の循環が dispatcher に制御を返さない (無限の循環) |
| `src/protocol/task_methods.nim:SDL:46e91f2a6973c554:0` | task_methods.nim:153 | `asyncCheck finishWhenDone(...)` → `discard` | 仕事が終わっても task が `working` のまま。結果を待つ側・状態を待つ側が終わらない (無限の待ち) |
| `src/protocol/tasks.nim:SDL:00b7375db0f52332:0` | protocol/tasks.nim:172 | `inc stop` → `discard` | 小数部の数字を数える循環が進まない (無限の循環) |
| `src/protocol/tasks.nim:LOR:e49625bc6768711d:0` | protocol/tasks.nim:314 | `and` → `or` | ttl のある task すべての期限が `int64.high` になり、期限切れを待つテストが終わらない (無限の待ち) |
| `src/protocol/tasks.nim:SDL:0fc71c49d8a85dfc:0` | protocol/tasks.nim:328 | `result.add id` → `discard` | 期限切れの id を集めないので何も消えず、`awaitOutcome` が 1 ミリ秒の待ちを繰り返す (無限の循環) |
| `src/protocol/tasks.nim:SDL:2daf5d8355cab0c8:0` | protocol/tasks.nim:331 | `store.entries.del(id)` → `discard` | 期限切れの task が消えない。同上 |
| `src/protocol/tasks.nim:SDL:f5ecd6662a858c88:0` | protocol/tasks.nim:475 | `change(entry, tsFailed, ...)` → `discard` | 失敗した task が `working` のまま。結果を待つ側が終わらない (無限の待ち) |
| `src/protocol/tasks.nim:SDL:ca4f2b74329f947c:0` | protocol/tasks.nim:477 | `change(entry, tsCompleted, ...)` → `discard` | 同上、`completed` |
| `src/protocol/tasks.nim:SDL:dc19cb5cda93c14c:0` | protocol/tasks.nim:491 | `change(entry, tsCancelled, ...)` → `discard` | 同上、`cancelled` |
| `src/protocol/tasks.nim:SDL:c74c22393c54b1c4:0` | protocol/tasks.nim:518 | `await waiter` → `discard` | ttl 無しの task の待ちが、譲らない循環になる (無限の循環) |
| `src/server/tasks.nim:RVR:f84cc25beb6a1bac:0` | server/tasks.nim:217 | `getClientTask` の return → 既定値 | 既定の `McpTask` は `working` で、`awaitClientTask` の poll が終わらない (無限の循環) |

測定: `nim-muter`、ジョブ `tests/mutation/tasks.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/protocol/tasks.nim`、`src/protocol/task_methods.nim`、`src/server/tasks.nim`、`src/client/tasks.nim`。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 296 | 195 | 9 | 67 | 0 | 25 |

生き残り 67 件の分類。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 19 |
| 2 ジョブに無い既存のテストが検出 (ジョブに追記) | 1 |
| 3 穴 (テストを追加) | 43 |
| 4 到達しない・冗長なコード | 0 |
| 5 欠陥 (上の件数とは別。生き残りを調べる中で見つかったもの) | 1 |
| 6 許容 | 4 |

分類 2 と 3 は、変異を 1 件ずつ手で当てて、追加したテスト (または既存のテスト) が落ちる、または止まることを確かめた。確かめた版は、`test_tasks_server` / `test_tasks_client` を既定の版・2025-11-25・2024-11-05 の 3 通りで流して、変異なしで通ることまで。
分類 1 は式から読んだ。

## 分類 1 の根拠

- **`return none(T)` を `return <default>` にする変異** (id 186 187 188 189 190 278 280 281 283 284 286 288): `Option[T]` の既定値は `none` なので、返す値が変わらない。`Option[Option[int64]]` も同じ。
- **`return false` を `return <default>` にする変異** (id 193 197): `bool` の既定値は `false`。
- id 179 (`failureMessage` 末尾の `none(string)` を `discard` にする): 関数の `result` は `Option[string]` で、代入しなければ `none`。
- id 59 (`dot >= 0` を `dot > 0` に): `dot == 0` は文字列が `.` で始まるとき。元のコードは小数部の数字を飛ばした残りで日時を読み、変異後は文字列全体を読む。どちらの残りも年の数字で始まらないので `parse` が失敗し、`none(int64)` になる。
- id 81 (`ttl > 0` を `ttl >= 0` に): `ttl == 0` なら右の項 `createdAtMs > int64.high - 0` は int64 のどの値でも偽。
- id 82 (`createdAtMs > int64.high - ttl` を `>=` に): 等しいとき、飽和は `int64.high`、飽和しない和も `createdAtMs + ttl == int64.high` で同じ値。`ttl > 0` が前の項で保証されているので `int64.high - ttl` は溢れない。
- id 94 (`ttl.get > store.maxTtlMs.get` を `>=` に): 等しいとき、代入される `maxTtlMs` は今の `ttl` と同じ値。

## 一覧

「検出するテスト」の列は、特に書かない限り `tests/test_tasks_store.nim` (store) / `test_tasks_server.nim` (server) / `test_tasks_client.nim` (client) の、表の名前のテスト。

| id | file:line | 変異 | 元 → 後 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 14 | client/tasks.nim:55 | SDL | `requireServerCapability(declared.isSome, ...)` → `discard` | 3 | tasks を宣言しない server に `getTask` すると、`McpUnsupportedError` の代わりに `declared.get` の `UnpackDefect`。client: Given a server that declared no tasks, when a task is asked for, then nothing is sent |
| 22 | client/tasks.nim:159 | SDL | 「task の無い通知を無視した」診断 → `discard` | 3 | client: Given a status notification that is no task, ... (stderr を捕まえて確かめる) |
| 24 | client/tasks.nim:179 | SDL | `params.delete("task")` → `discard` | 3 | 生の handler が `task` を含む要求を受ける。client: Given a handler that is called with a task, ... |
| 26 | client/tasks.nim:185 | SDL | 状態通知の失敗の診断 → `discard` | 3 | `brokenNotifications` の transport。client: Given a transport that cannot send notifications, ... |
| 27 | client/tasks.nim:193 | SDL | `requireNotConnected` (augmentWithTasks) → `discard` | 3 | 接続後の `augmentWithTasks` が通ってしまう。client: Given a connected client, when tasks are enabled or a request is augmented, ... |
| 28 | client/tasks.nim:230 | SDL | `requireNotConnected("enabling tasks")` → `discard` | 3 | 同上 (`sampling: false` で、別の理由の `McpError` に紛れない) |
| 42 | client/tasks.nim:210 | RVR | 不正な task の誤り応答 → 既定値 | 3 | client: Given a sampling request whose task is not an object, ... |
| 44 | client/tasks.nim:220 | RVR | store が拒んだときの誤り応答 → 既定値 | 3 | client: Given a store that holds one task at most, ... |
| 202 | task_methods.nim:48 | ROR | `resultStream(id) == request.id` → `!=` | 3 | server: Given a tasks/result that waits on a task, when the task ends, then the task no longer names that request as its stream |
| 215 | task_methods.nim:49 | SDL | `setResultStream(id, "")` → `discard` | 3 | 同上 |
| 230 | task_methods.nim:59 | RVR | cursor が文字列でない誤り → 既定値 | 3 | store: Given tasks/list with a cursor that is not a string, ... |
| 234 | task_methods.nim:74 | RVR | 未知の method の誤り → 既定値 | 3 | store: Given a method that is no task method, ... (`handleTaskMethod` は公開) |
| 209 | task_methods.nim:139 | LOR | `finish(...) and raised.len > 0` → `or` | 3 | 成功した仕事・取り消し後に失敗した仕事で、何も書かないこと。store: Given work that succeeds, ... / Given work that raises after its task was cancelled, ... |
| 206 | task_methods.nim:139 | ROR | `raised.len > 0` → `>= 0` | 3 | store: Given work that succeeds, when it ends, then nothing is logged |
| 223 | task_methods.nim:140 | SDL | 仕事が例外で終わった診断 → `discard` | 3 | store: Given work that raises, when it ends, then the task failed with a bare internal error and the cause is logged |
| 135 | protocol/tasks.nim:139 | BLR | `canTransition` の終端 `false` → `true` | 3 | store の `transition` は終端を先に断るので届かない。公開関数なので直接。store: Given a terminal status, when asked about a move from it, ... |
| 48 | protocol/tasks.nim:145 | AOR | `epochTime() * 1000` → `/ 1000` | 3 | store: Given the system clock, when read, then it counts milliseconds since the epoch |
| 59 | protocol/tasks.nim:163 | ROR | `dot >= 0` → `>` | 1 | 上の根拠 |
| 60 | protocol/tasks.nim:165 | ROR | `stop < base.len` → `<=` | 3 | 小数部で終わる文字列で `base[stop]` が範囲外 (`IndexDefect`)。store: Given a time whose fraction ends the text, ... |
| 186 | protocol/tasks.nim:169 | RVR | `return none(int64)` → 既定値 | 1 | 上の根拠 |
| 187 | protocol/tasks.nim:184 | RVR | `return none(McpTask)` → 既定値 | 1 | 同上 |
| 188 | protocol/tasks.nim:190 | RVR | 同上 | 1 | 同上 |
| 189 | protocol/tasks.nim:201 | RVR | 同上 | 1 | 同上 |
| 68 | protocol/tasks.nim:206 | ROR | `textAt("statusMessage").len > 0` → `>= 0` | 3 | 無いときに `some("")` になる。store: Given a task without statusMessage, when read, then it has none |
| 70 | protocol/tasks.nim:229 | ROR | `immediateResponse.len > 0` → `>= 0` | 3 | 空の `_meta` が付く。store: Given no immediate response, when a CreateTaskResult is made, then it has no _meta |
| 190 | protocol/tasks.nim:246 | RVR | `return none(Option[int64])` → 既定値 | 1 | 上の根拠 |
| 75 | protocol/tasks.nim:256 | ROR | `getBiggestInt() < 0` → `<= 0` | 3 | ttl 0 が拒まれる。store: Given a ttl of 0, when the params are parsed, ... |
| 117 | protocol/tasks.nim:264 | LOR | `value != value or value < 0` → `and` | 3 | 負の整数値 (`-2.0`) が通る。store: Given a ttl that is not a non-negative whole number, ... |
| 116 | protocol/tasks.nim:264 | LOR | `... or value == Inf` の前の `or` → `and` | 3 | 同上 (`-2.0`。`Inf` も同じテストに入れた) |
| 80 | protocol/tasks.nim:266 | ROR | `value >= 9.223372036854775807e18` → `>` | 6 | ちょうど 2^63 の変換が `int64.high` になるかは機種による。arm64 の `fcvtzs` は飽和して `int64.high` を返し、元のコードと同じ。x86-64 は `int64.low` になる。追加したテスト (store: Given a ttl of 2^63 milliseconds, ...) は `int64.high` を求め、x86-64 でなら落ちる。この機では区別できない |
| 81 | protocol/tasks.nim:308 | ROR | `ttl > 0` → `>= 0` | 1 | 上の根拠 |
| 82 | protocol/tasks.nim:308 | ROR | `createdAtMs > int64.high - ttl` → `>=` | 1 | 同上 |
| 168 | protocol/tasks.nim:332 | SDL | 期限切れの仕事を止められなかった診断 → `discard` | 3 | store: Given work that cannot be stopped, when its task expires, then the others are swept too and the failure is logged |
| 170 | protocol/tasks.nim:338 | SDL | `onExpire` が投げた診断 → `discard` | 3 | store: Given an expiry hook that raises, when a task expires, then the sweep goes on and the failure is logged |
| 166 | protocol/tasks.nim:339 | SDL | `entry.wake()` → `discard` | 3 | `tasks/result` の待ちが、別の操作の sweep で期限切れになっても自分の時計が鳴るまで起きない。store: Given a result awaited on a task that expires, when another operation sweeps it, then the wait fails at once (ttl 600 秒で、待ち手の時計が鳴るより前に調べる) |
| 87 | protocol/tasks.nim:367 | ROR | `requestedTtlMs.get < 0` → `<= 0` | 3 | store: Given a ttl of 0, when a task is created, then it has ttl 0 |
| 94 | protocol/tasks.nim:377 | ROR | `ttl.get > maxTtlMs.get` → `>=` | 1 | 上の根拠 |
| 96 | protocol/tasks.nim:407 | ROR | `requestId.len > 0` → `>= 0` | 3 | 結びを解くときにも hook が呼ばれ、保留の質問が stream 無しで送られる。store: Given a hook for result streams, when a stream is set and then cleared, then the hook hears only of the set |
| 193 | protocol/tasks.nim:431 | RVR | `return false` → 既定値 | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された。 |
| 136 | protocol/tasks.nim:431 | BLR | `return false` → `true` | 3 | 無い id の `transition` が真を返す。store: Given an id the store does not hold, ... |
| 97 | protocol/tasks.nim:435 | ROR | `status != entry.task.status` → `==` | 3 | 同じ状態の再設定が `McpTaskError` になる。store: Given a working task, when working is set again with a message, then only the message changes |
| 132 | protocol/tasks.nim:445 | LOR | `not content.isNil and kind == JArray` → `or` | 3 | `content` が無い・配列でない `isError` の結果で nil の参照・`FieldDefect`。store: Given a tool result with isError and no text, ... |
| 179 | protocol/tasks.nim:449 | SDL | `none(string)` → `discard` | 1 | 上の根拠 |
| 197 | protocol/tasks.nim:463 | RVR | `return false` → 既定値 | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された。 |
| 141 | protocol/tasks.nim:463 | BLR | `return false` → `true` | 3 | 無い id の `finish` が真を返す。store: Given an id the store does not hold, ... |
| 58 | protocol/tasks.nim:508 | AOR | `expiry.get - store.clock()` → `+` | 3 | 待ち手の時計が 2^31 ミリ秒に伸び、他の操作が無ければ期限切れに気づかない。store: Given a result awaited on a task with a short ttl, when the ttl elapses, then the wait fails by itself |
| 185 | protocol/tasks.nim:512 | SDL | `await waiter` → `discard` | 3 | ttl 無しの task の待ちが、譲らないループになる (呼び出しが戻らない。ジョブでは timeout になる)。store: Given a task with unlimited ttl, when its result is awaited, then the wait ends when the task does。それまでは ttl 無しの待ちを試すテストが無かった |
| 239 | server/tasks.nim:46 | ROR | `cursor.len > 0` → `>= 0` | 3 | 最初の頁を `{"cursor": ""}` で頼む。server: Given a tool listed on the second page, when called with a task, then the first page was asked for without a cursor and the task is made |
| 278 | server/tasks.nim:50 | RVR | `return none(JsonNode)` → 既定値 | 1 | 上の根拠 |
| 241 | server/tasks.nim:56 | ROR | `cursor.len == 0` → `!=` | 3 | 2 頁目の道具が見つからない。同じ server のテスト |
| 280 | server/tasks.nim:57 | RVR | `return none(JsonNode)` → 既定値 | 1 | 上の根拠 |
| 261 | server/tasks.nim:77 | SDL | 状態通知の失敗の診断 → `discard` | 3 | `failFor` の transport。server: Given a session that cannot be reached, when its task changes status, then the failure is logged and the task goes on |
| 242 | server/tasks.nim:99 | ROR | `queue.len >= maxQueuedMessages` → `>` | 2 | `tests/test_tasks_http.nim` の「Given a task whose held questions are limited, ...」(上限 0 で、質問が断られず task が失敗しない) が落ちる。ジョブに追加した (id 242 を手で当てて、既定の版と 2025-11-25 の両方で確認) |
| 267 | server/tasks.nim:117 | SDL | 終端で `held.del(taskId)` → `discard` | 3 | 取り消された task の保留の質問が、後の `tasks/result` で送られる。server: Given a question waiting for tasks/result, when the task is cancelled, then a later tasks/result does not send it |
| 268 | server/tasks.nim:118 | SDL | 終端で `sessionOf.del(taskId)` → `discard` | 6 | 下の「残っているもの」 |
| 269 | server/tasks.nim:124 | SDL | 期限切れで `held.del(taskId)` → `discard` | 6 | 同上 |
| 270 | server/tasks.nim:125 | SDL | 期限切れで `sessionOf.del(taskId)` → `discard` | 6 | 同上 |
| 281 | server/tasks.nim:130 | RVR | `return none(JsonRpcResponse)` → 既定値 | 1 | 上の根拠 |
| 283 | server/tasks.nim:135 | RVR | 同上 | 1 | 同上 |
| 249 | server/tasks.nim:137 | LOR | `name.isNil or name.kind != JString` → `and` | 3 | `name` の無い `tools/call` で nil の参照。server: Given a call that carries a task but no name, when it arrives, then it is Invalid params, as for a plain call |
| 284 | server/tasks.nim:138 | RVR | 同上 | 1 | 同上 |
| 286 | server/tasks.nim:146 | RVR | 同上 | 1 | 同上 |
| 288 | server/tasks.nim:152 | RVR | 同上 | 1 | 同上 |
| 251 | server/tasks.nim:183 | LOR | `clientCapabilities.isNone or tasks.isNone` → `and` | 3 | tasks を宣言しない client に `McpCapabilityError` の代わりに `UnpackDefect`。server: Given a client that declared no tasks, when the server asks as a task, then nothing is sent |
| 257 | server/tasks.nim:205 | BLR | `else: false` → `true` | 3 | sampling と elicitation 以外を task として送ってしまう。server: Given a client that declared tasks for sampling only, ... |
| 275 | server/tasks.nim:231 | SDL | `result.tasks.add` → `discard` | 3 | server: Given a client with tasks.list, when the server lists its tasks, then it gets the tasks and the cursor of the page |
| 247 | server/tasks.nim:232 | ROR | `answer{"nextCursor"}.kind == JString` → `!=` | 3 + 5 | 同じテスト。このテストを書いて、最後の頁 (`nextCursor` の無い応答) で nil を参照して落ちることが見つかった (分類 5): 元の式は `answer{"nextCursor"}` が nil のときの `.kind`。直した (コミット `fix(server): listClientTasks reads the last page, which has no nextCursor`) |

## timeout 9 件 (検出に数える)

| id | file:line | 変異 | 待ち続ける理由 |
|---:|---|---|---|
| 34 | client/tasks.nim:87 | RVR | `getTask` が既定の `McpTask` を返す。既定の status は `working` (列挙の先頭) で `pollInterval` も無いので、`waitForTask` の poll が終わらない |
| 221 | task_methods.nim:122 | SDL | `await sleepAsync(pause)` が無いと、`pollTask` の循環が dispatcher に制御を返さない (`fetch()` は完了済みの future) |
| 146 | protocol/tasks.nim:166 | SDL | `inc stop` が無いと、小数部の数字を数える循環が進まない |
| 119 | protocol/tasks.nim:308 | LOR | `ttl > 0 or ...` は ttl のある task すべての期限を `int64.high` にする。期限切れを待つテストが期限切れにならない |
| 164 | protocol/tasks.nim:322 | SDL | 期限切れの id を集めないので、何も消えない。`awaitOutcome` の循環が (1 ミリ秒の待ちを繰り返して) 終わらない |
| 165 | protocol/tasks.nim:325 | SDL | `entries.del(id)` が無いので、期限切れの task が消えない。同上 |
| 180 | protocol/tasks.nim:469 | SDL | `change(entry, tsFailed, ...)` が無いので、失敗した task が `working` のまま。結果を待つ側が終わらない |
| 181 | protocol/tasks.nim:471 | SDL | 同上、`completed` |
| 182 | protocol/tasks.nim:485 | SDL | 同上、`cancelled` |

## 残っているもの

- **id 80** (分類 6): 上の表のとおり。機種による。この機 (arm64) の測定では区別できない。追加したテストは x86-64 で変異を検出する (実行は確かめていない)。
- **id 268 269 270** (分類 6): `server/tasks.nim` の `enableTasks` が持つ 2 つの表 `held` と `sessionOf` の掃除。
  `sessionOf` は task の id で引かれるだけで、終端と期限切れの後はその task に状態の変化が起きない (`transition`・`finish`・`cancel` は終端を先に断る) ので、掃除を消しても読まれない。
  `held` の期限切れの掃除 (id 269) も同じで、期限切れの task には `tasks/result` が届かず (`store.get` が先に断る)、`onResultStream` が呼ばれないので読まれない。
  差は、サーバーを動かし続けたときのメモリだけ。表は `enableTasks` の局所変数で、外から数える手段が無い。
  終端で `held` を消す id 267 は、取り消された task の質問が後で送られてしまうので、テストで捉えた。
- 分類 5 の欠陥 1 件 (id 247 の近く) は直した。他に分類 4 (到達しないコード) はない。
- `docs/quality/g2-protocol-versions.md` の表で、この 4 モジュールの行 (52〜55 行) を「未測定」から外した。`src/server/tasks.nim` の他の行 (68・86・88 行) は別の理由 (HTTP の経路・security テスト) で並ぶ行なので触れていない。
