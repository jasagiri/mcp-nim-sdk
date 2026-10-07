# G2 変異検出: http_client ジョブ

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

## 見つかった不具合 (4 件、どれも落ちるテストを先に書いて修正)

| 場所 | 不具合 | 修正 |
|---|---|---|
| `http.nim` `postOnce` | イベントストリームで答えた要求が、ストリームの終了後も `inflight` に残る。閉じた接続が溜まり、その id を後から取り消すと、同じ id の次の要求のストリーム切断のエラーが握りつぶされて呼び出し側が待ち続ける | `fix(transport): forget a request whose event stream has ended` |
| `http.nim` `track` | `close()` の後に開き終わったストリームを誰も閉じない。閉じたトランスポートへメッセージを配り続ける | `fix(transport): close a stream that finishes opening after the transport closed` |
| `http_wire.nim` `receive` | `close()` で起こされた読み取りが "Bad file descriptor" の失敗になる。`readSome` は "" を返し、ヘッダ待ちは「打ち切られた」で終わるのが本来 | `fix(transport): a read woken by close() of its response ends quietly` |
| `http_wire.nim` `chooseBodyMode` | `Content-Length: -5` を受け入れ、空の本文として扱う | `fix(transport): refuse a negative Content-Length` |

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
- `sameOrigin` は既定のポートの明示と省略を別オリジンと見る (`g2-protocol-versions.md` の注)。
- `http.nim:153` の `hasKey("id")` は `isResponse` に含まれる冗長な条件 (変異の対象外)。
- g2g-hc-b が読んで挙げた 2 つの疑い (`pump` 末尾の `abandoned.excl idKey(requestId)` が通知で nil を引く、取り消した要求を
  `resume` が再開して答えを配る) は、**再現も否定もしていない**。次に確かめる。

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

### 確認したこと

- 検出するテストは、変異を当てた状態で 1 本ずつ (1 回の実行で 1 つの変異) 流し、落ちるのを見た。落ちた後は `jj restore` で戻した。
- 変更した 5 つのテストファイルは、既定版 2026-07-28、`-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25` で全部通る (`test_param_headers_http.nim` は 2025-11-25 のみ。2024-11-05 では新しい suite が `SpeaksModern` の外れで飛ばされるのは隣と同じ)。
- `tests/test_spec_coverage.nim` が通る。

### 残っているもの

- 83 (受容): `key.len > 0` は「id が無い (通知)」を「空の id」と区別しない。空文字列の id は JSON-RPC では正しいが、SDK のクライアントは作らず、`cancelRequest("")` を呼ぶ箇所もない。空の id の要求は取り消せない。直すなら条件を `not requestId.isNil` にする (3 か所)。リードの判断に任せる。
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
- 観察 (欠陥とは判断しなかった): endpoint が時間内に来ず `connect` が自分でストリームを閉じたとき、`readLoop` は `t.closed` がまだ偽なので、読み取りの失敗を `[mcp-sse] event stream ... failed with ...: Bad file descriptor` として stderr に書く。`close()` による意図した終了は報告しない、というコメントと同じ扱いが、`connect` の中の `response.close()` には及んでいない。テストの出力にこの行が出る。直すなら `t.closed` とは別に「自分で閉じた」を表す状態が要るので、リードに任せる。
- 既知で直さないもの: `sameOrigin` は port を書かれたまま比べる (`http://h:80/` は `http://h/` と別の生成元になる)。この件のために書いたテストは無い。この担当の生き残りに、既定 port の差でしか区別できないものは無かった。
