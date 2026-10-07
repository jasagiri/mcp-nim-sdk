# G2 変異検出: http_server (担当 g2f-hs-c)

`http_server` ジョブ全体の測定値 (commit 36a4c8a5): 変異 391 件、killed 218、timeout 64、survived 94、compileError 15、runError 0。

この文書は、そのうち次の範囲の生き残り 37 件の記録である。残りは他の担当 (`http_server.nim` の 229-668 行と 679-1036 行) が書く。

- `src/transport/http_server.nim` の測定時の行 1050-1175 (24 件)
- `src/transport/sse_stream.nim` の全部 (13 件)

測定後に両ファイルが変わった (待ちを `or` から `firstOf` / `Doorbell` へ)。このため `sse_stream.nim` の行番号は、測定時の値に 1 を足したものが現在の行である (`import ./first_of` の 1 行)。`serveStream` の中の 161 / 177 / 182 行は、それぞれ現在の 169 / 189 / 194 行に当たる。`http_server.nim` の 1050 行以降は、現在の行が 1 行ずれている。変異の文面で照合し、すべて現在のファイルに同じ文が残っている (「置き換えられた文」はなかった)。

## 結果

| クラス | 件数 |
|---|---|
| 1 同値 | 2 |
| 2 別のテストで検出 | 12 |
| 3 穴 (テストを足して検出を確認) | 20 |
| 4 死んだコード | 0 |
| 5 欠陥 | 0 |
| 6 許容 | 3 |

クラス 2 の 12 件は `tests/test_http_documents.nim` が検出する。このテストはジョブの `testCommand` に入っていなかったので、`tests/mutation/http_server.json` に足した。

クラス 3 は、すべて変異を手で当てて、名前を挙げたテストが落ちることを見て、`jj restore` で戻した。確認できていないものはない。

## 一覧

「検出するテスト」は、変異を当てて落ちるのを見たもの。記号は `D` = `tests/test_http_documents.nim`、`S` = `tests/test_http_streams.nim`、`L` = `tests/test_http_sse_legacy.nim`、`H` = `tests/test_streamable_http.nim`、`X` = `tests/test_security_http.nim`。

### http_server.nim (serveDocument)

| id | 行 (測定時) | 変異 | 元 → 変異 | クラス | 理由と検出するテスト |
|---|---|---|---|---|---|
| 338 | 1050 | SDL | `await req.respondEmpty(Http204, extra)` → `discard` | 2 | 応答が出ず、D の「HEAD or a preflight」が待ち続ける (timeout)。 |
| 193 | 1054 | LOR | `wanted.isSome and etag.len > 0` → `or` | 2 | `If-None-Match` のない GET で `wanted.get` が失敗する。D の認可フックの GET などが落ちる。 |
| 119 | 1054 | ROR | `etag.len > 0` → `>= 0` | 3 | ETag のない文書への `If-None-Match: *` が 304 になる。D (g2f-hs-c) の「document without an ETag」が落ちる。 |
| 120 | 1057 | ROR | `tag == "*"` → `!=` | 2 | D の「client that holds the document's ETag」(`*` が 304 にならない)。 |
| 195 | 1057 | LOR | 1 つ目の `or` → `and` | 2 | 同じテスト (`*` と `"v1"` が 304 にならない)。 |
| 121 | 1057 | ROR | `tag == etag` → `!=` | 2 | 同じテスト (古い ETag が 304 になる)。 |
| 194 | 1057 | LOR | 2 つ目の `or` → `and` | 2 | 同じテスト。 |
| 122 | 1057 | ROR | `tag == "W/" & etag` → `!=` | 2 | 同じテスト (古い ETag が 304 になる)。 |
| 222 | 1058 | BLR | `named = true` → `false` | 2 | 同じテスト (304 が出ない)。 |
| 123 | 1060 | ROR | `etag.len > 0` → `>= 0` | 3 | ETag のない文書に空の `ETag` ヘッダが付く。D (g2f-hs-c) が `ETag` の不在を確かめて落ちる。 |
| 339 | 1061 | SDL | `headers.add ("ETag", etag)` → `discard` | 2 | D の「HEAD or a preflight」と最初のテストが `ETag` を読んで落ちる。 |
| 340 | 1063 | SDL | `respondEmpty(Http304, headers)` → `discard` | 2 | 304 が出ず D の ETag のテストが待ち続ける (timeout)。 |
| 124 | 1068 | ROR | `reqMethod == HttpHead` → `!=` | 2 | GET の本文が空になる。D の最初のテスト (本文 `{"a":1}`) と g2f-hs-c のテストが落ちる。 |
| 342 | 1071 | SDL | `respondEmpty(Http405, ...)` → `discard` | 2 | 405 が出ず D の「POSTs or DELETEs」が待ち続ける (timeout)。 |

### http_server.nim (経路の振り分け、handle、start)

| id | 行 (測定時) | 変異 | 元 → 変異 | クラス | 理由と検出するテスト |
|---|---|---|---|---|---|
| 125 | 1078 | ROR | `legacySsePath.len > 0` → `>= 0` | 3 | SSE のパスを空にしても `/messages` が生きて、POST が 404 でなく 400 になる。L (g2f-hs-c) の「switched off ... messages path」。 |
| 196 | 1078 | LOR | `len > 0 and speaks(ftHttpSse)` → `or` | 3 | 同じテスト (既定の版では `speaks` が真なので、空のパスの扱いが変わる)。 |
| 350 | 1118 | SDL | `respondEmpty(Http405, {"Allow": "POST"})` → `discard` | 3 | `/messages` への GET が答えられず待ち続ける (timeout)。L (g2f-hs-c) の「messages path ... GET」。 |
| 356 | 1135 | SDL | `req.client.close()` (書き込み失敗) → `discard` | 6 | 下の「残っているもの」を参照。 |
| 357 | 1138 | SDL | `stderr.writeLine("[mcp-http-server] ...")` → `discard` | 3 | 失敗が log に残らず握りつぶされる。X (g2f-hs-c) が stderr を取り、`[mcp-http-server] ValueError: end callback failed` を確かめて落ちる。 |
| 358 | 1140 | SDL | `respondEmpty(Http500)` → `discard` | 3 | 500 が出ず、X (g2f-hs-c) が待ち続ける (timeout)。 |
| 359 | 1142 | SDL | `req.client.close()` (500 の書き込み失敗) → `discard` | 6 | 下の「残っているもの」を参照。 |
| 366 | 1170 | SDL | `await sleepAsync(50)` → `discard` | 6 | 下の「残っているもの」を参照。 |
| 367 | 1174 | SDL | `t.listen()` (start 内) → `discard` | 3 | `start` の後も `port` が 0 のまま。H (g2f-hs-c) の「start is called」が落ちる。 |
| 368 | 1175 | SDL | `await t.serve()` (start 内) → `discard` | 3 | `start` がすぐ終わる。同じテストの `not running.finished` が落ちる。 |

### sse_stream.nim

| id | 行 (測定時) | 変異 | 元 → 変異 | クラス | 理由と検出するテスト |
|---|---|---|---|---|---|
| 49 | 66 | RVR | `return false` → `<return default>` | 1 | `bool` の既定値は `false` で、変異後の文と同じになる。 |
| 22 | 66 | BLR | `return false` の `false` → `true` | 3 | 終わったストリームへの `push` が真を返す。S (g2f-hs-c) の「finished stream ... refused」。 |
| 23 | 72 | BLR | 末尾の `true` → `false` | 3 | 受け付けた `push` が偽を返す。同じテストと「remembers its last two of three」が落ちる。 |
| 5 | 86 | ROR | `dash <= 0` → `< 0` | 3 | `-5` が空のストリーム id の event id になる。S (g2f-hs-c) の「not the id of an event」。 |
| 50 | 87 | RVR | `return none(...)` → `<return default>` | 1 | `Option` の既定値は `none` で、変異後の文と同じになる。 |
| 7 | 95 | ROR | `events.len > 0` → `>= 0` | 3 | 空のストリームで `events[0]` を読んで落ちる。S (g2f-hs-c) の「has sent nothing」。 |
| 8 | 96 | ROR | `seqNo >= oldest - 1` → `>` | 3 | 最後に忘れたイベントの直後からの再開が拒まれる。S (g2f-hs-c) の「remembers its last two of three」と「has sent nothing」。 |
| 3 | 96 | AOR | `oldest - 1` → `oldest + 1` | 3 | 同じ 2 つのテスト。 |
| 9 | 96 | ROR | `seqNo < nextSeq` → `<=` | 3 | まだ出していないイベントの後からの再開が通る。同じ 2 つのテスト。 |
| 35 | 106 | SDL | `armWatch(client, gone)` (再装填) → `discard` | 3 | 余分な 1 バイトを送ってから閉じた相手を見失う。S (g2f-hs-c) の「stray byte」(timeout 内に終わらない)。 |
| 12 | 161 | ROR | `batch.len > 0` → `>= 0` | 3 | 何も書かなかった接続が `written` を進める。S (g2f-hs-c) の「no connection has written」(`writtenUpTo` が 0 でなく 2)。 |
| 47 | 177 | SDL | keep-alive の `send` → `discard` | 3 | コメントが届かない。S (g2f-hs-c) の「keep-alive period passes」。 |
| 48 | 182 | SDL | `finally` の `req.client.close()` → `discard` | 3 | 接続を保つ HTTP/1.1 の相手の接続が、ストリームの終わりに閉じない。S (g2f-hs-c) の「server closes the connection of a client that asked to keep it」。 |

## 足したもの

- `tests/test_http_documents.nim`: 1 件 (ETag のない文書)
- `tests/test_http_sse_legacy.nim`: 2 件 (SSE を切ったときの `/messages`、`/messages` への GET)
- `tests/test_streamable_http.nim`: 1 件 (`start`)
- `tests/test_security_http.nim`: 1 件 (内部の失敗は 500 と log)
- `tests/test_http_streams.nim`: 8 件 (ストリームの緩衝、`serveStream` の keep-alive、接続の閉じ方、見失わないこと、`written`)
- Scenario: `MCP-HTTPSTREAM-g2f-hs-c-1`, `-2`、`MCP-HTTPSSE-g2f-hs-c-1`、`MCP-HTTP-g2f-hs-c-1`, `-2`、`MCP-SEC-g2f-hs-c-1`
- `tests/mutation/http_server.json`: `testCommand` に `tests/test_http_documents.nim` を足した。

版の確認: 足したテストを持つ 5 ファイルを、既定の版、`-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25` で流し、すべて合格した (`test_http_documents.nim` は版に依らない)。

## 残っているもの

- 356 / 359 (許容): 書き込みに失敗した接続を `close()` する文。相手はすでに去っており、クライアントから見える違いは出ない。違いは記述子を手放す時機だけである。書き込みの失敗を決まった形で起こす方法が見つからなかった (相手が閉じた後の最初の書き込みは、カーネルの緩衝に入って成功することが多い)。記述子の数を測る検査は不安定になるので書かなかった。
- 366 (許容): 記述子が上限に近いときの `sleepAsync(50)`。この文を消すと、枝が await のない空回りになり、イベントループが止まる。ただし枝に入るには、プロセスが `RLIMIT_NOFILE` の 5 つ手前まで記述子を使っていなければならない。`setrlimit` で上限を下げて試したが、下げた状態でソケットを作ると macOS の kqueue 側で `Bad file descriptor` になり、安定したテストにならなかったので外した (コミットしていない)。`asynchttpserver` の `maxFDs` は非公開で、トランスポートからは変えられない。公開された口を足すなら `http_server.nim` の変更になるので、リードの判断に任せる。
- クラス 4 (死んだコード) と 5 (欠陥) はなかった。
