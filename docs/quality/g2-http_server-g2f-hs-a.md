# G2: http_server (第 1 部、229〜668 行、g2f-hs-a)

測定は 36a4c8a5 (change `owwryuxn`) の `tests/mutation/http_server.json`。ジョブ全体の数字は total 391 / killed 218 / timeout 64 / survived 94 / runError 0 / compileError 15。
この文書はそのうち `src/transport/http_server.nim` の 229〜668 行 (測定時の行番号) にある生き残り 30 件を扱う。残りの行は別の担当 (679〜1036 行、1050〜1175 行と `sse_stream.nim`) で、リードが 3 部を 1 つに統合する。

測定後に `http_server.nim` は変わった (`or` による待ちを `firstOf` に替えた。941 行付近)。この部の 30 件はいずれも、その変更より前の文なので、現行の本線 (`kvonwtpk`) では測定時の行番号に +1 した位置にある。変異した文はすべて現行のファイルに残っている。

クラスは build/G2_BRIEF.md の 1〜6。手で変異を入れて落ちるテストを見たものだけを 3 と書いた。

## 結果の件数

表の行を数えた (30 件、全 id が 1 回ずつ)。

| クラス | 件数 | id |
|---|---|---|
| 1 同値 | 6 | 136, 135, 75, 377, 260, 90 |
| 2 他のテストで検出 | 0 | |
| 3 欠落 (テストを足し、手で変異を入れて落ちるのを確認) | 21 | 224, 202, 371, 372, 138, 243, 248, 71, 74, 143, 206, 150, 151, 92, 95, 264, 97, 266, 99, 100, 267 |
| 4 死んだコード / 効果が観測できない | 1 | 213 |
| 5 欠陥 | 0 | |
| 6 受け入れ | 2 | 73, 76 |

## 生き残りの一覧

テストの置き場: `H` = `tests/test_http_streams.nim` の suite "the HTTP server transport's own rules (mutation review, g2f-hs-a)"、`S` = `tests/test_security_http.nim` の suite "The Host header names this server, in its odd forms (mutation review, g2f-hs-a)"、`F` = `tests/test_version_floor.nim` の suite "an HTTP server transport for a version outside the build (mutation review, g2f-hs-a)"。

「確認」の欄は、その変異を手で入れてテストが落ちたことを見た、という意味。

| id | file:line (測定時) | mutator | original → replacement | クラス | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 224 | http_server.nim:229 | SDL | `requireSupported(protocolVersion)` → `discard` | 3 | 話さない版の transport は作れない。`F` "Given a version the build does not speak, when a transport is made for it, then ValueError is raised"。既定のビルドでは全版が話す版なので拒む相手がなく、`-d:mcpOldestProtocolVersion=2026-07-28` のビルド (ジョブが `test_version_floor.nim` を流している) で落ちる。確認: そのビルドで 4 版すべてについて `Expect Failed` |
| 202 | http_server.nim:255 | BLR | `started: false` → `true` | 3 | `H` "Given a transport that was never started, ..."。作っただけの transport は受け付けていない、listen で始まり close で止まる。確認 |
| 371 | http_server.nim:266 | RVR | `receiveMessage` の `return (await t.receive()).message` → `nil` | 3 | `H` "Given a posted request, when the server takes it with receiveMessage, then it gets the message"。確認 (method と id の検査が落ちる) |
| 136 | http_server.nim:279 | LOR | `body.isNil or body.kind != JObject or clientId.isNil` の 1 つ目の `or` → `and` | 1 | `(A and B) or C` になる。`body` は `message[key]` で、`hasKey` を確かめた後なので nil にならない (JSON の null も nil ではない)。非 nil の `body` では `A and B` は偽、`clientId` は nil にならない (下の 135) ので全体は偽になり、次の `body{"_meta"}` へ進む。`{}` は object でない節に対して nil を返す (std/json の仕様) ので、そこの `meta.isNil` が同じ `return body` に着く。戻り値は同じ |
| 135 | http_server.nim:279 | LOR | 同じ式の 2 つ目の `or` → `and` | 1 | `A or (B and C)` になる。C = `clientId.isNil` は偽: `Exchange.idNode` を作る場所は 2 つだけで (http_server.nim:936 の `item["id"]`、1014 の `message["id"]`)、どちらも欠けていれば KeyError になり、nil は入らない。C が偽なら `B and C` も偽で、非 object の `body` は 136 と同じ道で `return body` に着く |
| 372 | http_server.nim:280 | RVR | 同じ `if` の `return body` → `return default` (nil) | 3 | params が object でない通知 (JSON-RPC は配列の params を許す) が、要求の経路に載るとき送ったとおりに届く。`H` "Given a notification whose params is an array, when the server sends it on a request's stream, then it arrives as it was sent"。確認: 変異すると params が nil になり、JSON の直列化で SIGSEGV |
| 138 | http_server.nim:285 | LOR | `named.isNil or named.kind != JString or named.getStr() != exchangeId` の 2 つ目の `or` → `and` | 3 | 別の購読を名指す `_meta` の subscriptionId は書き換えず、この要求の交換 id を名指すものだけを client の id に直す。`H` "Given a subscription stream, when the server sends a notification that names another subscription, ..."。確認: 変異すると "other" が 7 に書き換わる (2026-07-28 のビルドのみ) |
| 243 | http_server.nim:435 | SDL | `endSession` の `stream.finish()` → `discard` | 3 | セッションが終わると、POST の応答ストリームも終わる。`H` "Given a response stream still open, when its session ends, then the stream ends"。確認: 変異するとストリームが 3 秒黙って `sse_reader` が落とす |
| 71 | http_server.nim:444 | ROR | `sessionIdleTimeoutMs <= 0` → `< 0` | 3 | 0 は「DELETE まで保つ」と型のコメントにある。`H` "Given a session timeout of 0, when idle sessions are expired long after the last request, then the session stays"。確認 |
| 73 | http_server.nim:450 | ROR | `(now - session.lastActive) * 1000 >= timeout` → `>` | 6 | 受け入れ。浮動小数の時刻 2 つの差がちょうど設定値に等しい瞬間の話で、時計を差し込む口がなく、等しい値を作れない。境界の片側は同じ式の別の値で毎回検査されている (`H` の既存テスト "idle sessions")。時間の定数の扱いとして、テストしない |
| 248 | http_server.nim:457 | SDL | `close` の `t.server.close()` → `discard` | 3 | close すると待ち受けの口が閉じ、接続が拒まれる。`H` "Given a transport that was never started, ..." (同じテストの後半)。確認: 変異すると close 後も接続できて `Expect Failed` |
| 74 | http_server.nim:471 | ROR | `contentType.len > 0` → `>= 0` | 3 | 本文のない応答 (202) に Content-Type は付かない。`H` "Given an initialized session, when a notification is posted on it, then the empty answer carries no Content-Type"。確認: 変異すると空の Content-Type が付く |
| 75 | http_server.nim:503 | ROR | `close < 0` → `<= 0` | 1 | `value.startsWith("[")` の後なので `value[0]` は `[` で、`]` は 0 番にならない。`find(']')` の結果は -1 か 1 以上で、`0` は出ない。両者は同じ結果になる |
| 76 | http_server.nim:505 | ROR | `colon >= 0` → `> 0` | 6 | 受け入れ。違いが出るのは Host の値が `:` で始まる (名前が空の) ときだけで、どちらでも拒まれる。差が出る唯一の場合は `allowedHosts` に空文字列を入れたときで、原文は `:80` を通し、変異は通さない。空の名前を許す設定は意味がないので、その挙動は固定しない |
| 143 | http_server.nim:505 | LOR | `colon >= 0 and value.count(':') == 1` → `or` | 3 | 角括弧のない IPv6 (`::1`) を名前として切り刻まない。`S` "Given a transport bound to loopback, when a request names the bare IPv6 loopback address, then it is served"。確認: 変異すると `::1` が `:` に切られて 403 |
| 377 | http_server.nim:515 | RVR | `return false` → `return default` | 1 | `bool` の既定値は `false` なので、置き換えた文も `false` を返す。同じプログラムである (Host の欠落を 403 にする本体は 206) |
| 206 | http_server.nim:515 | BLR | `return false` → `return true` | 3 | Host のない要求は 403 (DNS rebinding の対策)。`S` "Given a transport bound to loopback, when a request carries no Host header at all, then the answer is 403"。確認: 変異すると 400 になる (通ってしまう) |
| 150 | http_server.nim:576 | LOR | `owner == session and exchange.idNode == clientId` → `or` | 3 | 取り消しは、送り手のセッションの、その id の要求だけを名指す。`H` "Given two sessions that chose the same request ids, when one cancels its requests, then each notification names that session's own request"。既存の `test_security_http.nim` の同種のテストは `pendingExchangeCount` だけを見ていて、どの要求が取り消されたかは見ていなかった。新しいテストは、サーバーが受け取る通知の requestId が、どの交換 id かを見る。確認: 変異すると `http-3` を指す (正しくは `http-4`) |
| 260 | http_server.nim:578 | SDL | `exchangeOf` の最後の `none(string)` → `discard` | 1 | 結果の `Option[string]` の既定値は none で、`none(string)` と同じ |
| 151 | http_server.nim:594 | LOR | `session.len == 0 or named.isNil` → `and` | 3 | セッションのない取り消しは捨てる (2026-07-28 は接続を閉じて取り消す。交換 id を推測して他人の要求を取り消せてはならない)。この経路に着くのは、legacy 版を話さないビルド (`-d:mcpOldestProtocolVersion=2026-07-28`) だけで、混在ビルドではセッションのない通知は先に 400 になる。`F` "Given a request in progress on a server of 2026-07-28 alone, when a cancellation naming its id comes without a session, then it is not passed to the server"。ジョブはこのビルドで `test_version_floor.nim` を流している。確認: そのビルドで変異すると取り消しがサーバーに届く。なお既存の `test_security_http.nim` のテストは実サーバーを使い、2026-07-28 のサーバーが `notifications/cancelled` を無視するので、この変異を見分けられなかった |
| 90 | http_server.nim:620 | ROR | `session.created < oldestAt` → `<=` | 1 | 作成時刻が等しい 2 つのうちどちらが「いちばん古い」かは決まっていない。要求は順に来るので `created` はふつう異なり、異なる値では同じ結果になる。等しい場合の選択は仕様にない |
| 92 | http_server.nim:631 | ROR | `maxSessionsPerPeer > 0` → `>= 0` | 3 | 0 は「上限なし」。`H` "Given no limit on sessions per address (0), when a client initializes, then it gets a session"。確認: 変異すると最初の initialize が 503 になる |
| 95 | http_server.nim:635 | ROR | `sessions.len >= maxSessions` → `>` | 3 | 上限に達したとき、使われてアイドルになったセッションを捨てて新しい client に席を譲る。`H` "Given the session limit is reached by sessions that were used and then went idle, ..."。既存のテストはセッションを一度も使っておらず、使っていないセッションの追い出し (`evictUnused`) が先に効いてこの経路を通らなかった。確認 |
| 264 | http_server.nim:636 | SDL | `t.expireIdleSessions()` → `discard` | 3 | 95 と同じテスト。確認 |
| 97 | http_server.nim:644 | ROR | `requestQueue.len + adding > maxQueuedMessages` → `>=` | 3 | 上限ちょうどの数は受け取り、その次を断る。`H` "Given a limit of two queued messages and nobody receiving, when two requests are posted, then both are taken and a third is refused"。確認: 変異すると 2 件目が断られる |
| 266 | http_server.nim:652 | SDL | `legacyCeiling` の本体 → `discard` | 3 | initialize の応答が版を名指さないとき、そのセッションは build が話す最新の legacy 版として扱われ、話さない版のヘッダを 400 で断る。`H` "Given an initialize answer that names no version, when the session is used, then it is held to the newest version the build speaks and ..."。確認: 変異すると 2024-11-05 扱いになってヘッダを検査しない。2025-06-18 以降を話さないビルドでは `legacyCeiling` の値が既定値と同じになり、テストは動かない (既定のビルドと 2025-11-25 のビルドで動く) |
| 99 | http_server.nim:656 | ROR | `session.streams.len > maxStoredStreams` → `>=` | 3 | 上限ちょうどまでは終わったストリームを残す。`H` "Given a session that keeps two finished streams, when a second request ends, then both can be resumed"。確認: 変異すると最初のストリームが 400 で再開できない |
| 100 | http_server.nim:662 | ROR | `oldestFinished.len == 0` → `!= 0` | 3 | 上限を超えたら終わったストリームのうち古いものを捨てる。`H` "Given a session that keeps one finished stream, when a second request ends, then the first stream can no longer be resumed and the second can"。確認: 変異すると古いストリームが捨てられず 200 のまま |
| 267 | http_server.nim:664 | SDL | `session.streams.del(oldestFinished)` → `discard` | 3 | 100 と同じテスト。確認: 変異すると `while` が終わらず (終わったストリームを見つけても捨てない) テストが戻らない。60 秒の `timeout` で打ち切った。測定でも timeout (検出) になる種類 |
| 213 | http_server.nim:668 | BLR | `cancel` の `group.abandoned = true` → `false` | 4 | `abandoned` を読むのは `sendResponse` と `deliver` の 2 か所で、どちらも「もう誰も読まないストリームへ push しない」ためのもの。`cancel` が呼ばれるのは 2026-07-28 の要求だけ (http_server.nim:948, 961) で、その要求はセッションを持たないので、ストリームは `rememberStream` に入らず、再開もできない。取り消した後の書き込みは、`Exchange` から外れて誰も参照しない `group` の中にたまるだけで、外から観測できる違いがない。既存の "Given a cancelled request, when the server answers it anyway, then the answer is dropped without an error" は、フラグが無くても `pendingExchangeCount == 0` で通る。削除はしない。リードの判断を求める |

## 残っているもの

- 213 (クラス 4): `group.abandoned` の 2 つの保護は、外から観測できる効果を持たない。削除するか、効果を持たせる (取り消し後に push すると何が悪いのか) かをリードが決める。
- 73、76 (クラス 6): 上の理由で、固定するテストは書かない。
- 224、151 は、ジョブの `testCommand` にすでにある `-d:mcpOldestProtocolVersion=2026-07-28` の `test_version_floor.nim` で検出される。ほかの変異はすべて既定のビルドで検出される。`tests/mutation/*.json` は変えていない。
- 224 は `-d:mcpDefaultProtocolVersion=2025-11-25` のビルドでも検出される (2026-07-28 が話さない版になる)。
