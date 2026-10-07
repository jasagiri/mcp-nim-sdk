# G2 変異検出: server ジョブ、server.nim 1302 行以降と timeout (g2c-server-c の分担)

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5。担当は `src/server/server.nim` の 1302 行から末尾の生き残りと、server.nim の timeout 2 件 (id 239 と 296)。
総数はリードが g2-server.md にまとめる。ここでは担当分の 55 件 + timeout 2 件を 1 件ずつ記録する。

分類の件数 (timeout 2 件を含む 57 行):

| 分類 | 件数 |
|---|---:|
| 1 | 4 |
| 2 | 24 |
| 3 | 19 |
| 4 | 1 |
| 6 | 9 |

分類 2 と 3 は、変異を 1 件ずつ手で当ててテストが落ちる (または止まる) ことを確かめた (id 239 の行は 917 行目)。分類 1 は式と不変条件から読んだ。

| id | file:line | mutator | 原文 → 変異 | 分類 | 理由 | 検出するテスト |
|---:|---|---|---|---|---|---|
| 274 | server.nim:1302 | SDL | `stderr.writeLine(...)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 275 | server.nim:1303 | SDL | `newJsonRpcErrorResponse(...)` → discard | 2 | `input_required` を返せない場合の内部エラー応答が空になる | test_mrtr: handler asks for nothing など |
| 406 | server.nim:1305 | RVR | `return defect(...)` → 既定値 | 2 | 版が複数往復を持たないときの内部エラー | test_mrtr: version without multi round-trips |
| 407 | server.nim:1307 | RVR | `return defect(...)` → 既定値 | 2 | 許されないメソッドの内部エラー | test_mrtr: request that does not support input_required |
| 408 | server.nim:1310 | RVR | `return defect(problem.get)` → 既定値 | 2 | 何も尋ねない handler の内部エラー | test_mrtr: handler that asks for nothing |
| 72 | server.nim:1312 | ROR | `payloadProblems.len > 0` → `>= 0` | 2 | 常に真になり正常な尋ね返しが内部エラーになる | test_mrtr: tool that needs input |
| 409 | server.nim:1313 | RVR | `return defect(payloadProblems.join)` → 既定値 | 2 | 規則違反の input request の内部エラー | test_mrtr: input request breaks the rules |
| 73 | server.nim:1315 | ROR | `missing.len > 0` → `>= 0` | 2 | 常に真になり正常な尋ね返しが capability 欠落になる | test_mrtr: tool that needs input |
| 410 | server.nim:1318 | RVR | `return newJsonRpcErrorResponse(...)` → 既定値 | 2 | capability 欠落エラー | test_mrtr: client that did not declare |
| 273 | server.nim:1325 | SDL | `newJsonRpcResponse(...)` → discard | 2 | input_required の応答そのもの | test_mrtr: tool that needs input |
| 413 | server.nim:1342 | RVR | `return inputRequiredResponse(...)` → 既定値 | 2 | `McpInputRequired` の応答 | test_mrtr: tool that needs input |
| 416 | server.nim:1359 | RVR | `return none(...)` → 既定値 | 1 | `Option[JsonRpcResponse]` の既定値は none で、同じ値を返す |  |
| 417 | server.nim:1361 | RVR | `return some(error)` → 既定値 | 3 | resultType が文字列でないときの内部エラーを確かめるテストが無かった | test_extensions: Given a tool whose result has a resultType that is not a string |
| 418 | server.nim:1365 | RVR | `return none(...)` → 既定値 | 1 | 同上 (既定値が none) |  |
| 419 | server.nim:1370 | RVR | `return some(internal error)` → 既定値 | 2 | どの拡張も定義しない resultType の内部エラー | test_extensions: handler that returns a resultType no extension defines |
| 420 | server.nim:1375 | RVR | `return some(missing capability)` → 既定値 | 3 | 宣言していない拡張の resultType への -32021 が未検査だった | test_extensions: Given a tool whose result carries an extension's resultType ... |
| 276 | server.nim:1376 | SDL | 末尾の `none(...)` → discard | 1 | `result` の既定値が none で、同じ値を返す |  |
| 425 | server.nim:1401 | RVR | `return newJsonRpcErrorResponse(...)` → 既定値 | 2 | inputResponses / requestState の型違いは invalid params | test_mrtr: inputResponses or requestState of the wrong type |
| 150 | server.nim:1413 | LOR | `isNil or kind != JObject` → `and` | 3 | handler の結果が object でない (nil / 配列) とき 2026-07-28 は内部エラー。標準の handler は途中で検査済みで、この守りに届くのはフィルターなどが差し替えた結果だけだった | test_request_hooks: Given a filter that turns a 2026-07-28 result into something that is not an object |
| 426 | server.nim:1414 | RVR | `return newJsonRpcErrorResponse(...)` → 既定値 | 3 | 同上 | 同上 |
| 427 | server.nim:1418 | RVR | `return unusable.get` → 既定値 | 2 | 使えない resultType の応答を返す | test_extensions: handler that returns a resultType no extension defines |
| 281 | server.nim:1454 | SDL | `handling.addCallback(finished = true)` → 削除 | 3 | 応答済みの detached 要求に cancel しても ctx が cancelled にならない、が未検査だった | test_server_progress_cancel: Given a detached request that has been answered, when it is cancelled ... |
| 170 | server.nim:1454 | BLR | `finished = true` → false | 3 | 同上 | 同上 |
| 151 | server.nim:1457 | LOR | `not finished and not cancelled` → `or` | 3 | 2 回目の cancel と応答後の cancel が何も変えないことが未検査だった | test_server_progress_cancel: detached request ... cancelled twice / answered |
| 171 | server.nim:1458 | BLR | `ctx.cancelled = true` → false | 2 | tasks/cancel で tool が停止を知らされる | test_tasks_server: Given a working task, when cancelled, then ... the tool is told |
| 282 | server.nim:1460 | SDL | `ctx.cancelSignal.complete()` → discard | 2 | 同上 | test_tasks_server: Given a working task, when cancelled ... |
| 284 | server.nim:1471 | SDL | `cancelSignal.completesWith(settled)` → 削除 | 3 | 取り消された要求の待ちが、止められない handler の終了まで続く。transport への通知が handler の終了後になる | test_server_progress_cancel: Given a request in flight, when the client cancels it, then the transport is told at once ... |
| 286 | server.nim:1476 | SDL | 放棄した handler の `addCallback` → discard | 6 | コールバックの効果は中の診断行だけ。診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 288 | server.nim:1478 | SDL | `stderr.writeLine(cancelled ... ended with)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 287 | server.nim:1480 | SDL | `stderr.writeLine(... cancelled; no response sent)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 289 | server.nim:1486 | SDL | `stderr.writeLine(... failed with)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 79 | server.nim:1492 | ROR | `getOrDefault(key) == ctx` → `!=` | 3 | 同じ id が再利用されたとき、先の要求の終了が後の要求の登録を消してしまう | test_server_progress_cancel: Given a request id used again while the first request runs ... |
| 290 | server.nim:1493 | SDL | `server.inFlight.del(key)` → discard | 4 | 消さない効果は private な表 `inFlight` の肥大だけ。完了済みの項目は `cancelRequest` が finished で拒むので公開 API からは見えない。観測用の公開手続き (`subscriptionCount` の類) が無いと検査できない。リードに報告 (公開 API の追加になるため触れない) |  |
| 291 | server.nim:1495 | SDL | `transport.requestDropped(...)` → discard | 3 | 取り消した要求を transport が知らされることが未検査だった (SessionedTransport に記録を追加) | test_server_progress_cancel: transport is told at once |
| 296 | server.nim:1526 | SDL | `server.resolveResponse(...)` → discard (timeout) | 2 | timeout: 応答がサーバーの待ちに届かず、サーバー発の要求を待つテストが終わらない | test_server_requests など (timeout として検出済み) |
| 239 | server.nim:917 | SDL | `waiting.complete(response)` → discard (timeout) | 2 | timeout: 同上。待ちの future が完了しないので、答えを待つテストが終わらない | 同上 |
| 299 | server.nim:1532 | SDL | `server.cancelSession(session)` → discard | 3 | transport が閉じたとき処理中の要求が cancelled になることが未検査だった (待ちの失敗は `failPending(none)` が代行するので隠れていた) | test_server_progress_cancel: Given a transport that closes, when a request is in flight, then it is cancelled |
| 298 | server.nim:1533 | SDL | `failPending(none, e)` (McpTransportClosedError 節) → discard | 1 | 直前のループで `cancelSession` が全セッションの `failPending(some(session))` を済ませる。待ちの表の鍵のセッションは必ず `server.sessions` にある (`request` は operational なセッションにしか出さず、`endSession` は cancelSession の後で消す) ので、ここは常に空振り |  |
| 300 | server.nim:1536 | SDL | `failPending(none, e)` (CatchableError 節) → discard | 3 | transport が close 以外の失敗をしたとき、サーバーの待ちが失敗することが未検査だった (SessionedTransport に `breakDown` を追加) | test_server_requests: Given a transport that fails while the server waits ... |
| 301 | server.nim:1537 | SDL | `stderr.writeLine(transport loop ended with)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 304 | server.nim:1550 | SDL | `server.endSession(session)` → discard | 3 | transport がセッションを終えたとき、要求の cancel とクライアントの忘却が未検査だった | test_server_progress_cancel: Given a transport that ends a session ... |
| 307 | server.nim:1575 | SDL | `stderr.writeLine(could not send ... session)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 308 | server.nim:1593 | SDL | `await transport.sendNotification(notification)` → discard | 2 | 購読ストリームへの配信 | test_subscriptions: tool list changes ... tagged with its id |
| 309 | server.nim:1595 | SDL | `stderr.writeLine(could not send ... subscription)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 310 | server.nim:1606 | SDL | `deliverToSubscribers(...)` → discard (`notifySubscribers`) | 3 | 拡張が購読者に通知する公開手続きを呼ぶテストが無かった。変異すると nil の future を返し、テストは SIGSEGV で落ちる | test_subscriptions: Given an open subscription, when an extension notifies the subscribers ... |
| 312 | server.nim:1619 | SDL | `await deliverToSubscribers(...)` (deliverAll) → discard | 2 | list_changed が購読ストリームにも届く | test_subscriptions: tool list changes ... |
| 154 | server.nim:1642 | LOR | `resources.isSome and ...subscribe` → `or` | 3 | resources を宣言しないサーバーで notifyResourceUpdated が何も送らず、投げないことが未検査だった | test_request_hooks: Given a server that declared no tools, prompts or resources ... |
| 155 | server.nim:1660 | LOR | tools `isSome and listChanged` → `or` | 2 | listChanged 無しの tools では送らない | test_request_hooks: Given a list the server did not declare listChanged for ... |
| 156 | server.nim:1662 | LOR | prompts `and` → `or` | 3 | prompts / resources の同じ守りは tools でしか検査されていなかった | test_request_hooks: Given prompts and resources declared without listChanged ... |
| 157 | server.nim:1664 | LOR | resources `and` → `or` | 3 | 同上 | 同上 |
| 316 | server.nim:1668 | SDL | `deliverAll(...)` (notifyListChanged) → discard | 2 | params 付きの list_changed | test_request_hooks: notifyListChanged carries params |
| 174 | server.nim:1697 | BLR | `tornDown = true` → false | 3 | endSubscriptions を続けて 2 回呼んでも、取り消しと応答は 1 回だけであることが未検査だった | test_subscriptions: Given a stdio server that ends its subscriptions twice in a row ... |
| 82 | server.nim:1698 | ROR | `kind == mtkStdio` → `!=` | 2 | stdio だけが notifications/cancelled を送る | test_subscriptions: stdio ... notifications/cancelled |
| 321 | server.nim:1703 | SDL | `await sendNotification(cancelled)` → discard | 2 | 同上 | test_subscriptions: Given a stdio server, when it ends a subscription ... |
| 322 | server.nim:1705 | SDL | `stderr.writeLine(could not cancel subscription)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 320 | server.nim:1707 | SDL | `subscription.closed.complete()` → discard | 2 | listen の応答が返らず、テストが終わらない (止まる = 検出) | test_subscriptions: ends a subscription (止まる) |
| 84 | server.nim:1721 | ROR | `level >= known.logLevel.get` → `>` | 3 | クライアントが設定した水準そのものの配信が未検査だった | test_server_logging: Given a client whose level is error, when the server logs at error ... |

## ジョブへの追記 (tests/mutation/server.json の testCommand)

`test_mrtr` / `test_extensions` / `test_request_hooks` / `test_tasks_server` / `test_subscriptions` を末尾に追記した。

## 他の共有ファイルへの追記

- `tests/sessioned_transport.nim`: `dropped` と `requestDropped`、`breakDown` を追加。
- `specs/tests.map` と `specs/*.feature`: MCP-EXT-5、MCP-HOOKS-2 (新)、MCP-CANCEL-1/3/7 (7 は新)、MCP-SERVERREQ-6、MCP-LISTCHANGED-1、MCP-SUBSCRIBE-3/6、MCP-LOGGING-2 に行を追加。

## 残っているもの

- id 290 (`server.nim:1493`、分類 4): `inFlight` の肥大は公開 API から観測できない。`inFlight` の件数を返す公開手続きを足せば検査できる。リードの判断を待つ。
- id 296 と 239 (917 行) は timeout として検出済み。
- 診断行 (分類 6) の 9 件は文面だけの差で、許容した。
