# G2 変異検出: ext_tasks ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/ext_tasks.json`、拡張ブランチの c9b5c264 (初回の測定。比べる記録は無い)。
対象は `src/ext/tasks.nim` と `src/ext/tasks/{client,server,wire}.nim`。`src/ext/**` は測定後に変わっていないので、行番号は今のものと同じ。 (2026-10-12 より前の話。下記。)

2026-10-12 に `src/ext/tasks/client.nim` と `src/ext/tasks/server.nim` を変えた (冗長な削除と届かない枝を消した)。次の測定で測り直す。以降の行番号はずれる。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 149 | 91 | 6 | 40 | 0 | 12 |

生き残り 40 件の分類。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 5 |
| 2 / 2b ジョブの外のテストで検出 | 0 |
| 3 穴 (テストを追加、全件で変異を手で当てて確認) | 31 |
| 4 死んだコード・冗長なコード (リードへ報告) | 4 |
| 5 欠陥 | 0 |
| 6 許容 | 0 |
| 計 | 40 |

`RVR` (戻り値の変異) は、`return none(T)` では `default(Option[T])` (= `none`)、`return (McpTask(), some("..."))` のような構築式では
`default(タプル)` (= 問題なし) になる。後者は手で `default(typeof(...))` を当てて確認した (nim-muter 0.2.5 の規則は `build/G2_EXT_BRIEF.md`)。

## 生き残り 1 件ずつ

分類 3 の「検出するテスト」は、変異を手で当てて失敗するのを見たもの。変異で落ちるのではなくプロセスごと異常終了 (nil 参照、SIGSEGV) する場合も
「検出」とした (テスト実行が正常終了しないため)。

### src/ext/tasks/client.nim

| id | 行 | 変異 | 元 → 変異 | 分類 | 理由 | 検出するテスト |
|---:|---:|---|---|---|---|---|
| 125 | 61 | SDL | `client.requireFeature(ftExtensions, operation)` → `discard` | 3 | 拡張を宣言したクライアントが 2026-07-28 より前の版で接続したとき、`tools/call` を送ってしまう。`callExtension` は同じ検査を持つが `startToolCall` は通らない。 | `test_ext_tasks_client`: Given a client that enabled the extension but negotiated an earlier version, when it calls a tool as a task, then it raises and sends nothing |
| 127 | 100 | SDL | `client.requireDeclared(GetTaskMethod)` → `discard` | 3 | `callExtension` が同じ型 (McpUnsupportedError) で拒むので例外の型は変わらないが、`enableTasksExtension` を案内する文面が落ちる。その案内を公開の振る舞いとして固定した。 | `test_ext_tasks_client`: Given a client that did not enable the extension, when it follows, answers, cancels or watches a task, then each raises McpUnsupportedError pointing to enableTasksExtension and sends nothing |
| 128 | 110 | SDL | `client.requireDeclared(UpdateTaskMethod)` → `discard` | 3 | 127 と同じ (`updateTask`)。 | 同上 |
| 129 | 118 | SDL | `client.requireDeclared(CancelTaskMethod)` → `discard` | 3 | 127 と同じ (`cancelTask`)。 | 同上 |
| 130 | 133 | SDL | `client.requireDeclared(ListenMethod)` → `discard` | 3 | 宣言していないクライアントが `subscriptions/listen` を送り、サーバーの -32021 を受ける (何も送らない、という約束が破れる)。 | 同上 |
| 131 | 139 | SDL | `task.delete("_meta")` → `discard` | 4 | `parseDetailedTask` は `taskId` `status` `createdAt` ほか名前を指定した鍵しか読まず、`result` `error` `inputRequests` は部分木として取り出す。通知の `params` の `_meta` はどこからも読まれないので、`copy()` と `delete` ごと冗長。手で当てて 26 件すべて通ることを確認した。 | (なし。リードの判断待ち) |
| 136 | 202 | SDL | `answered.incl key` → `discard` | 3 | サーバーが答え済みの鍵を続けて載せると、同じ要求に二度答える。SDK のサーバーは答えた鍵を載せなくなるので、既存のテストでは見えなかった。手書きの相手で鍵を載せ続けさせた。 | `test_ext_tasks_client`: Given a server that lists an answered input request again, when the client waits, then it neither answers it again nor sends an empty update |
| 121 | 203 | ROR | `responses.len > 0` → `>= 0` | 3 | 答える鍵が無いのに空の `inputResponses` で `tasks/update` を送る。136 と同じテストが `tasks/update` の件数 1 を見る。 | 同上 |
| 140 | 207 | SDL | `await sleepAsync(pause)` → `discard` | 3 | `sleep` を渡さない既定の経路が待たずに繰り返し問い合わせる。既存のテストは `sleep` を差し替えた経路だけを見ていた。待ち時間の下限 (90 ms) だけを見るので、遅い機械でも不安定にならない。 | `test_ext_tasks_client`: Given a task that suggests an interval, when the client waits without a sleep of its own, then it really waits between polls |

### src/ext/tasks/server.nim

| id | 行 | 変異 | 元 → 変異 | 分類 | 理由 | 検出するテスト |
|---:|---:|---|---|---|---|---|
| 14 | 106 | LOR | `params.isNil or params.kind != JObject` → `and` | 4 | 2026-07-28 の要求の版・クライアント情報・能力は `params._meta` にあるので、`params` が無い・オブジェクトでない `tasks/get` などは拡張のメソッドに届く前に -32601 で止まる (手で確認: `params` なし・配列のどちらも「Method not found」)。`params` が nil か非オブジェクトの枝は到達できない防御。 | (なし。リードの判断待ち) |
| 28 | 112 | SDL | `stderr.writeLine("[mcp-tasks] " & what)` → `discard` | 4 | `internalError` を呼ぶのは「`completed` なのに結果が無い」「`failed` なのにエラーが無い」の 2 か所だけ。ストアは `finish` で結果かエラーのどちらかを必ず持たせ、拡張の task は `toolErrorsFail = false` で作るので、この 2 つは起きない (起きるのは 62 の変異のように、結果もエラーも持たない応答がストアに入ったときだけ)。防御で、到達しない。 | (なし) |
| 29 | 113 | SDL | `newRequestError(ErrInternal, "Internal error")` → `discard` | 4 | 28 と同じ。 | (なし) |
| 23 | 147 | BLR | `var answeredAny = false` → `true` | 3 | 誰も尋ねていない鍵だけを載せた `tasks/update` で、`working` の task を `working` に「遷移」させ、`lastUpdatedAt` が動き、購読者に状態通知が出る。 | `test_ext_tasks`: Given a working task, when tasks/update names only keys nobody asked for, then the task is left as it was |
| 24 | 153 | BLR | `answeredAny = true` → `false` | 3 | 全部に答えても `input_required` のまま `working` に戻らない。 | `test_ext_tasks`: Given a task that waits on two requests at once, when one is answered, then it stays input_required until the other is answered too |
| 16 | 154 | LOR | `answeredAny and inputs.pending.len == 0` → `or` | 3 | 未回答が残っているのに `working` に戻す (24 のテスト) か、何も答えていないのに戻す (23 のテスト)。 | 上の 2 件 |
| 4 | 154 | ROR | `inputs.pending.len == 0` → `!=` | 3 | 未回答が残っているときに `working` に戻す。2 つの要求を同時に待つ task を作り、片方だけ答えて `input_required` と残りの鍵を確かめる。 | `test_ext_tasks`: Given a task that waits on two requests at once, ... |
| 32 | 192 | SDL | `inputs.used.incl issued` → `discard` | 3 | 答え済みの鍵を後から再び使えてしまう (「task の一生で鍵を二度使わない」が破れる)。 | `test_ext_tasks`: Given a key a task used and had answered, when the tool asks again with that key, then it raises ValueError |
| 35 | 199 | SDL | `inputs.pending.del(issued)` → `discard` | 1 | 取り消しで待ちが終わるのは、`store.cancel` が `cancelWork` を呼んだ後 (同じ呼び出しの中で) `tsCancelled` へ遷移し、`statusChanged` が `ext.inputs.del(taskId)` で `TaskInputs` ごと落とすとき、または `store.sweep` が期限切れで `cancelWork` を呼んだ後 `onExpire` が同じく落とすときだけ。どちらも `pending` を読む者 (`detailed`) に届かなくなってから、非同期の継続が `pending.del` を実行する。手で当てて 55 件すべて通ることを確認した。 | |
| 37 | 213 | SDL | `stderr.writeLine("[mcp-tasks] a task's request ended with resultType ...")` → `discard` | 3 | task の中の要求が `input_required` 等で終わったとき、診断が出なくなる。標準エラーを取り込んで見る。 | `test_ext_tasks`: Given a tool whose request in a task ends asking for input the multi round-trip way, when the task is polled, then it failed with an internal error and the log points to requestInput |
| 62 | 215 | RVR | `return newJsonRpcErrorResponse(...)` → `default(JsonRpcResponse)` | 3 | 結果もエラーも無い応答がストアに入り、task が `failed` (-32603 Internal error) でなく `completed` になる。 | 37 と同じテスト |
| 39 | 227 | SDL | `stderr.writeLine("[mcp-tasks] could not announce ...")` → `discard` | 3 | 購読の流れに書けなかった失敗が黙って消える。サーバー側のループバックの通知送信を壊して取り込んだ。 | `test_ext_tasks_client`: Given a stream the server cannot write to, when a watched task changes status, then the server logs that it could not announce it and the task goes on |
| 41 | 233 | SDL | `ext.inputs.del(task.taskId)` → `discard` | 3 | 終わった (取り消された) task の入力の記録が残る。見えるのは、取り消し後も動き続けた道具が `requestInput` を呼んだときの例外 (「この拡張の task ではない」の `ValueError` でなく `McpCancelled`)。期限切れ側の同じ記録は `MCP-SEC-SWEEP-2` のテストが押さえている。 | `test_ext_tasks`: Given a task cancelled while its tool runs on, when the tool asks for input afterwards, then the task is no longer one the extension serves |
| 56 | 346 | SDL | `previousExpire(owner, task)` → `discard` | 3 | 他の持ち主の task の期限切れで、前に付いていた `onExpire` (core の `enableTasks` が付けるもの) が呼ばれなくなり、core の記録が残る。core のフックそのものは外から見えないので、ストアに先に付けた任意のフックで見る。 | `test_ext_tasks_dual`: Given an expiry hook set on the store before the extension, when a task of another owner expires, then that hook is still called |
| 22 | 357 | LOR | `name.isNil or name.kind != JString` → `and` | 3 | `name` のない `tools/call` で nil 参照 (SIGSEGV) になり、サーバー自身の -32602 に届かない。 | `test_ext_tasks`: Given a tools/call whose name is missing or not a string, when a client declaring the extension sends it, then the server's own -32602 answers |
| 68 | 355 | RVR | `return none(JsonRpcResponse)` → `default(Option[JsonRpcResponse])` | 1 | 非リテラルの戻り値は `default(typeof(...))` になる。`Option` の既定値は `none` (`has = false`) なので同じ値。 | |
| 69 | 358 | RVR | 同上 | 1 | 同上。 | |
| 70 | 363 | RVR | 同上 | 1 | 同上。 | |
| 71 | 366 | RVR | 同上 | 1 | 同上。 | |

### src/ext/tasks/wire.nim

| id | 行 | 変異 | 元 → 変異 | 分類 | 理由 | 検出するテスト |
|---:|---:|---|---|---|---|---|
| 85 | 67 | LOR | `not error.data.isNil and error.data.kind != JNull` → `or` | 3 | `data` が無いか `null` のとき、nil 参照になるか `"data": null` を書く。 | `test_ext_tasks`: Given a failed task with error data, when written and parsed, then the data survives; without data the key is absent |
| 74 | 67 | ROR | `error.data.kind != JNull` → `==` | 3 | 実際の `data` が書かれなくなる。 | 同上 |
| 86 | 79 | LOR | `node.isNil or node.kind != JObject` → `and` | 3 | nil で nil 参照 (SIGSEGV)、配列で「object でない」でなく「taskId」の問題になる。 | `test_ext_tasks`: Given a Task with one field missing or of the wrong kind, when parsed, then the problem names that field |
| 104 | 80 | RVR | `return (McpTask(), some("a task must be an object"))` → `default(タプル)` | 3 | 問題なしとして通る。 | 同上 |
| 88 | 85 | LOR | `id.isNone or id.get.len == 0` → `and` | 3 | 鍵が無いと `none.get` で落ち、空文字列の `taskId` が通る。 | 同上 |
| 105 | 86 | RVR | `taskId must be a non-empty string` の戻り → `default(タプル)` | 3 | 空の `taskId` が通る。 | 同上 |
| 108 | 102 | RVR | `lastUpdatedAt must be an ISO 8601 timestamp` の戻り → `default(タプル)` | 3 | 壊れた時刻が通る。 | 同上 |
| 89 | 104 | LOR | `ttl.isNil or ttl.kind notin {JNull, JInt}` → `and` | 3 | `ttlMs` が無いと nil 参照 (SIGSEGV)。 | 同上 |
| 109 | 105 | RVR | `ttlMs must be an integer or null` の戻り → `default(タプル)` | 3 | 文字列の `ttlMs` が通る。 | 同上 |
| 110 | 114 | RVR | `pollIntervalMs must be an integer` の戻り → `default(タプル)` | 3 | 文字列の `pollIntervalMs` が通る。 | 同上 |
| 94 | 143 | LOR | `error.kind != JObject or error{"code"}.isNil` の `or` → `and` | 3 | `code` の無い `error` で nil 参照 (SIGSEGV)。 | `test_ext_tasks`: Given a failed task whose error lacks a code or a message of the right kind, when parsed, then it is a problem |
| 92 | 144 | LOR | `error{"code"}.kind != JInt or error{"message"}.isNil` の `or` → `and` | 3 | 文字列の `code` が通る。`message` が無いと nil 参照 (SIGSEGV)。 | 同上 |

## timeout 6 件

どれも「変異のせいで終わらない」もので、テストが無限に待つのではない。5 件 (id 144・120・139・141・142、すべて `client.nim`) は `awaitTask` の `while true` が終わらない。
`tasks/get` の戻りが既定値になる (144、`DetailedTask()` の状態は `working` なので永遠に待つ)、`input_required` の判定が反転する (120)、
`tasks/update` を送らない (139)、注入した `sleep` を呼ばないのでテストが `sleep` の中で進める解放が起きない (141)、
`onCreated` を呼ばないのでテストがその中で行う取り消しが起きない (142)。1 件 (id 34・`server.nim:176`、`requestInput` の鍵の番号を進めない) は同期的な
`while true` で、イベントループごと止まる。いずれも検出済みとして数える。テストの側に上限は無く、止めるのは実行基盤の制限時間だけ。

## 残っているもの

- **分類 4 (決定 2026-10-12)**: 4 件のうち 2 件を消し、2 件を残した。
  - 消した: `client.nim` の `task.delete("_meta")` (id 131)。`parseDetailedTask` と `parseTask` は名前を挙げたキーだけを読み、`_meta` を読まないので、消しても結果が同じ。`params.copy()` は残した (通知はこのあとクライアント自身のハンドラーにも渡るので、`onTask` に渡す節点を共有しない)。
  - 消した: `server.nim` の `taskIdParam` の「`params` が nil か非オブジェクト」の枝 (id 14)。`params{"taskId"}` は nil と非オブジェクトでも nil を返すので、枝が無くても同じ -32602 になる。さらに、`tasks/get` などは `_meta` の無い要求を先に -32602 (`params._meta is required`) で退けることを、nil・配列・文字列・`_meta` の無いオブジェクトで確かめた (版を `_meta` から取る `-d:mcpOldestProtocolVersion=2026-07-28` のビルド。通常のビルドでは版が付かず -32601)。
  - 残した: `server.nim` の `detailed` の 2 つの `internalError` (id 28・29、「結果の無い completed」「エラーの無い failed」)。届かないのではなく、公開の `TaskStore.finish` に `TaskOutcome()` (結果もエラーも無い) を `toolErrorsFail = false` で渡すと、結果の無い `completed` の task が作れる (コードを読んだ結論。実行では確かめていない)。消すと、結果の無い完了した task がそのままワイヤに出る。拡張自身の経路 (`task_methods.nim`) は必ずどちらかを持つ。
- 分類 1 の id 35 と 68〜71 は同値として記録した。
- 分類 5 (欠陥) と分類 6 (許容) は無い。確認できていない分類 3 も無い。
