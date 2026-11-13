# G2 変異検出: client ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/client.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。状態: 測定済み。仕分けは 2026-11-14、テストを書いた社員とは別の担当が、コードと仕様を読んで行った (変異は当てていない)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 398 | 344 | 14 | 30 | 0 | 10 |

仕分けの内訳: test_owed 9、spec_question 3、equivalent 9、unreached 2、accepted 7、undecided 0。

### 生き残りの仕分け

| 指紋 | 場所 | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/client/cancel_token.nim:ROR:bc7d3f515c3dea3a:0` | cancel_token.nim:60 | `at >= 0` → `at > 0` | accepted | `unwatchCancellation` に関する生き残りは受け入れる (代表の決定 2026-11-11)。変異だと、先頭の待ち手だけがトークンに残る | — |
| `src/client/cancel_token.nim:SDL:b8560021a4a528ae:0` | cancel_token.nim:61 | `token.waiters.del(at)` → `discard` | accepted | `unwatchCancellation` に関する生き残りは受け入れる (代表の決定 2026-11-11)。変異だと、終わった要求の待ち手がトークンに残る | — |
| `src/client/client.nim:ROR:ec3dcd4a35d1e675:0` | client.nim:278 | `maxServerRequestsInProgress > 0` → `>= 0` | test_owed | 上限 0 (制限なし) のとき、変異だと `serverRequestsInProgress >= 0` が常に真になり、サーバーの要求をすべて -32603 で断る。仕様は「0: no limit」と書いているが、0 を入れるテストが無い (既定値 64 を確かめるだけ) | MCP-SEC-SWEEP-8。`tests/external/test_security_sampling_limits.nim` に: `maxServerRequestsInProgress = 0` の client に sampling/createMessage を 1 件 (または 3 件を同時に) 送り、どれも error なしで答えられ handler が呼ばれることを見る。変異だと 1 件目が「Too many requests in progress」になる |
| `src/client/client.nim:ROR:99ececf14e11d202:0` | client.nim:533 | `reason.len > 0` → `>= 0` (`abandon` の stderr の行) | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。理由が空のとき stderr の行の末尾に「: 」が付くだけで、要求を手放すこと・サーバーへの通知は変わらない | — |
| `src/client/client.nim:SDL:bf1513f4858062ec:0` | client.nim:607 | `options.cancel.unwatchCancellation(watching)` → `discard` | accepted | `unwatchCancellation` に関する生き残りは受け入れる (代表の決定 2026-11-11) | — |
| `src/client/client.nim:ROR:d88c07a69f76d3b8:1` | client.nim:608 | `progressKey.len > 0` → `>= 0` (`finally` の `del`) | equivalent | `progressKey` が空なのは `onProgress` が nil のときだけで、そのとき 579 行の登録も同じ条件で行われない。`progressCallbacks` はこのモジュールだけが書くので、鍵 `""` は表に無く、`del("")` は何もしない | — |
| `src/client/client.nim:BLR:ef687d54c37fe225:0` | client.nim:858 | `client.keepAliveRunning = true` → `false` | spec_question | 変異だと、セッションを作り直したとき (`renewSession` → `initialize`) に keepalive の周回が 2 本になる。相手が ping に答えていれば 2 本とも同じ `lastActivity` を見るので ping の数は変わらないが、答えない相手には `pingTimeoutMs` の間に ping が 2 つ出る。「keepalive は接続につき 1 本」はどの仕様 ID にも無い | 問い: 「セッションを作り直しても keepalive の周回は 1 本のまま」を仕様にしますか。案 A (推奨): MCP-LIFECYCLE-26 に 1 文足し、HTTP の 404 で作り直したあと ping に答えない相手へ、`pingTimeoutMs` の間に ping が 1 つだけ出ることを E テストで見る。案 B: 仕様にせず、この行を等価に近いものとして受け入れる (代表の決定が要る) |
| `src/client/client.nim:LOR:8cfb491cc9ed65e8:0` | client.nim:860 | `state != mlsShutdown and client.transport == transport` → `or` | spec_question | 変異だと `close()` のあとも周回が終わらない (`state != mlsOperational` の枝で `lastActivity` を進めて眠り続ける)。ping は出ないので「closing the client stops the pings」のテストは通る。外から見える違いは、dispatcher に時計が残り続けること (`hasPendingOperations()` が真のまま) だけで、どの仕様 ID にも無い | 問い: 「閉じた client は dispatcher に仕事を残さない」を仕様にしますか。案 A (推奨): MCP-LIFECYCLE-26 の「closing the client stops the pings」に足し、`close()` のあと `pingIntervalMs` を過ぎたら `hasPendingOperations()` が偽になることを E テストで見る。案 B: 条件の `client.transport == transport` を消す (2 回目の `connect` を入口で断るのと組にする。下の「実装の欠陥の疑い」)。消せばこの LOR は生まれない |
| `src/client/client.nim:ROR:03dee8ca16c7a195:0` | client.nim:862 | `idle < interval` → `<=` | equivalent | `idle == interval` のちょうど 1 ミリ秒のときだけ `sleepAsync(0)` を 1 回挟んで次の周で ping を送る。遅れは 1 ミリ秒未満で、外から区別できない | — |
| `src/client/client.nim:AOR:e836bc7120ccf10e:0` | client.nim:863 | `interval - idle` → `interval + idle` | test_owed | 眠っている間に通信があると、変異では次の ping が「最後の通信から `pingIntervalMs`」より遅れる (最大で約 3 倍の間隔)。今のテストは接続の直後 (idle がほぼ 0) からしか測らないので差が出ない | MCP-LIFECYCLE-26 (「When the connection has been idle for pingIntervalMs Then the client sends a ping」)。`tests/external/test_client_keepalive_fix.nim` に: `pingIntervalMs = 300` で接続し、30 ms 後に tools/list を 1 回送り、接続から 600 ms までに ping が 1 つ以上届くことを見る。元は約 330 ms、変異は約 870 ms で届く |
| `src/client/client.nim:SDL:b64362b1bc15ad75:0` | client.nim:873 | stderr の行「keepalive ping answered with an error: …」→ `discard` | test_owed | keepalive は誰にも待たれないので、ping がエラーで答えられたことの原因はこの行にしか残らない。相手に原因を返さない失敗の原因を stderr の 1 行に書く箇所で、2026-11-13 の代表の決定 (server 側 MCP-ERRORS-3 と同じ扱い) に当たる | クライアント側に同じ仕様の文が無い。足す先の提案: `specs/errors.feature` に MCP-ERRORS-4「A failure of the client that no caller is told is written to stderr as one line」(keepalive の ping がエラーで答えられた・セッションが終わっていた・接続を閉じ損ねた)。テスト: `test_client_keepalive_fix.nim` の「Given a peer that answers a ping with an error…」を `loggedWhile` で包み、stderr に「keepalive ping answered with an error」と相手の文面 (Method not found) が 1 行で出ることを見る |
| `src/client/client.nim:SDL:f45f24d3e99abbdb:0` | client.nim:876 | stderr の行「keepalive ping found the session ended: …」→ `discard` | test_owed | 同上。keepalive の ping が 404 を受けてセッションの作り直しが走ったことは、この行にしか残らない (呼び手はいない) | 提案の MCP-ERRORS-4。`tests/external/test_session_expiry_fix.nim` の `expiringServer` で、`pingIntervalMs` を短くした client を繋ぎ、ping が 404 を受けたあと stderr に「keepalive ping found the session ended」が出て、`counts.initializes == 2` になることを見る |
| `src/client/client.nim:SDL:7b8bd1ef2303fbec:0` | client.nim:888 | `await transport.close()` → `discard` (ping が失敗したあと) | test_owed | 仕様は「closes the connection」と言うが、今のテストは `client.state == mlsShutdown` と待ちの要求の失敗しか見ず、transport が閉じられたことを見ていない | MCP-LIFECYCLE-26。`tests/external/stuck_transport.nim` (ping に答えない。`closeCalls` を数える) を旧版の client に繋ぎ (initialize の答えは `inject` で渡す)、`pingIntervalMs = 30`・`pingTimeoutMs = 60` で ping が時間切れになったあと `closeCalls == 1` を見る。変異だと 0 |
| `src/client/client.nim:SDL:62b9584ef1b1cd92:0` | client.nim:890 | stderr の行「closing the connection failed: …」→ `discard` | test_owed | ping の失敗のあと接続を閉じ損ねた原因は、この行にしか残らない (呼び手はいない)。2026-11-13 の代表の決定に当たる | 提案の MCP-ERRORS-4。`close()` が例外を投げる transport (stuck_transport に `closeFails` の欄を足す) で ping を時間切れにし、stderr に「closing the connection failed」と例外の文面が 1 行で出ること、`client.state == mlsShutdown` を見る |
| `src/client/client.nim:SDL:4fb9d814e3c843cb:0` | client.nim:894 | stderr の行「keepalive ended with …」→ `discard` | unreached | 外側の `except CatchableError` に届く例外が無い。周回の中で待つのは `sleepAsync` と ping だけで、ping の `CatchableError` は内側の 3 つの `except` がすべて受け、その中の `transport.close()` も自分の `try` で包まれている。`failPending` は終わっていない future を失敗させるだけで投げない | — (この `except` 節ごと消せば生き残りも消える) |
| `src/client/client.nim:BLR:b8d2df6c5dee987b:0` | client.nim:897 | `client.keepAliveRunning = false` → `true` (`finally`) | equivalent | 周回が終わるのは `state == mlsShutdown` か transport が替わったときだけ。`keepAlive` を呼ぶのは `initialize` だけで、shutdown のあとは `renewSession` が何もせず (983 行)、`initialize` は `mlsUninitialized` 以外を断るので、終わったあとにこの旗を読む経路が無い | — |
| `src/client/client.nim:SDL:835812ed87f5fb7a:0` | client.nim:985 | stderr の行「the server ended the session; starting a new one」→ `discard` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。呼び手は `McpSessionExpiredError` (`renewed` つき) を受け取るので原因は返っており、消えるのは知らせの行だけ | — |
| `src/client/client.nim:SDL:9bd5da1ab8ba6a71:0` | client.nim:991 | stderr の行「a new session could not be started: …」→ `discard` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。呼び手は、作り直しの失敗を親に持ち同じ文面を含む `McpSessionExpiredError` を受け取るので、原因は呼び手に返っている | — |
| `src/client/client.nim:BLR:7b3b544c7959f2c3:0` | client.nim:996 | `failed.current = true` → `false` | spec_question | 作り直しに失敗したとき呼び手が受け取る `McpSessionExpiredError` の公開の欄 `current` が偽になる。SDK の中でこの値を読み直す経路は無い (state が shutdown なので `renewSession` は先に戻る)。MCP-HTTPSTREAM-28 は「failure as parent, renewed false」だけを言い、`current` に触れていない | 問い: 作り直しに失敗したときの `current` を仕様にしますか。案 A (推奨): MCP-HTTPSTREAM-28 の文に「current true」を足し、`test_session_expiry_fix.nim` の「…a server that refuses the new initialize…」に `check expired.current` を 1 行足す (欄の説明は既にそう約束している)。案 B: 仕様にしない (その場合この代入は消せる) |
| `src/client/client.nim:ROR:080f250a54bf828a:0` | client.nim:1016 | `v > result.get` → `>=` | equivalent | `v == result.get` のとき `result` に同じ値を入れ直すだけで、戻り値は変わらない | — |
| `src/client/client.nim:BLR:4a74703e2a2ee211:0` | client.nim:1038 | `var answered = false` → `true` | equivalent | `answered` は直後の `try` で必ず代入される。代入しない経路 (2 つの `except`) は `raise` か `return` で抜けるので、初期値は読まれない | — |
| `src/client/client.nim:RVR:40ca21d69a02a055:0` | client.nim:1087 | `return pvModern` → `<return default>` | equivalent | `default(ProbeVerdict)` は最初の列挙子 `pvModern` で、元と同じ値 | — |
| `src/client/client.nim:SDL:275dad15c7ff65a8:0` | client.nim:1089 | `raiseAssert "server/discover was probed twice without a verdict"` → `discard` | unreached | `discover` の 2 周目 (`attempt == 1`) は、どの枝も `return` か `raise` で終わる (やり直す `continue` は `attempt == 0` のときだけ)。サーバーが何を答えてもこの行に届かない | — |
| `src/client/client.nim:LOR:7a1b3980f863ad33:0` | client.nim:1098 | `waiting.isNil or waiting.finished` → `and` | test_owed | 待っている要求が無い id (時間切れで手放した要求など) の喪失を transport が知らせると、変異では nil の `finished` を読んで落ちる。今のテストは待っている要求の喪失しか通さない | MCP-HTTP-49。`tests/external/test_request_lost_fix.nim` に: client を transport に繋ぎ、client が入れた `transport.onRequestLost` を、誰も待っていない id (手放した要求の id) で呼ぶ。client は何も投げず、次の要求が答えられることを見る。変異だとプロセスが落ちる |
| `src/client/client.nim:SDL:2f756b70317c80ea:0` | client.nim:1100 | `client.pendingRequests.del(requestId)` → `discard` | test_owed | 失われた要求が待ちの表に残る。同じ id をもう一度使うと「is in flight」で断られる (仕様は「the caller may send it again」) | MCP-HTTP-49。同じファイルに: ストリームが応答の前に終わるサーバーへ `startRequest(…, id = "r1")` を送り、`McpRequestLostError` のあと `client.pendingRequests.len == 0` であること、同じ id "r1" でもう一度 `startRequest` できる (2026-07-28) ことを見る。変異だと表に 1 件残り、2 回目が `ValueError` になる |
| `src/client/content.nim:RVR:0b3a908190e4c846:0` | content.nim:48 | `return none(string)` → `<return default>` | equivalent | `default(Option[string])` は none で、元の戻り値と同じ | — |
| `src/client/sampling.nim:RVR:22bd31688538b11f:0` | sampling.nim:69 | `return none(float)` → `<return default>` | equivalent | `default(Option[float])` は none で、元の戻り値と同じ | — |
| `src/client/sampling.nim:LOR:4e851ee8f751a18c:0` | sampling.nim:79 | `maxTokens.isNil or maxTokens.kind != JInt` → `and` | test_owed | `maxTokens` の無い params で、変異では nil の `kind` を読んで落ちる (整数でない値は、続く `getBiggestInt() < 1` が 0 を読んで同じ例外になるので区別できない)。handler の経路では手前の `createMessageParamsProblems` が先に断るので届かないが、`parseSamplingRequest` は `mcp` から公開されていて直接呼べる | MCP-SEC-SWEEP-9 (「maxTokens is missing」)。`tests/external/test_security_sampling.nim` に: `maxTokens` の無い object を `parseSamplingRequest` に渡し、`McpProtocolError` を見る。変異だとプロセスが落ちる。別の道: `parseSamplingRequest` を公開から外せば、この変異は unreached になる |
| `src/client/sampling.nim:RVR:60d8e05cd3878e9c:0` | sampling.nim:187 | `return newJsonRpcErrorResponse(request.id, -32603, "the sampling handler answered with something that does not match the request")` → `<return default>` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。result も error も無い応答は、transport が -32603「Internal error」として送る (MCP-TRANSPORT-3) ので、断ることと符号 -32603 は保たれ、id は `processRequest` が要求のものを入れる。変わるのは文面だけ | — |
| `src/client/tools.nim:RVR:2e352bc38ad16857:0` | tools.nim:54 | `return McpToolAnnotations()` → `<return default>` | equivalent | `McpToolAnnotations()` は全部の欄が未設定の値で、型の既定値と同じ | — |

### timeout

timeout は検出に数える。無限に待つ・回る変異か、ただ遅いだけかを 1 行ずつ書く (コードから読んだ見立てで、当てて確かめてはいない)。

| 指紋 | 場所 | 変異 | 見立て |
|---|---|---|---|
| `src/client/client.nim:SDL:097073d7c1c89b5e:0` | client.nim:310 | `subscription.ended.complete()` → `discard` | 待ち続ける。購読の `ended` が完了せず、それを待つテストが止まる |
| `src/client/client.nim:SDL:71e163352870e7c4:0` | client.nim:404 | `promise.complete(response)` → `discard` | 待ち続ける。どの要求も応答を受け取れず、要求の時間切れ (既定 60 秒) まで待つ |
| `src/client/client.nim:BLR:441e41b22fd35db0:0` | client.nim:412 | `while true` → `false` | 待ち続ける。受信の周回が回らず、応答が処理されない |
| `src/client/client.nim:SDL:8f1e478c467bd84e:0` | client.nim:421 | `asyncCheck client.processResponse(response)` → `discard` | 待ち続ける。応答が捨てられる |
| `src/client/client.nim:BLR:6224b683d15c83d1:0` | client.nim:709 | `toolsListedAgain = true` → `false` | 無限に回る。2 回目の拒否でも tools/list を読み直して送り直し続ける |
| `src/client/client.nim:SDL:3599c229f44384bc:0` | client.nim:725 | `inc rounds` → `discard` | 無限に回る。`maxInputRounds` に達しない |
| `src/client/client.nim:ROR:055f590c43452ade:0` | client.nim:856 | `interval <= 0` → `< 0` | 無限に回る見込み。間隔 0 で周回に入り、眠らずに ping を送り続ける。止まらなくても「Given an interval of 0…no ping is sent」が落とすはず |
| `src/client/client.nim:LOR:38c119cf033b54c7:0` | client.nim:856 | `interval <= 0 or keepAliveRunning` → `and` | 同上 (間隔 0 で周回に入る) |
| `src/client/client.nim:ROR:16a59f22d90f0c5e:0` | client.nim:865 | `state != mlsOperational` → `==` | ただ遅いだけの見込み。operational の間 ping を送らなくなり、ping を待つテストが上限 (版ごとに 3 秒) まで待ってから `check` で落ちるはず。測り直しの候補 |
| `src/client/client.nim:ROR:9eb67d6fa934c509:0` | client.nim:939 | `error.code == ErrUnsupportedProtocolVersion` → `!=` | ただ遅いだけの見込み。別の符号の拒否で 2 回目の discover に進み、要求の時間切れ (60 秒) まで待つ。測り直しの候補 |
| `src/client/client.nim:RVR:42868e292d07ee69:0` | client.nim:1053 | `return pvSilent` → `<return default>` (`pvModern`) | 見立てに確信なし。答えない相手を「確立済み」とみなして initialize を送らず、その後の要求が時間切れまで待つと読める。時間切れの後に落とす `check` があるかは確かめていない。検出できていない疑いがあり、測り直しの候補 |
| `src/client/client.nim:SDL:6f89b0986d70fae4:0` | client.nim:1105 | `asyncCheck client.processMessages()` → `discard` | 待ち続ける。何も受信せず `connect` が終わらない |
| `src/client/client.nim:ROR:980cfee04d924e41:0` | client.nim:1121 | `verdict != pvSilent` → `==` | 見立てに確信なし。探りに答えた旧版の相手が initialize をモダンの符号で断ると、もう一度 discover を送って要求の時間切れまで待つと読める。ただ遅いだけなら測り直しの候補 |
| `src/client/content.nim:SDL:02d0793da7827490:0` | content.nim:160 | `inc pages` → `discard` | 無限に回る。`maxPages` に達せず、終わらない一覧を読み続ける |

### 仕分けの中で気づいたこと

- 実装の欠陥の疑い: `connect` は、既に繋がっている client に呼ばれても、先に `client.transport` を差し替えて受信の周回をもう 1 本起こし、そのあと `initialize` が「Client already initialized」で断る (旧版)。断る前に状態が書き換わっている。
- 前の記録 (2026-10-07・2026-10-10) の「リードの判断」は、この節の accepted の根拠にしていない。894 行と 1089 行は、今のコードを読んで unreached とした。

## 最初の測定 (本線の 36a4c8a5、2026-10-07)

測定: `nim-muter`、ジョブ `tests/mutation/client.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/client/` の 8 ファイル。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 344 | 215 | 8 | 113 | 0 | 8 |

生き残り 113 件の分類 (3 人で分担し、下の 3 節に 1 件ずつ記録した)。

| 分類 | 1〜584 行 | 585 行以降 | client.nim 以外 | 計 |
|---|---:|---:|---:|---:|
| 1 同値 | 3 | 6 | 3 | 12 |
| 2 ジョブに無い既存のテストが検出 (ジョブに追記) | 15 | 15 | 0 | 30 |
| 3 穴 (テストを追加) | 30 | 26 | 12 | 68 |
| 4 到達しない・冗長なコード | 2 | 1 | 0 | 3 |
| 5 欠陥 (上の件数とは別。生き残りを調べる中で見つかったもの) | 1 | 0 | 0 | 1 |
| 6 許容 | 0 | 0 | 0 | 0 |

分類 2 と 3 は、変異を 1 件ずつ手で当てて、テストが落ちる (または止まる) ことを確かめた。分類 1 は式から読んだ。

## 到達しないコードの扱い (リードの判断、2026-10-07)

- id 247 (`client.nim:405`、受信ループの `except` 節の `failPending("the client was closed")`): 削除した。`close()` が先に `failPending` を呼び、
  その後は `ensureOpen` が新しい要求を断るので、ここに来るとき待ちの表は空。
- id 260 (`client.nim:483-485`、`abandon` の `try` / `except` と中の診断): 削除した。`sendNotification` は async の手続きで、失敗は呼び出しの時点では
  投げられず future に載る。失敗の報告は、残した `addCallback` が行う。
- id 307 (`client.nim:914`、`discover` のループの後の `return pvLegacy`): 2 周目はどの枝も `return` か `raise` で終わるので届かない。
  「届いたら旧版とみなす」のをやめ、`raiseAssert` に替えた (届いたら内部の誤りで、旧版のサーバーではない)。この行は届かないままなので、
  次の測定でも生き残る。理由はここに書いたとおり。

## 見つかった欠陥

- `startRequest` で送信に失敗した要求が、待ちの表 (`pendingRequests`) に残り続けていた (標準ライブラリの `or` が、結合する future の
  既存のコールバックを消すため)。失敗するテストを先に書いて修正した (`fix(client)`)。同じ `or` の使い方がほかに 7 か所あり、
  別途調べる (`docs/quality/g2-protocol-versions.md` の未測定の節を参照)。

この修正と到達しないコードの整理で `src/client/client.nim` が測定後に変わった。push の前に、このジョブを測り直す。

## src/client/client.nim の 1〜584 行

測定日 2026-10-07。対象は mainline 先端 36a4c8a5 (jj change `owwryuxn`) の `nim-muter` 報告
(`tests/mutation/client.json`)。585 行以降は `g2-client-b` の担当で、リードが `g2-client.md` にまとめる。

### 数字 (client.nim の 1〜584 行に限る)

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 112 | 52 | 5 | 50 | 0 | 5 |

分類の内訳は次のとおり (50 件)。

| 分類 | 件数 | 意味 |
|---|---:|---|
| 1 同値 | 3 | 294, 303 の RVR と 539 |
| 2 他のテストが検出 | 15 | ジョブに足したテストが検出 |
| 3 穴 (テストを書いた) | 30 | 新しい外部仕様テストで検出 |
| 4 死んだ・冗長なコード | 2 | 405, 484 |
| 5 欠陥 | 0 件の行 | 下の「見つかった欠陥」。253, 165, 288 のテストを書く途中で見つかり、その 3 件は 3 に数えた |
| 6 受容 | 0 | |

「検出」は、変異を手で当ててそのテストが落ちるのを見たことを指す。変異は 1 件ずつ当て、毎回 `jj restore` で戻した。

### 一覧

- 区分 2 の検出元は、`tests/mutation/client.json` に足した 5 本 (後述)。
- 区分 3 の検出元の「新」は、このラウンドで足したテスト。

| id | 行 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 212 | 225 | SDL | `pendingRequests.clear()` → 削除 | 3 | 失敗させた future が表に残る。`test_client_requests`「Given a pending request, when the server ends the stream, then it fails with McpConnectionClosedError and nothing stays registered as pending」(新) |
| 157 | 240 | LOR | `elicitation.isSome and has(ftElicitation)` → `or` | 2 | `test_client_elicitation`「Given a connection of a version before elicitation, when the server asks, then the client answers method not found」 |
| 218 | 273 | SDL | `logHandlerFailure(what)` → 削除 | 3 | `test_security_diagnostic_client`「Given a list-changed callback that raises, ...」(新)。例外を握りつぶさず、どのコールバックが何で落ちたかを stderr に出す |
| 219 | 280 | SDL | `subscriptions.del(id)` → 削除 | 2 | `test_subscriptions` の「stdio の client が cancel する」ほか 4 件が `subscriptions.len == 0` で落ちる |
| 220 | 283 | SDL | `ended.complete()` → 削除 | 2 | `test_subscriptions`「Given the server answers the listen request, ... then the stream ended gracefully」が `ended` を待って止まる |
| 286 | 294 | RVR | `return false` → `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された (同じ行の BLR のために足したテスト)。 |
| 197 | 294 | BLR | `return false` → `return true` | 2 | `test_subscriptions`「Given a notification tagged with an unknown subscription id, ...」 |
| 117 | 295 | ROR | `method == AcknowledgedMethod` → `!=` | 2 | `test_subscriptions` の listen が acknowledgment を受け取れず落ちる (2 件) |
| 221 | 302 | SDL | `acknowledgement.complete()` → 削除 | 2 | `test_subscriptions`「Given a modern server, when the client listens, ...」が acknowledgment を待って落ちる |
| 287 | 303 | RVR | `return false` → `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された (同じ行の BLR のために足したテスト)。 |
| 198 | 303 | BLR | `return false` → `return true` | 3 | acknowledgment が購読ストリームのコールバックに届く。`test_subscriptions`「Given an acknowledged subscription, when a second acknowledgment arrives, then the first counts and the stream's callback does not see it」(新)。acknowledgment は client が消費する (ルーティングの doc コメント) |
| 199 | 304 | BLR | `true` → `false` | 2 | `test_subscriptions`「Given an open subscription, when notifications arrive, ...」ほか |
| 224 | 324 | SDL | `logHandlerFailure("progress callback")` → 削除 | 3 | `test_security_diagnostic_client`「Given a progress callback that raises, ...」(新) |
| 226 | 334 | SDL | `logHandlerFailure("log callback")` → 削除 | 3 | 同「Given a log callback that raises, ...」(新) |
| 228 | 341 | SDL | `logHandlerFailure("resource-updated callback")` → 削除 | 3 | 同「Given a resource-updated callback that raises, ...」(新) |
| 161 | 351 | LOR | `not target.isNil and kind in {JString, JInt}` → `or` | 3 | requestId の無い `notifications/cancelled` で nil を読み SIGSEGV。`test_subscriptions`「Given an open subscription, when notifications/cancelled arrives without a request id or with one that names nothing, then the stream stays open」(新) |
| 232 | 352 | SDL | `endSubscription(...)` → 削除 | 2 | `test_subscriptions`「Given a stdio server that cancels the stream, ...」 |
| 119 | 352 | ROR | `kind == JString` → `!=` | 2 | 同上 |
| 162 | 359 | LOR | `not subscription.isNil and not onNotification.isNil` → `or` | 3 | 自前のコールバックを持たない購読への通知で nil の closure を呼び SIGSEGV。`test_subscriptions`「Given an open subscription without a callback of its own, when a notification arrives on it, then the client's callback still runs」(新) |
| 234 | 361 | SDL | `subscription.onNotification(...)` → 削除 | 2 | `test_subscriptions`「Given an open subscription, when notifications arrive, ...」ほか |
| 235 | 363 | SDL | `logHandlerFailure("subscription callback")` → 削除 | 3 | `test_security_diagnostic_client`「Given a stream callback that raises, ...」(新、2026-07-28 のみ) |
| 236 | 367 | SDL | `await handler(notification)` → 削除 | 2 | `test_client_elicitation`「Given an accepted URL request, when the completion notification arrives, ...」 |
| 237 | 369 | SDL | `logHandlerFailure("handler for " & ...)` → 削除 | 3 | `test_security_diagnostic_client`「Given a handler for a notification that raises, ...」(新) |
| 244 | 401 | SDL | `failPending("the transport was closed")` → 削除 | 3 | EOF (McpTransportClosedError) で待っている要求が失敗せず、表に残る。`test_client_requests`「Given a pending request, when the server ends the stream, ...」(新)。EOF を再現するため loopback に `endStream` を足した |
| 247 | 405 | SDL | `failPending("the client was closed")` → 削除 | 4 | 下の「死んだコード」を参照 |
| 245 | 408 | SDL | `stderr.writeLine("transport loop ended with ...")` → 削除 | 3 | `test_security_diagnostic_client`「Given a transport that fails, when the receive loop ends, then the log names the error」(新) |
| 164 | 433 | LOR | `getOrDefault(id) == promise and not promise.finished` → `or` | 3 | 手放した要求の送信失敗が報告されなくなる。`test_client_requests`「Given a request given up while it was being sent, when the sending fails afterwards, then the failure is reported」(新) |
| 250 | 434 | SDL | `pendingRequests.del(id)` → 削除 | 3 | `test_client_requests`「Given sending that fails while the request waits, ...」(新)。送信失敗のあと表に残る |
| 252 | 438 | SDL | `stderr.writeLine("sending ... failed after the request was given up")` → 削除 | 3 | 433 と同じテスト |
| 253 | 451 | SDL | `await (started.sent or started.response)` → 削除 | 3 | `test_client_requests` の「starting a request without waiting for its response」の 3 件 (新)。手で当てたのは、修正後の `try` の中身を `discard` にした変異 (await の削除と同じ) |
| 165 | 451 | LOR | `sent or response` → `and` | 3 | 同「Given a request that is started, when the server has not answered, ...」(新)。応答を待って止まる |
| 288 | 454 | RVR | `return (id:, response:)` → `return default` | 3 | 同じ suite。`id` が空になる (新) |
| 254 | 457 | SDL | `ensureOpen()` → 削除 (sendNotification) | 3 | `test_client_requests`「Given a closed client, when a notification is sent, then it raises McpConnectionClosedError without sending」と「Given a client that never connected, ...」(新) |
| 201 | 462 | BLR | `unsent = false` → `true` | 3 | 購読の cancel で `cancelRequest` が 2 回呼ばれる。`test_subscriptions`「Given an open subscription over HTTP, when the client cancels it, then the transport is asked once to close the stream and no notification is sent」(新) |
| 258 | 468 | SDL | `cancelRequest(id)` (unsent) → 削除 | 3 | `test_client_requests`「Given a request whose sending has not finished, when it times out, then the transport is asked to give up sending and the server is told」(新) |
| 167 | 473 | LOR | `modern and kind != mtkStdio` → `or` | 3 | 旧版の HTTP で `notifications/cancelled` が送られなくなる。`test_client_requests`「Given a legacy connection over HTTP, when a request that was sent times out, ...」(新) |
| 126 | 473 | ROR | `kind != mtkStdio` → `==` | 3 | 「Given a connection over HTTP, ...」と「Given a connection over stdio, ...」(2026-07-28 の suite、新) |
| 259 | 474 | SDL | `cancelRequest(id)` (modern HTTP) → 削除 | 3 | 同「Given a connection over HTTP, when a request times out, then the transport is asked to cancel it and no notification is sent」(新) |
| 260 | 484 | SDL | `stderr.writeLine("could not cancel request ...")` (except 節) → 削除 | 4 | 下の「死んだコード」を参照 |
| 257 | 486 | SDL | `cancelling.addCallback(...)` → 削除 | 3 | `test_client_requests`「Given a notification of cancellation that cannot be sent, when a request times out, then the caller still gets McpTimeoutError and the failure is reported」(新)。loopback に `brokenNotifications` を足した |
| 261 | 488 | SDL | `stderr.writeLine("could not cancel request ...")` (callback 内) → 削除 | 3 | 同じテスト |
| 169 | 499 | LOR | `modern and not traceContext.isEmpty` → `or` | 2 | `test_trace_context`「Given a legacy version, when a request has a trace context in the options, then the keys are not sent」 |
| 262 | 506 | SDL | `inc nextProgressToken` → 削除 | 3 | 同時に進行する 2 要求の進捗が混ざる (進捗トークンは同時に有効な要求の間で一意でなければならない)。`test_client_requests`「Given two requests with progress callbacks in flight, ...」(新) |
| 127 | 515 | ROR | `progressKey.len > 0` → `>= 0` | 3 | コールバックなしの要求が空トークンに nil を登録し、空トークンの進捗で nil の closure を呼んで SIGSEGV。`test_client_requests`「Given a request without a progress callback, when progress arrives with an empty token, then the client carries on」(新) |
| 129 | 532 | ROR | `reason.len > 0` → `>= 0` | 3 | 理由なしの取り消しの例外メッセージに空の括弧 `()` が付く。`test_client_requests`「Given a token cancelled without a reason, ...」(新) |
| 130 | 539 | ROR | `progressKey.len > 0` → `>= 0` | 1 | 下の「同値」を参照 |
| 131 | 560 | ROR | `undeclared.len > 0` → `>= 0` | 2 | `test_mrtr`「Given an input_required answer, when the client has the handler, ...」ほか |
| 132 | 583 | ROR | `methodName == "tools/call"` → `!=` | 2 | `test_param_headers_http`「Given a tool that gained x-mcp-header after it was listed, ...」ほか |
| 133 | 584 | ROR | `code == ErrHeaderMismatch` → `!=` | 2 | 同上 |
| 174 | 584 | LOR | `... code == ErrHeaderMismatch and usesModernProtocol` → `or` | 3 | 結合は `((A and B and C) or D) and E and F` になり、2026-07-28 の HTTP では成功した `tools/call` でも tools/list を読み直して同じ呼び出しをもう一度送る (副作用の二重実行)。`test_param_headers_http` は検出しない。`test_client_requests`「Given a connection over HTTP, when a call is answered with a result, then it was sent once and the tools were not listed again」と「... refused for another reason, ...」(新) |

#### 同値 (区分 1)

- 286, 287: `return false` を `return default` にしても、`default(bool)` が `false` なので値が同じ。
- 130 (539 行): `progressKey` が空になるのは `onProgress` が nil のときだけで、そのとき 515 行の登録も行われない
  (登録は同じ `progressKey.len > 0` で守られ、`progressCallbacks` はこのモジュールだけが書く)。
  登録されていない鍵 `""` の `del` は何もしない。

#### 死んだ・冗長なコード (区分 4、リードの判断を待つ)

- 247 (405 行、`client.nim:405` の `failPending("the client was closed")`): この分岐に入るのは `state == mlsShutdown` のときで、
  それは `close()` が `state` を設定したあとか 400 行の `McpTransportClosedError` の分岐のあとだけ。
  `close()` は `state` を設定した直後に、`await` を挟まず自分で `failPending("the client was closed")` を呼ぶ。
  `beginRequest` は `ensureOpen` で shutdown 中の新規要求を断るので、受信ループがここに来るとき表は空である。
  変異を当てても `test_client_requests` は落ちなかった。この行を消すと `return` だけが残る (`lastTransportError` を残さない効果は `return` が持つ)。
- 260 (484 行、`client.nim:483-485` の `except CatchableError as e:` と中の `stderr.writeLine`): `sendNotification` は `{.async.}` で、
  async の手続きは例外を呼び出しの時点では投げず、返す future に載せる。つまり `try` の中で例外は起きず、この節には到達しない。
  失敗は直後の `cancelling.addCallback` (486-489 行) が扱う。`try`/`except` ごと消せる。

### 見つかった欠陥 (区分 5)

`startRequest` (client.nim:442 付近): `await (started.sent or started.response)` の `or` は、結合する future の既存のコールバックを消す
(Nim 2.2.8 の `asyncfutures.nim` の `callback=` は `clearCallbacks` してから登録する)。そのため、`beginRequest` が `sent` に付けた
「送信が失敗したら応答を失敗させて表から外す」コールバックが外れる。送信が失敗すると `startRequest` は正しく例外を投げるが、
要求は `pendingRequests` に残り続ける (応答が来ない future が溜まる)。購読の `listen` も `startRequest` 経由。
修正は `try`/`except` で表から外して再送出する小さなもの。テストは先に書き、落ちるのを見てから直した。コミット `fix(client): startRequest unregisters a request whose sending failed`。

### 足したもの

- テスト: `tests/test_subscriptions.nim` 4 件、`tests/test_client_requests.nim` 18 件 (新しい suite 4 つ、うち 2 つは 2026-07-28 のみ)、
  `tests/test_security_diagnostic_client.nim` 7 件。いずれも `-d:mcpDefaultProtocolVersion=2024-11-05` と `=2025-11-25` でも通る。
- テスト用の足場: `tests/loopback_transport.nim` に `endStream` (EOF)、`kind` の指定、送信の保留 (`holdSendsOf` と `sendGate`)、`brokenNotifications`、`cancelRequested`。
  `tests/client_peer.nim` の `startPeer` に `kind`。
- `tests/mutation/client.json` の `testCommand` の末尾に追記した 5 本 (追記のみ):
  `test_subscriptions`, `test_client_elicitation`, `test_trace_context`, `test_mrtr`, `test_param_headers_http`。
- `specs/tests.map` に追記した 4 行 (すべて `tests/test_subscriptions.nim`):
  MCP-SUBSCRIBE-9 の 2 行 (「without a callback of its own」「a second acknowledgment arrives」)、
  MCP-SUBSCRIBE-10 の 2 行 (「notifications/cancelled arrives without a request id」「over HTTP, when the client cancels it」)。
  `test_client_requests.nim` と `test_security_diagnostic_client.nim` の新しいテストは仕様 ID を持たない SDK の挙動で、対応表には足していない。

### 残っているもの

- 死んだコードの 2 件 (247 = 405 行、260 = 484 行)。リードが消すかどうかを決める。
- 同値の 3 件 (286, 287, 130) は理由を上に書いた。これ以外に、理由のない生き残りと「許容しない」の行はない。

## src/client/client.nim の 585 行以降

対象は mainline の先端 36a4c8a5 で `nim-muter` を流した結果(`tests/mutation/client.json`)のうち、`src/client/client.nim` の 585 行から後ろ(ヘッダー不一致の再試行、サーバー能力の解釈、`initialize`、`discover`、`connect`、`close`)。584 行までは `g2b-client-a` が担当する。

### 数字

ジョブ全体(8 ファイル):

| 総数 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 344 | 215 | 8 | 113 | 0 | 8 |

このうち `client.nim` の 585 行以降の生き残りは 48 件、`client.nim` の timeout は 7 件(585 行以降が 2 件、それより前が 5 件)。48 件の内訳は次のとおり。

| 区分 | 件数 |
|---|---|
| 1 equivalent | 6 |
| 2 detected elsewhere | 15 |
| 3 gap(テストを足した) | 26 |
| 4 dead code | 1 |
| 5 defect | 0 |
| 6 accepted | 0 |

(class 2 と 3 は、人手で変異を当てて、そのテストが落ちる(または止まる)のを見た。class 1 と 4 は手で当てず、理由を式から読み取った。)

### 生き残りの一覧

「検出するテスト」の列は、変異を当てた状態でそのテストが落ちる(または止まる)のを確かめたもの。`H` は `tests/test_param_headers_http.nim`、`E` は `tests/test_era_matrix.nim`、`X` は `tests/test_extensions.nim` を指す。

| id | 行 | 変異 | 元 → 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 172 | 585 | LOR | `… has(ftParameterHeaders) and kind != mtkStdio` → `or` | 3 | `or` にすると HTTP なら何を受けても true になり、成功した呼び出しのあとにも `tools/list` を読み直す。H「Given a tool call that the server answers, when it is sent over HTTP, then the client does not read the tool list again」 |
| 134 | 586 | ROR | `kind != mtkStdio` → `==` | 2 | H の既存の再試行テスト(「…lists the tools again and retries…」ほか)が落ちる。job に H を足した |
| 272 | 599 | SDL | `tools/list` 失敗の診断行 → `discard` | 3 | H「Given a header mismatch and a tool list that cannot be read…」が、診断行の存在と、相手の文章が制御文字を含まない 1 行になること(MCP-SEC-HTTP-7)を確かめる |
| 290 | 601 | RVR | `return false` → `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された (同じ行の BLR のために足したテスト)。 |
| 202 | 601 | BLR | `return false` → `return true` | 3 | 同上のテスト。一覧が読めないのに再試行して `calls == 2` になる |
| 135 | 604 | ROR | `name == toolName` → `!=` | 2 | H の既存の再試行テストが落ちる |
| 291 | 605 | RVR | `return true` → `return default` | 2 | 値は `false`(203 と同じ)。H の既存の再試行テストが落ちる |
| 203 | 605 | BLR | `return true` → `return false` | 2 | 同上 |
| 177 | 607 | LOR | `next.isNil or …` → `and` | 3 | `nextCursor` が無いとき `nil.kind` を読んで SIGSEGV。H「…a tool list without the tool…」(プロセスが落ちる) |
| 136 | 607 | ROR | `next.kind != JString` → `==` | 3 | H「…a tool listed on the second page…」「…whose nextCursor is not a string…」「…never ends…」 |
| 292 | 608 | RVR | `return false` → `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された (同じ行の BLR のために足したテスト)。 |
| 204 | 608 | BLR | `return false` → `return true` | 3 | H「…a tool list without the tool…」「…nextCursor is not a string…」が落ちる(再試行が起きる) |
| 270 | 610 | SDL | 100 ページ超過の診断行 → `discard` | 3 | H「…a server whose tool list never ends…」が診断行を確かめる |
| 293 | 612 | RVR | `return false` → `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された (同じ行の BLR のために足したテスト)。 |
| 205 | 612 | BLR | `return false` → `return true` | 3 | H「…never ends…」が落ちる(100 ページ読んだあとに再試行する) |
| 206 | 634 | BLR | `toolsListedAgain = false` → `true` | 2 | H の既存の再試行テストが落ちる |
| 208 | 640 | BLR | `toolsListedAgain = true` → `false` | 2 | 2 回目の拒否でも読み直しを繰り返して止まらない。H が止まる(timeout として検出される型) |
| 294 | 643 | RVR | `return response` → `return default` | 3 | 拒否を返さず空の応答を返す。H「…a tool list that cannot be read…」「…without the tool…」が落ちる(従来は一覧にツールがある場合しか通らなかった) |
| 179 | 644 | LOR | `not usesModernProtocol or result.isNone` → `and` | 2 | モダンで result が無い応答(エラー)で `result.get` に落ちる。H の既存の 2 回目の拒否のテストが落ちる |
| 273 | 656 | SDL | `inc rounds` → `discard` | 2 | 上限に達せず再試行が終わらない。`tests/test_mrtr.nim` の上限テストが止まる。job に足した |
| 137 | 657 | ROR | `rounds > maxInputRounds` → `>=` | 2 | `tests/test_mrtr.nim`「…when the limit is reached…」が `len == 4` で落ちる |
| 138 | 664 | ROR | `declared.kind != JString` → `==` | 2 | `X`「…both sides support the extension…」が落ちる。job に足した |
| 297 | 667 | RVR | `return response` → `return default` | 2 | 同上 |
| 182 | 748 | LOR | `not json.isNil and kind == JObject` → `or` | 3 | 配列の `capabilities` で `pairs` の表明が落ちる。X「Given a server whose capabilities are not an object…」 |
| 140 | 748 | ROR | `json.kind == JObject` → `!=` | 3 | オブジェクトのとき `additional` を読まない。X「…a capability the core does not define…」 |
| 183 | 751 | LOR | `name notin known and kind == JObject` → `or` | 3 | 核の能力が `additional` に入る。X「…does not define…」(`serverCapability("tools")` が none であること) |
| 141 | 751 | ROR | `settings.kind == JObject` → `!=` | 3 | 同上 |
| 142 | 753 | ROR | `other.len > 0` → `>=` | 3 | 空の `additional` が付く。X「…only capabilities the core defines…」 |
| 274 | 766 | SDL | `wire.parseServerInfo(node)` → `discard` | 2 | `tests/test_implementation_info.nim` が 3 件落ちる。job に足した |
| 185 | 791 | LOR | `code == … and not data.isNil and anyIt` の 1 つ目の `and` → `or` | 3 | silent なプローブのあと、別のコードで initialize を拒否し `data.supported` にモダンの版があると、2 回目の discover に進んでしまう。E「Given a peer silent to the probe that refuses initialize with another error…」 |
| 184 | 791 | LOR | 2 つ目の `and` → `or` | 3 | 同上 |
| 275 | 807 | SDL | `protocolVersionNegotiated` → `discard` | 2 | `tests/test_streamable_http.nim`「…falls back to initialize and calls a tool」が落ちる。job に足した |
| 299 | 824 | RVR | `return capabilities` → `return default` | 3 | `connect` は戻り値を捨てる。`tests/test_legacy_handshake.nim`「Given a client attached to a transport, when initialize is called…」 |
| 188 | 833 | LOR | `offered.isNil or kind != JArray` → `and` | 3 | `supported` が無い拒否で nil を読んで SIGSEGV。E「…as unsupported without naming versions…」 |
| 190 | 842 | LOR | `isModern(v) and (…)` → `or` | 3 | 旧版だけの一覧でも「モダンの選択」が出る。E「…naming only legacy versions…」「…lists only legacy versions…」 |
| 147 | 842 | ROR | `v > result.get` → `>=` | 1 | `v == result.get` のとき `result` に同じ値を入れ直すだけで、結果は変わらない |
| 209 | 864 | BLR | `var answered = false` → `true` | 1 | `answered` は直後の `try` で必ず代入される。代入しない経路は `return` か `raise` で抜ける |
| 301 | 873 | RVR | `return pvLegacy` → `return default` | 2 | `default(ProbeVerdict)` は `pvModern`(最初の列挙子)。`test_streamable_http`「…rejects the probe without a JSON-RPC body…」が落ちる |
| 279 | 876 | SDL | `pendingRequests.del(started.id)` → `discard` | 3 | 放棄したプローブが pending に残る。E「Given a transport that never finishes sending the probe…」が `pendingRequests.len == 0` を確かめる |
| 280 | 878 | SDL | `cancelRequest(started.id)` → `discard` | 3 | 同上のテストが `cancelled == @[プローブの id]` を確かめる |
| 149 | 890 | ROR | `attempt == 0` → `!=` | 3 | 拒否に挙がったモダンの版で 1 度やり直さない。E「…naming a modern version the client speaks…」「…twice…」 |
| 304 | 894 | RVR | `return pvLegacy` → `return default` | 3 | `pvModern` になり initialize が送られない。E「…naming only legacy versions…」 |
| 305 | 903 | RVR | `return pvLegacy` → `return default` | 3 | 同上。E「…a discover result that lists only legacy versions…」 |
| 152 | 910 | ROR | `identity.kind == JObject` → `!=` | 2 | `test_implementation_info`「…when the client discovers it…」が落ちる |
| 306 | 913 | RVR | `return pvModern` → `return default` | 1 | `default(ProbeVerdict)` が `pvModern` なので同じ値 |
| 307 | 914 | RVR | `return pvLegacy` → `return default` | 4 | ループ(`attempt` 0 と 1)の 2 周目は、すべての枝が `return` か `raise` で終わるので、ここには届かない。Nim が戻り値の定義を求めるための行 |
| 282 | 947 | SDL | `failPending("the client was closed")` → `discard` | 3 | ループが止まらない transport では待機中の要求が失敗しない。`tests/test_client_requests.nim`「Given a transport whose receive loop close() does not end…」(新しい足場 `tests/stuck_transport.nim`) |
| 283 | 949 | SDL | `await transport.close()` → `discard` | 3 | 同上のテストが `closeCalls == 1` を確かめる |

### timeout

timeout は検出に数える。待ち続ける理由を 1 行ずつ書く。

| id | 行 | 変異 | 待ち続ける理由 |
|---|---|---|---|
| 239 | 377 | SDL | `promise.complete(response)` が無いので、要求の Future が完了せず、タイムアウトまで待つ |
| 200 | 385 | BLR | `while true` が `false` になり、受信ループが回らず、応答が処理されない |
| 241 | 393 | SDL | `processResponse` を起動しないので、応答が捨てられる |
| 171 | 525 | LOR | `response or timer` が `and` になり、片方が完了しない限り待ち続ける |
| 170 | 525 | LOR | `response or timer or cancelled` が `and` になり、同上 |
| 178 | 637 | LOR | `not toolsListedAgain and refused` が `or` になり、2 回目の拒否でも一覧を読み直し続ける(208 と同じ型) |
| 281 | 923 | SDL | `processMessages` を起動しないので、プローブにも initialize にも応答が届かず `connect` が終わらない |

### 追加したもの

- `tests/test_param_headers_http.nim`: 再試行の止まる所(一覧が読めない・ツールが無い・`nextCursor` が文字列でない・一覧が終わらない)、2 ページ目にツールがある場合、成功した呼び出しでは読み直さないこと(MCP-HTTP-18、6 件)
- `tests/test_extensions.nim`: `serverCapability` と `additional`(MCP-EXT-15、3 件、Scenario 追加)
- `tests/test_era_matrix.nim`: プローブの拒否とやり直し、旧版だけの一覧、版を挙げない拒否、silent なプローブのあとの別のエラー、放棄したプローブ(MCP-LIFECYCLE-14、7 件、Scenario 追加)
- `tests/test_legacy_handshake.nim`: `initialize` が能力を返す(MCP-LIFECYCLE-3 に 1 件と文を追加)
- `tests/test_client_requests.nim`: `close` が待機中の要求を失敗させ transport を閉じる(`specs/tests.map` に載せていない。同じ suite の他のテストも載せていないため)
- `tests/stuck_transport.nim`: 足場(受信ループが終わらず、`close()` が何もしない transport)
- `tests/mutation/client.json`: `test_param_headers_http`、`test_mrtr`、`test_extensions`、`test_implementation_info`、`test_streamable_http` を追加

`-d:mcpDefaultProtocolVersion=2024-11-05` と `=2025-11-25` でも `test_era_matrix`、`test_legacy_handshake`、`test_extensions` を通した。`test_client_requests` は 2024-11-05、`test_param_headers_http` は 2025-11-25 で通した。

### 残っているもの

- class 4: 307(914 行 `return pvLegacy`)。`discover` のループの外にある、届かない行。消すかどうかは lead が決める。
- accepted はない。
- 変異を当てて確かめなかったのは class 1 の 6 件(290, 292, 293, 147, 209, 306)と class 4 の 307。理由は式から読み取れるため。

## client.nim 以外 (content / roots / sampling / tools / utilities)

測定: `nim-muter`、ジョブ `tests/mutation/client.json`、mainline の 36a4c8a5 (2026-10-07)。
この記録は `src/client/` のうち `client.nim` 以外のファイルの生存変異 15 件の分で、`client.nim` の分は別の記録 (g2-client-core) にある。
`prompts.nim` と `resources.nim` に生存変異はない。

| ファイル | survived |
|---|---|
| content.nim | 4 |
| roots.nim | 2 |
| sampling.nim | 4 |
| tools.nim | 4 |
| utilities.nim | 1 |

### survived 15 件

分類は、1 = 同値、3 = 穴 (新しい外部仕様テストを足した)、6 = 受け入れ。
クラス 3 の行は、変異を手で当てて該当テストが落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは戻した)。
`nil` を `.kind` で読む変異は、テストが nil 参照で異常終了する形で検出される (どれも変異なしでは全件通るので、異常終了も検出として数える)。

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 70 | content.nim:48 | RVR | `return none(string)` → 既定値 | 1 | `Option[string]` の既定値は none で、元の戻り値と同じ。 |
| 52 | content.nim:76 | LOR | `node.isNil or node.kind != JObject` → `and` | 3 | resource オブジェクトのない埋め込み resource ブロックが、protocol error でなく nil 参照になる。`Given an embedded resource block without its resource object, when it is parsed, then McpProtocolError is raised` (test_client_operations) |
| 53 | content.nim:85 | LOR | 同上 (`parseContentItem`) | 3 | オブジェクトでない content ブロックが protocol error にならず、未知のブロックとして通る (nil は nil 参照)。`Given a content block that is not an object, when it is parsed, then McpProtocolError is raised` (test_client_operations) |
| 40 | content.nim:120 | ROR | `mimeType.len > 0` → `>= 0` | 3 | mimeType のない埋め込み resource を書き戻すと `"mimeType": ""` が付く。`Given an embedded resource without a mimeType, when it is written back, then no mimeType key is written` (test_client_operations) |
| 310 | roots.nim:21 | SDL | `requireNotConnected("the roots provider")` → 削除 | 3 | 接続後に roots provider を足しても拒まれず、サーバーに宣言していない capability になる。`Given a connected client, when a roots provider is set, then McpError is raised` (test_client_server_requests) |
| 313 | roots.nim:35 | SDL | `requireFeature(ftRootsListChanged, ...)` → 削除 | 3 | 2026-07-28 の接続でも `notifications/roots/list_changed` を送ってしまう。`Given a 2026-07-28 connection, when the client notifies that its roots changed, then McpUnsupportedError is raised and nothing is sent` (test_client_server_requests、デフォルト版が 2026-07-28 のときだけ実行される。ほかの版のビルドでは、その版に機能があるので検査の対象がない) |
| 108 | sampling.nim:69 | RVR | `return none(float)` → 既定値 | 1 | `Option[float]` の既定値は none で、元の戻り値と同じ。 |
| 87 | sampling.nim:76 | LOR | `params.isNil or params.kind != JObject` → `and` | 3 | params が nil の `parseSamplingRequest` が protocol error でなく nil 参照になる (オブジェクトでない非 nil の params は、変異ありでも `requiredArray` が同じ例外を出すので区別できない)。`Given params that are not an object, when they are parsed as a sampling request, then McpProtocolError is raised` (test_client_server_requests) |
| 111 | sampling.nim:177 | RVR | `return newJsonRpcErrorResponse(request.id, -32602, e.msg)` → 既定値 | 3 | `createMessageParamsProblems` を通ったあとで、型の誤り (temperature が文字列) が `parseSamplingRequest` で見つかる経路。invalid params (-32602) とフィールド名を確かめる。`Given a temperature that is not a number, when the server asks, then the client answers invalid params naming the field and the handler is not called` (test_client_server_requests)。既存の「壊れた params」のテストは maxTokens だけが欠けた形で、手前の検査で止まっていた。 |
| 107 | sampling.nim:182 | SDL | 「答えを送らなかった」の診断行 → 削除 | 3 | 内部エラーを返す理由が、ローカルの開発者に何も残らない。診断の全文でなく、「the sampling handler's answer was not sent」の句が stderr に出ることを確かめる。`Given a handler that answers toolUse without a tool_use block, when the server asks, then the client says on stderr that the answer was not sent` (test_client_sampling_tools、2025-11-25 以上のデフォルト版で実行) |
| 30 | tools.nim:54 | RVR | `return McpToolAnnotations()` → 既定値 | 1 | `annotationsOf` は annotations がないとき `McpToolAnnotations()` (全フィールド未設定) を返す。型の既定値は同じ値なので、観測できる差がない。 |
| 26 | tools.nim:98 | SDL | `toolOutputSchemas.del(tool.name)` → 削除 | 3 | 再取得した一覧で outputSchema がなくなったツールの結果を、古い schema で検査し続ける。`Given a tool listed with an outputSchema, when it is listed again without one, then its results are no longer checked` (test_structured_tool_output) |
| 20 | tools.nim:111 | BLR | `getBool(false)` → `getBool(true)` | 3 | isError のない結果がエラーとして読まれる (仕様の既定は false)。`Given a tool result without isError, when it is read, then isError is false` (test_client_operations) |
| 29 | tools.nim:124 | SDL | `requireTools("tools/call")` → 削除 | 3 | tools capability のないサーバーに tools/call を送ってしまう。`Given a server without the tools capability, when a tool is called, then McpUnsupportedError is raised and nothing is sent` (test_client_operations) |
| 336 | utilities.nim:33 | LOR | `completion.isNil or completion.kind != JObject` → `and` | 3 | `completion` のない答えが protocol error でなく nil 参照になる。`Given a completion answer without a completion object, when completing, then McpProtocolError is raised` (test_client_operations) |

### 追加したテストと仕様

- `tests/test_client_operations.nim` (suite `answers that do not have the shape the specification gives them`、6 件)、`tests/test_client_server_requests.nim` (4 件)、`tests/test_structured_tool_output.nim` (1 件)、`tests/test_client_sampling_tools.nim` (1 件)。
- `specs/content.feature` に MCP-CONTENT-FIELDS-2 を追加し、MCP-STRUCTOUT-5、MCP-COMPLETION-5、MCP-CLIENTREQ-1、MCP-CLIENTREQ-4 の Scenario に 1 行ずつ足した。`specs/tests.map` に対応を書いた。
- `tests/mutation/client.json` の `testCommand` は変更なし (4 つのテストファイルを既に含む)。
- 新しいテストは、デフォルト版 2024-11-05 と 2025-11-25 でも通ることを確かめた (版による有無はテスト側のガードに従う)。

### 前回の手による検証 (build/keep/g2-hand-verified.md) との対応

前回「穴」としたもののうち、この記録の範囲は 40 (mimeType)、111 (sampling params)、26 (outputSchema)、20 (isError)。すべてテストを足して検出に変えた。30 は同値と確かめた。

### 残っているもの

- 同値 (id 70, 108, 30) は上表の理由のとおり。
- id 313 のテストは、デフォルト版が 2026-07-28 のビルドでだけ実行される (その版でだけ機能が無い)。client ジョブはデフォルト版で走るので検出される。
- 他に未決のものはない。

## 測り直し (本線 76a08c6a、2026-10-10)

変異 346、検出 319、時間切れ 9、コンパイル不能 9、**生き残り 9** (前回 113)。7 件は前回も生き残っていて、この文書に分類と理由がある。新しく現れた 2 件:

| 場所 | 変異 | 分類 | 理由 |
|---|---|---|---|
| `cancel_token.nim:53` | SDL `result.complete()` → `discard` (すでに取り消されたトークンを見張る) | 2b | このジョブのテストからは届かない: `sendRequest` は取り消し済みのトークンを見張る前に断り、その間に await が無い。`listen` は要求の送信を待つので届く。`tests/test_subscriptions.nim` に「送信中に取り消されたトークン」のテストを足した (MCP-SUBSCRIBE-11)。変異を当てると `McpTimeoutError` で落ちる。このジョブは `test_subscriptions` を流さないので、ジョブの報告には残る |
| `client.nim:900` | SDL `raiseAssert "server/discover was probed twice without a verdict"` → `discard` | 4 | 2 回目の探りは、サーバーが何を答えても return かエラーで終わる。表明に届く入力は無い |
