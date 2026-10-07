# G2 変異検査: http_client (src/transport/http.nim 134-346 行、g2g-hc-a の担当分)

ジョブ `http_client` の全体の測定値 (コミット 36a4c8a5): 変異 369、killed 173、timeout 29、survived 149、compileError 18、runError 0。

この文書は、そのうち `src/transport/http.nim` の 134 行から 346 行までの survived 45 件 (依頼文は 41 件としていたが、報告を数え直すと 45 件) を扱う。`http.nim` はこの測定以後に変わっていないため、行番号は現在の本線と一致する。残りの行は g2g-hc-b (349 行以降と http_compat.nim)、g2g-hc-c (http_wire.nim)、g2g-hc-d (sse_legacy.nim) が持つ。

分類の件数: 1 (等価) 3、2b (測定後に足されたテストが検出) 1、3 (穴。テストを足して確認) 37、4 (冗長なコード) 1、6 (受け入れ) 3、runError 0。クラス 5 (欠陥) は変異の分類ではなく、読解中に見つけた 1 件を別に直した (後述)。

穴 (クラス 3) の 37 件は、変異を 1 件ずつ手で当て、名指しのテストが落ちることを見たうえで `jj restore` で戻した。確認の欠けたものはない。報告 (`~/.kuratsugi/runs/.../http_client.report.json`) は作業の途中で消えたため、id・行・変異は着手時に控えた一覧による。

テストはどれも、ジョブの testCommand に入っている `tests/test_http_client_streams.nim` と `tests/test_param_headers_http.nim` に足した (新しい suite、名前の末尾が `(mutation review, g2g-hc-a)`)。ジョブ定義 `tests/mutation/http_client.json` は変えていない。仕様 ID は `MCP-HTTP-g2g-hc-a-1` から `-6` (リードが付け替える)。版の確認は既定版 (2026-07-28) と `-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25` で行った。

## 一覧

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

## 読解中に見つけた欠陥 (クラス 5)

`http.nim` の `track` は、`close()` の後に開き終わったストリームも `streams` に足すだけで、誰も閉じなかった。`close()` は、その時点で追跡されているストリームしか閉じない。GET (`listen`、再開) の接続が `close()` と入れ違いに応答すると、その接続は開いたまま読み続けられ、閉じたトランスポートへメッセージを配った。

- 先に落ちるテスト (原文で確認): S: `GET stream still being opened, when the client closes, then the connection of that stream is closed as well`
- 修正: `fix(transport): close a stream that finishes opening after the transport was closed`。`track` が `closed` の時は足さずに閉じる。公開 API は変わらない。
- これで 104 の条件 (`closed` の時の例外) が成り立たなくなるため、104 はクラス 4 になる。

## 残っているもの

- 71、156 (クラス 6): `untrack` が `streams` から取り除かない場合、閉じた応答が `close()` まで残る。外から観測できず、メモリが残るだけ。テストにするには `streams` の長さを見る口が要る。リードの判断を仰ぐ。
- 73 (クラス 6): 空の `id:` フィールドの扱い。仕様に定めが無い。
- 104 (クラス 4): 防御的な条件。消すかどうかはリードの判断。
- 153 行の `message.hasKey("id")` は `isResponse` が含む冗長な条件 (変異の対象にはなっていない)。
