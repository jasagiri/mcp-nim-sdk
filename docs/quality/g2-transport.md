# G2 変異検出: `src/transport/transport.nim`

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: 変異検査の道具 0.2.15、ジョブ `tests/mutation/transport.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。
状態: 測定済み。行番号は b04fcb9c のもの。その後 8e0c1321 で私的な `isUtf8` を `src/compat/utf8.nim` に移したので、今のファイルとは数行ずれる。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 46 | 22 | 4 | 17 | 0 | 3 |

### 生き残りの仕分け

`test_owed` の 9 件は、どれも既存の外部仕様テスト `tests/external/test_utf8_refused_fix.nim` が検出するはずで、このファイルがジョブの `testCommand` に入っていない。新しいテストは要らない。

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/transport/transport.nim:RVR:f09e9e232af8b35b:0` | transport.nim:153 | `isUtf8`: `return false` → `return true` (`validateUtf8` が断ったとき) | undecided | 対象のコードは src/compat/utf8.nim に移った。測り直しで消える | — |
| `src/transport/transport.nim:BLR:6ec2d660335697fb:0` | transport.nim:153 | `isUtf8`: `false` → `true` (同じ return) | undecided | 対象のコードは src/compat/utf8.nim に移った。測り直しで消える | — |
| `src/transport/transport.nim:AOR:7a64b52a5aa837a4:0` | transport.nim:155 | `isUtf8`: `text[i + 1]` → `text[i - 1]` (代用対の検査) | undecided | 対象のコードは src/compat/utf8.nim に移った。測り直しで消える | — |
| `src/transport/transport.nim:ROR:238bd2eca17c095f:0` | transport.nim:155 | `isUtf8`: `text[i + 1] >= '\xA0'` → `>` | undecided | 対象のコードは src/compat/utf8.nim に移った。測り直しで消える | — |
| `src/transport/transport.nim:RVR:f09e9e232af8b35b:1` | transport.nim:156 | `isUtf8`: `return false` → `return true` (代用対を見つけたとき) | undecided | 対象のコードは src/compat/utf8.nim に移った。測り直しで消える | — |
| `src/transport/transport.nim:BLR:6ec2d660335697fb:1` | transport.nim:156 | `isUtf8`: `false` → `true` (同じ return) | undecided | 対象のコードは src/compat/utf8.nim に移った。測り直しで消える | — |
| `src/transport/transport.nim:RVR:87aa8baa528c4cef:0` | transport.nim:163 | `notUtf8`: `return ""` → 既定値 (node が nil のとき) | equivalent | 文字列のリテラルの RVR は `""` で、`string` の既定値も `""`。変異の前後で返る値が同じ | — |
| `src/transport/transport.nim:RVR:a2dd9206bd48cfc4:0` | transport.nim:166 | `notUtf8`: `return at` → `return ""` (文字列の値が UTF-8 でないとき) | test_owed | UTF-8 でない文字列の値が「問題なし」になり、要求・通知がそのまま書かれ、応答は内部エラーに差し替わらない | MCP-STDIO-9、MCP-HTTP-43。既存の `tests/external/test_utf8_refused_fix.nim` の `Given a string that is not UTF-8, when a request or a notification holds it as a value or as a member name, then it is not sent and nothing is written` が検出するはず (`{"text": text}` の通知が断られなくなる)。testCommand に足す |
| `src/transport/transport.nim:ROR:02b067559cb29e3c:0` | transport.nim:171 | `notUtf8`: 配列の `found.len > 0` → `>= 0` | test_owed | 配列の最初の要素だけを見て返る。最初の要素が正しければ、後ろの要素の UTF-8 でない文字列が見逃される | MCP-STDIO-9。同じテストが検出するはず (`{"list": [1, {"deep": text}]}` の要求は、最初の要素 `1` で `""` が返り、断られなくなる)。testCommand に足す |
| `src/transport/transport.nim:RVR:ceab9c9546dcaee1:0` | transport.nim:171 | `notUtf8`: 配列の `return found` → `return ""` | test_owed | 配列の中の UTF-8 でない文字列が、どの位置でも見逃される | MCP-STDIO-9。同じテストが検出するはず (`{"list": [1, {"deep": text}]}` の要求が断られなくなる)。testCommand に足す |
| `src/transport/transport.nim:RVR:8db25eed5f4242b0:0` | transport.nim:174 | `notUtf8`: `return at & ": a member name"` → `return ""` | test_owed | UTF-8 でないメンバー名が「問題なし」になり、メッセージがそのまま書かれる | MCP-STDIO-9。同じテストが検出するはず (`named[text] = %1` を params にした通知が断られなくなる)。testCommand に足す |
| `src/transport/transport.nim:ROR:02b067559cb29e3c:1` | transport.nim:176 | `notUtf8`: オブジェクトの `found.len > 0` → `>= 0` | test_owed | オブジェクトの最初のメンバーだけを見て返る。メッセージの最初のメンバーは `jsonrpc` なので、params の中は一切見られなくなる | MCP-STDIO-9、MCP-HTTP-43。同じテストが検出するはず (3 つの送信がどれも断られなくなる)。testCommand に足す |
| `src/transport/transport.nim:RVR:ceab9c9546dcaee1:1` | transport.nim:176 | `notUtf8`: オブジェクトの `return found` → `return ""` | test_owed | オブジェクトのメンバーの値にある UTF-8 でない文字列が見逃される (メッセージ自体がオブジェクトなので、値の検査がすべて効かなくなる) | MCP-STDIO-9、MCP-HTTP-43。同じテストが検出するはず (`{"text": text}` の通知が断られなくなる)。testCommand に足す |
| `src/transport/transport.nim:SDL:5dfcc871d9e1c8fc:0` | transport.nim:199 | 要求の `toJson`: `requireUtf8(...)` → `discard` | test_owed | 要求が UTF-8 かを確かめずに書かれる | MCP-STDIO-9、MCP-HTTP-43。同じテストの `sendRequest` の行と、`Given a string that is not UTF-8, when a client posts a request that holds it, then the request is refused and nothing is posted` が検出するはず。testCommand に足す |
| `src/transport/transport.nim:SDL:d89e230832afd22c:0` | transport.nim:208 | 通知の `toJson`: `requireUtf8(...)` → `discard` | test_owed | 通知が UTF-8 かを確かめずに書かれる | MCP-STDIO-9。同じテストの `sendNotification` の行が検出するはず (断られず、`output.data == ""` も崩れる)。testCommand に足す |
| `src/transport/transport.nim:SDL:23e974a338100fa4:0` | transport.nim:234 | 応答の `toJson`: `stderr.writeLine("[mcp-transport] response ... holds a string that is not UTF-8 ...")` → `discard` | spec_question | 応答が内部エラーに差し替わることは保たれ、stderr の 1 行が出なくなる。文面が変わるのではなく行そのものが消えるので「失敗の文面」の決定には当てなかった。この行を定める仕様 ID は無い (MCP-STDIO-9 は書かれるバイトだけを定める) | 問い: UTF-8 でない応答を内部エラーに差し替えたとき stderr に 1 行書くことを仕様にするか (結果も error も無い応答のほうは MCP-TRANSPORT-3 が「1 行を記録する」と定めている)、それともこの行を消すか |
| `src/transport/transport.nim:ROR:70f734de428b7829:0` | transport.nim:239 | 応答の `toJson`: `notUtf8(id, "").len > 0` → `>= 0` | test_owed | 常に真になり、差し替えた内部エラーの id が、元の id が正しくても null になる | MCP-STDIO-9。既存の `tests/external/test_utf8_refused_fix.nim` の `Given a result that holds a string that is not UTF-8, when the response is sent, then the peer gets an internal error under the same id and what is written is UTF-8` が検出するはず (`written["id"].getStr() == "r7"` が落ちる)。testCommand に足す |

### 時間切れの 4 件

どれも変異した式そのものは終わらないループを作らない。応答が待ち手に届かなくなり、テストが応答を待ち続ける形の時間切れと読んだ (コードを読んでの推論で、流して確かめてはいない)。負荷による偽の時間切れと見る理由は無い。

| 指紋 | file:line | 変異 | 見立て |
|---|---|---|---|
| `src/transport/transport.nim:ROR:3c179a5fd5b9d151:0` | transport.nim:249 | `idText`: `node.kind == JString` → `!=` | 変異による待ち続け。文字列の id が引用符つきの文面 (`"\"r1\""`) になり、数の id は `""` になる。復号した応答の id が、待っている要求の id と合わなくなる |
| `src/transport/transport.nim:LOR:f7179b62e94c0b8c:0` | transport.nim:292 | `isRequest`: 2 つ目の `and` → `or` (`(オブジェクト and id あり) or method あり`) | 変異による待ち続け。id を持つ応答が要求にもなり、通知も要求になる。応答が待ち手に渡らない |
| `src/transport/transport.nim:ROR:ba6e054163a861a2:0` | transport.nim:295 | `isResponse`: `json.kind == JObject` → `!=` | 変異による待ち続け。オブジェクトの応答がどれも応答と見なされなくなる (オブジェクトでない JSON は `hasKey` で落ちる) |
| `src/transport/transport.nim:LOR:9a125f66e4b2fed1:0` | transport.nim:296 | `isResponse`: `hasKey("result") or hasKey("error")` → `and` | 変異による待ち続け。result と error の両方を持つものだけが応答になり、正しい応答はどれも応答と見なされなくなる |

### 仕分けの途中で見つけた、変異ではないこと

b04fcb9c の 239 行 (今の `toJson(response)` の `notUtf8(id, "")`) は、id が文字列のとき働かない。`notUtf8` は文字列の値が UTF-8 でないと `at` を返し、ここでは `at` が `""` なので、長さは 0 のままで id は null にならない。UTF-8 でない文字列の id を持つ応答は、内部エラーに差し替わっても、その id がそのまま書かれると読める (MCP-STDIO-9 の「そのままは書かれない」に反する)。読んだだけで、流して確かめてはいない。直すかどうかは仕分けの外。

## 2026-10-07 の測定 (mainline の 36a4c8a5)

測定: 変異検査の道具、ジョブ `tests/mutation/transport.json`、mainline の 36a4c8a5 (2026-10-07)。
2026-10-12 に `transport.nim` を変えた。次の測定で測り直す。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 21 | 6 | 6 | 6 | 0 | 3 |

timeout 6 件は個別に調べていない (検出として数える)。

## survived 6 件

分類は、3 = 穴 (新しい外部仕様テストを足した)。
すべて 3 で、変異を手で当てて `tests/test_transport.nim` が落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは戻した)。
このテストファイルは、ジョブの `testCommand` に足した。

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 16 | transport.nim:80 | SDL | `await t.sendNotification(notification)` → `discard` | 3 | 経路 (route) を指定した通知が、経路を無視する移送の通常の送信に渡らず失われる。`Given a transport that ignores routes, when a notification is sent with one, then the plain send gets it` (`MCP-TRANSPORT-1`) |
| 17 | transport.nim:85 | SDL | `await t.sendRequest(request)` → `discard` | 3 | 同じく要求が失われる。`Given a transport that ignores routes, when a request is sent with one, then the plain send gets it` (`MCP-TRANSPORT-1`) |
| 12 | transport.nim:208 | LOR | `isResponse`: `kind == JObject and hasKey("id")` の `and` → `or` | 3 | オブジェクトでない JSON で `hasKey` が AssertionDefect を出す。`id` のない result も応答になる。`Given JSON that is not an object, ...`、`Given a result without an id, ...` (`MCP-TRANSPORT-2`) |
| 11 | transport.nim:208 | LOR | `isResponse`: `A and B and C` の 2 つ目の `and` → `or` (`(A and B) or C`) | 3 | id のない result が応答になり、要求 (id と method) も応答になる。`Given a request, ...`、`Given a result without an id, ...`、`Given JSON that is not an object, ...` |
| 15 | transport.nim:212 | LOR | `isNotification`: `kind == JObject and (not hasKey("id"))` の `and` → `or` | 3 | オブジェクトでない JSON で AssertionDefect。`Given JSON that is not an object, ...`。要求が通知になることも `Given a request, ...` が見る。 |
| 14 | transport.nim:212 | LOR | `isNotification`: 2 つ目の `and` → `or` (`(A and not B) or C`) | 3 | method を持つ要求が通知になる。`Given a request, when classified, then it is a request only` ほか 2 件 |

## 残っているもの

なし。
