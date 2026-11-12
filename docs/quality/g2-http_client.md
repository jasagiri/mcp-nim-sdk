# G2 変異検出: http_client ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: nim-muter 0.2.15、全 414 変異。killed 279、survived 73、timeout 39、compileError 23。
生き残りは 2 人で分担して仕分けた (http_wire.nim と、それ以外)。

### http_wire.nim の生き残り

状態: 測定済み。生き残り 52 件。
内訳: test_owed 34、equivalent 9、unreached 5、spec_question 3、accepted 1、undecided 0。
E テストは `http_wire` を直接 import しないので、見えるのは `StreamableHttpTransport`・`SseLegacyTransport`・アイコンの取得・認可の取得を通した振る舞いだけ。
`http_wire.request` の呼び手が使うメソッドは GET・POST (本文つき)・DELETE だけで、HEAD と PUT、本文の無い POST は公開の入口から作れない。
仕分けは読解だけで行い、変異を当てて走らせてはいない。

| 指紋 | 場所 | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/transport/http_wire.nim:SDL:6550c95298b9a3f4:0` | http_wire.nim:83 | `X509_free(certificate)` → `discard` | equivalent | 接続 1 本につき X509 の参照を 1 つ解放しないだけ。応答・例外・記述子は変わらず、公開の入口から見えるものは無い (残るのはメモリだけ。前回 id 306 と同じ読み) | — |
| `src/transport/http_wire.nim:SDL:23821c14d11f59f0:0` | http_wire.nim:103 | 証明書を断ったときの `socket.close()` → `discard` | test_owed | 証明書を断った接続の記述子が残り、サーバーは切断を見ない。今これを見るのは内部の `tests/internal/test_security_wire_tls.nim` だけ | MCP-SEC-WIRE-20。案 W13 |
| `src/transport/http_wire.nim:ROR:f786273d59942e92:0` | http_wire.nim:139 | `url.path.len > 0` → `>=` | test_owed | パスの無い URL で要求行が `POST  HTTP/1.1` (対象が空) になる | MCP-SEC-WIRE-15。案 W1 |
| `src/transport/http_wire.nim:ROR:7f2b6c957092d608:0` | http_wire.nim:140 | `url.query.len > 0` → `>=` | test_owed | クエリの無い URL で要求行が `POST /? HTTP/1.1` になる | MCP-SEC-WIRE-15。案 W1 |
| `src/transport/http_wire.nim:ROR:a2cefaede4013b4c:0` | http_wire.nim:142 | `url.port.len > 0` → `>=` | accepted | ポートの無い URL で `Host: name:` になる。見るには 80 番 (https なら 443 番) で待つ相手が要り、公開の入口には接続先だけを差し替える口が無い。前の記録「内部実装テストの扱い」の id 233 (「このテストでしか検出できない変異は…許容とする」) による。**その記録はリードの判断で、代表の記録かは確かめられていない** | MCP-SEC-WIRE-15 の「Host names … the port only when the URL has one」は E テストを持てない |
| `src/transport/http_wire.nim:ROR:3659d57a7d6c5662:0` | http_wire.nim:148 | `body.len > 0` → `>=` | test_owed | 本文の無い GET・DELETE に `Content-Length: 0` が付く | MCP-SEC-WIRE-15。案 W2 |
| `src/transport/http_wire.nim:LOR:2f7089b6f1a8c01a:0` | http_wire.nim:148 | `body.len > 0 or httpMethod == HttpPost` → `and` | equivalent | 差が出るのは本文の無い POST と、POST 以外で本文のある要求だけ。呼び手 (`http.nim` の POST は JSON-RPC のメッセージ、`sse_legacy.nim` の POST も同じ、`auth/oauth/fetch.nim` の POST はフォームか JSON の文書、GET と DELETE は本文なし) はどちらも作らない | MCP-SEC-WIRE-15 の「for a POST and for any request with a body」のうち、本文の無い POST と PUT は公開の入口から確かめられない |
| `src/transport/http_wire.nim:ROR:acbce228c56a3ffa:0` | http_wire.nim:148 | `httpMethod == HttpPost` → `!=` | test_owed | 本文の無い GET・DELETE に `Content-Length: 0` が付く (本文のある POST は左の条件で付くまま) | MCP-SEC-WIRE-15。案 W2 |
| `src/transport/http_wire.nim:ROR:9ad2cda0f77cc4cb:0` | http_wire.nim:162 | `status.len < 2` → `<=` | test_owed | 理由句の無い状態行 (`HTTP/1.1 200`) が「HTTP の応答ではない」と断られる | MCP-SEC-WIRE-16。案 W3 |
| `src/transport/http_wire.nim:ROR:95d1016392c12067:0` | http_wire.nim:169 | `code < 100` → `<=` | test_owed | 状態 100 が「状態行が不正」と断られる。元は応答として受け、`McpTransportError.code` が 100 になる (変異では 0) | MCP-SEC-WIRE-23 (範囲は 100 から 599)。案 W4 |
| `src/transport/http_wire.nim:LOR:8cda8e348861f1df:0` | http_wire.nim:169 | `code < 100 or code > 599` → `and` | test_owed | 範囲の外の状態 (2049、-5) を通し、`HttpCode(code)` が RangeDefect になる | MCP-SEC-WIRE-23。既存の `tests/external/test_security_wire_shapes.nim` の「Given a status code above 599 …」「Given a negative status code …」が検出するはず。testCommand に足す |
| `src/transport/http_wire.nim:ROR:f8aa84cb4705fa6b:0` | http_wire.nim:169 | `code > 599` → `>=` | test_owed | 状態 599 が「状態行が不正」と断られる (`code` が 599 でなく 0) | MCP-SEC-WIRE-23。案 W4 |
| `src/transport/http_wire.nim:ROR:fb29fb68bb0cf79a:0` | http_wire.nim:175 | `colon > 0` → `>=` | equivalent | `: x` の行が名前の空のヘッダーとして入るだけ。応答のヘッダーを読む側 (Content-Type・Mcp-Session-Id・Location・WWW-Authenticate・Transfer-Encoding・Content-Length) は空の名前を引かない | MCP-SEC-WIRE-16 の「a line without a name is no header」は公開の入口から確かめられない |
| `src/transport/http_wire.nim:LOR:afa1d4e3d056925c:0` | http_wire.nim:180 | `httpMethod == HttpHead or code < 200` → `and` | test_owed | HEAD でない要求への 1xx が「接続が閉じるまでが本文」になり、相手が接続を保つと終わらない (元は本文なしで直ちに終わり、接続を閉じる)。HEAD の側は呼び手が無い | MCP-SEC-WIRE-16。案 W5 |
| `src/transport/http_wire.nim:LOR:2d4d48653272c466:0` | http_wire.nim:180 | `… or code in [204, 304]` → `and` | test_owed | 1xx・204・304 がどれも本文を待つ。204 で答えて接続を保つ相手への通知が終わらない (既存の 204 のテストは DELETE で、本文を読まずに閉じるので見ない) | MCP-SEC-WIRE-16。案 W5 |
| `src/transport/http_wire.nim:BLR:6648c3d18d2d303a:0` | http_wire.nim:199 | `close` の `r.closed = true` → `false` | spec_question | `close` は待っている recv を EBADF で失敗させるので、起きた `receive` が「中断」でなく `reading the response failed` の McpTransportError で終わる。Streamable HTTP では取り消し (`abandoned`) と close (`closed`) の両方で上の層がその失敗を黙って捨てるので結果は同じ。外に出るのは失敗の文面と、旧 SSE で endpoint を待ち切れて閉じたときに診断 `[mcp-sse] event stream … failed` が 1 行増えることだけで、その診断を定める仕様 ID は無い | 問い Q1 (下) |
| `src/transport/http_wire.nim:SDL:d6e20945c156a180:0` | http_wire.nim:201 | `r.interrupt.complete()` → `discard` | spec_question | 上と同じ。待っている読み取りは `interrupt` でなく recv の失敗で起き、`reading the response failed` で終わる (止まりはしない: 止まるなら取り消しのテストが落ちる) | 問い Q1 |
| `src/transport/http_wire.nim:LOR:57c83ac1dd79dc2b:0` | http_wire.nim:202 | `not r.socket.isNil and not r.socket.isClosed` → `or` | equivalent | `AsyncSocket.close` は閉じ済みなら何もしない。`socket` が nil のまま `close` が呼ばれることも無い (`connected` も例外の処理も `socket` を入れた後)。前回 id 284 と同じ読み | — |
| `src/transport/http_wire.nim:RVR:1cd163f0376d5767:0` | http_wire.nim:209 | `return (data: "", interrupted: true)` → 既定値 | unreached | 閉じた応答で `receive` が呼ばれない。`readSome` は `close` が立てる `finished` を先に見て抜け、`exchangeHead` は送信の後に待ちを挟まず `receive` に入る (送信の途中で閉じられれば送信の失敗で抜ける)。前の記録「内部実装テストの扱い」も「公開の口からは届かない」 | — |
| `src/transport/http_wire.nim:BLR:815d0a6eb4cc9d4b:0` | http_wire.nim:209 | `interrupted: true` → `false` | unreached | 上と同じ文 | — |
| `src/transport/http_wire.nim:SDL:69127dcb00db7d48:0` | http_wire.nim:215 | recv の失敗の `r.close()` → `discard` | unreached | この節に来るのは、`close` より先に recv が OSError で失敗したときだけ。相手役からは作れない (接続の切断は asyncdispatch が空の読み取りにする。前回 id 326 で試して作れなかった) | — |
| `src/transport/http_wire.nim:LOR:aa607b45cf389e41:0` | http_wire.nim:220 | `r.closed or not pending.finished` → `and` | spec_question | `close` の後は recv が失敗で終わっているので条件が偽になり、`pending.read()` の OSError から `reading the response failed` になる。199・201 行と同じ結果 | 問い Q1 |
| `src/transport/http_wire.nim:RVR:1cd163f0376d5767:1` | http_wire.nim:221 | `return (data: "", interrupted: true)` → 既定値 | test_owed | 中断が「相手が閉じた」(空の読み取り) になる。Content-Length の無い JSON の本文 (閉じるまでが本文) の途中で取り消すと、途中までの本文が全部として返り、`sendRequest` が JSON の解析の失敗で終わる。既存のテスト (`bPartialHold`) は Content-Length つきなので、変異でも McpTransportError になり `abandoned` が黙らせる | MCP-SEC-WIRE-19 (MCP-HTTP-32)。案 W6 |
| `src/transport/http_wire.nim:BLR:815d0a6eb4cc9d4b:1` | http_wire.nim:221 | `interrupted: true` → `false` | test_owed | 上と同じプログラム | MCP-SEC-WIRE-19。案 W6 |
| `src/transport/http_wire.nim:SDL:69127dcb00db7d48:1` | http_wire.nim:225 | 2 つ目の `except OSError` の `r.close()` → `discard` | unreached | `r.closed` なら 221 行で先に戻る。閉じていないのに `pending` が失敗していれば 213 行の `firstOf` が先に失敗する。前回 id 327 と同じ読み | — |
| `src/transport/http_wire.nim:SDL:443904262a20286a:0` | http_wire.nim:244 | 遅れて終わる接続への `attempt.addCallback(…)` → `discard` | test_owed | 接続の制限時間の後に TLS のハンドシェイクが終わると、その接続が閉じられずに残る。今これを見るのは内部の `test_security_wire_tls.nim` だけ | MCP-SEC-WIRE-20。案 W14 |
| `src/transport/http_wire.nim:SDL:d25407cf64c95e94:0` | http_wire.nim:248 | `attempt.read().close()` → `discard` | test_owed | 上と同じ | MCP-SEC-WIRE-20。案 W14 |
| `src/transport/http_wire.nim:ROR:e582ac1448caec29:0` | http_wire.nim:268 | `head.len > MaxHeadSize` → `>=` | test_owed | ちょうど 64 KiB まで届いて終わりがまだ来ていない頭が断られる | MCP-SEC-WIRE-18。案 W7 |
| `src/transport/http_wire.nim:SDL:92cccf31e1675a58:0` | http_wire.nim:297 | ヘッダーの待ち切れの `response.close()` → `discard` | equivalent | 直後の `raise` が同じ `try` の `except CatchableError` に入り、そこの `response.close()` が待ちを挟まずに走る。前回 id 341 と同じ読み | — |
| `src/transport/http_wire.nim:SDL:2b50c5c53d3d4667:0` | http_wire.nim:298 | 放棄した `exchange` の失敗を読む `addCallback` → `discard` | equivalent | 誰も待たない future の失敗は、読んでも読まなくても何も起こさない (`asyncCheck` していない)。前回 id 342 と同じ読み | — |
| `src/transport/http_wire.nim:LOR:c021a896957300f5:0` | http_wire.nim:362 | `text.len == 0 or text.len > 15` → `and` | test_owed | 16 桁以上の大きさを通し、`result * 16 + digit` が OverflowDefect になる | MCP-SEC-WIRE-23。既存の `tests/external/test_security_wire_shapes.nim` の「Given a chunk size that does not fit in an integer …」が検出するはず。testCommand に足す |
| `src/transport/http_wire.nim:ROR:908a6271e751bc55:0` | http_wire.nim:362 | `text.len > 15` → `>=` | test_owed | 15 桁の大きさ (先頭に 0 を並べたもの。int に収まる) が断られる | MCP-SEC-WIRE-23。案 W8 |
| `src/transport/http_wire.nim:AOR:677494dbad0b5697:0` | http_wire.nim:367 | `ord(c) - ord('0')` → `+` | test_owed | 数字の桁が 96 以上になり、チャンクの大きさが狂う。イベントストリームでは届いた分が先に配られ、最後の失敗は診断になるだけなので、既存のチャンクのテストは通る。JSON の本文なら要求が失敗する | MCP-SEC-WIRE-23。既存の `test_security_wire_shapes.nim` の「Given a well-formed chunked answer …」(大きさ `58`) が検出するはず。testCommand に足す |
| `src/transport/http_wire.nim:AOR:904ad839e5d0aace:0` | http_wire.nim:368 | `ord(c) - ord('a')` → `+` | test_owed | 小文字の桁 `a`〜`f` が 204 以上になる。JSON の本文で、大きさに英字の桁を持つものを読む E テストが無い | MCP-SEC-WIRE-23。案 W8 |
| `src/transport/http_wire.nim:AOR:cedabd4dfadbc44c:0` | http_wire.nim:368 | `… + 10` → `- 10` | test_owed | 小文字の桁が負になり、大きさが負になる | MCP-SEC-WIRE-23。案 W8 |
| `src/transport/http_wire.nim:AOR:2c181b06a9cd674e:0` | http_wire.nim:369 | `ord(c) - ord('A')` → `+` | test_owed | 大文字の桁 `A`〜`F` が狂う | MCP-SEC-WIRE-23。案 W8 |
| `src/transport/http_wire.nim:AOR:91a1613fc6739f4c:0` | http_wire.nim:369 | `… + 10` → `- 10` | test_owed | 大文字の桁が負になる | MCP-SEC-WIRE-23。案 W8 |
| `src/transport/http_wire.nim:ROR:6bc662be21c97f8d:0` | http_wire.nim:387 | `r.line.len > 64` → `>=` | test_owed | 64 バイトの大きさの行 (拡張つき) が断られる | MCP-SEC-WIRE-18。案 W9 |
| `src/transport/http_wire.nim:LOR:9e79d51c8bf60178:0` | http_wire.nim:404 | `c == '\c' and r.line.len == 0` → `or` | test_owed | データの直後の余分な 1 バイトを通す。既存の `test_security_wire_shapes.nim` は余分を 2 バイト (`XX`) 置くので、2 バイト目で断られ、変異でも通る | MCP-SEC-WIRE-23。案 W10 |
| `src/transport/http_wire.nim:ROR:53e018ffc3bff233:2` | http_wire.nim:411 | トレーラーの `c == '\n'` → `!=` | test_owed | 最後のチャンクの次の 1 バイト目で本文が終わる。空行が来る前に接続が切れても、本文が全部として受け取られる | MCP-SEC-WIRE-18。案 W11 |
| `src/transport/http_wire.nim:ROR:36bb4f701e0752b8:0` | http_wire.nim:412 | `r.line.len == 0` → `!=` | test_owed | 空行で終わらず、トレーラーの行で終わる。トレーラーの無い本文は終わらなくなり、相手が閉じると失敗する | MCP-SEC-WIRE-18。既存の `test_security_wire_shapes.nim` の「Given a well-formed chunked answer …」が検出するはず。testCommand に足す (案 W11 も検出する) |
| `src/transport/http_wire.nim:ROR:388fe6862d760fd1:0` | http_wire.nim:415 | `c != '\c'` → `==` | test_owed | CR が行に溜まって空行を認められず、正しいチャンクの本文が終わらない | MCP-SEC-WIRE-18。既存の `test_security_wire_shapes.nim` の「Given a well-formed chunked answer …」が検出するはず。testCommand に足す |
| `src/transport/http_wire.nim:SDL:8cb5943fd131cd10:1` | http_wire.nim:416 | トレーラーの `r.line.add c` → `discard` | test_owed | トレーラーの行が空と見なされ、その行の終わりで本文が終わる (空行を待たない) | MCP-SEC-WIRE-18。案 W11 |
| `src/transport/http_wire.nim:RVR:87aa8baa528c4cef:0` | http_wire.nim:433 | `return ""` → 既定値 | equivalent | 文字列のリテラルの置き換えは `""` で、同じプログラム | — |
| `src/transport/http_wire.nim:BLR:d81d812f01f9642e:1` | http_wire.nim:437 | `bmNone` の `r.finished = true` → `false` | unreached | `chooseBodyMode` が `bmNone` なら `finished` を立てるので、`while not r.finished` の中に `bmNone` で入らない。前回 id 302 と同じ読み | — |
| `src/transport/http_wire.nim:SDL:69127dcb00db7d48:2` | http_wire.nim:440 | Content-Length の本文が途中で切れたときの `r.close()` → `discard` | test_owed | Streamable HTTP・アイコン・認可の呼び手は失敗しても自分で閉じるので見えない。旧 SSE の `connect` は、エラーの応答の本文を読む `readAll` が失敗すると閉じないので、そこでだけ記述子が残る | MCP-SEC-WIRE-18 (「a body cut short fails, and the response is finished」)。案 W15 |
| `src/transport/http_wire.nim:ROR:5d8027d83be9c587:0` | http_wire.nim:446 | `n > 0` → `>=` | equivalent | ここでは `data.len > 0` かつ `remaining > 0` (0 なら `finished`)、負の Content-Length は入口で断るので、n は常に 1 以上。前回 id 266 と同じ読み | — |
| `src/transport/http_wire.nim:SDL:69127dcb00db7d48:5` | http_wire.nim:455 | チャンクの本文が途中で切れたときの `r.close()` → `discard` | test_owed | 440 行と同じ (チャンクの本文で) | MCP-SEC-WIRE-18。案 W15 |
| `src/transport/http_wire.nim:SDL:69127dcb00db7d48:6` | http_wire.nim:459 | 最後のチャンクの後の `r.close()` → `discard` | test_owed | 本文が終わっても応答が終わらず、次の読み取りが相手を待つ。相手が閉じると「最後のチャンクの前に閉じた」で失敗する | MCP-SEC-WIRE-18。既存の `test_security_wire_shapes.nim` の「Given a well-formed chunked answer …」が検出するはず。testCommand に足す |
| `src/transport/http_wire.nim:ROR:97f56bf0367a2e95:0` | http_wire.nim:460 | `decoded.len > 0` → `>=` | test_owed | 大きさの行だけが先に届くと `readSome` が "" (本文の終わり) を返し、`readAll` が空の本文で終える。既存のチャンクのテストは 7 バイト目で切るのでデータが 3 バイト入り、見ない | MCP-SEC-WIRE-18。案 W12 |
| `src/transport/http_wire.nim:RVR:87aa8baa528c4cef:1` | http_wire.nim:462 | 末尾の `return ""` → 既定値 | equivalent | 433 行と同じ | — |
| `src/transport/http_wire.nim:SDL:69127dcb00db7d48:7` | http_wire.nim:476 | 上限を超えたときの `r.close()` → `discard` | test_owed | Streamable HTTP の呼び手は `finally` で閉じるので見えない。旧 SSE の `connect` は `readAll(ErrorBodyPreview)` が失敗すると閉じないので、512 バイトを超えるエラーの本文を送り続ける相手との接続が残る | MCP-SEC-WIRE-18 (「a body that outgrows its limit has its connection closed」)。案 W16 |

#### http_wire.nim: 足すテストの案

まず `tests/external/test_security_wire_shapes.nim` (MCP-SEC-WIRE-23) を `tests/mutation/http_client.json` の testCommand に足す。新しいテストは要らず、169 行の LOR、362 行の LOR、367・412・415・459 行の 6 件を検出するはず。

残りは `StreamableHttpTransport` の通知・要求を、答えをそのまま書ける相手役 (`test_security_wire_headers.nim` の `startScripted`) に送る形で書ける。

| 案 | 仕様 ID | 入れるもの・見るもの | 検出する変異 (行) |
|---|---|---|---|
| W1 | MCP-SEC-WIRE-15 | パスもクエリも無い URL (`http://127.0.0.1:<port>`) と、`/a?b=1` の URL へ通知を送る。相手が受けた要求行が `POST / HTTP/1.1`、`POST /a?b=1 HTTP/1.1` であること | 139、140 |
| W2 | MCP-SEC-WIRE-15 | 本文の無い要求 (ストリームを開く GET か、セッションを終える DELETE) を相手が受ける。その頭に `Content-Length` が無いこと | 148 の ROR 2 件 |
| W3 | MCP-SEC-WIRE-16 | `HTTP/1.1 200` (理由句なし) と `Content-Length: 0` で答える。通知が成功すること | 162 |
| W4 | MCP-SEC-WIRE-23 | 状態 100 と 599 で答える。失敗が McpTransportError で、その `code` が 100、599 であること (「状態行が不正」ではない) | 169 の ROR 2 件 |
| W5 | MCP-SEC-WIRE-16 | 100・204・304 を本文なしで答え、接続を保つ。通知が待ち続けず (204 は成功、ほかは HTTP の失敗)、クライアントが接続を閉じること | 180 の LOR 2 件 |
| W6 | MCP-SEC-WIRE-19 | 200・`application/json`・Content-Length なしで本文を半分だけ送って黙る。その要求を取り消すと `sendRequest` が失敗せずに終わること | 221 の RVR・BLR |
| W7 | MCP-SEC-WIRE-18 | 頭をちょうど 65536 バイト送って待ち、その後で終わりの空行を送る。通知が成功すること (1 バイト多ければ断る) | 268 |
| W8 | MCP-SEC-WIRE-23 | JSON の答えをチャンクに分け、大きさを小文字の英字の桁 (`a`〜`f`)、大文字の桁 (`A`〜`F`)、先頭に 0 を並べた 15 桁で書く。メッセージがそのまま届くこと | 362 の ROR、368・369 の AOR 4 件 |
| W9 | MCP-SEC-WIRE-18 | 大きさの行を拡張で 64 バイト (CR を含む) にする。受け取ること (65 バイトは断る) | 387 |
| W10 | MCP-SEC-WIRE-23 | チャンクのデータと行末の間に余分を 1 バイトだけ置く。要求が McpTransportError で失敗すること | 404 |
| W11 | MCP-SEC-WIRE-18 | 最後のチャンクとトレーラーの 1 行まで送り、空行を送らずに閉じる。要求が失敗すること (空行まで送れば成功) | 411、416 (412 も) |
| W12 | MCP-SEC-WIRE-18 | 大きさの行だけを送って少し待ち、その後でデータと最後のチャンクを送る。メッセージが届くこと | 460 |
| W13 | MCP-SEC-WIRE-20 | `-d:ssl` の `test_security_trusted_ca.nim` で、別のホストの証明書を出すサーバーへ繰り返し送る。開いている記述子の数が増えないこと (またはサーバーが切断を見ること) | 103 |
| W14 | MCP-SEC-WIRE-20 | 同じファイルで、ハンドシェイクを `connectTimeoutMs` より遅らせる中継を挟む。失敗の後、ハンドシェイクが終わった接続をクライアントが閉じること | 244、248 |
| W15 | MCP-SEC-WIRE-18 | 旧 SSE のトランスポートの GET に、500 と、Content-Length (またはチャンク) より短い本文で答えて閉じる、を繰り返す。開いている記述子の数が増えないこと | 440、455 |
| W16 | MCP-SEC-WIRE-18 | 旧 SSE の GET に、500 と 512 バイトを超えて続く本文で答えて接続を保つ。クライアントが接続を閉じること | 476 |

W15・W16 は、`sse_legacy.nim` の `connect` が `readAll` の失敗のときに自分で閉じるように直すと、Streamable HTTP と同じく二重の守りになり、3 件は公開の入口から見えなくなる。どちらにするかは実装の担当と司会の判断。

#### http_wire.nim: 代表への問い

- Q1 (199・201・220 行の 3 件): `close` で起こした読み取りを「失敗」でなく「中断」として終える区別は、公開の入口では、旧 SSE で endpoint を待ち切れて閉じたときに診断が 1 行増えるかどうかにしか現れない。これを仕様にするか。
  - 案 A (推奨): 仕様に足す。「旧 SSE で endpoint を待ち切れたとき、報告は待ち切れの失敗 1 つで、ストリームの失敗の診断は出ない」を `specs/` に足し、E テストを 1 本書く。3 件とも検出できる。
  - 案 B: 仕様にしない。区別は wire の層の内部の作りとして残し、3 件は「外に出るのは失敗の文面と診断だけ」として受け入れる。

#### http_wire.nim: timeout の 16 件

読んだ限り、16 件とも無限ループか、相手を待ち続ける変異で、遅いだけのものは無い (走らせて確かめてはいない)。

- `BLR:085d09f9368c1317:0` (95 行、`buffered = false` → `true`): 読み取りが 16 KiB 溜まるまで戻らず、届いたイベントが配られない。待ち続ける。
- `SDL:5126c393547291a4:0` (150 行): 要求の頭が空行で終わらず、相手が頭を待ち続ける。
- `SDL:81c71e71da00fe1e:0` (151 行): 本文が送られず、相手が Content-Length の分を待ち続ける。
- `SDL:e79dfbd7dc6e33dc:0` (176 行): 応答のヘッダーが 1 つも入らず、どの本文も「閉じるまで」になって待ち続ける。
- `AOR:806e5f00fa515203:0` (176 行、`colon + 1` → `- 1`): ヘッダーの値の頭に名前の末尾と `:` が付く。Content-Length は断られ、Content-Type はイベントストリームと認められず、ストリームを「閉じるまでの本文」として待ち続ける。
- `LOR:36218ee9716291c1:0`・`ROR:d3520d2ffd069e77:0`・`ROR:7745eaab4f5e0fcb:0` (194 行): 本文の無い応答 (Content-Length: 0 など) が終わらず、読み取りが相手を待ち続ける。
- `SDL:39e61f218cbb9ce6:0` (260 行): 要求を送らないので、双方が待ち続ける。
- `ROR:032e232f62ac8a98:0` (273 行): 相手が閉じると空の読み取りを足し続ける。無限ループ。
- `SDL:d280f1d5546c923c:0` (275 行): 頭が溜まらず、読み続ける。相手が閉じた後は無限ループ。
- `SDL:67a1badf9643ab78:0` (277 行): 本文の読み方が決まらず `finished` も立たないので、本文を捨てたうえで相手を待ち続ける。
- `ROR:58fb097c98a9bf39:0`・`LOR:b2f25044cf8c9a57:0` (375 行): 入力の終わりを越えて回る。データの途中なら進まずに無限ループ。
- `SDL:c7f896b75934631c:2` (410 行): トレーラーで `i` が進まず無限ループ。
- `ROR:941050a292b5b5e8:0` (470 行): 本文の終わり ("") で抜けず、空を足し続ける無限ループ。

### http.nim・sse_legacy.nim・first_of.nim・http_compat.nim の生き残り

状態: 測定済み。生き残り 21 件 (http.nim 17、first_of.nim 2、sse_legacy.nim 2、http_compat.nim 0)。
内訳: test_owed 4、spec_question 2、equivalent 12、unreached 2、accepted 1、undecided 0。
仕分けは読解だけで行い、変異を当てて走らせてはいない。

| 指紋 | 場所 | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/transport/first_of.nim:BLR:e6b33bb416d844ca:0` | first_of.nim:43 | `bell.rung = true` → `false` | test_owed | `firstOf` では差が無い (終わっている future への `addCallback` は `callSoon` で、`wait` が先に待ち手を置く)。差が出るのは `Doorbell` を使い回す `sse_stream.nim` の配送ループ: `await req.client.send` の間に `idle` (keep-alive の時計) が鳴ると、鳴ったことが失われ、時計が掛け直されず、次の出来事まで keep-alive が出なくなる | MCP-HTTPSTREAM-20 (keep-alive は周期ごとに出る)。案 T1: 下の「足すテストの案」 |
| `src/transport/first_of.nim:SDL:36d44f174725a394:0` | first_of.nim:55 | `bell.deliver(result)` → `discard` | test_owed | 上と同じ場面 (誰も待っていない間に鳴った) で、次の `wait` が完了せず `rung` も真のまま残るので、その接続の配送ループが止まる。以後のイベントも keep-alive も書かれない | MCP-HTTPSTREAM-20。案 T1 (同じ 1 本) |
| `src/transport/http.nim:ROR:3f525d5735463583:0` | http.nim:146 | `declared.bindings.len > 0` → `>=` | equivalent | 束縛が空の tool に空の seq が入るだけ。`paramHeaderFor` は `hasKey` で入るが、`paramHeadersFor` は空の束縛では何も足さず断りも返さない | — |
| `src/transport/http.nim:ROR:dd1900757d85feff:0` | http.nim:244 | `index >= 0` → `>` | equivalent | 先頭の閉じた応答が `t.streams` に残るだけ。`streams` を読むのは `untrack` の `find` (参照の同一性) と `close()` で、`WireResponse.close` は閉じ済みなら何もしない。公開の入口から見えるものは変わらない (残るのはメモリだけ) | — |
| `src/transport/http.nim:SDL:9910722072133c8e:0` | http.nim:245 | `t.streams.delete(index)` → `discard` | equivalent | 上と同じ。閉じた応答が `close()` まで `t.streams` に残り、長く生きるトランスポートでは増え続けるが、公開の入口からは見えない (`streams` の長さを見る口が無い) | — |
| `src/transport/http.nim:ROR:c4ff7c8002fa0bae:0` | http.nim:267 | `event.id.len > 0` → `>=` | spec_question | サーバーが id を送った後に空の `id:` を送ると、解析器の最後の id が空になる。元は最後の空でない id を残して再開に使い、変異は消して再開しない (要求は lost と報告される)。外から見えるが、空の `id:` を定める仕様 ID が無い (MCP-HTTP-30 は「id の無いイベント」だけ) | 問い: 空の `id:` の後も最後の空でない id で再開する、を MCP-HTTP-30 に足すか。足さないなら条件を消して `lastEventId = event.id` にする (SSE の規格の読み) |
| `src/transport/http.nim:LOR:56c66a7ffe4ae195:0` | http.nim:279 | `not t.closed and (…)` → `or` | unreached | 差が出るのは `t.closed` が真のまま `consume` が例外で終わるときだけ。`close()` は追跡中の全ストリームを閉じ、`track` は閉じた後に開いたものをその場で閉じる。閉じた応答の `receive` は例外ではなく中断 (`r.closed` で `interrupted`) を返すので、その経路が無い | — |
| `src/transport/http.nim:RVR:f05a7a388d80ae9f:0` | http.nim:303 | `return none(WireResponse)` → `<return default>` | equivalent | `default(Option[WireResponse])` は `none` と同じ値 | — |
| `src/transport/http.nim:SDL:d624ad06191cc360:0` | http.nim:311 | 末尾の式 `none(WireResponse)` → `discard` | equivalent | async proc の `result` の既定値が `none` なので、式を消しても戻り値は同じ | — |
| `src/transport/http.nim:RVR:43c46aaddc669ed7:0` | http.nim:335 | `return outcome.answered` → `<return default>` (false) | test_owed | 再開したストリームで応答が届いても `resume` が false を返し、`pump` が `reportLost` を呼ぶ: 応答が届いた要求に `onRequestLost` が呼ばれる。既存のテスト (`Given a resumed stream that carries the response …`) は「メッセージがもう届かない」だけを見ており、失われた報告がメッセージではなくなった今 (MCP-HTTP-49) は検出できない | MCP-HTTP-30・MCP-HTTP-49。案 T2 |
| `src/transport/http.nim:SDL:6a94f725a86c88ec:0` | http.nim:352 | `t.abandoned.excl key` → `discard` | test_owed | 取り消した id が `abandoned` に残り、同じ id の次の要求のストリームが切れても `onRequestLost` が呼ばれない。既存のテスト (`Given an id that was cancelled while its stream was open …`) は検出するはずだが、`lostIds`・`lostSeen` がファイル全体で共有され、直前のテストが残した読まれていない "r1" を `lostRequest()` が拾うので通ってしまう | MCP-HTTP-28 (cancelled id can be used again)。案 T3 |
| `src/transport/http.nim:ROR:3711cde0363a1b89:0` | http.nim:411 | `key.len > 0` → `>=` | accepted | 通知の POST の接続が `inflight[""]` に入る。見えるのは `cancelRequest("")` を呼んだときだけ。前の記録「id 83 (`http.nim` の `key.len > 0`): 空文字列の id の要求は取り消せない。SDK のクライアントは空の id を作らない」「2026-10-12 に今のままと決めた」(下の「残っているもの」と g2g-hc-b の節) による。記録に決めた人の名は無い | 条件を `not requestId.isNil` にすれば、この行と下の 2 行の変異は生まれない |
| `src/transport/http.nim:ROR:3711cde0363a1b89:1` | http.nim:418 | `key.len > 0` → `>=` | equivalent | 411 行が `""` を入れないので、`inflight` に無い `""` を `del` するだけ | — |
| `src/transport/http.nim:ROR:3711cde0363a1b89:2` | http.nim:445 | `key.len > 0` → `>=` | equivalent | 同上 | — |
| `src/transport/http.nim:ROR:f99471a73a0fec35:1` | http.nim:482 | `text.len > 0` → `>=` | equivalent | 空の本文は `parseJson("")` が例外を出し、直後の `except` が `nil` にする。条件が偽のときと同じく HTTP のエラーになる | — |
| `src/transport/http.nim:SDL:bb40b74fada7da28:0` | http.nim:510 | `t.inflight.del requestId` → `discard` | equivalent | 取り消した要求の項目は、接続の失敗 (418 行)・本文の読み終わり (445 行)・`pumpAnswer` のどれかが必ず消す。それまでの間の 2 度目の取り消しは、集合への同じ id の追加と閉じ済みの接続の `close` で、何も変えない | — |
| `src/transport/http.nim:BLR:3adb551801d7e426:0` | http.nim:526 | `var retry = false` → `true` | equivalent | 直後の `try` が `retry` に必ず代入するか、例外で抜ける | — |
| `src/transport/http.nim:SDL:d18cca18d4f2372e:0` | http.nim:615 | `stderr.writeLine("… DELETE … timed out")` → `discard` | spec_question | DELETE に 5 秒 (`DeleteTimeoutMs`、定数) 答えないサーバーのときの 1 行が出なくなる。閉じること自体は成功のまま。MCP-HTTP-36 が定めるのは「500 か切断を記録する」で、答えないサーバーは入っていない | 問い: 「DELETE に答えないサーバーも記録する」を MCP-HTTP-36 に足すか (5 秒待つテストになる。待ち時間を設定にすれば短くできる)、診断の 1 行として受け入れるか |
| `src/transport/http.nim:SDL:9a1cd9d884668560:0` | http.nim:630 | `t.streams.setLen(0)` → `discard` | equivalent | `close()` の後に `t.streams` を読むのは、読み終えた `untrack` の `find` と `delete` だけ。`closed` が立っているので `close()` の 2 度目は何もしない | — |
| `src/transport/sse_legacy.nim:ROR:09f7b2257dfb84c7:0` | sse_legacy.nim:100 | `event.data.len > t.maxResponseSize` → `>=` | unreached | 差が出るのは data がちょうど `maxResponseSize` バイトのとき。解析器 (`initSseParser(max, max)`) は `data` の値の長さ + 1 が `max` を超えると `SseLimitError` で先に断る (`event_stream.nim` の `takeLine`) ので、ここに届く data は `max - 1` バイトまで | — |
| `src/transport/sse_legacy.nim:SDL:b82c8dfda034100c:0` | sse_legacy.nim:139 | `await ready` → `discard` | equivalent | `withTimeout(ready, …)` は `ready` が失敗していればその失敗で自分が失敗する (標準ライブラリの今の実装)。真を返した時点で `ready` は成功しており、`await ready` は何も足さない | — |

足すテストの案:

- T1 (MCP-HTTPSTREAM-20。first_of.nim の 2 件): `tests/external/test_http_streams.nim` の keep-alive の suite に足す。短い `sseKeepAliveMs` のサーバーの GET ストリームを開き、クライアントが読まないまま、ソケットのバッファが埋まるだけの通知をサーバーから送る (書き込みが keep-alive の周期より長く止まる)。そのあと全部読み、何も送らずに keep-alive が周期のうちに届くこと、続けて送った通知が届くことを見る。BLR では keep-alive が届かず、SDL では keep-alive も後の通知も届かない。このテストのファイルは http_client のジョブの testCommand に入っていないので、足すか、`first_of.nim` を http_server のジョブの sources に移す。
- T2 (MCP-HTTP-30・MCP-HTTP-49。http.nim:335): `tests/external/test_http_client_streams.nim` の `Given a resumed stream that carries the response, when it ends, …` に、`onRequestLost` がこのテストの間に 1 度も呼ばれないことの確かめを足す (テストの中で置いた数え手で数える)。変異では "r1" が 1 度報告される。
- T3 (MCP-HTTP-28。http.nim:352): 同じファイルの `Given an id that was cancelled while its stream was open, …` で、失われた報告をテストの中の数え手で受ける (ファイルで共有している `lostIds`・`lostSeen` を使わない)。変異では 2 度目の "r1" が報告されず落ちる。共有の数え手は、ほかの `lostRequest()` の確かめも同じ理由で弱めている。

### http.nim・sse_legacy.nim・first_of.nim・http_compat.nim の timeout

39 件のうち 23 件。どれも「遅いだけ」ではなく、テストが通らなくなる変異と読んだ (走らせてはいない)。

- 譲らずに回り続ける (無限ループ) 6 件:
  first_of.nim:31 (`rung` が真のまま残り、`sse_stream.nim` の配送ループの `wait` が毎回すぐ返る)、
  http.nim:264 (ストリームの終わりの空の読み取りで抜けない)、
  http.nim:535 (認可のやり直しの回数が増えない)、
  http.nim:632・sse_legacy.nim:70・sse_legacy.nim:196 (待ち手を取り出さない `while t.waiters.len > 0`)。
- 待ちが終わらない 17 件:
  first_of.nim:34・41・49・65 (`firstOf` が完了しない)、
  http.nim:231 (イベントストリームを本文として最後まで読もうとする)、
  http.nim:494 (HTTP のエラーに載った JSON-RPC の答えを配らない)、
  http_compat.nim:43・70・80 (決まったことが伝わらない・要求を送らない・決まる前に Streamable 側で待つ)、
  sse_legacy.nim:59・61・103・186 (届いたメッセージを待ち手に渡さない・待ち手を置かない)、
  sse_legacy.nim:114 (ストリームの終わりで待ち手を失敗させない)、
  sse_legacy.nim:154・169・172 (接続しない・要求や通知を送らない)。

## 最初の測定 (本線の 36a4c8a5、2026-10-07)

測定: `nim-muter`、ジョブ `tests/mutation/http_client.json`、本線の 36a4c8a5 (2026-10-07)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 369 | 173 | 29 | 149 | 0 | 18 |

生き残り 149 件の分類 (4 人で分担し、下の 4 節に 1 件ずつ記録した)。

| 分類 | http.nim 134〜346 行 | http.nim 349〜572 行と http_compat.nim | http_wire.nim | sse_legacy.nim | 計 |
|---|---:|---:|---:|---:|---:|
| 1 同値 | 3 | 7 | 3 | 0 | 13 |
| 2 / 2b 既存テストで検出 (`test_auth_client_flow` をジョブに追加、ほか 1 件は測定後のテスト) | 1 | 1 | 0 | 0 | 2 |
| 3 穴 (テストを追加、全件で変異を当てて確認) | 37 | 25 | 40 | 14 | 116 |
| 4 到達しない・冗長 | 1 | 0 | 5 | 4 | 10 |
| 6 許容 | 3 | 2 | 2 | 0 | 7 |
| 測定後に置き換わった文 (置き換え後の文で確認) | 0 | 0 | 1 | 0 | 1 |
| 計 | 45 | 35 | 51 | 18 | 149 |

## 見つかった不具合 (6 件、どれも落ちるテストを先に書いて修正)

| 場所 | 不具合 | 修正 |
|---|---|---|
| `http.nim` `postOnce` | イベントストリームで答えた要求が、ストリームの終了後も `inflight` に残る。閉じた接続が溜まり、その id を後から取り消すと、同じ id の次の要求のストリーム切断のエラーが握りつぶされて呼び出し側が待ち続ける | `fix(transport): forget a request whose event stream has ended` |
| `http.nim` `track` | `close()` の後に開き終わったストリームを誰も閉じない。閉じたトランスポートへメッセージを配り続ける | `fix(transport): close a stream that finishes opening after the transport closed` |
| `http_wire.nim` `receive` | `close()` で起こされた読み取りが "Bad file descriptor" の失敗になる。`readSome` は "" を返し、ヘッダ待ちは「打ち切られた」で終わるのが本来 | `fix(transport): a read woken by close() of its response ends quietly` |
| `http_wire.nim` `chooseBodyMode` | `Content-Length: -5` を受け入れ、空の本文として扱う | `fix(transport): refuse a negative Content-Length` |

取り込みの後、担当が読んで挙げた 2 つの疑いをリードがテストで再現し、直した (`fix(transport): a stream that answers a notification, and a cancelled request, are left alone`):

| 場所 | 不具合 | テスト |
|---|---|---|
| `http.nim` `pump` | 通知の POST にサーバーがイベントストリームで答えると、ストリームの終了時に nil の id を読んで **クライアントのプロセスが SIGSEGV で落ちる** (相手のサーバーが起こせる) | MCP-HTTP-40 |
| `http.nim` `pump` / `resume` | イベント id を受け取った後に取り消した要求を、`Last-Event-ID` で再開し、取り消したはずの答えを配る | MCP-HTTP-41 |

3 つ目の修正には、取り込み時にリードが 1 点足した: `readAll` は、`close()` が本文の途中で読み取りを終わらせたときは
`McpTransportError` を上げる (それまでに読めた分は本文ではない)。足さないと、取り消された要求の途中までの JSON が
「不正な JSON-RPC メッセージ」として報告されていた (2 人の修正を合わせたときに `test_http_client_streams` が落ちて分かった)。

## 分類 4 の扱い (リードの判断)。今回はどれも残す

| id | 場所 | 内容 | 残す理由 |
|---|---|---|---|
| 3、4 | `sse_legacy.nim` の `port` | 測定後に削除済み (呼び出し元が無かった) | — |
| 13 | `sse_legacy.nim` の `event.data.len > t.maxResponseSize` | 解析器が同じ上限で先に止める | 上限の二重の守り。解析器の上限の決め方が変わっても、配送する 1 件の大きさはここで決まる |
| 33 | `sse_legacy.nim` の `await ready` | `withTimeout` が失敗を伝えるので何も足さない | 失敗を伝えるのは標準ライブラリの今の実装の振る舞い。`endpoint` の待ちの失敗をここで上げる、という意図をコードに残す |
| 284 | `http_wire.nim` の `not isClosed` | `AsyncSocket.close` は閉じ済みなら何もしない | 二重に閉じない、を呼ぶ側で言う |
| 341 | `http_wire.nim:292` | 直後の `raise` が `except` に捕まり、そこの `close()` が先に走る | 失敗の経路ごとに接続を閉じる、を保つ |
| 327 | `http_wire.nim` `receive` の 2 つ目の `try`/`except` | 修正後は届かない | future の値を読む場所が、その失敗が出る場所。`firstOf` の振る舞いに頼らない |
| 302 | `http_wire.nim` `readSome` の `bmNone` | `chooseBodyMode` が先に `finished` を立てる | `case` の網羅 |
| 266 | `http_wire.nim` の `n > 0` | 常に真 | 空の文字列を「本文の終わり」と読ませないための条件 |
| 104 | `http.nim:256` の `t.closed` | 上の `track` の修正後は届かない | 閉じたトランスポートの読み取りの失敗を報告しない、という防御 |

## 内部実装テストの扱い

`tests/test_http_wire_internals.nim` は `http_wire.nim` を `include` して内部の関数を直接見る内部実装テスト。
変異検査のコマンドは外部仕様テストだけにするので、**ジョブには入れていない** (担当の提案を採らなかった)。
このテストでしか検出できない変異は次のとおりで、許容とする。

- id 233 (`requestText` の `Host` ヘッダーで既定のポートを省く): 外から見るには 80 番で待つサーバーが要る。
- `receive` の冒頭の「閉じ済みなら読み始めない」: 公開の口からは届かない。

## 残っているもの

- 許容 7 件と上の 2 件。理由は各節の行。
- id 83 (`http.nim` の `key.len > 0`): 空文字列の id の要求は取り消せない。SDK のクライアントは空の id を作らない。
- `sameOrigin` は既定のポートの明示と省略を別オリジンと見る (`g2-protocol-versions.md` の注)。2026-10-12 に今のままと決めた。
- `http.nim:153` の `hasKey("id")` は `isResponse` に含まれる冗長な条件 (変異の対象外)。

## G2 変異検査: http_client (src/transport/http.nim 134-346 行、g2g-hc-a の担当分)

ジョブ `http_client` の全体の測定値 (コミット 36a4c8a5): 変異 369、killed 173、timeout 29、survived 149、compileError 18、runError 0。

この文書は、そのうち `src/transport/http.nim` の 134 行から 346 行までの survived 45 件 (依頼文は 41 件としていたが、報告を数え直すと 45 件) を扱う。`http.nim` はこの測定以後に変わっていないため、行番号は現在の本線と一致する。残りの行は g2g-hc-b (349 行以降と http_compat.nim)、g2g-hc-c (http_wire.nim)、g2g-hc-d (sse_legacy.nim) が持つ。

分類の件数: 1 (等価) 3、2b (測定後に足されたテストが検出) 1、3 (穴。テストを足して確認) 37、4 (冗長なコード) 1、6 (受け入れ) 3、runError 0。クラス 5 (欠陥) は変異の分類ではなく、読解中に見つけた 1 件を別に直した (後述)。

穴 (クラス 3) の 37 件は、変異を 1 件ずつ手で当て、名指しのテストが落ちることを見たうえで `jj restore` で戻した。確認の欠けたものはない。報告 (`~/.kuratsugi/runs/.../http_client.report.json`) は作業の途中で消えたため、id・行・変異は着手時に控えた一覧による。

テストはどれも、ジョブの testCommand に入っている `tests/test_http_client_streams.nim` と `tests/test_param_headers_http.nim` に足した (新しい suite、名前の末尾が `(mutation review, g2g-hc-a)`)。ジョブ定義 `tests/mutation/http_client.json` は変えていない。仕様 ID は `MCP-HTTP-26` から `-6` (リードが付け替える)。版の確認は既定版 (2026-07-28) と `-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25` で行った。

### 一覧

テスト名は長いので、`P:` は test_param_headers_http.nim、`S:` は test_http_client_streams.nim の、末尾が `(mutation review, g2g-hc-a)` の suite にあるテスト (名前の一部) を指す。全文は specs/tests.map にある。

| id | 行 | mutator | 原文 → 置換 | クラス | 理由・検出するテスト |
|---|---|---|---|---|---|
| 95 | 134 | LOR | `tools.isNil or kind != JArray` → `and` | 3 | tools が無い・配列でない answer で nil を読んで落ちる。P: `tools/list answer without a tools member`、`whose tools member is no array` |
| 144 | 141 | SDL | 無効な tool を無視する旨のログ | 3 | P: `tool listed with an invalid x-mcp-header ... says which tool it left out` (ログに tool 名が出る、1 行) |
| 145 | 143 | SDL | `paramBindings.del name` (無効な宣言の分) | 3 | 一度有効に載った tool が次の一覧で無効になっても古い束縛が残り、ヘッダーを付け続ける。P: `next listing declares it invalid ... no longer carries the header` |
| 63 | 145 | ROR | `bindings.len > 0` → `>=` | 1 | 束縛が空の tool に空の seq が入るだけ。`paramHeadersFor` は空の束縛ではヘッダーを足さず拒否も返さない (for が空回り) ので、観測できる差は無い |
| 146 | 148 | SDL | `paramBindings.del name` (宣言が無くなった分) | 3 | P: `next listing no longer declares it ... no longer carries the header` |
| 97 | 153 | LOR | `isResponse and hasKey("id")` → `or` | 3 | `isResponse` は id の存在を含むので `hasKey` は冗長 (置換後は `hasKey` だけになる)。差が出るのは id の衝突、サーバーの要求が tools/list の id と同じ時。P: `request of the server whose id equals that of a pending tools/list` |
| 147 | 154 | SDL | `toolListIds.excl` | 3 | 答えた後も id が残り、同じ id の 2 通目が再び学習される。P: `tools/list answered twice with the same id` |
| 98 | 156 | LOR | `not listed.isNil and kind == JObject` → `or` | 2b | error 応答で nil を読んで落ちる。P の `Given a header mismatch and a tool list that cannot be read ...` (測定コミットには無いテスト) が、変異を当てて落ちる (SIGSEGV) のを確認した。ファイルはジョブに入っている |
| 66 | 164 | ROR | `text.len > maxResponseSize` → `>=` | 3 | S: `body exactly as long as the limit ... delivered` |
| 101 | 176 | LOR | `kind == JObject and jsonrpc == "2.0"` → `or` | 3 | jsonrpc の無い error 本文を JSON-RPC 応答として配ってしまう。S: `HTTP error whose JSON body has an error but no jsonrpc version` |
| 100 | 176 | LOR | `(A and B) and C` の B と C の間 → `or` | 3 | 本文が JSON の配列だと `body{"error"}` が nil で落ち、jsonrpc の無い error 本文は通ってしまう。S: 上と `HTTP error whose JSON body is no object` |
| 152 | 194 | SDL | `MCP-Protocol-Version` を足す行 | 3 | S: `negotiated version that has the header ... each request names the version` (POST・GET・DELETE の 3 本が落ちる)。既定版 2026-07-28 の測定ではこの行は一度も通らなかった (交渉した版が新式だと `protocolVersion` が入らない) ため生き残っていた |
| 154 | 216 | SDL | `streams.add` | 3 | close が GET ストリームを閉じず、接続が残る。S: `GET stream that is open, when the client closes, then the connection of the stream is closed` |
| 155 | 219 | SDL | `untrack` の `response.close()` | 3 | JSON でないイベントでストリームが途切れても接続を閉じない (本文を最後まで読めた場合は wire が自分で閉じるので差が出ない)。S: `event that is no JSON, when it arrives on the stream of a request ... closes the connection` |
| 71 | 221 | ROR | `index >= 0` → `>` | 6 | 先頭 (index 0) の閉じた応答が `streams` に残るだけ。`close()` が閉じ済みの応答をもう一度閉じても無害 (`WireResponse.close` は冪等)。外から見えず、メモリが解放されないだけ。リードへの報告に挙げる |
| 156 | 222 | SDL | `streams.delete(index)` | 6 | 71 と同じ。閉じた応答が残り続ける (長寿命のトランスポートで増える) が、外から見えない |
| 73 | 244 | ROR | `event.id.len > 0` → `>=` | 6 | `SseEvent.id` はパーサーが持つ「最後の id」(event_stream.nim:58) で、id の無いイベントでも前の id が入る。`id` が空なのは「まだ id が来ていない」時か、サーバーが空の `id:` で SSE 仕様どおり id を消した時だけ。前者は差が無い。後者では原文が最後の既知の id を残し、置換は消す。MCP は空の `id:` を定めておらず、最後の既知の id から再開できる方が有用なので、固定しない |
| 103 | 249 | LOR | `not answered and isResponse` の `and` → `or` | 3 | S: `stream with a request of the server that has the id of the posted request` |
| 102 | 249 | LOR | `... and id == requestId` の `and` → `or` | 3 | S: 上と `stream that carries the response to another request` |
| 75 | 249 | ROR | `id == requestId` → `!=` | 3 | S: `stream that carries the response to another request`、`stream that carries the response and then ends` |
| 133 | 250 | BLR | `answered = true` → `false` | 3 | 応答の後に不要な stream-closed エラーが配られる。S: `stream that carries the response and then ends ... nothing else is delivered`、`resumed stream that carries the response` |
| 134 | 251 | BLR | `delivered = true` → `false` | 3 | 再開・再接続の試行回数が「何か届いたら 0 に戻る」にならない。S: `server that says something on every resumed stream ... the response still arrives` |
| 104 | 256 | LOR | `not closed and (...)` → `or` | 4 | `closed` が真のまま consume が例外で終わる経路が無い。`close()` は追跡済みの全ストリームを閉じ、読み手は例外ではなく中断 (`readSome` が "" を返す) で終わる。直す前は、`close` の後に開き終わったストリームがあり得た (下のクラス 5) が、直した後は無い。防御的な条件で、変異は観測できない |
| 105 | 256 | LOR | `requestId.isNil or notin abandoned` → `and` | 3 | POST では常にログが消え、GET では nil を読んで落ちる。S: `event that is no JSON, when it arrives on the stream of a request`、`no JSON on the GET stream` |
| 158 | 257 | SDL | ストリームが失敗した時のログ | 3 | 同じ 2 件 (ログに `event stream from <url> failed with McpTransportError`、1 行) |
| 159 | 260 | SDL | `untrack(response)` | 3 | 155 と同じテスト |
| 164 | 279 | SDL | GET が失敗した時のログ | 3 | S: `server that hangs up on the GET ... logs the failure once` |
| 210 | 280 | RVR | `return none(WireResponse)` → `default` | 1 | `default(Option[WireResponse])` は `none` と同じ値 |
| 107 | 281 | LOR | `is2xx and isEventStream` → `or` | 3 | event-stream でない 200 を読み続け、何度も GET する。S: `server that answers the GET with 200 and no event stream` |
| 165 | 282 | SDL | `track response` | 3 | 154 と同じテスト |
| 161 | 284 | SDL | event-stream でない応答の `response.close()` | 3 | S: `answers the GET with 200 and no event stream`、`answers the GET with 405` (サーバー側が切断を見る) |
| 77 | 285 | ROR | `code != Http405` → `==` | 3 | S: 上の 2 件 (405 では何も書かず、200 では書く) |
| 166 | 286 | SDL | 405 以外で断られた時のログ | 3 | S: `answers the GET with 200 and no event stream` (ログの 1 行) |
| 162 | 288 | SDL | 最後の式 `none(WireResponse)` | 1 | async proc の `result` の既定値が `none` なので、式を消しても戻り値は同じ |
| 110 | 296 | LOR | `not answered and not closed` → `or` | 3 | 応答が届いた後も再開を続け、GET をもう 1 回送る。S: `resumed stream that carries the response ... neither asks again` |
| 80 | 310 | ROR | `next.lastEventId.len > 0` → `>=` | 3 | id の無い再開ストリームで最後の id を失う。S: `resumed stream whose events carry no id ... next resumption still names the last id` |
| 212 | 311 | RVR | `return outcome.answered` → `default` | 3 | 再開で応答が届いたのに stream-closed エラーが配られる。S: `resumed stream that carries the response` |
| 113 | 321 | LOR | `not answered and not closed` → `or` | 3 | 応答の後、また close の後にも stream-closed エラーが配られる。S: `stream that carries the response and then ends`、`request whose event stream is open, when the client closes, then no stream-closed error is delivered` |
| 169 | 323 | SDL | `abandoned.excl` | 3 | 取り消した id を使い直すと、その id のエラーが握りつぶされる。S: `id that was cancelled while its stream was open ... used again` |
| 81 | 330 | ROR | `attempts <= maxReconnects` → `<` | 3 | S: `server that ends every GET stream at once ... asks once and as often again as it may reconnect` (GET は 1 + maxReconnects 回) |
| 82 | 335 | ROR | `outcome.lastEventId.len > 0` → `>=` | 3 | S: `GET streams whose later events carry no id ... every reconnection names the last id` |
| 171 | 340 | SDL | `inc attempts` | 3 | 何も届かない GET が止まらない。S: 81 と同じテスト |
| 172 | 342 | SDL | 再接続前の `sleepAsync` | 3 | S: `GET stream cut after a message ... waits for the reconnect delay` |
| 135 | 343 | BLR | `listening = false` → `true` | 3 | 終わった GET ストリームのあと、初期化し直しても開き直さない。S: `GET stream that ended because the server offers none ... initialized again, then it asks again` |
| 118 | 346 | LOR | `listening or closed` → `and` | 3 | 開いている間に初期化し直すと 2 本目を開く。S: `GET stream that is open, when the client is initialized again, then it does not open a second stream` |

### 読解中に見つけた欠陥 (クラス 5)

`http.nim` の `track` は、`close()` の後に開き終わったストリームも `streams` に足すだけで、誰も閉じなかった。`close()` は、その時点で追跡されているストリームしか閉じない。GET (`listen`、再開) の接続が `close()` と入れ違いに応答すると、その接続は開いたまま読み続けられ、閉じたトランスポートへメッセージを配った。

- 先に落ちるテスト (原文で確認): S: `GET stream still being opened, when the client closes, then the connection of that stream is closed as well`
- 修正: `fix(transport): close a stream that finishes opening after the transport was closed`。`track` が `closed` の時は足さずに閉じる。公開 API は変わらない。
- これで 104 の条件 (`closed` の時の例外) が成り立たなくなるため、104 はクラス 4 になる。

### 残っているもの

- 71、156 (クラス 6): `untrack` が `streams` から取り除かない場合、閉じた応答が `close()` まで残る。外から観測できず、メモリが残るだけ。テストにするには `streams` の長さを見る口が要る。リードの判断を仰ぐ。
- 73 (クラス 6): 空の `id:` フィールドの扱い。仕様に定めが無い。
- 104 (クラス 4): 防御的な条件。消すかどうかはリードの判断。
- 153 行の `message.hasKey("id")` は `isResponse` が含む冗長な条件 (変異の対象にはなっていない)。

## G2 変異検出: http_client (g2g-hc-b の分担)

ジョブ `http_client` (測定コミット 36a4c8a5) の合計は 369 件: killed 173 / timeout 29 / survived 149 / compileError 18 / runError 0。
この文書は、そのうち `src/transport/http.nim` の 349〜572 行の生き残り 29 件 (報告書から数えた件数。依頼では 33 件とあった) と、`src/transport/http_compat.nim` の 6 件の計 35 件を扱う。
行番号は測定時のもの (本線の先端では `pumpAnswer` を足したため、postOnce より後ろは 9 行ずれている)。

分類の件数 (35 件): 別のテストが検出 (2) が 1、ギャップを埋めたもの (3) が 25、同値 (1) が 7、到達不能または冗長 (4) が 0、受容 (6) が 2。(2b) はなし。
別に、欠陥 (5) を 1 件見つけて直した (下記 `pumpAnswer`。生き残りの行ではなく、テストを書く途中で見つけたもの)。

全部の変異を手で当て、名前を挙げたテストが落ちるのを見てから戻した (class 3 と 2)。`pumpAnswer` の後の 188 は、当てても落ちないのを確かめた。

### 見つかった欠陥 (class 5)

`http.nim` の `postOnce`: イベントストリームで答えた要求は、ストリームが終わっても `inflight` の表に残っていた (JSON で答えた要求は `finally` で消える)。
閉じた接続が要求ごとに 1 つ溜まり、`cancelRequest` は「答えた要求には何もしない」と文書にあるのに、そのような要求の id を取り消し済みとして `abandoned` に入れた。
そのまま同じ id で次の要求が (応答なしにストリームが切れて) 失敗すると、ストリーム切断のエラーが握りつぶされ、呼び出し側が返事を待ち続ける。
落ちるテストを先に書き (`Given a request whose answer was an event stream, when the client cancels it afterwards and sends the id again, ...`)、`pumpAnswer` でストリームが終わったときに表から消すようにした。コミット `fix(transport): forget a request whose event stream has ended`。

### 一覧

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
| 213 | http.nim:484 | RVR | `return false` → `<return default>` | 検出 (測り直し) | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。測り直し (76a08c6a) で検出された (現在の 505 行)。 |
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

### 確認したこと

- 検出するテストは、変異を当てた状態で 1 本ずつ (1 回の実行で 1 つの変異) 流し、落ちるのを見た。落ちた後は `jj restore` で戻した。
- 変更した 5 つのテストファイルは、既定版 2026-07-28、`-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25` で全部通る (`test_param_headers_http.nim` は 2025-11-25 のみ。2024-11-05 では新しい suite が `SpeaksModern` の外れで飛ばされるのは隣と同じ)。
- `tests/test_spec_coverage.nim` が通る。

### 残っているもの

- 83 (受容): `key.len > 0` は「id が無い (通知)」を「空の id」と区別しない。空文字列の id は JSON-RPC では正しいが、SDK のクライアントは作らず、`cancelRequest("")` を呼ぶ箇所もない。空の id の要求は取り消せない。直すなら条件を `not requestId.isNil` にする (3 か所)。2026-10-12 に今のままと決めた。
- 203 (受容): DELETE が 5 秒返らないときの診断 1 行。
- リードへ (本分担の外、`http.nim` 313〜323 行の `pump` と `resume`): (1) 通知の POST がイベントストリームで答えられると、`pump` の末尾 `t.abandoned.excl idKey(requestId)` が `requestId` の nil を引く疑い (読んだだけで、テストで再現していない)。(2) イベント id を受け取った後に取り消した要求は、`resume` が `Last-Event-ID` つきで GET をもう一度開き、取り消したはずの答えを配送し得る疑い (同じく未再現)。

## G2 変異検出: http_client の `http_wire.nim` (g2g-hc-c)

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

### 欠陥 (class 5)

1. `src/transport/http_wire.nim` の `receive` (現在 198 行目から): `close()` が読み取りの `interrupt` を完了してからソケットを閉じるため、待っていた recv が EBADF で失敗し、再開した `receive` が「`reading the response failed: Bad file descriptor`」を投げていた。意図して放棄した読み取り (`readSome` の待ち、リクエストの頭の待ち) が、`""` の返却や "was abandoned" でなくエラーで終わっていた。360 / 298 / 327 を調べていて見つけた。落ちるテストを先に書き (S5 の 2 件)、`fix(transport): a read woken by close() of its response ends quietly` で直した。
2. `chooseBodyMode` (現在 185 行目): `Content-Length: -5` を `parseInt` が受け付け、長さ -5 の本文として空で終わっていた (RFC 9110 8.6 は数字のみ)。266 の `n > 0` が冗長な理由を詰める中で見つけた。落ちるテストを先に書き、`fix(transport): refuse a negative Content-Length` で直した。`+5` は数値として通るままで、これは触っていない。

### 一覧

テスト名の略: S1〜S6 は `specs/security.feature` の `MCP-SEC-WIRE-15..6` (リードが採番し直す)。
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

### 残っているもの

- class 4 の 5 件 (284、341、327、302、266) は、冗長または到達しない文。削除はしていない。リードの判断を待つ。327 の節は修正で到達しなくなったので、`receive` の 2 つ目の `try` / `except` ごと消せる (`pending.read()` は成功した future の取り出しだけになる)。302 は `case` の網羅のための枝。
- class 6 の 2 件 (306、326) は受け入れ。306 は X509 の参照の漏れで、挙動に現れない。326 は loopback で作れないカーネルの recv の失敗。
- `sameOrigin` がポートを書かれたとおりに比べる (既定ポートを明記すると別オリジンになる) のは記録済みで、直していない (安全側)。
- 修正の過程で `receive` の冒頭に「close 済みなら読み始めずに中断を返す」分岐を足した。公開インタフェース越しには到達できない (close すると `finished` になり `readSome` は入らず、`exchangeHead` は先に send で失敗する) ため、`test_http_wire_internals` が直接確かめる。
- 実行した確認: `test_security_wire_headers` (3 つの既定版、`-d:ssl` 有り無し)、`test_http_wire_internals` (3 版)、`test_security_wire_tls` (`-d:ssl`、3 版)、ジョブの他のテスト全部 (既定版)、`test_spec_coverage`。
- 変異を手で当てたのは修正後のソースで、テストは最終版と同じ内容 (suite を末尾へ並べ替える前)。並べ替えた後に全変異を当て直してはいない。

## G2 変異検出: http_client ジョブ、sse_legacy.nim の分 (g2g-hc-d)

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

追加したテストは `tests/test_http_sse_legacy.nim` 末尾の 2 つの suite (`... (mutation review, g2g-hc-d)`)。Scenario は `specs/http_sse.feature` の `MCP-HTTPSSE-12` から `-6`。サーバー側の挙動 (接続を閉じたか) は、生のソケットで待ち受ける手書きのサーバーから観測する。

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

### 残っているもの

- 分類 4 の 2 件は、削除するかどうかをリードが決める。`src/transport/sse_legacy.nim` の `await ready` (id 33、現在 135 行) と、`readLoop` の `event.data.len > t.maxResponseSize` の検査 (id 13、現在 96〜98 行)。同じ検査は `http.nim` の `readLoop` にもある (別の担当の範囲)。
- 受け入れとして残した変異は無い。
- 観察 (欠陥とは判断しなかった): endpoint が時間内に来ず `connect` が自分でストリームを閉じたとき、`readLoop` は `t.closed` がまだ偽なので、読み取りの失敗を `[mcp-sse] event stream ... failed with ...: Bad file descriptor` として stderr に書く。`close()` による意図した終了は報告しない、というコメントと同じ扱いが、`connect` の中の `response.close()` には及んでいない。テストの出力にこの行が出る。直すなら `t.closed` とは別に「自分で閉じた」を表す状態が要るので、リードに任せていた。2026-10-12 に今のままと決めた。
- 既知で直さないもの: `sameOrigin` は port を書かれたまま比べる (`http://h:80/` は `http://h/` と別の生成元になる)。この件のために書いたテストは無い。この担当の生き残りに、既定 port の差でしか区別できないものは無かった。

## 測り直し (本線 76a08c6a、2026-10-10)

36a4c8a5 の測定のあとに足したテストと修正を入れたコミットで、同じジョブを測り直した。変異 386、検出 291、時間切れ 40、コンパイル不能 22、**生き残り 33** (前回 149)。所要 285 分。前回のあとに `first_of.nim` (変異 10) がジョブの対象に加わっている。

前回の生き残りとの突き合わせは変異の指紋で行った (指紋が変わった行は、ファイル・変異の文面・近い行番号で合わせた)。33 件のうち 30 件は前回も生き残っていて、この文書に分類と理由がある。前回「穴」(分類 3) としてテストを足した変異は、1 件も残っていない。「未判定」としていた id 213 (`return false` → `return true`) は検出された。

### 新しく現れた生き残り 3 件 (どれも前回の測定のあとに入った行)

| 場所 | 変異 | 分類 | 理由 |
|---|---|---|---|
| `http.nim:306` | LOR `t.closed or idKey(requestId) in t.abandoned` → `and` | 3 穴 | 再開を待っている間 (ストリームが切れてから `GET` を出すまで) に取り消した要求を、再開してしまう。前からあるテストはストリームが開いている間に取り消していて、`resume` に入る前の検査で止まっていた。足したテスト (MCP-HTTP-41): Given a request whose stream was cut after an event id, when the client cancels it before the stream is asked for again, then it is not asked for and no answer arrives。変異を当てて落ちることを確かめた |
| `first_of.nim:43` | BLR `bell.rung = true` → `false` | 6 許容 | 誰も待っていないときに鳴った分を、次の `wait` に持ち越さなくなる。外部仕様テストからは、2 つの future が同じ回の待ちのうちに終わる巡り合わせでしか通らず、狙って作れない。内部実装テスト `tests/test_first_of.nim` (Given a future that finished while nobody waited, when a wait starts, then it completes at once ほか 2 本) が、この変異で落ちることを確かめた |
| `first_of.nim:55` | SDL `bell.deliver(result)` → `discard` | 6 許容 | 持ち越した分があるときの `wait` が終わらなくなる。上と同じ経路で、同じ 3 本の内部実装テストが落ちることを確かめた |

`first_of.nim` の 2 件は、内部実装テストで確かめていて外部仕様テストでは確かめていない、という扱いでよいかが利用者の判断になっていた。2026-10-12 に、内部実装テストの確認で許容すると決めた。

### 時間切れ 40 件

上限は 277 秒。27 件は前回も時間切れ。新しい 13 件:

- `first_of.nim` の 5 件 (31、34、41、49、65 行)。待ちを起こす文そのものを消す・無効にする変異で、待っている側が起きなくなる。
- 前回は検出だった 8 件 (`http.nim:246`、`http_wire.nim:190` の 3 件、`http_wire.nim:269`、`http_wire.nim:273`、`sse_legacy.nim:150`、`sse_legacy.nim:168`)。どのテストで止まっているかは調べていない。`http_server` の測り直しで見たのと同じく、前回のあとに足したテストが上限なしで待っている可能性がある (未確認)。

時間切れは「テストが通らなかった」側の結果で、生き残りの判定には影響しない。
