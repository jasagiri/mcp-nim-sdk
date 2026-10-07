# G2: client ジョブ、`src/client/client.nim` の 1〜584 行 (生き残りの記録)

測定日 2026-10-07。対象は mainline 先端 36a4c8a5 (jj change `owwryuxn`) の `nim-muter` 報告
(`tests/mutation/client.json`)。585 行以降は `g2-client-b` の担当で、リードが `g2-client.md` にまとめる。

## 数字 (client.nim の 1〜584 行に限る)

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

## 一覧

- 区分 2 の検出元は、`tests/mutation/client.json` に足した 5 本 (後述)。
- 区分 3 の検出元の「新」は、このラウンドで足したテスト。

| id | 行 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 212 | 225 | SDL | `pendingRequests.clear()` → 削除 | 3 | 失敗させた future が表に残る。`test_client_requests`「Given a pending request, when the server ends the stream, then it fails with McpConnectionClosedError and nothing stays registered as pending」(新) |
| 157 | 240 | LOR | `elicitation.isSome and has(ftElicitation)` → `or` | 2 | `test_client_elicitation`「Given a connection of a version before elicitation, when the server asks, then the client answers method not found」 |
| 218 | 273 | SDL | `logHandlerFailure(what)` → 削除 | 3 | `test_security_diagnostic_client`「Given a list-changed callback that raises, ...」(新)。例外を握りつぶさず、どのコールバックが何で落ちたかを stderr に出す |
| 219 | 280 | SDL | `subscriptions.del(id)` → 削除 | 2 | `test_subscriptions` の「stdio の client が cancel する」ほか 4 件が `subscriptions.len == 0` で落ちる |
| 220 | 283 | SDL | `ended.complete()` → 削除 | 2 | `test_subscriptions`「Given the server answers the listen request, ... then the stream ended gracefully」が `ended` を待って止まる |
| 286 | 294 | RVR | `return false` → `return default` | 1 | `default(bool)` は `false` で、値が同じ |
| 197 | 294 | BLR | `return false` → `return true` | 2 | `test_subscriptions`「Given a notification tagged with an unknown subscription id, ...」 |
| 117 | 295 | ROR | `method == AcknowledgedMethod` → `!=` | 2 | `test_subscriptions` の listen が acknowledgment を受け取れず落ちる (2 件) |
| 221 | 302 | SDL | `acknowledgement.complete()` → 削除 | 2 | `test_subscriptions`「Given a modern server, when the client listens, ...」が acknowledgment を待って落ちる |
| 287 | 303 | RVR | `return false` → `return default` | 1 | 294 と同じ |
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

### 同値 (区分 1)

- 286, 287: `return false` を `return default` にしても、`default(bool)` が `false` なので値が同じ。
- 130 (539 行): `progressKey` が空になるのは `onProgress` が nil のときだけで、そのとき 515 行の登録も行われない
  (登録は同じ `progressKey.len > 0` で守られ、`progressCallbacks` はこのモジュールだけが書く)。
  登録されていない鍵 `""` の `del` は何もしない。

### 死んだ・冗長なコード (区分 4、リードの判断を待つ)

- 247 (405 行、`client.nim:405` の `failPending("the client was closed")`): この分岐に入るのは `state == mlsShutdown` のときで、
  それは `close()` が `state` を設定したあとか 400 行の `McpTransportClosedError` の分岐のあとだけ。
  `close()` は `state` を設定した直後に、`await` を挟まず自分で `failPending("the client was closed")` を呼ぶ。
  `beginRequest` は `ensureOpen` で shutdown 中の新規要求を断るので、受信ループがここに来るとき表は空である。
  変異を当てても `test_client_requests` は落ちなかった。この行を消すと `return` だけが残る (`lastTransportError` を残さない効果は `return` が持つ)。
- 260 (484 行、`client.nim:483-485` の `except CatchableError as e:` と中の `stderr.writeLine`): `sendNotification` は `{.async.}` で、
  async の手続きは例外を呼び出しの時点では投げず、返す future に載せる。つまり `try` の中で例外は起きず、この節には到達しない。
  失敗は直後の `cancelling.addCallback` (486-489 行) が扱う。`try`/`except` ごと消せる。

## 見つかった欠陥 (区分 5)

`startRequest` (client.nim:442 付近): `await (started.sent or started.response)` の `or` は、結合する future の既存のコールバックを消す
(Nim 2.2.8 の `asyncfutures.nim` の `callback=` は `clearCallbacks` してから登録する)。そのため、`beginRequest` が `sent` に付けた
「送信が失敗したら応答を失敗させて表から外す」コールバックが外れる。送信が失敗すると `startRequest` は正しく例外を投げるが、
要求は `pendingRequests` に残り続ける (応答が来ない future が溜まる)。購読の `listen` も `startRequest` 経由。
修正は `try`/`except` で表から外して再送出する小さなもの。テストは先に書き、落ちるのを見てから直した。コミット `fix(client): startRequest unregisters a request whose sending failed`。

## 足したもの

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

## 残っているもの

- 死んだコードの 2 件 (247 = 405 行、260 = 484 行)。リードが消すかどうかを決める。
- 同値の 3 件 (286, 287, 130) は理由を上に書いた。これ以外に、理由のない生き残りと「許容しない」の行はない。
