# G2 変異検出: tasks ジョブ

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
