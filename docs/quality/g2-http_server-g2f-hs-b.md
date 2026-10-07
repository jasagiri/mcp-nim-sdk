# G2 変異検出: http_server ジョブ (g2f-hs-b の分)

測定: `nim-muter`、ジョブ `tests/mutation/http_server.json` (`src/transport/http_server.nim`、`src/transport/sse_stream.nim`)、本線の 36a4c8a5 (2026-10-07)。
ジョブ全体の数: 全変異 391、killed 218、timeout 64、survived 94、runError 0、compileError 15。
このファイルは、そのうち `http_server.nim` の 679〜1036 行 (36a4c8a5 の行番号) にある生き残り 27 件の分。
ほかの行 (229〜668 行、1050〜1175 行、`sse_stream.nim`) は別の担当で、リードが 3 つの記録を 1 つにまとめる。
測定後に `http_server.nim` は変わった (待ちを `or` から `firstOf` へ: import が 1 行増えた) ので、現在の行は測定時の行 + 1。
文面で探して当てた。測定後に消えた文は無い。

`nim-muter` の `original` 欄は式全体ではなく、変異した部分式を指す。
`not modern and isRpcRequest and methodName == "initialize"` の `and` は左結合なので、変異は
`(not modern or isRpcRequest) and methodName == "initialize"` であって `not modern or (isRpcRequest and ...)` ではない
(後者を当てると既存のテストが多数落ちる。最初に後者で当ててしまい、前者でやり直した)。

生き残り 27 件の内訳: 同値 (1) 4 件、検出済み (2) 0 件、穴 (3) 19 件、死んだ・余分なコード (4) 3 件、欠陥 (5) 0 件、許容 (6) 1 件。
分類 3 の 19 件は、変異を 1 件ずつ手で当て、名前を挙げたテストが落ちることを見てから `jj restore` で戻した。確かめていないものは無い。

追加したテストは、既存のテストファイルの末尾に、`(mutation review, g2f-hs-b)` の名の新しい suite として足した。
ジョブの `testCommand` は、どのファイルも既に含んでいる (ジョブの変更は無い)。
`tests/test_version_floor.nim` の 3 件は `-d:mcpOldestProtocolVersion=2026-07-28` でだけ中身が走る (既存の隣のテストと同じ守り方。ジョブはその版でも流す)。
ほかの版の確認: `-d:mcpDefaultProtocolVersion=2024-11-05` と `=2025-11-25` でも、追加した suite は通る (その版では走らないテストは守りで外れる)。

| id | 場所 (測定時) | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 384 | http_server.nim:679 | RVR | `return none(JsonRpcError)` → `return default` | 1 同値 | `Option[JsonRpcError]` の既定値が `none`。 |
| 385 | http_server.nim:682 | RVR | 同上 | 1 同値 | 同上。 |
| 269 | http_server.nim:687 | SDL | 末尾の `none(JsonRpcError)` → `discard` | 1 同値 | `result` を書かなければ既定値の `none` が返る。 |
| 280 | http_server.nim:751 | SDL | `respondEmpty(Http405, {"Allow": "POST, DELETE"})` → `discard` | 3 穴 | 2024-11-05 で成立したセッションの GET は 405 で、`Allow` は `POST, DELETE`。`Given a session negotiated at 2024-11-05, when it opens GET, then the answer is 405 naming POST and DELETE` (`test_http_streams.nim`)。変異後は答えが返らず落ちる。 |
| 282 | http_server.nim:759 | SDL | GET の版ヘッダ誤りの `respondError(Http400, ...)` → `discard` | 3 穴 | `Given a GET that names a version the server does not speak, when it arrives, then the answer is 400` (`test_http_streams.nim`)。 |
| 103 | http_server.nim:771 | ROR | `session.listen.id == streamId` → `!=` | 3 穴 | GET ストリーム (listen) は、自分の event id で再開でき、持っていないストリームの id では再開されない。`Given the GET stream of a session, when the client left after an event and asks for the rest by that event's id, then it gets the later events` と `Given a GET stream that has sent events, when an event id of a stream the session never had is presented, then the answer is 400` (どちらも落ちる)。 |
| 284 | http_server.nim:790 | SDL | GET の `finally` の `dec session.busy` → `discard` | 3 穴 | GET ストリームが終わったセッションは、使われないまま上限を過ぎれば期限切れになる (`busy` が戻る)。`Given a session whose GET stream has ended, when it then stays unused, then it stays only for the limit counted from the end of the stream, and then expires` (`test_http_streams.nim`)。 |
| 285 | http_server.nim:791 | SDL | GET の `finally` の `session.touch()` → `discard` | 3 穴 | 同じテスト。期限は、ストリームが終わった時点から数える (ストリームが開いていた間は数えない)。 |
| 293 | http_server.nim:827 | SDL | 本文が単独の値のときの `respondError(Http400, ...)` → `discard` | 3 穴 | `Given a JSON body that is a single value and no object, when posted, then the answer is 400 invalid request` (`test_streamable_http.nim`)。これまでのテストが送っていた `[1, 2]` は後ろの検査で 400 になるため、この文には届いていなかった。 |
| 171 | http_server.nim:844 | LOR | `not isBatch and isRequest(rpc)` → `or` | 3 穴 | 2026-07-28 だけを話すサーバーは、最初の要素が完全な 2026-07-28 の要求であるバッチも 400 で断る (変異後は最初の要求として 200 で答える)。通知は版を名指ししても 202 (変異後は要求として検査して 400)。`Given a batch whose first message is a 2026-07-28 request, ...`、`Given a notification that names 2026-07-28, ...` (`test_version_floor.nim`)。 |
| 177 | http_server.nim:850 | LOR | `not modern and isRpcRequest` → `or` (`initialize` との `and` の左) | 3 穴 | セッションを開くのは `initialize` の要求だけ。`id` の無い `initialize` という名の通知は、セッションが無ければ 400 で、セッションは作られない (変異後は 202)。`Given a notification whose method is initialize and no session, when posted, then the answer is 400 and no session is made` (`test_streamable_http.nim`)。 |
| 182 | http_server.nim:858 | LOR | `modern and sessionless` → `or` | 3 穴 | 2026-07-28 だけを話すサーバーでは、`initialize` という名の通知は旧クライアントの拒否 (400) ではなく 202。`Given a notification whose method is initialize, when it is posted, then the answer is 202 and not the legacy-client refusal` (`test_version_floor.nim`、`-d:mcpOldestProtocolVersion=2026-07-28`)。 |
| 303 | http_server.nim:891 | SDL | セッションの無い版でバッチを断る `respondError(Http400, ...)` → `discard` | 3 穴 | `Given a batch whose first message is a 2026-07-28 request, when it is posted, then the answer is 400 invalid request` (`test_version_floor.nim`)。 |
| 304 | http_server.nim:907 | SDL | `inc session.busy` → `discard` | 3 穴 | 要求を処理したセッションは、そのあと使われなければ上限を過ぎて期限切れになる (`busy` が 0 に戻る。変異後は -1 のままで期限切れにならない)。`Given a session that has served a request, when it then stays unused beyond the limit, then it expires` (`test_http_streams.nim`)。 |
| 307 | http_server.nim:910 | SDL | `defer` の `dec session.busy` → `discard` | 3 穴 | 同じテスト (変異後は 1 のまま)。 |
| 314 | http_server.nim:930 | SDL | バッチの中の通知の `t.enqueueFromClient(...)` → `discard` | 3 穴 | 要求と通知が混ざったバッチでは、通知がサーバーに届く。`Given a batch of a request and a notification, when posted, then the server receives the notification` (`test_http_streams.nim`)。これまでは答えの本数しか見ていなかった。 |
| 317 | http_server.nim:948 | SDL | 中断された要求の `req.client.close()` → `discard` | 4 余分 | `gone` が先に終わるのは、相手が接続を閉じた (または読みが失敗した) ときだけ (`armWatch`)。その接続は、`asynchttpserver` の `processClient` が次の要求を読もうとして EOF かエラーを受け、自分で閉じる。したがってこの `close()` は、相手が既に閉じた接続を閉じ直すだけで、観測できる違いが無い (あるとすれば記述子が閉じるまでの一瞬)。コードを読んで決めた。記述子数を数える実験はしていない。削除するかはリードが決める。 |
| 320 | http_server.nim:953 | SDL | JSON で答えた後の `req.client.close()` → `discard` | 3 穴 | JSON の本文で答えた POST は、答えが済んだら接続を閉じる (接続を見張る読みが次の要求を食べないように)。生のソケットで要求を送り、答えを読み切ったあとに EOF が来ることを確かめる。`Given a POST answered with a JSON body, when the answer is complete, then the server closes the connection` (`test_streamable_http.nim`)。変異後は答えは届くが EOF が来ず、`closed` の検査だけが落ちる。 |
| 115 | http_server.nim:959 | ROR | `group.pending > 0` → `>=` | 1 同値 | `pending == 0` で通知を送ったグループ (`notified`) では、答えるたびに `sendResponse` が `t.exchanges.del` しているので、`cancel` が見つける交換が無く `onRequestCancelled` は呼ばれない。変わるのは `group.abandoned` だけで、それを読むのは、そのグループにもう来ない答えと通知の分岐だけ。 |
| 323 | http_server.nim:975 | SDL | `handleLegacySse` の `session.touch()` → `discard` | 4 余分 | HTTP+SSE のセッション (`legacy`) の `lastActive` を読むのは `expireIdleSessions` だけで、そこは `not session.legacy` で外している。接続が続く限りの寿命で、期限切れの対象ではない。 |
| 331 | http_server.nim:1007 | SDL | HTTP+SSE の POST の `refuseOverload()` → `discard` | 3 穴 | 処理中の要求が上限に達しているとき、HTTP+SSE の POST は 503 と `Retry-After` で断られる。`Given requests in progress up to the limit, when a client of HTTP+SSE posts another, then the answer is 503 with Retry-After` (`test_security_http.nim`)。Streamable HTTP の分はあったが、こちらの口にはテストが無かった。 |
| 217 | http_server.nim:1009 | BLR | HTTP+SSE の POST の `used = true` → `false` | 4 余分 | `used` を読むのは `evictUnused` だけで、そこは `not session.legacy` で外している。HTTP+SSE のセッションの `used` は誰も読まない。 |
| 332 | http_server.nim:1011 | SDL | HTTP+SSE の POST の `inc t.exchangeCount` → `discard` | 3 穴 | 同時に処理中の 2 つの要求が同じ交換 id `http-0` になり、2 つめの答えが失われる。`Given two requests in progress at once, when the server answers them one after the other, then each answer carries the id its own request chose` (`test_http_sse_legacy.nim`)。変異後は `no HTTP exchange is waiting for response id http-0`。 |
| 336 | http_server.nim:1034 | SDL | `stderr.writeLine("[mcp-http] authorization hook failed: ...")` → `discard` | 6 許容 | 診断の 1 行そのもの。標準エラーの内容を見るテストは、この SDK の他の診断行にも無い。診断が消えるだけで、答え (500) と、何も通さないことは `Given an authorization hook that raises, ...` が確かめている。 |
| 337 | http_server.nim:1035 | SDL | フックが落ちたときの `respondEmpty(Http500)` → `discard` | 3 穴 | フックが例外を投げたら、答えは 500。`Given an authorization hook that raises, when a request arrives, then the answer is 500 and nothing reaches the server` (`test_security_http.nim`)。変異後は答えが返らず落ちる。 |
| 389 | http_server.nim:1036 | RVR | `return (answered: true, ...)` → `return default` | 3 穴 | 同じテスト。変異後は `answered` が `false` になり、500 を返した要求がそのままサーバーに渡り、セッションまで作られる (フックが決められないとき何も通さない、が破れる)。 |
| 218 | http_server.nim:1036 | BLR | `answered: true` → `false` | 3 穴 | 同じテスト (389 と同じ挙動になる)。 |

## 分類ごとの件数

| 分類 | 件数 | id |
|---|---:|---|
| 1 同値 | 4 | 384, 385, 269, 115 |
| 2 検出済み | 0 | |
| 3 穴 | 19 | 280, 282, 103, 284, 285, 293, 171, 177, 182, 303, 304, 307, 314, 320, 331, 332, 337, 389, 218 |
| 4 余分 | 3 | 317, 323, 217 |
| 5 欠陥 | 0 | |
| 6 許容 | 1 | 336 |

## 残っているもの

- 317 (`http_server.nim:948`)、323 (`:975`)、217 (`:1009`) は余分なコード (分類 4)。消すかどうかはリードが決める。
  323 と 217 は、HTTP+SSE のセッションが `touch` / `used` の対象外であることが理由で、消してよい。
  317 は読んで決めたもので、接続の後始末が `asynchttpserver` と二重になっている。実験で確かめてはいない。
- 336 は許容 (診断の 1 行)。
- 追加したテストのうち `test_version_floor.nim` の 3 件は、既定の版 (2026-07-28 と旧版の両方を話すビルド) では中身が走らない。
  走るのは `-d:mcpOldestProtocolVersion=2026-07-28` のときで、ジョブの `testCommand` はその版でこのファイルを流している。
