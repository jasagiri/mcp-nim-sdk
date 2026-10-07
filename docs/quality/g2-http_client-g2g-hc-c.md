# G2 変異検出: http_client の `http_wire.nim` (g2g-hc-c)

`tests/mutation/http_client.json` の測定 (commit 36a4c8a5、jj change `owwryuxn`) のうち、`src/transport/http_wire.nim` の分。
`http.nim` / `http_compat.nim` / `sse_legacy.nim` は別の担当 (g2g-hc-a / b / d) が記録する。

| 項目 | 件数 |
|---|---|
| ジョブ全体の変異 | 369 |
| killed | 173 |
| timeout | 29 |
| survived | 149 |
| runError | 0 |
| compileError | 18 |
| うち `http_wire.nim` の survived | 51 |

`http_wire.nim` は測定の後で変わっている (読み取りと `close`・接続・応答ヘッダの待ちが `or` から `firstOf` に、`leftOpen` が読み取りごとの `interrupt` に)。
各変異は元の文とその周りで現在のファイルに対応付け、行は現在のもの (括弧内は測定時の行) で書く。

分類の内訳: class 3 (穴) 40、class 4 (冗長・到達不能) 5、class 1 (同値) 3、class 6 (受け入れ) 2、置換で消えた文 1。
class 2 / 2b は無い。リードが挙げた候補 (`test_security_address`、`test_security_icons`、`test_icon_fetch` ほか) を変異ありで走らせて確かめることはしていない: 各群を読解で分けた結果、群ごとに自前のテストを書く方が確実だったため。
class 5 (欠陥) は 2 件、下に書く。

## 欠陥 (class 5)

1. `src/transport/http_wire.nim` の `receive` (現在 198 行目から): `close()` が読み取りの `interrupt` を完了してからソケットを閉じるため、待っていた recv が EBADF で失敗し、再開した `receive` が「`reading the response failed: Bad file descriptor`」を投げていた。意図して放棄した読み取り (`readSome` の待ち、リクエストの頭の待ち) が、`""` の返却や "was abandoned" でなくエラーで終わっていた。360 / 298 / 327 を調べていて見つけた。落ちるテストを先に書き (S5 の 2 件)、`fix(transport): a read woken by close() of its response ends quietly` で直した。
2. `chooseBodyMode` (現在 185 行目): `Content-Length: -5` を `parseInt` が受け付け、長さ -5 の本文として空で終わっていた (RFC 9110 8.6 は数字のみ)。266 の `n > 0` が冗長な理由を詰める中で見つけた。落ちるテストを先に書き、`fix(transport): refuse a negative Content-Length` で直した。`+5` は数値として通るままで、これは触っていない。

## 一覧

テスト名の略: S1〜S6 は `specs/security.feature` の `MCP-SEC-WIRE-g2g-hc-c-1..6` (リードが採番し直す)。
S1〜S5 のテストは `tests/test_security_wire_headers.nim` の末尾の suite (名前に `(mutation review, g2g-hc-c)`)、S6 は `tests/test_security_wire_tls.nim` の末尾と同ファイルの `-d:ssl` 無しの suite、`test_http_wire_internals` は新しい `tests/test_http_wire_internals.nim`。
class 3 の変異はすべて作業場所 `build/ws/g2g-hc-c` で手で当て、名前を挙げたテストが落ちるのを見てから `jj restore src/transport/http_wire.nim` で戻した。

| id | file:line | mutator | 原文 → 置換 | class | 理由 | 検出するテスト |
|---|---|---|---|---|---|---|
| 219 | `http_wire.nim:116` (測定時 112) | AOR | `{…} + Digits` → `{…} - Digits` | 3 (穴) | 数字を含むヘッダ名 (`X-Request-Id-2`) が拒否される | S1: header name with digits |
| 226 | `http_wire.nim:90` (測定時 86) | ROR | connect: `url.port.len > 0` → `>= 0` | 3 (穴) | ポート無しの URL で `parseInt("")` が ValueError になり、接続の失敗ではなく URL の不正になる。:80 は束縛できないので、メッセージに `invalid integer` が無いことで検出する | S1: URL with no port |
| 227 | `http_wire.nim:93` (測定時 89) | ROR | connect: `connectTo.len > 0` → `>= 0` | 3 (穴) | `connectTo` 無しでも空の宛先へ dial し (loopback になる)、URL のホストでなく loopback へつながる。解決できない名前 + loopback のサーバで検出 | S1: host that does not resolve |
| 230 | `http_wire.nim:118` (測定時 114) | ROR | isToken: `name.len > 0` → `>= 0` | 3 (穴) | 空のヘッダ名が通る | S1: empty header name |
| 231 | `http_wire.nim:138` (測定時 134) | ROR | requestText: `url.path.len > 0` → `>= 0` | 3 (穴) | パスの無い URL で request line が `GET  HTTP/1.1` になる | S1: neither path nor query |
| 232 | `http_wire.nim:139` (測定時 135) | ROR | requestText: `url.query.len > 0` → `>= 0` | 3 (穴) | クエリの無い URL で `GET /? HTTP/1.1` になる | S1: neither path nor query |
| 233 | `http_wire.nim:141` (測定時 137) | ROR | requestText: `url.port.len > 0` → `>= 0` | 3 (穴) | ポート無しで `Host: name:` になる。:80 を束縛できないためソケット越しには見えず、`include` した内部テストで request text を直接見る | test_http_wire_internals: Host names the host alone |
| 234 | `http_wire.nim:147` (測定時 143) | ROR | requestText: `body.len > 0` → `>= 0` | 3 (穴) | 本文の無い GET に `Content-Length: 0` が付く | S1: GET without a body |
| 278 | `http_wire.nim:147` (測定時 143) | LOR | requestText: `body.len > 0 or POST` の `or` → `and` | 3 (穴) | 本文の無い POST に Content-Length が付かず、本文のある PUT にも付かない | S1: POST without a body, PUT with a body |
| 235 | `http_wire.nim:147` (測定時 143) | ROR | requestText: `httpMethod == HttpPost` → `!=` | 3 (穴) | GET に Content-Length: 0 が付き、空の POST に付かない | S1: GET without a body, POST without a body |
| 277 | `http_wire.nim:125` (測定時 121) | LOR | checkRequestFields: `hasControlCharacter(…) or ' ' in url.path` の `or` → `and` | 3 (穴) | 空白の無いパスの NUL・CR LF が通り、制御文字の無いパスの空白が通る | S1: path with a NUL but no space, or a space but no control character |
| 236 | `http_wire.nim:161` (測定時 157) | ROR | parseHead: `status.len < 2` → `<= 2` | 3 (穴) | 理由句の無い状態行 (`HTTP/1.1 200`) が拒否される | S2: status line without a reason phrase |
| 279 | `http_wire.nim:161` (測定時 157) | LOR | parseHead: `status.len < 2 or not startsWith("HTTP/")` の `or` → `and` | 3 (穴) | `FOO/1.1 200 OK` が通り、`HTTP/1.1` だけの行では `status[1]` で IndexDefect になる | S2: status line that does not start with HTTP/ |
| 237 | `http_wire.nim:170` (測定時 166) | ROR | parseHead: `colon > 0` → `>= 0` | 3 (穴) | 名前の無い行 (`: x`) が名前 "" のヘッダになる | S2: header line that starts with a colon |
| 281 | `http_wire.nim:175` (測定時 171) | LOR | chooseBodyMode: `HEAD or code < 200` の `or` → `and` | 3 (穴) | HEAD の応答が Content-Length 分の本文を待つ | S2: HEAD request |
| 280 | `http_wire.nim:175` (測定時 171) | LOR | chooseBodyMode: `… or code in [204, 304]` の `or` → `and` | 3 (穴) | 1xx / 204 / 304 が本文を持つ応答として扱われ、終わらない | S2: answer of 1xx, 204 or 304 |
| 244 | `http_wire.nim:259` (測定時 246) | ROR | exchangeHead: `at >= 0` → `> 0` | 3 (穴) | 先頭が空行だけの頭が「頭の終わり」と認識されず、"not an HTTP response" でなく接続終了になる | S2: head of nothing but the blank line |
| 245 | `http_wire.nim:263` (測定時 250) | ROR | exchangeHead: `head.len > MaxHeadSize` → `>= MaxHeadSize` | 3 (穴) | ちょうど 64 KiB の頭 (終端は次の recv で届く) が拒否される | S4: head of exactly the limit |
| 343 | `http_wire.nim:299` (測定時 286) | SDL | requestOnce: except 節の `response.close()` を `discard` に | 3 (穴) | HTTP でない応答で失敗した後も接続が閉じられない (サーバ側が EOF を見ない) | S2: answer that is not HTTP … connection is closed |
| 291 | `http_wire.nim:314` (測定時 301) | LOR | sameOrigin: `scheme == and host ==` の `and` → `or` | 3 (穴) | 同じスキーム・同じポートで別ホスト名への redirect が追従される | S3: another host name on the same port |
| 290 | `http_wire.nim:314` (測定時 301) | LOR | sameOrigin: `(… and …) and port ==` の 2 つ目の `and` → `or` | 3 (穴) | 同じポートなら別ホスト・別スキームでも追従される | S3: another host name on the same port; another scheme |
| 344 | `http_wire.nim:347` (測定時 334) | SDL | request: redirect の `response.close()` を `discard` に | 3 (穴) | redirect を返した接続が閉じられない (追従する場合も拒否する場合も) | S3: connection that gave it is closed (2 tests) |
| 257 | `http_wire.nim:371` (測定時 358) | ROR | decodeChunked: `r.line.len > 64` → `>= 64` | 3 (穴) | 64 バイトのサイズ行 (拡張つき) が拒否される | S4: chunk size line of 64 bytes |
| 260 | `http_wire.nim:387` (測定時 374) | ROR | decodeChunked (csTrailers): `c == '\n'` → `!=` | 3 (穴) | trailer の行が来た時点で本文が終わる (空行を待たない) | S4: trailer … not complete until the blank line |
| 261 | `http_wire.nim:388` (測定時 375) | ROR | decodeChunked (csTrailers): `r.line.len == 0` → `!=` | 3 (穴) | 空行で終わらず、trailer の行で終わる | S4: chunked body that ends …; last chunk … not the blank line |
| 262 | `http_wire.nim:391` (測定時 378) | ROR | decodeChunked (csTrailers): `c != '\r'` → `==` | 3 (穴) | CR だけが行に溜まり、空行を認識できない (正常な chunked 本文が最後まで読めない) | S4: chunked body that ends with the last chunk |
| 350 | `http_wire.nim:392` (測定時 379) | SDL | decodeChunked (csTrailers): `r.line.add c` を `discard` に | 3 (穴) | trailer の行が空と見なされ、trailer の途中で本文が終わる | S4: trailer … not complete until the blank line |
| 270 | `http_wire.nim:435` (測定時 422) | ROR | readSome: `decoded.len > 0` → `>= 0` | 3 (穴) | サイズ行だけが先に届くと readSome が "" (本文の終わり) を返し、readAll が本文を切る | S4: chunk size line that arrives before its data |
| 272 | `http_wire.nim:446` (測定時 433) | ROR | readAll: `result.len > maxSize` → `>= maxSize` | 3 (穴) | ちょうど maxSize バイトの本文が拒否される | S4: body of exactly maxSize bytes |
| 357 | `http_wire.nim:447` (測定時 434) | SDL | readAll: 上限超過時の `r.close()` を `discard` に | 3 (穴) | 上限を超えて拒否した後も接続が閉じられず、応答が終了しない | S4: body that grows past maxSize |
| 351 | `http_wire.nim:415` (測定時 402) | SDL | readSome (bmLength): 途中切断時の `r.close()` を `discard` に | 3 (穴) | 本文が足りずに失敗した応答が終了せず、接続が閉じられない | S4: Content-Length body cut short |
| 354 | `http_wire.nim:425` (測定時 417) | SDL | readSome (bmChunked): 途中切断時の `r.close()` を `discard` に | 3 (穴) | 同上 (chunked) | S4: chunked body cut short |
| 355 | `http_wire.nim:430` (測定時 421) | SDL | readSome (bmChunked): 最終 chunk 後の `r.close()` を `discard` に | 3 (穴) | 接続を開いたままのサーバでは本文が終わらず readAll が戻らない | S4: chunked body that is complete, when the server keeps the connection open |
| 243 | `http_wire.nim:233` (測定時 220) | ROR | connectWithin: `timeoutMs > 0` → `>= 0` | 3 (穴) | `connectTimeoutMs = 0` (無制限) が即座にタイムアウトになる | S4: connect timeout of 0 |
| 329 | `http_wire.nim:239` (測定時 226) | SDL | connectWithin: 遅れて終わる接続への `attempt.addCallback(…)` を `discard` に | 3 (穴) | タイムアウト後に TLS ハンドシェイクが成功しても、その接続が閉じられない (`-d:ssl`、遅延転送器で再現) | S6: handshake that ends after the connect timeout |
| 330 | `http_wire.nim:243` (測定時 230) | SDL | connectWithin: `attempt.read().close()` を `discard` に | 3 (穴) | 同上 | S6: handshake that ends after the connect timeout |
| 314 | `http_wire.nim:102` (測定時 98) | SDL | connect (TLS): 検証失敗時の `socket.close()` を `discard` に | 3 (穴) | 証明書を拒否した接続のファイル記述子が残る (繰り返して数える) | S6: certificate for another host … no connection is left open |
| 315 | `http_wire.nim:105` (測定時 101) | SDL | connect (-d:ssl 無し): `socket.close()` を `discard` に | 3 (穴) | `https` を拒否した接続のファイル記述子が残る (`-d:ssl` 無しでのみコンパイルされる枝) | S6: build without -d:ssl … no connection is left open |
| 360 | `http_wire.nim:216` (測定時 203) | RVR | receive: `return (data: "", interrupted: true)` → 既定値 | 3 (穴) | close() で起こされた読み取りが「中断」でなく「接続終了」になる: ヘッダ待ちは "connection closed before the response"、本文待ちは例外。**この検証で欠陥 (class 5) を見つけた (下記)** | S5: closed while its body / head is awaited |
| 298 | `http_wire.nim:216` (測定時 203) | BLR | receive: `interrupted: true` → `false` | 3 (穴) | 同上 (360 と同じプログラム) | S5 |
| 323 | `http_wire.nim:196` (測定時 189) | SDL | close: `r.leftOpen.complete()` → `discard` | gone: the statement was replaced after the measurement | 測定後に `leftOpen` が `interrupt` (読み取りごとの future) に置き換わり、この文は無い。置換後の `r.interrupt.complete()` を `discard` にすると S5 の 2 テストが落ちることを確認した | S5 (置換後の文について) |
| 284 | `http_wire.nim:197` (測定時 190) | LOR | close: `not isNil and not isClosed` の `and` → `or` | 4 (冗長) | `AsyncSocket.close` が閉じ済みなら何もしない (`if socket.closed: return`、Nim 2.2.8 asyncnet.nim:736) ので `not isClosed` の判定は冗長。`isNil` 側は、`close` が呼ばれるのは `socket` を代入した後だけ (`connected` も例外処理も接続後) なので到達しない | - (変異ありで S1–S6 全て通過を確認) |
| 341 | `http_wire.nim:292` (測定時 279) | SDL | requestOnce: ヘッダタイムアウト時の `response.close()` を `discard` に | 4 (冗長) | 直後の `raise` が同じ `try` の `except CatchableError` に捕まり、そこで `response.close()` が await 無しで走る。2 つの close の間に観測できる差が無い | - (変異ありで全て通過を確認; タイムアウト後に接続が閉じることは S2 の別テストが見る) |
| 327 | `http_wire.nim:220` (測定時 207) | SDL | receive: 2 つ目の `except OSError` 内の `r.close()` を `discard` に | 4 (冗長) | 測定時のコードでは到達できた (close() が interrupt を完了した後 recv が EBADF で失敗する競合。欠陥の原因そのもの) が、そこでは既に close 済みで `r.close()` は何もしない。修正後は `r.closed` なら先に戻るので、この節自体が到達しない (`pending` が失敗していて firstOf が成功するのは interrupt が先に終わったときだけで、それは close 済みを意味する) | - (変異ありで全て通過を確認) |
| 302 | `http_wire.nim:412` (測定時 399) | BLR | readSome (bmNone): `r.finished = true` → `false` | 4 (冗長) | `chooseBodyMode` が bmNone なら `finished = true` にしており、`while not r.finished` の本体に bmNone で入ることが無い。`case` の網羅のために残っている枝 | - (変異ありで全て通過を確認) |
| 266 | `http_wire.nim:421` (測定時 408) | ROR | readSome (bmLength): `n > 0` → `>= 0` | 4 (冗長) | `data.len > 0` かつ `remaining > 0` (0 なら finished) なので n ≥ 1。負の Content-Length は今回の修正で入口 (chooseBodyMode) で拒否される | - (変異ありで全て通過を確認) |
| 342 | `http_wire.nim:293` (測定時 280) | SDL | requestOnce: 放棄した exchange の失敗を読む `addCallback` を `discard` に | 1 (同値) | Nim の async は、await も asyncCheck もされない失敗した future を報告しない (`-d:futureLogging` 以外)。読む・読まないで挙動は変わらない | - (変異ありで全て通過を確認) |
| 365 | `http_wire.nim:408` (測定時 395) | RVR | readSome: `return ""` → 既定値 | 1 (同値) | string の既定値は `""` で同一のプログラム | - |
| 369 | `http_wire.nim:437` (測定時 424) | RVR | readSome: 末尾の `return ""` → 既定値 | 1 (同値) | 同上 | - |
| 306 | `http_wire.nim:82` (測定時 78) | SDL | verifyPeerName: `X509_free(certificate)` を `discard` に | 6 (受け入れ) | 1 接続につき X509 の参照を 1 つ漏らす。メモリの漏れで、挙動 (応答・例外・記述子) に現れず、プロセス内のテストは測れない。LeakSanitizer などの実行が要る | - |
| 326 | `http_wire.nim:210` (測定時 200) | SDL | receive: 1 つ目の `except OSError` 内の `r.close()` を `discard` に | 6 (受け入れ) | recv が OSError になるのは ECONNRESET 以外のカーネルの失敗 (asyncdispatch は ECONNRESET を `""` にする) だけで、loopback では作れない。ヘッダ待ちでは外側の `requestOnce` が閉じ、本文待ちでは呼び出し側 (http.nim) が失敗した応答を閉じる。試みた作り方 (記述子を AsyncSocket の背後で閉じる) は IOSelectorsException になり、この節に来ない | - |

## 残っているもの

- class 4 の 5 件 (284、341、327、302、266) は、冗長または到達しない文。削除はしていない。リードの判断を待つ。327 の節は修正で到達しなくなったので、`receive` の 2 つ目の `try` / `except` ごと消せる (`pending.read()` は成功した future の取り出しだけになる)。302 は `case` の網羅のための枝。
- class 6 の 2 件 (306、326) は受け入れ。306 は X509 の参照の漏れで、挙動に現れない。326 は loopback で作れないカーネルの recv の失敗。
- `sameOrigin` がポートを書かれたとおりに比べる (既定ポートを明記すると別オリジンになる) のは記録済みで、直していない (安全側)。
- 修正の過程で `receive` の冒頭に「close 済みなら読み始めずに中断を返す」分岐を足した。公開インタフェース越しには到達できない (close すると `finished` になり `readSome` は入らず、`exchangeHead` は先に send で失敗する) ため、`test_http_wire_internals` が直接確かめる。
- 実行した確認: `test_security_wire_headers` (3 つの既定版、`-d:ssl` 有り無し)、`test_http_wire_internals` (3 版)、`test_security_wire_tls` (`-d:ssl`、3 版)、ジョブの他のテスト全部 (既定版)、`test_spec_coverage`。
- 変異を手で当てたのは修正後のソースで、テストは最終版と同じ内容 (suite を末尾へ並べ替える前)。並べ替えた後に全変異を当て直してはいない。
