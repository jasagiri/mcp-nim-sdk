# G2 変異検査: client ジョブ、`src/client/client.nim` の 585 行以降

対象は mainline の先端 36a4c8a5 で `nim-muter` を流した結果(`tests/mutation/client.json`)のうち、`src/client/client.nim` の 585 行から後ろ(ヘッダー不一致の再試行、サーバー能力の解釈、`initialize`、`discover`、`connect`、`close`)。584 行までは `g2b-client-a` が担当する。

## 数字

ジョブ全体(8 ファイル):

| 総数 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 344 | 215 | 8 | 113 | 0 | 8 |

このうち `client.nim` の 585 行以降の生き残りは 48 件、`client.nim` の timeout は 7 件(585 行以降が 2 件、それより前が 5 件)。48 件の内訳は次のとおり。

| 区分 | 件数 |
|---|---|
| 1 equivalent | 6 |
| 2 detected elsewhere | 15 |
| 3 gap(テストを足した) | 26 |
| 4 dead code | 1 |
| 5 defect | 0 |
| 6 accepted | 0 |

(class 2 と 3 は、人手で変異を当てて、そのテストが落ちる(または止まる)のを見た。class 1 と 4 は手で当てず、理由を式から読み取った。)

## 生き残りの一覧

「検出するテスト」の列は、変異を当てた状態でそのテストが落ちる(または止まる)のを確かめたもの。`H` は `tests/test_param_headers_http.nim`、`E` は `tests/test_era_matrix.nim`、`X` は `tests/test_extensions.nim` を指す。

| id | 行 | 変異 | 元 → 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 172 | 585 | LOR | `… has(ftParameterHeaders) and kind != mtkStdio` → `or` | 3 | `or` にすると HTTP なら何を受けても true になり、成功した呼び出しのあとにも `tools/list` を読み直す。H「Given a tool call that the server answers, when it is sent over HTTP, then the client does not read the tool list again」 |
| 134 | 586 | ROR | `kind != mtkStdio` → `==` | 2 | H の既存の再試行テスト(「…lists the tools again and retries…」ほか)が落ちる。job に H を足した |
| 272 | 599 | SDL | `tools/list` 失敗の診断行 → `discard` | 3 | H「Given a header mismatch and a tool list that cannot be read…」が、診断行の存在と、相手の文章が制御文字を含まない 1 行になること(MCP-SEC-HTTP-7)を確かめる |
| 290 | 601 | RVR | `return false` → `return default` | 1 | `default(bool)` は `false` で、元の式と同じ値 |
| 202 | 601 | BLR | `return false` → `return true` | 3 | 同上のテスト。一覧が読めないのに再試行して `calls == 2` になる |
| 135 | 604 | ROR | `name == toolName` → `!=` | 2 | H の既存の再試行テストが落ちる |
| 291 | 605 | RVR | `return true` → `return default` | 2 | 値は `false`(203 と同じ)。H の既存の再試行テストが落ちる |
| 203 | 605 | BLR | `return true` → `return false` | 2 | 同上 |
| 177 | 607 | LOR | `next.isNil or …` → `and` | 3 | `nextCursor` が無いとき `nil.kind` を読んで SIGSEGV。H「…a tool list without the tool…」(プロセスが落ちる) |
| 136 | 607 | ROR | `next.kind != JString` → `==` | 3 | H「…a tool listed on the second page…」「…whose nextCursor is not a string…」「…never ends…」 |
| 292 | 608 | RVR | `return false` → `return default` | 1 | 290 と同じ |
| 204 | 608 | BLR | `return false` → `return true` | 3 | H「…a tool list without the tool…」「…nextCursor is not a string…」が落ちる(再試行が起きる) |
| 270 | 610 | SDL | 100 ページ超過の診断行 → `discard` | 3 | H「…a server whose tool list never ends…」が診断行を確かめる |
| 293 | 612 | RVR | `return false` → `return default` | 1 | 290 と同じ |
| 205 | 612 | BLR | `return false` → `return true` | 3 | H「…never ends…」が落ちる(100 ページ読んだあとに再試行する) |
| 206 | 634 | BLR | `toolsListedAgain = false` → `true` | 2 | H の既存の再試行テストが落ちる |
| 208 | 640 | BLR | `toolsListedAgain = true` → `false` | 2 | 2 回目の拒否でも読み直しを繰り返して止まらない。H が止まる(timeout として検出される型) |
| 294 | 643 | RVR | `return response` → `return default` | 3 | 拒否を返さず空の応答を返す。H「…a tool list that cannot be read…」「…without the tool…」が落ちる(従来は一覧にツールがある場合しか通らなかった) |
| 179 | 644 | LOR | `not usesModernProtocol or result.isNone` → `and` | 2 | モダンで result が無い応答(エラー)で `result.get` に落ちる。H の既存の 2 回目の拒否のテストが落ちる |
| 273 | 656 | SDL | `inc rounds` → `discard` | 2 | 上限に達せず再試行が終わらない。`tests/test_mrtr.nim` の上限テストが止まる。job に足した |
| 137 | 657 | ROR | `rounds > maxInputRounds` → `>=` | 2 | `tests/test_mrtr.nim`「…when the limit is reached…」が `len == 4` で落ちる |
| 138 | 664 | ROR | `declared.kind != JString` → `==` | 2 | `X`「…both sides support the extension…」が落ちる。job に足した |
| 297 | 667 | RVR | `return response` → `return default` | 2 | 同上 |
| 182 | 748 | LOR | `not json.isNil and kind == JObject` → `or` | 3 | 配列の `capabilities` で `pairs` の表明が落ちる。X「Given a server whose capabilities are not an object…」 |
| 140 | 748 | ROR | `json.kind == JObject` → `!=` | 3 | オブジェクトのとき `additional` を読まない。X「…a capability the core does not define…」 |
| 183 | 751 | LOR | `name notin known and kind == JObject` → `or` | 3 | 核の能力が `additional` に入る。X「…does not define…」(`serverCapability("tools")` が none であること) |
| 141 | 751 | ROR | `settings.kind == JObject` → `!=` | 3 | 同上 |
| 142 | 753 | ROR | `other.len > 0` → `>=` | 3 | 空の `additional` が付く。X「…only capabilities the core defines…」 |
| 274 | 766 | SDL | `wire.parseServerInfo(node)` → `discard` | 2 | `tests/test_implementation_info.nim` が 3 件落ちる。job に足した |
| 185 | 791 | LOR | `code == … and not data.isNil and anyIt` の 1 つ目の `and` → `or` | 3 | silent なプローブのあと、別のコードで initialize を拒否し `data.supported` にモダンの版があると、2 回目の discover に進んでしまう。E「Given a peer silent to the probe that refuses initialize with another error…」 |
| 184 | 791 | LOR | 2 つ目の `and` → `or` | 3 | 同上 |
| 275 | 807 | SDL | `protocolVersionNegotiated` → `discard` | 2 | `tests/test_streamable_http.nim`「…falls back to initialize and calls a tool」が落ちる。job に足した |
| 299 | 824 | RVR | `return capabilities` → `return default` | 3 | `connect` は戻り値を捨てる。`tests/test_legacy_handshake.nim`「Given a client attached to a transport, when initialize is called…」 |
| 188 | 833 | LOR | `offered.isNil or kind != JArray` → `and` | 3 | `supported` が無い拒否で nil を読んで SIGSEGV。E「…as unsupported without naming versions…」 |
| 190 | 842 | LOR | `isModern(v) and (…)` → `or` | 3 | 旧版だけの一覧でも「モダンの選択」が出る。E「…naming only legacy versions…」「…lists only legacy versions…」 |
| 147 | 842 | ROR | `v > result.get` → `>=` | 1 | `v == result.get` のとき `result` に同じ値を入れ直すだけで、結果は変わらない |
| 209 | 864 | BLR | `var answered = false` → `true` | 1 | `answered` は直後の `try` で必ず代入される。代入しない経路は `return` か `raise` で抜ける |
| 301 | 873 | RVR | `return pvLegacy` → `return default` | 2 | `default(ProbeVerdict)` は `pvModern`(最初の列挙子)。`test_streamable_http`「…rejects the probe without a JSON-RPC body…」が落ちる |
| 279 | 876 | SDL | `pendingRequests.del(started.id)` → `discard` | 3 | 放棄したプローブが pending に残る。E「Given a transport that never finishes sending the probe…」が `pendingRequests.len == 0` を確かめる |
| 280 | 878 | SDL | `cancelRequest(started.id)` → `discard` | 3 | 同上のテストが `cancelled == @[プローブの id]` を確かめる |
| 149 | 890 | ROR | `attempt == 0` → `!=` | 3 | 拒否に挙がったモダンの版で 1 度やり直さない。E「…naming a modern version the client speaks…」「…twice…」 |
| 304 | 894 | RVR | `return pvLegacy` → `return default` | 3 | `pvModern` になり initialize が送られない。E「…naming only legacy versions…」 |
| 305 | 903 | RVR | `return pvLegacy` → `return default` | 3 | 同上。E「…a discover result that lists only legacy versions…」 |
| 152 | 910 | ROR | `identity.kind == JObject` → `!=` | 2 | `test_implementation_info`「…when the client discovers it…」が落ちる |
| 306 | 913 | RVR | `return pvModern` → `return default` | 1 | `default(ProbeVerdict)` が `pvModern` なので同じ値 |
| 307 | 914 | RVR | `return pvLegacy` → `return default` | 4 | ループ(`attempt` 0 と 1)の 2 周目は、すべての枝が `return` か `raise` で終わるので、ここには届かない。Nim が戻り値の定義を求めるための行 |
| 282 | 947 | SDL | `failPending("the client was closed")` → `discard` | 3 | ループが止まらない transport では待機中の要求が失敗しない。`tests/test_client_requests.nim`「Given a transport whose receive loop close() does not end…」(新しい足場 `tests/stuck_transport.nim`) |
| 283 | 949 | SDL | `await transport.close()` → `discard` | 3 | 同上のテストが `closeCalls == 1` を確かめる |

## timeout

timeout は検出に数える。待ち続ける理由を 1 行ずつ書く。

| id | 行 | 変異 | 待ち続ける理由 |
|---|---|---|---|
| 239 | 377 | SDL | `promise.complete(response)` が無いので、要求の Future が完了せず、タイムアウトまで待つ |
| 200 | 385 | BLR | `while true` が `false` になり、受信ループが回らず、応答が処理されない |
| 241 | 393 | SDL | `processResponse` を起動しないので、応答が捨てられる |
| 171 | 525 | LOR | `response or timer` が `and` になり、片方が完了しない限り待ち続ける |
| 170 | 525 | LOR | `response or timer or cancelled` が `and` になり、同上 |
| 178 | 637 | LOR | `not toolsListedAgain and refused` が `or` になり、2 回目の拒否でも一覧を読み直し続ける(208 と同じ型) |
| 281 | 923 | SDL | `processMessages` を起動しないので、プローブにも initialize にも応答が届かず `connect` が終わらない |

## 追加したもの

- `tests/test_param_headers_http.nim`: 再試行の止まる所(一覧が読めない・ツールが無い・`nextCursor` が文字列でない・一覧が終わらない)、2 ページ目にツールがある場合、成功した呼び出しでは読み直さないこと(MCP-HTTP-18、6 件)
- `tests/test_extensions.nim`: `serverCapability` と `additional`(MCP-EXT-15、3 件、Scenario 追加)
- `tests/test_era_matrix.nim`: プローブの拒否とやり直し、旧版だけの一覧、版を挙げない拒否、silent なプローブのあとの別のエラー、放棄したプローブ(MCP-LIFECYCLE-14、7 件、Scenario 追加)
- `tests/test_legacy_handshake.nim`: `initialize` が能力を返す(MCP-LIFECYCLE-3 に 1 件と文を追加)
- `tests/test_client_requests.nim`: `close` が待機中の要求を失敗させ transport を閉じる(`specs/tests.map` に載せていない。同じ suite の他のテストも載せていないため)
- `tests/stuck_transport.nim`: 足場(受信ループが終わらず、`close()` が何もしない transport)
- `tests/mutation/client.json`: `test_param_headers_http`、`test_mrtr`、`test_extensions`、`test_implementation_info`、`test_streamable_http` を追加

`-d:mcpDefaultProtocolVersion=2024-11-05` と `=2025-11-25` でも `test_era_matrix`、`test_legacy_handshake`、`test_extensions` を通した。`test_client_requests` は 2024-11-05、`test_param_headers_http` は 2025-11-25 で通した。

## 残っているもの

- class 4: 307(914 行 `return pvLegacy`)。`discover` のループの外にある、届かない行。消すかどうかは lead が決める。
- accepted はない。
- 変異を当てて確かめなかったのは class 1 の 6 件(290, 292, 293, 147, 209, 306)と class 4 の 307。理由は式から読み取れるため。
