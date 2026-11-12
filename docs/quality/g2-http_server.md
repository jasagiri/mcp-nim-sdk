# G2 変異検出: http_server ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/http_server.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。状態: 測定済み (仕分けは 2026-11-12、コードを読んで行った。変異を当てて流してはいない)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 401 | 332 | 26 | 29 | 0 | 14 |

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/transport/http_server.nim:LOR:098b466bdedd5d25:0` | http_server.nim:303 | `body.isNil or body.kind != JObject` → `and` | equivalent | `(A and B) or C` になる。`body` は `message[key]` か応答の `result` で nil にならず、`clientId` (`Exchange.idNode`) は `isRequest` を通った `item["id"]`・`message["id"]` なので nil にならない。object でない `body` は次の `body{"_meta"}` が nil を返し、同じ `return body` に着く | |
| `src/transport/http_server.nim:LOR:becbdc05a26c9e55:0` | http_server.nim:303 | `… or clientId.isNil` の左の `or` → `and` | equivalent | `A or (B and C)` になる。C (`clientId.isNil`) は上の理由で常に偽なので `A` だけが残り、object でない `body` は `meta.isNil` の枝で同じ `return body` に着く | |
| `src/transport/http_server.nim:ROR:9b77def2f96bc83b:0` | http_server.nim:474 | `(now - session.lastActive) * 1000 >= timeout` → `>` | unreached | 違いが出るのは、`epochTime()` 2 つの差がちょうど設定値に等しい一点だけ。時計を差し込む公開の口が無く、その一点を通る入力を作れない (境界の両側は既存の期限切れのテストが通る)。前の記録 (id 73) は担当の「受け入れ」で、代表の決定の記録は無いので accepted にはしていない | |
| `src/transport/http_server.nim:RVR:c309449461795c77:0` | http_server.nim:526 | `return if close < 0: value else: value[1 ..< close]` → `return ""` | test_owed | 角括弧つきの Host の名前が空になる。loopback は `full` で決まるので既存の `[::1]:port` のテストは通るが、`allowedHosts` に IPv6 の番地を載せたとき `[番地]:port` が 403 になる (元は通す) | MCP-SEC-HTTP-5 (「the listed hosts are served」)。`tests/external/test_security_http.nim`: `allowedHosts = @["2001:db8::1"]` の transport に `sendAs("[2001:db8::1]:8443", …/mcp, HttpPost, ping)` と `sendAs("[2001:db8::1]", …)` を送り、403 でないことを見る。変異だと 403 |
| `src/transport/http_server.nim:ROR:b954d4dbaf3b2860:0` | http_server.nim:526 | `close < 0` → `<=` | equivalent | `value.startsWith("[")` の後なので 0 番は `[` で、`find(']')` は -1 か 1 以上。0 は出ない | |
| `src/transport/http_server.nim:ROR:0f037721df479561:0` | http_server.nim:528 | `colon >= 0` → `>` | spec_question | 違いが出るのは Host が `:80` のように `:` で始まるときだけで、名前が元は空文字列、変異は `:80` になる。`allowedHosts` に空文字列を入れた設定でだけ、元は通し変異は 403。問い: 空の名前の Host を `allowedHosts = @[""]` で通す挙動を仕様にするか、空の名前を常に断るようコードを直すか、仕様にせず残すか | 仕様 ID なし (MCP-SEC-HTTP-5 は空の名前に触れない) |
| `src/transport/http_server.nim:LOR:6446cd08fe02427a:0` | http_server.nim:528 | `colon >= 0 and value.count(':') == 1` → `or` | test_owed | 角括弧の無い、`:` が 2 つ以上の Host (裸の IPv6) が最後の `:` で切られる。loopback は `full` で決まるようになったので、既存の `::1` のテスト (MCP-HTTPSTREAM-18) はこの変異を見分けない。`allowedHosts = @["2001:db8::1"]` のとき、別の番地である `2001:db8::1:8443` が変異では通る (元は 403) | MCP-SEC-HTTP-5 / MCP-HTTPSTREAM-18 (「judged as the sender wrote it」)。上の 526 行と同じテストに `sendAs("2001:db8::1:8443", …) == Http403` を足す。変異だと 403 にならない |
| `src/transport/http_server.nim:SDL:2413a04126052c00:0` | http_server.nim:606 | `exchangeOf` の末尾の `none(string)` → `discard` | equivalent | `Option[string]` の `result` の既定値は none で、書かなくても同じ値が返る | |
| `src/transport/http_server.nim:ROR:97b629f387fc2d90:0` | http_server.nim:648 | `session.created < oldestAt` → `<=` | unreached | 違いが出るのは、追い出しの候補 2 つの `created` (`epochTime()`) がちょうど等しいときだけ (どちらを落とすかが入れ替わる)。別々の要求で作られるセッションの時刻を等しくする公開の口が無い。等しい 2 つのどちらが「いちばん古い」かは仕様に無い | |
| `src/transport/http_server.nim:BLR:ec9050dbd4339b51:0` | http_server.nim:696 | `cancel` の `group.abandoned = true` → `false` | equivalent | `abandoned` を読むのは `sendResponse` と `deliver` だけで、どちらも去った client のストリームへ push しないための早い return。変異すると、誰も読まないストリームと `group.responses` に溜まるだけで、交換の削除・`onRequestCancelled` の呼び出し・例外は変わらない。外から見える違いはメモリの使用量だけ (前の記録 id 213 で司会が「残す」と判断したコード) | |
| `src/transport/http_server.nim:RVR:55560fa5ef49175d:0` | http_server.nim:707 | `return none(JsonRpcError)` → 既定値 | equivalent | `Option[JsonRpcError]` の既定値は none | |
| `src/transport/http_server.nim:RVR:55560fa5ef49175d:1` | http_server.nim:710 | `return none(JsonRpcError)` → 既定値 | equivalent | 同上 | |
| `src/transport/http_server.nim:SDL:ac1cdc5394dff63c:0` | http_server.nim:715 | 末尾の `none(JsonRpcError)` → `discard` | equivalent | `result` を書かなければ既定値の none が返る | |
| `src/transport/http_server.nim:SDL:fc9c7696c04a0178:0` | http_server.nim:992 | 中断された要求の `req.client.close()` → `discard` | equivalent | ここに来るのは `gone` が先に終わったとき、つまり相手が接続を閉じた (読みが EOF か失敗) 後だけ。閉じなくても、ハンドラが戻ると `asynchttpserver` の `processClient` が次の要求を読んで EOF を受け、自分で閉じる。相手から見える違いは無く、変わるのは記述子を手放す時機だけ (前の記録 id 317。読んで決めた。記述子の数は測っていない) | |
| `src/transport/http_server.nim:ROR:ec6f999e329551a1:0` | http_server.nim:1004 | `group.pending > 0` → `>=` | equivalent | `pending == 0` なら全ての応答で `sendResponse` が `t.exchanges.del` を済ませているので、`cancel` は呼ぶ相手 (`onRequestCancelled`) を見つけない。変わるのは `group.abandoned` だけで、それを読む応答と通知はもうそのグループに来ない | |
| `src/transport/http_server.nim:SDL:ba5f3d9a3fc84eac:0` | http_server.nim:1077 | `stderr.writeLine("[mcp-http] authorization hook failed: " & $e.name)` → `discard` | spec_question | 500 で断ることと何も通さないことは保たれる (MCP-SEC-HTTP-9 のテストが見ている)。消えるのは診断の 1 行の全体で、文言の違いではない。問い: 認可フックの失敗を記録に 1 行残すことを MCP-SEC-HTTP-9 に足すか (トランスポート内部の失敗は MCP-SEC-HTTP-8 が「the log holds one line naming the failure」と定めている)、それとも「失敗の文面は契約ではない (代表の決定 2026-10-23)」に含めて accepted とするか | 仕様にするなら MCP-SEC-HTTP-9 に 1 句を足し、既存のテスト "Given an authorization hook that raises, …" で stderr を取って `[mcp-http] authorization hook failed: ` とエラーの型名を見る |
| `src/transport/http_server.nim:SDL:fc9c7696c04a0178:2` | http_server.nim:1178 | 書き込みの失敗の後の `req.client.close()` → `discard` | equivalent | 書き込みが OSError / IOError で失敗した = 相手は去っている。閉じなくても応答は誰にも届かず、接続は `processClient` の次の読みが EOF を受けて閉じる。相手から見える違いは無く、記述子を手放す時機だけが変わる (前の記録 id 356。読んで決めた。書き込みの失敗を決まった形で起こす方法は前の担当も見つけていない) | |
| `src/transport/http_server.nim:SDL:fc9c7696c04a0178:3` | http_server.nim:1185 | 500 の書き込みの失敗の後の `req.client.close()` → `discard` | equivalent | 同上 (前の記録 id 359) | |
| `src/transport/http_server.nim:SDL:9a1b2e84b3078684:0` | http_server.nim:1213 | 記述子が尽きたときの `await sleepAsync(50)` → `discard` | spec_question | 変異すると、記述子が上限の 5 つ手前まで使われたとき `serve` の輪が await なしで回り、イベントループが止まって進行中の交換も終わらない。枝に入る条件を作る公開の口が無い (`asynchttpserver` の `maxFDs` は非公開。前の担当は `setrlimit` で試して不安定だった)。問い: 「記述子が尽きても進行中の交換は終わる」を仕様にする (上限を下げる口を足す) か、仕様にせずコードを残すか | 仕様 ID なし |
| `src/transport/sse_stream.nim:RVR:f09e9e232af8b35b:0` | sse_stream.nim:77 | `push` の `return false` → `return true` | equivalent | 終わったストリームに何も足さずに戻る点は変わらず、変わるのは戻り値だけ。`push` の呼び手は `http_server.nim` の中だけで、全て `discard` している。`sse_stream` は公開の入口から export されない (`test_http_server_api.nim` が `serveStream` の非公開を確かめている)。**`push` の戻り値を無くせば、この変異は生まれない** | (MCP-HTTPSTREAM-19 の「the push is refused」は内部のテストだけが見ている) |
| `src/transport/sse_stream.nim:BLR:6ec2d660335697fb:0` | sse_stream.nim:77 | `return false` の `false` → `true` | equivalent | 上と同じ変異 (戻り値だけ) | |
| `src/transport/sse_stream.nim:BLR:b8309a95375a2001:0` | sse_stream.nim:83 | `push` の末尾の `true` → `false` | equivalent | 受け付けた event は足されて `wake` も済んでいる。変わるのは、どの呼び手も読まない戻り値だけ。`push` の戻り値を無くせば生まれない | |
| `src/transport/sse_stream.nim:ROR:e0b5738f1224ebef:0` | sse_stream.nim:97 | `dash <= 0` → `<` | equivalent | `-5` が空のストリーム id の event id として読まれるが、唯一の呼び手 `handleGet` では、空の id のストリームは `session.streams` にも `listen` にも無く (id は `newStreamId` の 16 桁)、`stream` が nil のまま同じ 400 になる | (MCP-HTTPSTREAM-19 の「a stream id is never empty」は内部のテストだけが見ている。外からは MCP-HTTPSTREAM-8 の 400 と区別できない) |
| `src/transport/sse_stream.nim:RVR:a64288e7521eef5f:0` | sse_stream.nim:98 | `return none(tuple[…])` → 既定値 | equivalent | `Option` の既定値は none | |
| `src/transport/sse_stream.nim:ROR:59cf3a8c74726a32:0` | sse_stream.nim:106 | `s.events.len > 0` → `>=` | unreached | 変異が違うのは event を 1 つも持たないストリームに `canResumeAfter` を尋ねたときだけ (`events[0]` で落ちる)。`handleGet` がそこへ行くには `Last-Event-ID` がそのストリームの id を名指す必要があるが、id は乱数で、event の `id:` 欄でしか client に渡らない。event を出したストリームは (`maxStreamEvents` が 1 以上なら) 空に戻らず、0 以下なら event が書かれないので id も渡らない | |
| `src/transport/sse_stream.nim:SDL:bab0d2220e6ff25c:0` | sse_stream.nim:169 | 最初の `bell.watch(idle)` → `discard` | test_owed | 何も起きないストリームで、最初の keep-alive のコメントが出ない (ほかの理由で起きるまで `idle` を見ない)。keep-alive を見るテストは内部側 (`serveStream` を直接呼び、短い周期を渡す) にしか無い | MCP-HTTPSTREAM-20 (「a keep-alive comment goes out and the stream stays open」)。`tests/external/test_http_streams.nim`: セッションの GET ストリームを開いて何も送らず、15 秒 (`DefaultKeepAliveMs`) 過ぎに `: keep-alive` のコメントが届き、ストリームが開いたままであることを見る。変異だとコメントが来ない。**周期を縮める公開の口が無いので、1 本で 15 秒以上かかる** |
| `src/transport/sse_stream.nim:ROR:e7951a920652ef89:0` | sse_stream.nim:186 | `batch.len > 0` → `>=` | test_owed | 何も書かなかった接続が `written` を `afterSeq` まで進める。GET ストリームで、どの接続も書いていない event の id を `Last-Event-ID` に名指して再開すると、その後に `Last-Event-ID` なしで開いた接続 (`writtenUpTo` の次から始まる) が、書かれていない event を受け取れなくなる | MCP-HTTPSTREAM-20 (「events that no connection wrote are not reported as written」)。`tests/external/test_http_streams.nim`: GET で通知 1 を受けて id を控えて切る → サーバーが通知 2・3 を送る → 同じストリームの 3 番を名指す `Last-Event-ID` で GET して切る → `Last-Event-ID` なしで GET し、通知 2・3 が届くことを見る。変異だと届かない |
| `src/transport/sse_stream.nim:SDL:bab0d2220e6ff25c:1` | sse_stream.nim:206 | 張り直した後の `bell.watch(idle)` → `discard` | test_owed | keep-alive のコメントが 1 回しか出ない (2 回目以降の時計を見ない) | MCP-HTTPSTREAM-20。上の 169 行のテストを 2 周期 (30 秒余り) 待ち、コメントが 2 回届くことを見る。変異だと 1 回 |
| `src/transport/sse_stream.nim:SDL:82dd9d5f40b493f4:0` | sse_stream.nim:208 | `await req.client.send(formatSseComment("keep-alive"))` → `discard` | test_owed | keep-alive のコメントが 1 回も出ない | MCP-HTTPSTREAM-20。169 行と同じテスト。変異だとコメントが来ない |

### 仕分けの件数と、決めてほしいこと

| class | 件数 |
|---|---|
| equivalent | 17 |
| unreached | 3 |
| test_owed | 6 |
| spec_question | 3 |
| accepted | 0 |
| undecided | 0 |

- test_owed は 3 本のテストにまとまる: Host の角括弧と裸の IPv6 (526 RVR・528 LOR、MCP-SEC-HTTP-5)、keep-alive (sse_stream 169・206・208、MCP-HTTPSTREAM-20)、書かれていない event の後からの再開 (sse_stream 186、MCP-HTTPSTREAM-20)。
- keep-alive のテストは、周期 (`DefaultKeepAliveMs` = 15 秒) を縮める公開の口が無いので、外部のテストでは 30 秒余り待つ。変異検査では全ての変異にこの時間が乗る。口 (transport の欄) を足すかどうかは実装の判断で、ここでは決めていない。
- 474 行と 648 行を unreached としたのは「等しい時刻を作る入力が無い」という意味で、変異した行そのものは実行される。台帳の語の当てはめが違えば、司会が直す。
- MCP-HTTPSTREAM-19 の「push は断られる」「ストリームの id は空にならない」は、公開の入口から違いが見えない (上の sse_stream 77・83・97 行)。この 2 句を確かめているのは内部のテストだけで、仕様の文が公開されていない部品について述べている。`push` の戻り値を無くし、この 2 句を仕様から外すと、戻り値の 3 件 (77 行の 2 件と 83 行) は生まれない。97 行は `handleGet` が同じ 400 を返すので、絞っても残る。

### 時間切れ 26 件

読んで分けた (流してはいない)。「輪」は await の無い輪が回り続けてイベントループごと止まるもの、「待ち」は応答や完了が来なくなり、テストの側が上限なしに待つもの。遅いだけで最後まで通りそうなものは見つからなかった。

| 指紋 | file:line | 変異 | 型 | 何が起きるか |
|---|---|---|---|---|
| `src/transport/http_server.nim:SDL:d610c71f3ae55a1a:0` | http_server.nim:286 | `t.receiveWaiters.addLast(fut)` → `discard` | 待ち | 待ち行列が空のときの `receive` が永久に終わらず、サーバーが何も処理しない |
| `src/transport/http_server.nim:SDL:4199325628733ac4:0` | http_server.nim:325 | `group.settled.complete()` → `discard` | 待ち | POST のハンドラが `settled` を待ったままになり、応答が出ない |
| `src/transport/http_server.nim:SDL:f7d3abf42827dfea:0` | http_server.nim:449 | 経路なしの `sendRequest` の `t.deliver(…)` → `discard` | 待ち | サーバーの要求が client に届かず、その答えを待つ側が止まる |
| `src/transport/http_server.nim:SDL:10c8e4a83bef4460:0` | http_server.nim:457 | `endSession` の `t.sessions.del(id)` → `discard` | 輪 | `claimSessionSlot` の `while` が、追い出しても数が減らないので終わらない |
| `src/transport/http_server.nim:SDL:6e3dce900617b756:0` | http_server.nim:484 | `close` の `open.add id` → `discard` | 待ち | `close` がセッションを終わらせず、ストリームが終わらないので読む側が待つ |
| `src/transport/http_server.nim:SDL:54cfc51f24478880:1` | http_server.nim:486 | `close` の `t.endSession(id)` → `discard` | 待ち | 同上 |
| `src/transport/http_server.nim:SDL:a2d687d161c7d12c:0` | http_server.nim:594 | `t.receiveWaiters.popFirst().complete(incoming)` → `discard` | 待ち | 待っている `receive` にメッセージが渡らず、失われる |
| `src/transport/http_server.nim:ROR:def43890a1075b4c:0` | http_server.nim:651 | `oldest.len == 0` → `!=` | 輪 | 追い出す相手が無いのに `evictUnused` が true を返し、`claimSessionSlot` の `while` が終わらない |
| `src/transport/http_server.nim:RVR:f09e9e232af8b35b:2` | http_server.nim:652 | `return false` → `return true` | 輪 | 同上 |
| `src/transport/http_server.nim:BLR:6ec2d660335697fb:2` | http_server.nim:652 | `false` → `true` | 輪 | 同上 |
| `src/transport/http_server.nim:SDL:9f007aabd17529b4:0` | http_server.nim:653 | `t.endSession(oldest)` → `discard` | 輪 | 追い出さずに true を返すので、同じ `while` が終わらない |
| `src/transport/http_server.nim:AOR:5e889f05fd3b94d8:0` | http_server.nim:673 | `t.exchanges.len + adding` → `-` | 待ち | 処理中の上限が効かず、503 で断られるはずの要求が受け取られて、誰も答えない応答を待つ |
| `src/transport/http_server.nim:SDL:72deb64d7463cbde:0` | http_server.nim:692 | `session.streams.del(oldestFinished)` → `discard` | 輪 | `rememberStream` の `while` が終わらない (前の記録 id 267 と同じ) |
| `src/transport/http_server.nim:SDL:9d0477eb81b3f7ea:0` | http_server.nim:982 | POST の `t.enqueue(forwarded, …)` → `discard` | 待ち | 要求がサーバーに渡らず、応答が出ない |
| `src/transport/http_server.nim:BLR:151811b9f2dad611:0` | http_server.nim:1015 | HTTP+SSE のセッションの `legacy: true` → `false` | 待ち | `/messages` への POST が 404 になり、ストリームで答えを待つ側が止まる |
| `src/transport/http_server.nim:ROR:0335069d73f0f1e9:0` | http_server.nim:1032 | `name == "sessionId"` → `!=` | 待ち | HTTP+SSE の POST が全て 400 になり、同上 |
| `src/transport/http_server.nim:ROR:5143bc440bd806f0:0` | http_server.nim:1034 | `id.len == 0` → `!=` | 待ち | 同上 |
| `src/transport/http_server.nim:ROR:438110fda31fdbde:0` | http_server.nim:1047 | `message.kind != JObject` → `==` | 待ち | 同上 |
| `src/transport/http_server.nim:SDL:d0bca8ed580ee62a:0` | http_server.nim:1059 | HTTP+SSE の POST の `t.enqueue(…)` → `discard` | 待ち | 要求がサーバーに渡らず、ストリームに答えが来ない |
| `src/transport/http_server.nim:ROR:5fbc5e7b4c5b3cbc:0` | http_server.nim:1153 | `req.reqMethod == HttpGet` → `!=` | 待ち | `/sse` の GET が 405 になり、HTTP+SSE の client がつながらない |
| `src/transport/http_server.nim:ROR:c742e14757ececfa:0` | http_server.nim:1158 | `req.reqMethod == HttpPost` → `!=` | 待ち | `/messages` の POST が 405 になり、答えを待つ側が止まる |
| `src/transport/http_server.nim:BLR:c3e32289b50152ba:0` | http_server.nim:1191 | `listen` の `t.started = true` → `false` | 待ち | `serve` の輪が 1 度も回らず、つないだ client が受け付けられない |
| `src/transport/http_server.nim:SDL:5cfa26fd3a2c1abc:0` | http_server.nim:1195 | `await sleepAsync(SweepIntervalMs)` → `discard` | 輪 | `sweepIdleSessions` の `while t.started` が await なしで回る |
| `src/transport/http_server.nim:SDL:91e4513a89546488:0` | http_server.nim:1206 | `await t.server.acceptRequest(requestHandler)` → `discard` | 輪 | `serve` の `while t.started` が await なしで回る |
| `src/transport/http_server.nim:SDL:58b525ad5f04e976:0` | http_server.nim:1218 | `start` の `await t.serve()` → `discard` | 待ち | `start` がすぐ終わり、誰も受け付けない |
| `src/transport/sse_stream.nim:SDL:afab93ac62dbff70:0` | sse_stream.nim:203 | `await bell.wait()` → `discard` | 輪 | `serveStream` の `while true` が await なしで回る |

「待ち」の 17 件は、テストが失敗として落ちずに上限なしで待っている。どのテストのどの待ちかは確かめていない (HTTP+SSE の 7 件は `tests/external/test_http_sse_legacy.nim` の待ちと見ている。未確認)。検出の判定には響かないが、測定の時間には響く。

## 最初の測定 (本線の 36a4c8a5、2026-10-07)

測定: `nim-muter`、ジョブ `tests/mutation/http_server.json`、本線の 36a4c8a5 (2026-10-07)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 391 | 218 | 64 | 94 | 0 | 15 |

生き残り 94 件の分類 (3 人で分担し、下の 3 節に 1 件ずつ記録した)。

| 分類 | http_server.nim 229〜668 行 | 679〜1036 行 | 1050〜1175 行と sse_stream.nim | 計 |
|---|---:|---:|---:|---:|
| 1 同値 | 6 | 4 | 2 | 12 |
| 2 ジョブに無かった既存テストで検出 (`test_http_documents` を追加) | 0 | 0 | 12 | 12 |
| 3 穴 (テストを追加、全件で変異を当てて確認) | 21 | 19 | 20 | 60 |
| 4 到達しない・冗長 | 1 | 3 | 0 | 4 |
| 6 許容 | 2 | 1 | 3 | 6 |
| 計 | 30 | 27 | 37 | 94 |

`http_server.nim` と `sse_stream.nim` は測定後に待ち方を `firstOf` / `Doorbell` に変えている
(`g2-protocol-versions.md` の「測定後に変わったモジュール」)。生き残りの文はすべて今のファイルに残っていた。
push の前の測り直しの対象。

## 分類 4 の扱い (リードの判断)

| id | 場所 (測定時) | 内容 | 判断 |
|---|---|---|---|
| 323 | `http_server.nim:975` | `handleLegacySse` の `session.touch()` | **削除した。** `lastActive` を読む `expireIdleSessions` は HTTP+SSE のセッションを対象にしない |
| 217 | `http_server.nim:1009` | HTTP+SSE の POST の `used = true` | **削除した。** `used` を読む `evictUnused` は HTTP+SSE のセッションを対象にしない |
| 317 | `http_server.nim:948` | 中断された要求の `req.client.close()` | 残す。記述子を手放す時機だけが変わる。標準ライブラリが後で閉じるという読みは実測していないので、自分で閉じる側に置く |
| 213 | `http_server.nim:668` | `cancel` の `group.abandoned = true` | 残す。取り消された要求の応答と通知を、誰も読まないストリームと `group.responses` に溜めないための文。外から見える違いは無い (メモリの使用量だけ) |

## 残っているもの

- 許容 6 件 (73、76、336、356、359、366)。理由は各節の行に書いた。366 (記述子が上限に近いときの `sleepAsync(50)`) は、
  上限を下げる口が `asynchttpserver` の非公開フィールドで、テストを書けない。
- 上の 317 と 213 は残したコード。

## G2: http_server (第 1 部、229〜668 行、g2f-hs-a)

測定は 36a4c8a5 (change `owwryuxn`) の `tests/mutation/http_server.json`。ジョブ全体の数字は total 391 / killed 218 / timeout 64 / survived 94 / runError 0 / compileError 15。
この文書はそのうち `src/transport/http_server.nim` の 229〜668 行 (測定時の行番号) にある生き残り 30 件を扱う。残りの行は別の担当 (679〜1036 行、1050〜1175 行と `sse_stream.nim`) で、リードが 3 部を 1 つに統合する。

測定後に `http_server.nim` は変わった (`or` による待ちを `firstOf` に替えた。941 行付近)。この部の 30 件はいずれも、その変更より前の文なので、現行の本線 (`kvonwtpk`) では測定時の行番号に +1 した位置にある。変異した文はすべて現行のファイルに残っている。

クラスは build/G2_BRIEF.md の 1〜6。手で変異を入れて落ちるテストを見たものだけを 3 と書いた。

### 結果の件数

表の行を数えた (30 件、全 id が 1 回ずつ)。

| クラス | 件数 | id |
|---|---|---|
| 1 同値 | 6 | 136, 135, 75, 377, 260, 90 |
| 2 他のテストで検出 | 0 | |
| 3 欠落 (テストを足し、手で変異を入れて落ちるのを確認) | 21 | 224, 202, 371, 372, 138, 243, 248, 71, 74, 143, 206, 150, 151, 92, 95, 264, 97, 266, 99, 100, 267 |
| 4 死んだコード / 効果が観測できない | 1 | 213 |
| 5 欠陥 | 0 | |
| 6 受け入れ | 2 | 73, 76 |

### 生き残りの一覧

テストの置き場: `H` = `tests/test_http_streams.nim` の suite "the HTTP server transport's own rules (mutation review, g2f-hs-a)"、`S` = `tests/test_security_http.nim` の suite "The Host header names this server, in its odd forms (mutation review, g2f-hs-a)"、`F` = `tests/test_version_floor.nim` の suite "an HTTP server transport for a version outside the build (mutation review, g2f-hs-a)"。

「確認」の欄は、その変異を手で入れてテストが落ちたことを見た、という意味。

| id | file:line (測定時) | mutator | original → replacement | クラス | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 224 | http_server.nim:229 | SDL | `requireSupported(protocolVersion)` → `discard` | 3 | 話さない版の transport は作れない。`F` "Given a version the build does not speak, when a transport is made for it, then ValueError is raised"。既定のビルドでは全版が話す版なので拒む相手がなく、`-d:mcpOldestProtocolVersion=2026-07-28` のビルド (ジョブが `test_version_floor.nim` を流している) で落ちる。確認: そのビルドで 4 版すべてについて `Expect Failed` |
| 202 | http_server.nim:255 | BLR | `started: false` → `true` | 3 | `H` "Given a transport that was never started, ..."。作っただけの transport は受け付けていない、listen で始まり close で止まる。確認 |
| 371 | http_server.nim:266 | RVR | `receiveMessage` の `return (await t.receive()).message` → `nil` | 3 | `H` "Given a posted request, when the server takes it with receiveMessage, then it gets the message"。確認 (method と id の検査が落ちる) |
| 136 | http_server.nim:279 | LOR | `body.isNil or body.kind != JObject or clientId.isNil` の 1 つ目の `or` → `and` | 1 | `(A and B) or C` になる。`body` は `message[key]` で、`hasKey` を確かめた後なので nil にならない (JSON の null も nil ではない)。非 nil の `body` では `A and B` は偽、`clientId` は nil にならない (下の 135) ので全体は偽になり、次の `body{"_meta"}` へ進む。`{}` は object でない節に対して nil を返す (std/json の仕様) ので、そこの `meta.isNil` が同じ `return body` に着く。戻り値は同じ |
| 135 | http_server.nim:279 | LOR | 同じ式の 2 つ目の `or` → `and` | 1 | `A or (B and C)` になる。C = `clientId.isNil` は偽: `Exchange.idNode` を作る場所は 2 つだけで (http_server.nim:936 の `item["id"]`、1014 の `message["id"]`)、どちらも欠けていれば KeyError になり、nil は入らない。C が偽なら `B and C` も偽で、非 object の `body` は 136 と同じ道で `return body` に着く |
| 372 | http_server.nim:280 | RVR | 同じ `if` の `return body` → `return default` (nil) | 3 | params が object でない通知 (JSON-RPC は配列の params を許す) が、要求の経路に載るとき送ったとおりに届く。`H` "Given a notification whose params is an array, when the server sends it on a request's stream, then it arrives as it was sent"。確認: 変異すると params が nil になり、JSON の直列化で SIGSEGV |
| 138 | http_server.nim:285 | LOR | `named.isNil or named.kind != JString or named.getStr() != exchangeId` の 2 つ目の `or` → `and` | 3 | 別の購読を名指す `_meta` の subscriptionId は書き換えず、この要求の交換 id を名指すものだけを client の id に直す。`H` "Given a subscription stream, when the server sends a notification that names another subscription, ..."。確認: 変異すると "other" が 7 に書き換わる (2026-07-28 のビルドのみ) |
| 243 | http_server.nim:435 | SDL | `endSession` の `stream.finish()` → `discard` | 3 | セッションが終わると、POST の応答ストリームも終わる。`H` "Given a response stream still open, when its session ends, then the stream ends"。確認: 変異するとストリームが 3 秒黙って `sse_reader` が落とす |
| 71 | http_server.nim:444 | ROR | `sessionIdleTimeoutMs <= 0` → `< 0` | 3 | 0 は「DELETE まで保つ」と型のコメントにある。`H` "Given a session timeout of 0, when idle sessions are expired long after the last request, then the session stays"。確認 |
| 73 | http_server.nim:450 | ROR | `(now - session.lastActive) * 1000 >= timeout` → `>` | 6 | 受け入れ。浮動小数の時刻 2 つの差がちょうど設定値に等しい瞬間の話で、時計を差し込む口がなく、等しい値を作れない。境界の片側は同じ式の別の値で毎回検査されている (`H` の既存テスト "idle sessions")。時間の定数の扱いとして、テストしない |
| 248 | http_server.nim:457 | SDL | `close` の `t.server.close()` → `discard` | 3 | close すると待ち受けの口が閉じ、接続が拒まれる。`H` "Given a transport that was never started, ..." (同じテストの後半)。確認: 変異すると close 後も接続できて `Expect Failed` |
| 74 | http_server.nim:471 | ROR | `contentType.len > 0` → `>= 0` | 3 | 本文のない応答 (202) に Content-Type は付かない。`H` "Given an initialized session, when a notification is posted on it, then the empty answer carries no Content-Type"。確認: 変異すると空の Content-Type が付く |
| 75 | http_server.nim:503 | ROR | `close < 0` → `<= 0` | 1 | `value.startsWith("[")` の後なので `value[0]` は `[` で、`]` は 0 番にならない。`find(']')` の結果は -1 か 1 以上で、`0` は出ない。両者は同じ結果になる |
| 76 | http_server.nim:505 | ROR | `colon >= 0` → `> 0` | 6 | 受け入れ。違いが出るのは Host の値が `:` で始まる (名前が空の) ときだけで、どちらでも拒まれる。差が出る唯一の場合は `allowedHosts` に空文字列を入れたときで、原文は `:80` を通し、変異は通さない。空の名前を許す設定は意味がないので、その挙動は固定しない |
| 143 | http_server.nim:505 | LOR | `colon >= 0 and value.count(':') == 1` → `or` | 3 | 角括弧のない IPv6 (`::1`) を名前として切り刻まない。`S` "Given a transport bound to loopback, when a request names the bare IPv6 loopback address, then it is served"。確認: 変異すると `::1` が `:` に切られて 403 |
| 377 | http_server.nim:515 | RVR | `return false` → `return default` | 検出 (測り直し) | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。測り直し (76a08c6a) で検出された。 |
| 206 | http_server.nim:515 | BLR | `return false` → `return true` | 3 | Host のない要求は 403 (DNS rebinding の対策)。`S` "Given a transport bound to loopback, when a request carries no Host header at all, then the answer is 403"。確認: 変異すると 400 になる (通ってしまう) |
| 150 | http_server.nim:576 | LOR | `owner == session and exchange.idNode == clientId` → `or` | 3 | 取り消しは、送り手のセッションの、その id の要求だけを名指す。`H` "Given two sessions that chose the same request ids, when one cancels its requests, then each notification names that session's own request"。既存の `test_security_http.nim` の同種のテストは `pendingExchangeCount` だけを見ていて、どの要求が取り消されたかは見ていなかった。新しいテストは、サーバーが受け取る通知の requestId が、どの交換 id かを見る。確認: 変異すると `http-3` を指す (正しくは `http-4`) |
| 260 | http_server.nim:578 | SDL | `exchangeOf` の最後の `none(string)` → `discard` | 1 | 結果の `Option[string]` の既定値は none で、`none(string)` と同じ |
| 151 | http_server.nim:594 | LOR | `session.len == 0 or named.isNil` → `and` | 3 | セッションのない取り消しは捨てる (2026-07-28 は接続を閉じて取り消す。交換 id を推測して他人の要求を取り消せてはならない)。この経路に着くのは、legacy 版を話さないビルド (`-d:mcpOldestProtocolVersion=2026-07-28`) だけで、混在ビルドではセッションのない通知は先に 400 になる。`F` "Given a request in progress on a server of 2026-07-28 alone, when a cancellation naming its id comes without a session, then it is not passed to the server"。ジョブはこのビルドで `test_version_floor.nim` を流している。確認: そのビルドで変異すると取り消しがサーバーに届く。なお既存の `test_security_http.nim` のテストは実サーバーを使い、2026-07-28 のサーバーが `notifications/cancelled` を無視するので、この変異を見分けられなかった |
| 90 | http_server.nim:620 | ROR | `session.created < oldestAt` → `<=` | 1 | 作成時刻が等しい 2 つのうちどちらが「いちばん古い」かは決まっていない。要求は順に来るので `created` はふつう異なり、異なる値では同じ結果になる。等しい場合の選択は仕様にない |
| 92 | http_server.nim:631 | ROR | `maxSessionsPerPeer > 0` → `>= 0` | 3 | 0 は「上限なし」。`H` "Given no limit on sessions per address (0), when a client initializes, then it gets a session"。確認: 変異すると最初の initialize が 503 になる |
| 95 | http_server.nim:635 | ROR | `sessions.len >= maxSessions` → `>` | 3 | 上限に達したとき、使われてアイドルになったセッションを捨てて新しい client に席を譲る。`H` "Given the session limit is reached by sessions that were used and then went idle, ..."。既存のテストはセッションを一度も使っておらず、使っていないセッションの追い出し (`evictUnused`) が先に効いてこの経路を通らなかった。確認 |
| 264 | http_server.nim:636 | SDL | `t.expireIdleSessions()` → `discard` | 3 | 95 と同じテスト。確認 |
| 97 | http_server.nim:644 | ROR | `requestQueue.len + adding > maxQueuedMessages` → `>=` | 3 | 上限ちょうどの数は受け取り、その次を断る。`H` "Given a limit of two queued messages and nobody receiving, when two requests are posted, then both are taken and a third is refused"。確認: 変異すると 2 件目が断られる |
| 266 | http_server.nim:652 | SDL | `legacyCeiling` の本体 → `discard` | 3 | initialize の応答が版を名指さないとき、そのセッションは build が話す最新の legacy 版として扱われ、話さない版のヘッダを 400 で断る。`H` "Given an initialize answer that names no version, when the session is used, then it is held to the newest version the build speaks and ..."。確認: 変異すると 2024-11-05 扱いになってヘッダを検査しない。2025-06-18 以降を話さないビルドでは `legacyCeiling` の値が既定値と同じになり、テストは動かない (既定のビルドと 2025-11-25 のビルドで動く) |
| 99 | http_server.nim:656 | ROR | `session.streams.len > maxStoredStreams` → `>=` | 3 | 上限ちょうどまでは終わったストリームを残す。`H` "Given a session that keeps two finished streams, when a second request ends, then both can be resumed"。確認: 変異すると最初のストリームが 400 で再開できない |
| 100 | http_server.nim:662 | ROR | `oldestFinished.len == 0` → `!= 0` | 3 | 上限を超えたら終わったストリームのうち古いものを捨てる。`H` "Given a session that keeps one finished stream, when a second request ends, then the first stream can no longer be resumed and the second can"。確認: 変異すると古いストリームが捨てられず 200 のまま |
| 267 | http_server.nim:664 | SDL | `session.streams.del(oldestFinished)` → `discard` | 3 | 100 と同じテスト。確認: 変異すると `while` が終わらず (終わったストリームを見つけても捨てない) テストが戻らない。60 秒の `timeout` で打ち切った。測定でも timeout (検出) になる種類 |
| 213 | http_server.nim:668 | BLR | `cancel` の `group.abandoned = true` → `false` | 4 | `abandoned` を読むのは `sendResponse` と `deliver` の 2 か所で、どちらも「もう誰も読まないストリームへ push しない」ためのもの。`cancel` が呼ばれるのは 2026-07-28 の要求だけ (http_server.nim:948, 961) で、その要求はセッションを持たないので、ストリームは `rememberStream` に入らず、再開もできない。取り消した後の書き込みは、`Exchange` から外れて誰も参照しない `group` の中にたまるだけで、外から観測できる違いがない。既存の "Given a cancelled request, when the server answers it anyway, then the answer is dropped without an error" は、フラグが無くても `pendingExchangeCount == 0` で通る。削除はしない。リードの判断を求める |

### 残っているもの

- 213 (クラス 4): `group.abandoned` の 2 つの保護は、外から観測できる効果を持たない。削除するか、効果を持たせる (取り消し後に push すると何が悪いのか) かをリードが決める。
- 73、76 (クラス 6): 上の理由で、固定するテストは書かない。
- 224、151 は、ジョブの `testCommand` にすでにある `-d:mcpOldestProtocolVersion=2026-07-28` の `test_version_floor.nim` で検出される。ほかの変異はすべて既定のビルドで検出される。`tests/mutation/*.json` は変えていない。
- 224 は `-d:mcpDefaultProtocolVersion=2025-11-25` のビルドでも検出される (2026-07-28 が話さない版になる)。

## G2 変異検出: http_server ジョブ (g2f-hs-b の分)

測定: `nim-muter`、ジョブ `tests/mutation/http_server.json` (`src/transport/http_server.nim`、`src/transport/sse_stream.nim`)、本線の 36a4c8a5 (2026-10-07)。
ジョブ全体の数: 全変異 391、killed 218、timeout 64、survived 94、runError 0、compileError 15。
このファイルは、そのうち `http_server.nim` の 679〜1036 行 (36a4c8a5 の行番号) にある生き残り 27 件の分。
ほかの行 (229〜668 行、1050〜1175 行、`sse_stream.nim`) は別の担当で、リードが 3 つの記録を 1 つにまとめる。
測定後に `http_server.nim` は変わった (待ちを `or` から `firstOf` へ: import が 1 行増えた) ので、現在の行は測定時の行 + 1。
文面で探して当てた。測定後に消えた文は無い。

`nim-muter` の `original` 欄は式全体ではなく、変異した部分式を指す。
`not modern and isRpcRequest and methodName == "initialize"` の `and` は左結合なので、変異は
`(not modern or isRpcRequest) and methodName == "initialize"` であって `not modern or (isRpcRequest and ...)` ではない
(後者を当てると既存のテストが多数落ちる。最初に後者で当ててしまい、前者でやり直した)。

生き残り 27 件の内訳: 同値 (1) 4 件、検出済み (2) 0 件、穴 (3) 19 件、死んだ・余分なコード (4) 3 件、欠陥 (5) 0 件、許容 (6) 1 件。
分類 3 の 19 件は、変異を 1 件ずつ手で当て、名前を挙げたテストが落ちることを見てから `jj restore` で戻した。確かめていないものは無い。

追加したテストは、既存のテストファイルの末尾に、`(mutation review, g2f-hs-b)` の名の新しい suite として足した。
ジョブの `testCommand` は、どのファイルも既に含んでいる (ジョブの変更は無い)。
`tests/test_version_floor.nim` の 3 件は `-d:mcpOldestProtocolVersion=2026-07-28` でだけ中身が走る (既存の隣のテストと同じ守り方。ジョブはその版でも流す)。
ほかの版の確認: `-d:mcpDefaultProtocolVersion=2024-11-05` と `=2025-11-25` でも、追加した suite は通る (その版では走らないテストは守りで外れる)。

| id | 場所 (測定時) | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 384 | http_server.nim:679 | RVR | `return none(JsonRpcError)` → `return default` | 1 同値 | `Option[JsonRpcError]` の既定値が `none`。 |
| 385 | http_server.nim:682 | RVR | 同上 | 1 同値 | 同上。 |
| 269 | http_server.nim:687 | SDL | 末尾の `none(JsonRpcError)` → `discard` | 1 同値 | `result` を書かなければ既定値の `none` が返る。 |
| 280 | http_server.nim:751 | SDL | `respondEmpty(Http405, {"Allow": "POST, DELETE"})` → `discard` | 3 穴 | 2024-11-05 で成立したセッションの GET は 405 で、`Allow` は `POST, DELETE`。`Given a session negotiated at 2024-11-05, when it opens GET, then the answer is 405 naming POST and DELETE` (`test_http_streams.nim`)。変異後は答えが返らず落ちる。 |
| 282 | http_server.nim:759 | SDL | GET の版ヘッダ誤りの `respondError(Http400, ...)` → `discard` | 3 穴 | `Given a GET that names a version the server does not speak, when it arrives, then the answer is 400` (`test_http_streams.nim`)。 |
| 103 | http_server.nim:771 | ROR | `session.listen.id == streamId` → `!=` | 3 穴 | GET ストリーム (listen) は、自分の event id で再開でき、持っていないストリームの id では再開されない。`Given the GET stream of a session, when the client left after an event and asks for the rest by that event's id, then it gets the later events` と `Given a GET stream that has sent events, when an event id of a stream the session never had is presented, then the answer is 400` (どちらも落ちる)。 |
| 284 | http_server.nim:790 | SDL | GET の `finally` の `dec session.busy` → `discard` | 3 穴 | GET ストリームが終わったセッションは、使われないまま上限を過ぎれば期限切れになる (`busy` が戻る)。`Given a session whose GET stream has ended, when it then stays unused, then it stays only for the limit counted from the end of the stream, and then expires` (`test_http_streams.nim`)。 |
| 285 | http_server.nim:791 | SDL | GET の `finally` の `session.touch()` → `discard` | 3 穴 | 同じテスト。期限は、ストリームが終わった時点から数える (ストリームが開いていた間は数えない)。 |
| 293 | http_server.nim:827 | SDL | 本文が単独の値のときの `respondError(Http400, ...)` → `discard` | 3 穴 | `Given a JSON body that is a single value and no object, when posted, then the answer is 400 invalid request` (`test_streamable_http.nim`)。これまでのテストが送っていた `[1, 2]` は後ろの検査で 400 になるため、この文には届いていなかった。 |
| 171 | http_server.nim:844 | LOR | `not isBatch and isRequest(rpc)` → `or` | 3 穴 | 2026-07-28 だけを話すサーバーは、最初の要素が完全な 2026-07-28 の要求であるバッチも 400 で断る (変異後は最初の要求として 200 で答える)。通知は版を名指ししても 202 (変異後は要求として検査して 400)。`Given a batch whose first message is a 2026-07-28 request, ...`、`Given a notification that names 2026-07-28, ...` (`test_version_floor.nim`)。 |
| 177 | http_server.nim:850 | LOR | `not modern and isRpcRequest` → `or` (`initialize` との `and` の左) | 3 穴 | セッションを開くのは `initialize` の要求だけ。`id` の無い `initialize` という名の通知は、セッションが無ければ 400 で、セッションは作られない (変異後は 202)。`Given a notification whose method is initialize and no session, when posted, then the answer is 400 and no session is made` (`test_streamable_http.nim`)。 |
| 182 | http_server.nim:858 | LOR | `modern and sessionless` → `or` | 3 穴 | 2026-07-28 だけを話すサーバーでは、`initialize` という名の通知は旧クライアントの拒否 (400) ではなく 202。`Given a notification whose method is initialize, when it is posted, then the answer is 202 and not the legacy-client refusal` (`test_version_floor.nim`、`-d:mcpOldestProtocolVersion=2026-07-28`)。 |
| 303 | http_server.nim:891 | SDL | セッションの無い版でバッチを断る `respondError(Http400, ...)` → `discard` | 3 穴 | `Given a batch whose first message is a 2026-07-28 request, when it is posted, then the answer is 400 invalid request` (`test_version_floor.nim`)。 |
| 304 | http_server.nim:907 | SDL | `inc session.busy` → `discard` | 3 穴 | 要求を処理したセッションは、そのあと使われなければ上限を過ぎて期限切れになる (`busy` が 0 に戻る。変異後は -1 のままで期限切れにならない)。`Given a session that has served a request, when it then stays unused beyond the limit, then it expires` (`test_http_streams.nim`)。 |
| 307 | http_server.nim:910 | SDL | `defer` の `dec session.busy` → `discard` | 3 穴 | 同じテスト (変異後は 1 のまま)。 |
| 314 | http_server.nim:930 | SDL | バッチの中の通知の `t.enqueueFromClient(...)` → `discard` | 3 穴 | 要求と通知が混ざったバッチでは、通知がサーバーに届く。`Given a batch of a request and a notification, when posted, then the server receives the notification` (`test_http_streams.nim`)。これまでは答えの本数しか見ていなかった。 |
| 317 | http_server.nim:948 | SDL | 中断された要求の `req.client.close()` → `discard` | 4 余分 | `gone` が先に終わるのは、相手が接続を閉じた (または読みが失敗した) ときだけ (`armWatch`)。その接続は、`asynchttpserver` の `processClient` が次の要求を読もうとして EOF かエラーを受け、自分で閉じる。したがってこの `close()` は、相手が既に閉じた接続を閉じ直すだけで、観測できる違いが無い (あるとすれば記述子が閉じるまでの一瞬)。コードを読んで決めた。記述子数を数える実験はしていない。削除するかはリードが決める。 |
| 320 | http_server.nim:953 | SDL | JSON で答えた後の `req.client.close()` → `discard` | 3 穴 | JSON の本文で答えた POST は、答えが済んだら接続を閉じる (接続を見張る読みが次の要求を食べないように)。生のソケットで要求を送り、答えを読み切ったあとに EOF が来ることを確かめる。`Given a POST answered with a JSON body, when the answer is complete, then the server closes the connection` (`test_streamable_http.nim`)。変異後は答えは届くが EOF が来ず、`closed` の検査だけが落ちる。 |
| 115 | http_server.nim:959 | ROR | `group.pending > 0` → `>=` | 1 同値 | `pending == 0` で通知を送ったグループ (`notified`) では、答えるたびに `sendResponse` が `t.exchanges.del` しているので、`cancel` が見つける交換が無く `onRequestCancelled` は呼ばれない。変わるのは `group.abandoned` だけで、それを読むのは、そのグループにもう来ない答えと通知の分岐だけ。 |
| 323 | http_server.nim:975 | SDL | `handleLegacySse` の `session.touch()` → `discard` | 4 余分 | HTTP+SSE のセッション (`legacy`) の `lastActive` を読むのは `expireIdleSessions` だけで、そこは `not session.legacy` で外している。接続が続く限りの寿命で、期限切れの対象ではない。 |
| 331 | http_server.nim:1007 | SDL | HTTP+SSE の POST の `refuseOverload()` → `discard` | 3 穴 | 処理中の要求が上限に達しているとき、HTTP+SSE の POST は 503 と `Retry-After` で断られる。`Given requests in progress up to the limit, when a client of HTTP+SSE posts another, then the answer is 503 with Retry-After` (`test_security_http.nim`)。Streamable HTTP の分はあったが、こちらの口にはテストが無かった。 |
| 217 | http_server.nim:1009 | BLR | HTTP+SSE の POST の `used = true` → `false` | 4 余分 | `used` を読むのは `evictUnused` だけで、そこは `not session.legacy` で外している。HTTP+SSE のセッションの `used` は誰も読まない。 |
| 332 | http_server.nim:1011 | SDL | HTTP+SSE の POST の `inc t.exchangeCount` → `discard` | 3 穴 | 同時に処理中の 2 つの要求が同じ交換 id `http-0` になり、2 つめの答えが失われる。`Given two requests in progress at once, when the server answers them one after the other, then each answer carries the id its own request chose` (`test_http_sse_legacy.nim`)。変異後は `no HTTP exchange is waiting for response id http-0`。 |
| 336 | http_server.nim:1034 | SDL | `stderr.writeLine("[mcp-http] authorization hook failed: ...")` → `discard` | 6 許容 | 診断の 1 行そのもの。標準エラーの内容を見るテストは、この SDK の他の診断行にも無い。診断が消えるだけで、答え (500) と、何も通さないことは `Given an authorization hook that raises, ...` が確かめている。 |
| 337 | http_server.nim:1035 | SDL | フックが落ちたときの `respondEmpty(Http500)` → `discard` | 3 穴 | フックが例外を投げたら、答えは 500。`Given an authorization hook that raises, when a request arrives, then the answer is 500 and nothing reaches the server` (`test_security_http.nim`)。変異後は答えが返らず落ちる。 |
| 389 | http_server.nim:1036 | RVR | `return (answered: true, ...)` → `return default` | 3 穴 | 同じテスト。変異後は `answered` が `false` になり、500 を返した要求がそのままサーバーに渡り、セッションまで作られる (フックが決められないとき何も通さない、が破れる)。 |
| 218 | http_server.nim:1036 | BLR | `answered: true` → `false` | 3 穴 | 同じテスト (389 と同じ挙動になる)。 |

### 分類ごとの件数

| 分類 | 件数 | id |
|---|---:|---|
| 1 同値 | 4 | 384, 385, 269, 115 |
| 2 検出済み | 0 | |
| 3 穴 | 19 | 280, 282, 103, 284, 285, 293, 171, 177, 182, 303, 304, 307, 314, 320, 331, 332, 337, 389, 218 |
| 4 余分 | 3 | 317, 323, 217 |
| 5 欠陥 | 0 | |
| 6 許容 | 1 | 336 |

### 残っているもの

- 317 (`http_server.nim:948`)、323 (`:975`)、217 (`:1009`) は余分なコード (分類 4)。消すかどうかはリードが決める。
  323 と 217 は、HTTP+SSE のセッションが `touch` / `used` の対象外であることが理由で、消してよい。
  317 は読んで決めたもので、接続の後始末が `asynchttpserver` と二重になっている。実験で確かめてはいない。
- 336 は許容 (診断の 1 行)。
- 追加したテストのうち `test_version_floor.nim` の 3 件は、既定の版 (2026-07-28 と旧版の両方を話すビルド) では中身が走らない。
  走るのは `-d:mcpOldestProtocolVersion=2026-07-28` のときで、ジョブの `testCommand` はその版でこのファイルを流している。

## G2 変異検出: http_server (担当 g2f-hs-c)

`http_server` ジョブ全体の測定値 (commit 36a4c8a5): 変異 391 件、killed 218、timeout 64、survived 94、compileError 15、runError 0。

この文書は、そのうち次の範囲の生き残り 37 件の記録である。残りは他の担当 (`http_server.nim` の 229-668 行と 679-1036 行) が書く。

- `src/transport/http_server.nim` の測定時の行 1050-1175 (24 件)
- `src/transport/sse_stream.nim` の全部 (13 件)

測定後に両ファイルが変わった (待ちを `or` から `firstOf` / `Doorbell` へ)。このため `sse_stream.nim` の行番号は、測定時の値に 1 を足したものが現在の行である (`import ./first_of` の 1 行)。`serveStream` の中の 161 / 177 / 182 行は、それぞれ現在の 169 / 189 / 194 行に当たる。`http_server.nim` の 1050 行以降は、現在の行が 1 行ずれている。変異の文面で照合し、すべて現在のファイルに同じ文が残っている (「置き換えられた文」はなかった)。

### 結果

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

### 一覧

「検出するテスト」は、変異を当てて落ちるのを見たもの。記号は `D` = `tests/test_http_documents.nim`、`S` = `tests/test_http_streams.nim`、`L` = `tests/test_http_sse_legacy.nim`、`H` = `tests/test_streamable_http.nim`、`X` = `tests/test_security_http.nim`。

#### http_server.nim (serveDocument)

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

#### http_server.nim (経路の振り分け、handle、start)

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

#### sse_stream.nim

| id | 行 (測定時) | 変異 | 元 → 変異 | クラス | 理由と検出するテスト |
|---|---|---|---|---|---|
| 49 | 66 | RVR | `return false` → `<return default>` | 検出 (測り直し) | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。測り直し (76a08c6a) で検出された。 |
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

### 足したもの

- `tests/test_http_documents.nim`: 1 件 (ETag のない文書)
- `tests/test_http_sse_legacy.nim`: 2 件 (SSE を切ったときの `/messages`、`/messages` への GET)
- `tests/test_streamable_http.nim`: 1 件 (`start`)
- `tests/test_security_http.nim`: 1 件 (内部の失敗は 500 と log)
- `tests/test_http_streams.nim`: 8 件 (ストリームの緩衝、`serveStream` の keep-alive、接続の閉じ方、見失わないこと、`written`)
- Scenario: `MCP-HTTPSTREAM-19`, `-2`、`MCP-HTTPSSE-11`、`MCP-HTTP-22`, `-2`、`MCP-SEC-HTTP-8`
- `tests/mutation/http_server.json`: `testCommand` に `tests/test_http_documents.nim` を足した。

版の確認: 足したテストを持つ 5 ファイルを、既定の版、`-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25` で流し、すべて合格した (`test_http_documents.nim` は版に依らない)。

### 残っているもの

- 356 / 359 (許容): 書き込みに失敗した接続を `close()` する文。相手はすでに去っており、クライアントから見える違いは出ない。違いは記述子を手放す時機だけである。書き込みの失敗を決まった形で起こす方法が見つからなかった (相手が閉じた後の最初の書き込みは、カーネルの緩衝に入って成功することが多い)。記述子の数を測る検査は不安定になるので書かなかった。
- 366 (許容): 記述子が上限に近いときの `sleepAsync(50)`。この文を消すと、枝が await のない空回りになり、イベントループが止まる。ただし枝に入るには、プロセスが `RLIMIT_NOFILE` の 5 つ手前まで記述子を使っていなければならない。`setrlimit` で上限を下げて試したが、下げた状態でソケットを作ると macOS の kqueue 側で `Bad file descriptor` になり、安定したテストにならなかったので外した (コミットしていない)。`asynchttpserver` の `maxFDs` は非公開で、トランスポートからは変えられない。公開された口を足すなら `http_server.nim` の変更になるので、リードの判断に任せる。
- クラス 4 (死んだコード) と 5 (欠陥) はなかった。

## 測り直し (本線 76a08c6a、2026-10-10)

36a4c8a5 の測定のあとに足したテストと修正を入れたコミットで、同じジョブを測り直した。変異 391、検出 264、時間切れ 92、コンパイル不能 15、**生き残り 20** (前回 94)。所要 451 分。

前回の生き残りとの突き合わせは変異の指紋で行った (指紋が変わった行は、ファイル・変異の文面・3 行以内の行番号で合わせた)。20 件のうち 18 件は前回も生き残っていて、この文書に分類と理由がある。「未判定」としていた 2 件 (g2f-hs-a の id 377 = `http_server.nim:516`、g2f-hs-c の id 49 = `sse_stream.nim:67`。どちらも `return false` → `return true`) は検出された。

### 新しく現れた生き残り 2 件

どちらも `sse_stream.nim` の `serveStream`。分類 3 (穴) で、テストを足した。変異を手で当てて、足したテストが落ちることを確かめた。

| 場所 | 変異 | 何が起きるか | 足したテスト |
|---|---|---|---|
| `sse_stream.nim:141` | SDL `stream.wake()` → `discard` | 置き換えられた古い接続が、次の通知が来るまで気づかない。気づく前にその通知を自分でも書き出すので、同じメッセージが 2 本の接続に流れる。前からあるテストは古い接続が終わることしか見ていなかった | MCP-HTTPGET-2: Given a second GET that took the stream over, when a notification is sent, then the first connection ends without carrying it |
| `sse_stream.nim:187` | SDL `bell.watch(idle)` → `discard` | keep-alive の時計を張り直したあと監視しないので、keep-alive のコメントが 1 回しか出ない。前からあるテストは 1 回目しか読んでいなかった | MCP-HTTPSTREAM-20: Given a stream with nothing to say, when two keep-alive periods pass, then a comment goes out in each |

141 行は前回 (待ちを `Doorbell` に変える前) は検出されていた。187 行は `Doorbell` に変えたときに入った行で、前回の測定には無い。

### 時間切れ 92 件

上限は 218 秒 (基準の実行 43.6 秒から道具が決めた値)。92 件とも上限ちょうどで打ち切られていて、遅いだけで終わるものは無い。道具は、4 並列の通しで時間切れになった変異を、最後に 1 件ずつ単独で流し直す。92 件はその流し直しでも時間切れだった。

- 62 件は前回も時間切れ。応答を返す文や待ちを解く文を消す変異 (SDL) が大半で、応答が来ないのでテストの側が待ち続ける。
- 30 件は前回は時間切れではなかった (前回の結果: 検出 22、生き残り 7、前回の測定に無い行 1)。

前回は検出だった変異が時間切れになった理由を、1 件 (`http_server.nim:851`、`methodName == "initialize"` → `!=`) を手で当てて調べた。`tests/test_http_streams.nim` は 60 件を超える検査で落ち (変異は検出されている)、そのあと、前回の測定のあとに足したテスト「Given a posted request, when the server takes it with receiveMessage, then it gets the message」が `receiveMessage` を上限なしで待って止まっていた。この待ちに 2 秒の上限を付けると、同じ変異でファイルは 5 秒で終わる (終了コード 1)。上限を付けたテストは、上の 2 本と同じコミットに入れた。

残りの 29 件を 1 件ずつは調べていない。テストの補助 `post` (`waitFor http.request`) にも上限が無く、応答を返さなくなる変異ではここで止まると見ている (未確認)。2026-10-12 に、補助 `post` の応答の待ちと本文の待ちに 10 秒の上限を付けると決め、付けた (時間切れはテストの失敗になる)。測定時間が減るかどうかは次の測定まで確かめていない。時間切れは「テストが通らなかった」側の結果なので、生き残りの判定には影響しない。影響するのは測定の時間で、今回の 451 分のうち、単独の流し直しだけで 92 × 218 秒 = 334 分を使っている。
