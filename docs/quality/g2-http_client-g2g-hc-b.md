# G2 変異検出: http_client (g2g-hc-b の分担)

ジョブ `http_client` (測定コミット 36a4c8a5) の合計は 369 件: killed 173 / timeout 29 / survived 149 / compileError 18 / runError 0。
この文書は、そのうち `src/transport/http.nim` の 349〜572 行の生き残り 29 件 (報告書から数えた件数。依頼では 33 件とあった) と、`src/transport/http_compat.nim` の 6 件の計 35 件を扱う。
行番号は測定時のもの (本線の先端では `pumpAnswer` を足したため、postOnce より後ろは 9 行ずれている)。

分類の件数 (35 件): 別のテストが検出 (2) が 1、ギャップを埋めたもの (3) が 25、同値 (1) が 7、到達不能または冗長 (4) が 0、受容 (6) が 2。(2b) はなし。
別に、欠陥 (5) を 1 件見つけて直した (下記 `pumpAnswer`。生き残りの行ではなく、テストを書く途中で見つけたもの)。

全部の変異を手で当て、名前を挙げたテストが落ちるのを見てから戻した (class 3 と 2)。`pumpAnswer` の後の 188 は、当てても落ちないのを確かめた。

## 見つかった欠陥 (class 5)

`http.nim` の `postOnce`: イベントストリームで答えた要求は、ストリームが終わっても `inflight` の表に残っていた (JSON で答えた要求は `finally` で消える)。
閉じた接続が要求ごとに 1 つ溜まり、`cancelRequest` は「答えた要求には何もしない」と文書にあるのに、そのような要求の id を取り消し済みとして `abandoned` に入れた。
そのまま同じ id で次の要求が (応答なしにストリームが切れて) 失敗すると、ストリーム切断のエラーが握りつぶされ、呼び出し側が返事を待ち続ける。
落ちるテストを先に書き (`Given a request whose answer was an event stream, when the client cancels it afterwards and sends the id again, ...`)、`pumpAnswer` でストリームが終わったときに表から消すようにした。コミット `fix(transport): forget a request whose event stream has ended`。

## 一覧

「検出するテスト」の `S` は `tests/test_http_client_streams.nim`、`L` は `tests/test_http_sse_legacy.nim`、`P` は `tests/test_param_headers_http.nim`、`T` は `tests/test_streamable_http.nim`、`A` は `tests/test_auth_failure.nim`。いずれも "(mutation review, g2g-hc-b)" の suite にある。

| id | file:line | mutator | original → replacement | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 136 | http.nim:349 | BLR | `t.listening = true` → `false` | 3 | initialized を 2 回言うと GET が 2 本開く。S "a client that says initialized twice ..." |
| 83 | http.nim:372 | ROR | `key.len > 0` → `>= 0` | 6 | 通知の POST で `inflight[""]` が残る。見えるのは `cancelRequest("")` だけで、SDK のクライアントは空の id を作らない。受容 (下記) |
| 84 | http.nim:379 | ROR | `key.len > 0` → `>= 0` | 1 | `inflight` に無い `""` を `del` するだけ。372 の条件があるので `""` は入っていない |
| 85 | http.nim:406 | ROR | `key.len > 0` → `>= 0` | 1 | 同上 |
| 176 | http.nim:380 | SDL | `t.inflight.del key` → `discard` | 3 | 接続後に失敗した要求を取り消すと id が取り消し済みで残る。S "a request that failed after the connection was made ..." |
| 177 | http.nim:383 | SDL | `t.abandoned.excl key` → `discard` | 3 | 無言のサーバーに対する取り消しの後、同じ id が silenced される。S "a request cancelled while the server was silent ..." |
| 178 | http.nim:393 | SDL | `t.track response` → `discard` | 3 | 閉じても POST のストリームが閉じない。S "a request whose event stream is open, when the transport closes ..." |
| 180 | http.nim:402 | SDL | `t.abandoned.excl key` → `discard` | 3 | 本文の途中で取り消すと id が残る。S "a request cancelled while its JSON body is arriving ..." |
| 181 | http.nim:408 | SDL | `response.close()` → `discard` | 3 | 本文が無い答え (202) では読み取りが接続を閉じない。S "a server that answers a notification with 202 and an empty body ..." |
| 182 | http.nim:407 | SDL | `t.inflight.del key` → `discard` | 3 | 答えた後の取り消しが id を silenced にする。S "a request whose answer was a JSON body ..." |
| 184 | http.nim:419 | SDL | `challenged.wwwAuthenticate.add value` → `discard` | 2 | `tests/test_auth_client_flow.nim` が落ちる ("a scope in the challenge and version 2025-06-18": resource_metadata が見つからず McpAuthorizationError)。ジョブの testCommand に足した |
| 87 | http.nim:424 | ROR | `text.len > 0` → `>= 0` | 1 | 空の本文は `parseJson("")` が例外を出し、直後の `except` が `nil` にする。結果は条件が偽のときと同じ |
| 188 | http.nim:452 | SDL | `t.inflight.del requestId` → `discard` | 1 | `pumpAnswer` を足した後は、取り消された要求の表の項目は 380 行・407 行・`pumpAnswer` のどれかが必ず消す。`abandoned` は集合なので、同じ id の 2 回目の取り消しは何も変えない。当てても全部のテストが通ることを確認した |
| 88 | http.nim:464 | ROR | `retries >= MaxAuthRetries` → `>` | 3 | 4 回目の再試行を許す。A "a hook that always says it improved things ... three times" |
| 138 | http.nim:468 | BLR | `var retry = false` → `true` | 1 | 直後の `try` は `retry` に必ず代入するか、例外で抜ける |
| 213 | http.nim:484 | RVR | `return false` → `<return default>` | 1 | `bool` の既定値は `false` |
| 139 | http.nim:484 | BLR | `false` → `true` | 3 | `_meta` に版が無い・文字列でない呼び出しにも Mcp-Param が付く。P "a call that does not name 2026-07-28 ..." |
| 124 | http.nim:486 | LOR | `parsed.isSome and ...` → `or` | 3 | 版 2025-11-25 の呼び出しに付く。知らない版では `parsed.get` が UnpackDefect。P 同上 |
| 126 | http.nim:493 | LOR | `name.isNil or kind != JString` → `and` | 3 | 名前の無い tools/call で nil を参照して落ちる (テストプロセスがクラッシュ)。P "a 2026-07-28 tools/call without a tool name ..." |
| 196 | http.nim:519 | SDL | `t.toolListIds.excl idKey(...)` → `discard` | 3 | 失敗した tools/list の id が残り、別の要求の答えが一覧として読まれる。P "a tools/list that failed ..." |
| 127 | http.nim:535 | LOR | `and not isModern(version)` → `or` | 3 | 2024-11-05・2025-03-26・2026-07-28 の通知に MCP-Protocol-Version が付く。T "versions without the header ..." |
| 203 | http.nim:557 | SDL | `stderr.writeLine(... "timed out")` → `discard` | 6 | DELETE の応答待ち 5 秒 (`DeleteTimeoutMs`) が過ぎたときの 1 行。見るには 5 秒待つテストになり、診断の文面だけを検査する。受容 |
| 202 | http.nim:560 | SDL | `response.close()` → `discard` | 3 | 本文の無い DELETE の答えで接続が閉じない。S "a server that answers DELETE with 204 and no body ..." |
| 128 | http.nim:561 | LOR | `not is2xx and != Http405` → `or` | 3 | 204・405 でも記録される。S "a server that answers DELETE with 204 or 405 ..." |
| 93 | http.nim:561 | ROR | `!= Http405` → `==` | 3 | 500 を記録せず 405 を記録する。S "... DELETE with 500 ..." と "... 204 or 405 ..." |
| 204 | http.nim:562 | SDL | `stderr.writeLine(... answered HTTP ...)` → `discard` | 3 | S "a server that answers DELETE with 500 ..." |
| 205 | http.nim:564 | SDL | `stderr.writeLine(... failed: ...)` → `discard` | 3 | S "a server that drops the connection on DELETE ..." |
| 207 | http.nim:571 | SDL | `response.close()` → `discard` | 3 | `close()` が開いているストリームを閉じない。S "a request whose event stream is open, when the transport closes ..." |
| 206 | http.nim:572 | SDL | `t.streams.setLen(0)` → `discard` | 1 | `close()` 以後に `t.streams` を読むのは、ストリームを読み終えた `untrack` の `find` と `delete` だけで、閉じた応答を探しても結果は変わらない。`closed` が立っているので `close()` は 2 度目は何もしない |
| 50 | http_compat.nim:70 | SDL | `sendFirst(... sendNotification ...)` → `discard` | 3 | 通知がどこにも送られない。L "a server of the old transport, when the client sends a notification after falling back ..." と "a version agreed through the wrapper ..." |
| 51 | http_compat.nim:74 | SDL | `sendFirst(... sendResponse ...)` → `discard` | 3 | L "... answers a request after falling back ..." |
| 53 | http_compat.nim:85 | SDL | `t.streamable.protocolVersionNegotiated(version)` → `discard` | 3 | 合意した版が Streamable HTTP に届かない。L "a version agreed through the wrapper ..." と "a Streamable HTTP server that issued a session ..." |
| 56 | http_compat.nim:89 | SDL | `t.decided.fail(...)` → `discard` | 3 | 選ぶ前に閉じても待っている receive が終わらない。L "a wrapper that has not decided ..." |
| 54 | http_compat.nim:90 | SDL | `await t.streamable.close()` → `discard` | 3 | セッションの DELETE が送られない。L "a Streamable HTTP server that issued a session ..." |
| 55 | http_compat.nim:91 | SDL | `await t.legacy.close()` → `discard` | 3 | 旧方式の SSE ストリームとサーバー側のセッションが閉じない。L "a server of the old transport, when the wrapper closes ..." |

(同じ条件に両側から当てる 128 と 93 は、204/405 と 500 の 2 つのテストで分けて落ちる。)

## 確認したこと

- 検出するテストは、変異を当てた状態で 1 本ずつ (1 回の実行で 1 つの変異) 流し、落ちるのを見た。落ちた後は `jj restore` で戻した。
- 変更した 5 つのテストファイルは、既定版 2026-07-28、`-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25` で全部通る (`test_param_headers_http.nim` は 2025-11-25 のみ。2024-11-05 では新しい suite が `SpeaksModern` の外れで飛ばされるのは隣と同じ)。
- `tests/test_spec_coverage.nim` が通る。

## 残っているもの

- 83 (受容): `key.len > 0` は「id が無い (通知)」を「空の id」と区別しない。空文字列の id は JSON-RPC では正しいが、SDK のクライアントは作らず、`cancelRequest("")` を呼ぶ箇所もない。空の id の要求は取り消せない。直すなら条件を `not requestId.isNil` にする (3 か所)。リードの判断に任せる。
- 203 (受容): DELETE が 5 秒返らないときの診断 1 行。
- リードへ (本分担の外、`http.nim` 313〜323 行の `pump` と `resume`): (1) 通知の POST がイベントストリームで答えられると、`pump` の末尾 `t.abandoned.excl idKey(requestId)` が `requestId` の nil を引く疑い (読んだだけで、テストで再現していない)。(2) イベント id を受け取った後に取り消した要求は、`resume` が `Last-Event-ID` つきで GET をもう一度開き、取り消したはずの答えを配送し得る疑い (同じく未再現)。
