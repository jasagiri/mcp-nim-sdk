# G2 変異検出: http_client ジョブ、sse_legacy.nim の分 (g2g-hc-d)

測定: `nim-muter`、ジョブ `tests/mutation/http_client.json`、本線の 36a4c8a5 (2026-10-07)。ジョブ全体は全変異 369 / killed 173 / timeout 29 / survived 149 / runError 0 / compileError 18。このファイルは、そのうち `src/transport/sse_legacy.nim` の生き残り 18 件の記録である (`http.nim`、`http_compat.nim`、`http_wire.nim` は別の担当)。

測定後に `sse_legacy.nim` は変わった。使われていない private の `port` (測定時の 49〜52 行) が消え、それより後ろは 5 行上がった。表の行番号は測定時のもので、現在の行は括弧に書いた。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 0 |
| 2 / 2b 他のテストで検出 | 0 |
| 3 穴 (テストを追加、全件で変異を当てて確認) | 14 |
| 4 死んだコード・冗長なコード | 4 (うち 2 件は測定後に関数ごと削除済み) |
| 5 欠陥 | 0 |
| 6 受け入れ | 0 |

追加したテストは `tests/test_http_sse_legacy.nim` 末尾の 2 つの suite (`... (mutation review, g2g-hc-d)`)。Scenario は `specs/http_sse.feature` の `MCP-HTTPSSE-g2g-hc-d-1` から `-6`。サーバー側の挙動 (接続を閉じたか) は、生のソケットで待ち受ける手書きのサーバーから観測する。

| id | file:line | mutator | original → replacement | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 3 | sse_legacy.nim:50 | ROR | `u.port.len > 0` → `>=` | 4 | `port` は呼び出し元が無く、`lxvnqzkz` で関数ごと削除済み。テストは足さない。 |
| 4 | sse_legacy.nim:51 | ROR | `u.scheme == "https"` → `!=` | 4 | 同上。 |
| 17 | sse_legacy.nim:55 (50) | LOR | `a.scheme == b.scheme and a.hostname... == b.hostname...` の `and` → `or` | 3 | 「scheme が違い host と port が同じ」「host が違い scheme と port が同じ」の端点を同一生成元として通してしまう。`Given an endpoint on the same host and port under another scheme ...` と `Given an endpoint on another host at the same port ...` が落ちる。 |
| 16 | sse_legacy.nim:55 (50) | LOR | 全体の 2 つ目の `and` (`... and a.port == b.port`) → `or` | 3 | port が同じなら他が違っても同一生成元になる。上の 2 件に加えて `Given an endpoint on the same host at another port ...` が落ちる (port だけが違う場合は `(A and B) or C` が真で、元は偽)。 |
| 19 | sse_legacy.nim:69 (64) | BLR | `t.streamEnded = true` → `false` | 3 | ストリームが終わった後に `receiveMessage` を呼ぶと、終了を知らされず永久に待つ。`Given a stream that ended some time ago, when the client then waits for a message, then McpTransportClosedError is raised at once` が落ちる (3 秒の上限で止まる)。 |
| 26 | sse_legacy.nim:99 (94) | SDL | `ready.fail(e)` → `discard` | 3 | 他の生成元の endpoint を拒否しても接続が失敗にならず、接続タイムアウトまで待つ。`Given an endpoint on another origin while the stream stays open, when the client connects, then it fails at once and says why` が落ちる (1.5 秒以内に理由つきで失敗することを確かめる)。 |
| 18 | sse_legacy.nim:100 (95) | LOR | `event.event in ["", "message"] and event.data.len > 0` の `and` → `or` | 3 | `message` 以外の種類の event (data は JSON ではない) を JSON として読んでストリームが落ちる。`Given events that are not messages ...` が落ちる。data の無い message event でも同じく落ちる (`Given message events without data ...`)。 |
| 12 | sse_legacy.nim:100 (95) | ROR | `event.data.len > 0` → `>= 0` | 3 | data の無い message event (`data:` だけの行。パーサーは data 欄が 1 つあれば空文字列の event として渡す) を `parseJson("")` に渡してストリームが落ちる。`Given message events without data ...` が落ちる。 |
| 13 | sse_legacy.nim:101 (96) | ROR | `event.data.len > t.maxResponseSize` → `>=` | 4 | 届かない。パーサーは `initSseParser(t.maxResponseSize, t.maxResponseSize)` で作られ、1 つの event の data/event/id 欄の `value.len + 1` の合計が上限を超えると `SseLimitError` を上げる (`event_stream.nim` の `takeLine`)。結合した data の長さは常にその合計より小さいので、`data.len` は上限以上になれず、この検査は `>` でも `>=` でも偽にしかならない。削除はリードの判断に任せる。 |
| 28 | sse_legacy.nim:108 (103) | SDL | `stderr.writeLine("[mcp-sse] event stream from ...")` → `discard` | 3 | 失敗したストリームが何も報告されなくなる。`Given a stream that fails on a message that is not JSON, when the client reads it, then it says so on stderr` が落ちる (stderr を一時ファイルに向けて、行の先頭と `failed with` を確かめる)。 |
| 29 | sse_legacy.nim:111 (106) | SDL | `finally` の `response.close()` → `discard` | 3 | ストリームが例外で終わったとき、クライアントが接続を閉じない。`Given a stream that fails on a message that is not JSON, when the client has read it, then it closes its end of the connection` が落ちる (サーバー側で EOF を観測)。 |
| 31 | sse_legacy.nim:113 (108) | SDL | `ready.fail(failure("... ended before it named an endpoint"))` → `discard` | 3 | endpoint を言わずに終わったストリームが接続タイムアウトまで待たせる。`Given a stream that ends before it names an endpoint, when the client connects, then it fails at once and says so` が落ちる。 |
| 34 | sse_legacy.nim:128 (123) | SDL | 2xx でない応答の後の `response.close()` → `discard` | 3 | 本文が空の応答 (`Content-Length: 0`) は `readAll` が終了済みと見なすだけで接続を閉じないので、この `close` が唯一の閉じ手。`Given a server answering the stream request with 404, when the client gives up, then it closes its end of the connection` が落ちる。 |
| 35 | sse_legacy.nim:132 (127) | SDL | Content-Type が event-stream でないときの `response.close()` → `discard` | 3 | 本文を読まずに諦めるので接続が残る。`Given a server answering the stream request with something that is no event stream, ...` が落ちる。 |
| 36 | sse_legacy.nim:138 (133) | SDL | endpoint が時間内に来なかったときの `response.close()` → `discard` | 3 | 諦めたのに読み取りの `readLoop` がストリームを開いたままにする。`Given a server that names no endpoint in time, when the client gives up, then it closes its end of the stream before it is closed itself` が落ちる (`close()` を呼ぶ前に確かめる)。 |
| 33 | sse_legacy.nim:140 (135) | SDL | `await ready` → `discard` | 4 | 冗長。`withTimeout` は、渡した future が失敗で終わったときは自分も同じエラーで失敗し (`asyncdispatch.nim` の `withTimeout`)、成功のときは `ready` は完了済みなので `await ready` は何も足さない。変異を当てても落ちるテストが無いことを確認した。削除はリードの判断に任せる。 |
| 39 | sse_legacy.nim:164 (159) | SDL | POST の `finally` の `response.close()` → `discard` | 3 | 本文が空の 202 は読み切っても接続が閉じないので、この `close` が唯一の閉じ手。`Given a POST the server answered, when the client has read the answer, then it closes its end of the POST connection` が落ちる。 |
| 44 | sse_legacy.nim:195 (190) | SDL | `close()` の `t.stream.close()` → `discard` | 3 | 閉じたクライアントのストリーム接続が残る。`Given a connected client, when it is closed, then it closes its end of the stream` が落ちる。 |

分類 3 の 14 件は、すべて変異を手で当ててから名前を挙げたテストが落ちることを見た (id 17、16、19、26、18、12、28、29、31、34、35、36、39、44)。当てた後は `jj restore` で戻し、`src/` に差分が残らないことを確かめた。変異を当てていない状態で `tests/test_http_sse_legacy.nim` は既定版、`-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25` のいずれでも 49 件が通る。`tests/test_spec_coverage.nim` も通る。

id 33 は分類 4 の確認として変異を当て、全件が通ることを見た。id 13 は上の理由 (パーサーの上限が先に働く) による読解で、変異を当てても何も落ちないことは自明なので当てていない。

## 残っているもの

- 分類 4 の 2 件は、削除するかどうかをリードが決める。`src/transport/sse_legacy.nim` の `await ready` (id 33、現在 135 行) と、`readLoop` の `event.data.len > t.maxResponseSize` の検査 (id 13、現在 96〜98 行)。同じ検査は `http.nim` の `readLoop` にもある (別の担当の範囲)。
- 受け入れとして残した変異は無い。
- 観察 (欠陥とは判断しなかった): endpoint が時間内に来ず `connect` が自分でストリームを閉じたとき、`readLoop` は `t.closed` がまだ偽なので、読み取りの失敗を `[mcp-sse] event stream ... failed with ...: Bad file descriptor` として stderr に書く。`close()` による意図した終了は報告しない、というコメントと同じ扱いが、`connect` の中の `response.close()` には及んでいない。テストの出力にこの行が出る。直すなら `t.closed` とは別に「自分で閉じた」を表す状態が要るので、リードに任せる。
- 既知で直さないもの: `sameOrigin` は port を書かれたまま比べる (`http://h:80/` は `http://h/` と別の生成元になる)。この件のために書いたテストは無い。この担当の生き残りに、既定 port の差でしか区別できないものは無かった。
