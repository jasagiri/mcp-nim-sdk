# G2 変異検出: server ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5 (2026-10-07)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 502 | 236 | 2 | 237 | 0 | 27 |

生き残り 237 件の分類 (4 人で分担し、下の 4 節に 1 件ずつ記録した)。

| 分類 | 338〜899 行 | 901〜1291 行 | 1302 行以降 | server.nim 以外 | 計 |
|---|---:|---:|---:|---:|---:|
| 1 同値 | 4 | 6 | 4 | 6 | 20 |
| 2 ジョブに無い既存のテストが検出 (ジョブに追記) | 4 | 25 | 24 | 0 | 53 |
| 3 穴 (テストを追加) | 41 | 21 | 19 | 4 | 85 |
| 4 到達しない・使われない・観測できないコード | 2 | 1 | 1 | 60 | 64 |
| 5 欠陥 | 0 | 0 | 0 | 0 | 0 |
| 6 許容 (標準エラーの診断の文面) | 5 | 3 | 9 | 0 | 17 |

分類 2 と 3 は、変異を 1 件ずつ手で当てて、テストが落ちる (または止まる) ことを確かめた。分類 1 は式と不変条件から読んだ。

## 分類 4 の扱い (リードの判断、2026-10-07)

- `src/server/resources.nim` (56 件) と `src/server/prompts.nim` (4 件): 削除した。SDK、examples、テスト、文書、下流のどこからも import されておらず
  (`import mcp` が取り込むのは `client/` の同名のモジュール)、`resources.nim` は単独ではコンパイルもできなかった。ジョブの `sources` からも外した。
- id 197・335 (`server.nim` の `handleInitialize`、合意できる旧版が無い場合の枝): 削除し、`doAssert` に替えた。握手の無い版しか話さないサーバーは、
  ここに来る前に `initialize` を断っている (`tests/test_version_floor.nim` の 2026-07-28 専用ビルドで確認)。
- id 127 (`server.nim:956`、`withoutInvalidParamHeaders` の早期 return): 残した。呼び出し元は `listPage` の結果だけなので今は届かないが、
  「結果が無い、または `tools` が配列でないなら触らない」という防御で、消すと後の変更で nil を踏む。届かないので次の測定でも生き残る。
- id 290 (`server.nim:1493`、`server.inFlight.del(key)`): 残した。消さなくても応答は変わらず、処理中の要求の表が大きくなるだけで、外からは見えない。
  件数を返す公開 API をこのためだけに足すことはしない。次の測定でも生き残る。
- id 439 (`completion.nim:24`、`requiredString` の nil と種類の検査): 残した。今の呼び出し元は nil でない JObject しか渡さないので同値。

## 仕様 ID の振り直し

3 人が別々に同じ番号を振っていたので、取り込み時に振り直した: 「フィルタは 2026-07-28 の結果をオブジェクト以外にできない」は MCP-HOOKS-3、
「request interceptor は要求に答えるか、サーバーに任せる」は MCP-HOOKS-4、「同じ要求への 2 度目の答えは無視される」は MCP-SERVERREQ-12。
下の各節の本文に残る MCP-HOOKS-2 / MCP-SERVERREQ-10 の表記のうち、これらの Scenario を指すものは、この番号に読み替える。

## 気づいた点 (未対応)

- 成功の応答で `result` も `error` も無いもの (ハンドラが既定値を返した場合) を、通信路の符号化が `"result": {}` として送っていた。
  ハンドラの誤りが空の成功に見える。2026-10-12 に、符号化を内部エラー (-32603、"Internal error") にし、stderr に 1 行出すと決めて直した
  (MCP-TRANSPORT-3、`transport.nim`)。本線の応答を作る経路 (`newJsonRpcResponse`、`newJsonRpcErrorResponse`) はすべて `result` か `error` を明示するので、
  この枝に入るのは既定値の `JsonRpcResponse` を返したハンドラだけ。下の id 172 付近の「外から見える違い」の記述は、この変更の前のもの。

測定の後に `src/server/server.nim` を変えた (上の `doAssert`)。push の前に、このジョブを測り直す。

## src/server/server.nim の 338〜899 行

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5 (2026-10-07)。ジョブ全体の数字 (7 ファイル):

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 502 | 236 | 2 | 237 | 0 | 27 |

この節は `src/server/server.nim` の 338〜899 行の生き残り 56 件 (id 順ではなく行順)。ほかの範囲は別の節 (別の担当) が記録する。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 4 |
| 2 ジョブに無い既存のテストが検出 (ジョブに追記) | 4 |
| 3 穴 (テストを追加) | 41 |
| 4 到達しない・冗長なコード | 2 |
| 5 欠陥 | 0 |
| 6 許容 | 5 |

分類 2 と 3 は、変異を 1 件ずつ手で当て、テストが落ちる (または止まる) ことを確かめた。そのあと `jj restore` で戻した。
分類 1 は式から読んだ。1 件も runError は無い。

ジョブの `testCommand` に足したテスト: `test_request_hooks`、`test_trace_context`、`test_server_sampling_tools` (後ろの 2 つは分類 2)。

| id | 場所 | 変異子 | 変異 | 分類 | 理由 | 検出するテスト |
|---:|---|---|---|---:|---|---|
| 328 | `server.nim:338` | RVR | `return false` → `<return default>` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された。 |  |
| 162 | `server.nim:338` | BLR | `false` → `true` | 3 | 未知の要求の取り消しが `true` を返さないこと (docstring の第 1 句) を直接呼んで確かめる。 | test_server_progress_cancel `cancelRequest called directly` |
| 87 | `server.nim:340` | LOR | `ctx.cancelled or ctx.finished` → `<or -> and>` | 3 | 同じ要求を 2 度取り消すと 2 度目は `false`。変異では `cancelSignal.complete()` を 2 度呼び FutureError になる。 | test_server_progress_cancel `cancelRequest called directly` |
| 329 | `server.nim:341` | RVR | `return false` → `<return default>` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された。 |  |
| 163 | `server.nim:341` | BLR | `false` → `true` | 3 | 既に取り消した要求・initialize の取り消しが `false` であること。 | test_server_progress_cancel `cancelRequest called directly` |
| 165 | `server.nim:345` | BLR | `true` → `false` | 3 | 生きている要求の取り消しが `true` を返すこと。 | test_server_progress_cancel `cancelRequest called directly` |
| 191 | `server.nim:373` | SDL | `server.listenFilterHooks.add hook` → `discard` | 3 | 4 つの拡張口のうち listen hook・interceptor・transform は、どのテストにも登録されていなかった。登録順に効くことを確かめる。 | test_request_hooks `hooks run in the order they were added` の listen filter hooks |
| 192 | `server.nim:378` | SDL | `server.interceptors.add interceptor` → `discard` | 3 | 同上 (interceptor)。 | test_request_hooks `hooks run in the order they were added` の request interceptors |
| 193 | `server.nim:383` | SDL | `server.responseFilters.add filter` → `discard` | 2 | response filter は test_request_hooks が検出する (job に追記)。 | test_request_hooks `response filters` |
| 194 | `server.nim:394` | SDL | `server.toolListTransforms.add transform` → `discard` | 3 | 同上 (tool list transform)。 | test_request_hooks `hooks run in the order they were added` の tool list transforms |
| 195 | `server.nim:460` | SDL | `await subscribe(uri)` → `discard` | 3 | 旧 API の subscribe ハンドラが呼ばれるテストが無かった。 | test_server_errors `the earlier API` の subscribe and unsubscribe handlers |
| 196 | `server.nim:464` | SDL | `await unsubscribe(uri)` → `discard` | 3 | 同上 (unsubscribe)。 | test_server_errors `the earlier API` の subscribe and unsubscribe handlers |
| 332 | `server.nim:477` | RVR | `return await get(name, arguments)` → `<return default>` | 3 | 旧 API の prompt get ハンドラの戻り値が prompts/get の結果になること。 | test_server_errors `the earlier API` の get handler |
| 333 | `server.nim:483` | RVR | `return newJsonRpcErrorResponse(request.id, -32600, "Server a` → `<return default>` | 3 | 2 度目の initialize が invalid request で、最初の握手が残ること。 | test_legacy_handshake `sends initialize again` |
| 90 | `server.nim:490` | LOR | `params.isNil or params.kind != JObject` → `<or -> and>` | 3 | params が無い・object でない initialize が invalid params であること (変異では nil を参照して落ちる)。 | test_legacy_handshake `no params or params that are no object` |
| 197 | `server.nim:505` | SDL | `supportedJson.add %($v)` → `discard` | 4 | 下の「残っているもの」を参照。 |  |
| 335 | `server.nim:506` | RVR | `return newJsonRpcErrorResponse(request.id, -32022,; "Unsuppo` → `<return default>` | 4 | 同上。 |  |
| 336 | `server.nim:523` | RVR | `return newJsonRpcErrorResponse(request.id, ErrInvalidParams,` → `<return default>` | 3 | clientInfo が Implementation でない initialize が invalid params で、握手が始まらないこと。 | test_legacy_handshake `a clientInfo that is no Implementation` |
| 200 | `server.nim:542` | SDL | `stderr.writeLine("[mcp-server] initialized notification in s` → `discard` | 6 | 診断の文言だけを書く行 (stderr)。 |  |
| 205 | `server.nim:558` | SDL | `stderr.writeLine("[mcp-server] notifications/cancelled witho` → `discard` | 6 | 同上。 |  |
| 36 | `server.nim:561` | ROR | `reasonNode.kind != JString` → `<!= -> ==>` | 3 | 取り消しの reason が ctx.cancelReason に届き、無い・文字列でないときは空であること。 | test_server_progress_cancel `a cancellation with a reason` |
| 207 | `server.nim:563` | SDL | `stderr.writeLine("[mcp-server] request " & peerText(requestI` → `discard` | 6 | 同上。 |  |
| 37 | `server.nim:565` | ROR | `reason.len > 0` → `<> -> >=>` | 6 | 診断の文言の末尾 (`: reason`) を付けるかどうかだけが変わる。 |  |
| 40 | `server.nim:580` | ROR | `samplingJson["tools"].kind == JObject` → `<== -> !=>` | 3 | sampling.tools が object のとき宣言とみなし、object でないとき宣言なしとみなすこと。 | test_legacy_handshake `declares capabilities as objects` / `that are no objects` |
| 41 | `server.nim:581` | ROR | `samplingJson["context"].kind == JObject` → `<== -> !=>` | 3 | 同上 (sampling.context)。 |  |
| 42 | `server.nim:584` | ROR | `elicitationJson.kind == JObject` → `<== -> !=>` | 3 | 同上 (elicitation)。 |  |
| 43 | `server.nim:590` | ROR | `experimentalJson.kind == JObject` → `<== -> !=>` | 3 | 同上 (experimental)。 |  |
| 44 | `server.nim:594` | ROR | `extensionsJson.kind == JObject` → `<== -> !=>` | 3 | 同上 (extensions)。 |  |
| 338 | `server.nim:653` | RVR | `return none(JsonRpcError)` → `<return default>` | 1 | `Option[T]` の既定値は `none`。`return none(JsonRpcError)` と `return default` は同じ。 |  |
| 341 | `server.nim:663` | RVR | `return rejectInvalidTraceContext(request.params)` → `<return default>` | 2 | 不正な traceparent を invalid params で断るテストが test_trace_context にある (job に追記)。 | test_trace_context `a malformed traceparent, when the request arrives` |
| 211 | `server.nim:664` | SDL | `none(JsonRpcError)` → `discard` | 1 | 手続きの最後の式 `none(JsonRpcError)` を `discard` にしても、`result` の既定値が `none`。 |  |
| 52 | `server.nim:723` | ROR | `logger.len > 0` → `<> -> >=>` | 3 | logger を渡さない log に logger キーが付かないこと。 | test_server_logging `without a logger` |
| 114 | `server.nim:736` | LOR | `ctx.finished or ctx.cancelled` → `<or -> and>` | 3 | 答えた後・取り消した後の log は何も送らないこと。 | test_server_logging `has been answered, when its context logs` / `cancelled, when its handler logs` |
| 56 | `server.nim:779` | ROR | `relatedTask.len > 0` → `<> -> >=>` | 3 | task を持たない要求は hold hook に尋ねず、すぐ送る。 | test_server_requests `names no task` |
| 120 | `server.nim:779` | LOR | `relatedTask.len > 0 and relatedRequestId.len == 0` → `<and -> or>` | 3 | task と元の要求の両方を持つ要求は、hold hook に尋ねず元の要求に載せて送る。 | test_server_requests `a task and a request of the client` |
| 57 | `server.nim:779` | ROR | `relatedRequestId.len == 0` → `<== -> !=>` | 3 | 同上。 |  |
| 119 | `server.nim:779` | LOR | `relatedTask.len > 0 and relatedRequestId.len == 0 and; not s` → `<and -> or>` | 3 | hook が無いか断る要求は、すぐ送る。 | test_server_requests `no hold hook` / `hook that declines` |
| 220 | `server.nim:784` | SDL | `server.pending.del(key)` → `discard` | 3 | hook が例外で断った要求は待ちの表から消え、後の sendHeld は何も送らない。 | test_server_requests `a hold hook that refuses` |
| 58 | `server.nim:786` | ROR | `timeoutMs > 0` → `<> -> >=>` | 3 | timeoutMs = 0 は無制限 (docstring)。変異では即座に timeout になる。 | test_server_requests `no time limit` |
| 221 | `server.nim:787` | SDL | `server.pending.del(key)` → `discard` | 3 | 保留中に時間切れになった要求は、後の sendHeld で送られない。 | test_server_requests `a held request whose time ran out` |
| 223 | `server.nim:794` | SDL | `stderr.writeLine("[mcp-server] could not cancel timed out " ` → `discard` | 6 | 診断の文言だけを書く行 (stderr)。 |  |
| 224 | `server.nim:808` | SDL | `await server.transport.sendRequest(outgoing)` → `discard` | 3 | sendHeld が保留した要求を tasks/result の stream に載せて送ること。 | test_server_requests `waits until sendHeld puts it on the stream` |
| 124 | `server.nim:841` | LOR | `roots.isNil or roots.kind != JArray` → `<or -> and>` | 3 | roots/list の答えに roots 配列が無ければ remote error。変異では nil を参照して落ちる。 | test_server_requests `answers roots/list without a roots array` |
| 228 | `server.nim:857` | SDL | `raiseIfAny("sampling/createMessage",; createMessageParamsPro` → `discard` | 2 | sampling/createMessage の引数検査は test_server_sampling_tools が検出する (job に追記)。 | test_server_sampling_tools `break the pairing of tool uses and results` |
| 229 | `server.nim:863` | SDL | `raiseIfAny("sampling/createMessage result",; createMessageRe` → `discard` | 2 | 結果の検査も同様。 | test_server_sampling_tools `an answer that stops for tool use without a tool_use block` ほか |
| 230 | `server.nim:876` | SDL | `inc scope.inputsOpen` → `discard` | 3 | task に属する要求が入力待ちを数えること。 | test_server_requests `told it needs input at the first request` |
| 60 | `server.nim:877` | ROR | `scope.inputsOpen == 1` → `<== -> !=>` | 3 | 同上。 |  |
| 231 | `server.nim:878` | SDL | `scope.awaitingInput(true)` → `discard` | 3 | 最初の要求で task に「入力待ち」を知らせること。 |  |
| 167 | `server.nim:878` | BLR | `true` → `false` | 3 | 同上 (引数が true)。 |  |
| 232 | `server.nim:885` | SDL | `dec scope.inputsOpen` → `discard` | 3 | 最後の答えで数を減らすこと。 |  |
| 61 | `server.nim:886` | ROR | `scope.inputsOpen == 0` → `<== -> !=>` | 3 | 同上。 |  |
| 233 | `server.nim:887` | SDL | `scope.awaitingInput(false)` → `discard` | 3 | 最後の答えで task に「入力待ちでない」を知らせること。 |  |
| 168 | `server.nim:887` | BLR | `false` → `true` | 3 | 同上 (引数が false)。 |  |
| 234 | `server.nim:892` | SDL | `await ctx.server.ping(ctx.session, input.relatedRequestId, i` → `discard` | 3 | ctx.ping が client に ping を送ること。 | test_server_requests `as no task` ほか |
| 235 | `server.nim:894` | SDL | `ctx.endInput()` → `discard` | 3 | ctx.ping の終わりに endInput が呼ばれること。 |  |
| 346 | `server.nim:899` | RVR | `return await ctx.server.listRoots(ctx.session, input.related` → `<return default>` | 3 | ctx.listRoots が client の roots を返すこと。 |  |

### 診断の行 (分類 6) の理由

id 200、205、207、223 は stderr に診断を 1 行書くだけの文、id 37 はその行の末尾 (`: reason`) を付けるかどうかの条件である。
診断は人が読むためで、プロトコルの結果にも状態にも効かない。`tests/test_security_diagnostic.nim` が検査するのは、ピアの文字列を `peerText` で無害にすること
(MCP-SEC-HTTP-7) で、この 5 行は対象に含まれない。行の有無や文言を検査するテストは、実装の文字列を写すだけになり、実装と独立な情報を持たない。

### 残っているもの

- id 197 と 335 (`server.nim:502-511`、`handleInitialize` の `negotiated.isNone` の枝): 到達しない (分類 4)。`handleInitialize` に来るのは
  `isModernPath` が偽の要求だけで、それは「サーバーの版が旧版」か「サーバーが旧版を話す」のどちらかのとき。どちらも
  `spokenVersionsUpTo(server.protocolVersion)` に旧版を 1 つ以上含み、`negotiateLegacyVersion` は旧版が 1 つでもあれば `none` を返さない。
  旧版を話さないサーバーへの旧版の initialize は `handleModernRequest` (`server.nim:1383-1387`) が -32022 で断る。枝は 10 行で、
  削除は未実施 (リードの判断を待つ)。残すなら、届かないと分かる `raiseAssert` に替える (client の id 307 と同じ扱い)。
- 分類 6 の 5 件 (上)。

## src/server/server.nim の 901〜1291 行

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5 (2026-10-07)。ジョブ全体の数字 (4 人で分担):

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 502 | 236 | 2 | 237 | 0 | 27 |

この節の担当は `src/server/server.nim` の 901〜1291 行で、生き残りは 56 件。この範囲の server.nim はレポートの時点から変わっていない
(`jj diff -r owwryuxn::mwslvmvr -- src/server` は空)。分類:

| 分類 | 件数 |
|---|---:|
| 1 同値 | 6 |
| 2 ジョブに無い既存のテストが検出 (ジョブに追記) | 25 |
| 3 穴 (テストを追加) | 21 |
| 4 到達しない・冗長なコード | 1 |
| 5 欠陥 | 0 |
| 6 許容 | 3 |

分類 2 と 3 は、変異を 1 件ずつ手で当てて、その 1 本のテストプログラムが落ちる (または止まる) ことを確かめた。分類 1 は式から読み、
`Option[T]` と `string` の既定値だけは nim で確かめた。

### 測り方についての注記

- `return <式>` を `return default` に替える RVR の変異は、応答を返す箇所では `JsonRpcResponse` の既定値になる。通信路の符号化
  (`transport.nim` の `toJson`) は result も error も無い応答を `"result": {}` にするので、**外から見える違いは `jsonrpc` が "2.0" でなくなること**
  だけになる箇所がある (成功の応答)。そこで `tests/server_harness.nim` の `responseTo` が、読んだ応答の `jsonrpc` が "2.0" であることを検査する
  ようにした (JSON-RPC 2.0 の規則)。分類 2 のうち RVR の行 (359, 362, 364, 365, 378, 379, 404) の検出は、この検査が入った状態で確かめた。
- 分類 3 の「穴」のうち 377 と 403 は、この harness の検査だけが検出する。

### 生き残り 56 件

| id | 場所 | 変異 | 元 → 変異後 | 分類 | 理由 | いま検出するテスト |
|---:|---|---|---|---|---|---|
| 64 | server.nim:956 | ROR | `tools.kind != JArray` → `<!= -> ==>` | 2 | `!=` を `==` にすると、配列の一覧では何も外さずに返る。 | test_param_headers_http: Given a tool whose x-mcp-header is invalid, when tools are listed, then the server does not publish it |
| 67 | server.nim:1115 | ROR | `registered.extensionId.len > 0` → `<> -> >=>` | 3 | `registerOpenMethod` にテストが無く、空の拡張 id でも宣言を求める変異が通った。 | test_extensions: Given a method of a specification that asks nothing of the client, when a client that declared nothing calls it, then the server serves it (MCP-EXT-16) |
| 71 | server.nim:1238 | ROR | `faults.len > 0` → `<> -> >=>` | 2 | `faults.len >= 0` では、適合する結果にも内部エラーを返す。 | test_structured_tool_output: Given structuredContent and no content, when the result is answered, then the serialized JSON is added as text ほか |
| 127 | server.nim:956 | LOR | `tools.isNil or tools.kind != JArray` → `<or -> and>` | 4 | `withoutInvalidParamHeaders` の呼び出し元は `listPage` の結果だけで、`result` は常に `tools` 配列を持つ。`tools.isNil` は決して真にならないので `or` を `and` にしても結果は同じ。この 2 行の早期 return (953-957 行) は防御で届かない。リードの判断を仰ぐ。 |  |
| 130 | server.nim:1056 | LOR | `capabilities.tools.isSome and capabiliti` → `<and -> or>` | 2 | `and` を `or` にすると、listChanged を宣言していない (または capability 自体が無い) 型を確認応答に含めてしまう。 | test_subscriptions: Given a type the server does not support, when it acknowledges, then that type is omitted |
| 131 | server.nim:1058 | LOR | `capabilities.prompts.isSome and capabili` → `<and -> or>` | 2 | `and` を `or` にすると、listChanged を宣言していない (または capability 自体が無い) 型を確認応答に含めてしまう。 | test_subscriptions: Given a type the server does not support, when it acknowledges, then that type is omitted |
| 132 | server.nim:1101 | LOR | `known.clientCapabilities.isSome and; kno` → `<and -> or>` | 2 | `declaredCapabilities` の 3 つの枝 (リクエスト自身の宣言、initialize の extensions、`and` の短絡)。 | test_extensions: Given a handler that uses ctx.requireClientExtension ... / Given a legacy client that declared an extension in initialize ... |
| 133 | server.nim:1115 | LOR | `registered.extensionId.len > 0 and not r` → `<and -> or>` | 2 | `and` を `or` にすると、宣言した client への呼び出しや servedUndeclared の拡張が missing-capability になる。 | test_extensions: Given an extension the server alone declares, when a client that declared nothing calls its method, then the server serves it and the client sends it ほか |
| 134 | server.nim:1115 | LOR | `registered.extensionId.len > 0 and not r` → `<and -> or>` | 2 | `and` を `or` にすると、宣言した client への呼び出しや servedUndeclared の拡張が missing-capability になる。 | test_extensions: Given an extension the server alone declares, when a client that declared nothing calls its method, then the server serves it and the client sends it ほか |
| 135 | server.nim:1136 | LOR | `caps.resources.isNone or server.resource` → `<or -> and>` | 3 | capability の宣言と handler の登録の両方が要る。既存のテストは両方とも無いサーバーしか使わず、`or` が `and` でも通った。残りの 2 通りを検査する。 | test_server_resources_prompts / test_server_errors: Given handlers for resources and prompts but no capability declared ... / Given the capabilities declared but no handlers ... / Given tool handlers but no tools capability ... (MCP-RESOURCES-13, MCP-TOOLS-6) |
| 136 | server.nim:1151 | LOR | `caps.resources.isNone or server.resource` → `<or -> and>` | 3 | capability の宣言と handler の登録の両方が要る。既存のテストは両方とも無いサーバーしか使わず、`or` が `and` でも通った。残りの 2 通りを検査する。 | test_server_resources_prompts / test_server_errors: Given handlers for resources and prompts but no capability declared ... / Given the capabilities declared but no handlers ... / Given tool handlers but no tools capability ... (MCP-RESOURCES-13, MCP-TOOLS-6) |
| 140 | server.nim:1201 | LOR | `caps.tools.isNone or server.toolCall.isN` → `<or -> and>` | 3 | capability の宣言と handler の登録の両方が要る。既存のテストは両方とも無いサーバーしか使わず、`or` が `and` でも通った。残りの 2 通りを検査する。 | test_server_resources_prompts / test_server_errors: Given handlers for resources and prompts but no capability declared ... / Given the capabilities declared but no handlers ... / Given tool handlers but no tools capability ... (MCP-RESOURCES-13, MCP-TOOLS-6) |
| 143 | server.nim:1245 | LOR | `caps.prompts.isNone or server.promptsLis` → `<or -> and>` | 3 | capability の宣言と handler の登録の両方が要る。既存のテストは両方とも無いサーバーしか使わず、`or` が `and` でも通った。残りの 2 通りを検査する。 | test_server_resources_prompts / test_server_errors: Given handlers for resources and prompts but no capability declared ... / Given the capabilities declared but no handlers ... / Given tool handlers but no tools capability ... (MCP-RESOURCES-13, MCP-TOOLS-6) |
| 144 | server.nim:1251 | LOR | `caps.prompts.isNone or server.promptGet.` → `<or -> and>` | 3 | capability の宣言と handler の登録の両方が要る。既存のテストは両方とも無いサーバーしか使わず、`or` が `and` でも通った。残りの 2 通りを検査する。 | test_server_resources_prompts / test_server_errors: Given handlers for resources and prompts but no capability declared ... / Given the capabilities declared but no handlers ... / Given tool handlers but no tools capability ... (MCP-RESOURCES-13, MCP-TOOLS-6) |
| 236 | server.nim:901 | SDL | `ctx.endInput()` → `discard` | 3 | ctx.listRoots / ctx.createMessage が入力の範囲を閉じないと、答えたあともタスクが input_required のまま (Tasks: 答えが届くまで input_required、そのあと working)。 | test_tasks_end_to_end: Given a tool that asks the client for sampling or roots inside a task, when the client has answered, then the task is working again while the tool goes on |
| 237 | server.nim:908 | SDL | `ctx.endInput()` → `discard` | 3 | ctx.listRoots / ctx.createMessage が入力の範囲を閉じないと、答えたあともタスクが input_required のまま (Tasks: 答えが届くまで input_required、そのあと working)。 | test_tasks_end_to_end: Given a tool that asks the client for sampling or roots inside a task, when the client has answered, then the task is working again while the tool goes on |
| 238 | server.nim:916 | SDL | `server.pending.del(key)` → `discard` | 3 | 答え済みの id への 2 度目の答えは、表に残った待ちを完了済みの future に再度 complete させる。表から消すことが「2 度目は無視」を成り立たせる。 | test_server_requests: Given an answer that arrives twice, when the second arrives, then it is ignored and the first answer stands |
| 248 | server.nim:962 | SDL | `stderr.writeLine("[mcp-server] not listi` → `discard` | 6 | 標準エラーへ出す診断行の文面だけの差 (tests/test_security_diagnostic.nim が検査するのは peerText を通ること。この 3 行は検査しない)。クライアントに返る答えは変わらない。同じ理由で 3 件まとめて許容。 |  |
| 252 | server.nim:1006 | SDL | `stderr.writeLine("[mcp-server] tools/lis` → `discard` | 6 | 標準エラーへ出す診断行の文面だけの差 (tests/test_security_diagnostic.nim が検査するのは peerText を通ること。この 3 行は検査しない)。クライアントに返る答えは変わらない。同じ理由で 3 件まとめて許容。 |  |
| 253 | server.nim:1008 | SDL | `none(JsonNode)` → `discard` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 256 | server.nim:1036 | SDL | `checkParamHeaders(declared.bindings, arg` → `discard` | 2 | `checkParamHeaders` を呼ばないと、Mcp-Param-* ヘッダと引数の食い違いが見逃される。 | test_param_headers_http: Given a Base64 header without its padding, when posted, then the answer is 400 header mismatch ほか |
| 257 | server.nim:1048 | SDL | `stderr.writeLine("[mcp-server] tools/cal` → `discard` | 6 | 標準エラーへ出す診断行の文面だけの差 (tests/test_security_diagnostic.nim が検査するのは peerText を通ること。この 3 行は検査しない)。クライアントに返る答えは変わらない。同じ理由で 3 件まとめて許容。 |  |
| 258 | server.nim:1082 | SDL | `server.subscriptions.add subscription` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 259 | server.nim:1077 | SDL | `hook(ctx, requested, honored)` → `discard` | 3 | `addListenFilterHook` に外部から見えるテストが無く、フックの呼び出しを消しても全部通った。 | test_subscriptions: Given listen filter hooks, when a client listens, then each runs in the order added and the acknowledgment carries what they leave in the filter (MCP-SUBSCRIBE-13) |
| 260 | server.nim:1084 | SDL | `await server.transport.sendNotification(` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 261 | server.nim:1087 | SDL | `subscription.closed.completesWith(ended)` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 262 | server.nim:1088 | SDL | `ctx.cancelSignal.completesWith(ended)` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 263 | server.nim:1089 | SDL | `await ended` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 264 | server.nim:1091 | SDL | `server.subscriptions.remove subscription` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 265 | server.nim:1103 | SDL | `newJNull()` → `discard` | 3 | `declaredCapabilities` の公開 API は「何も分からなければ JSON null」と文書化しているのに、nil を返しても通った。 | test_extensions: Given a legacy client, when a handler reads what the client declared, then only the extensions are carried over and nothing known is JSON null (MCP-EXT-12) |
| 350 | server.nim:996 | RVR | `return none(JsonNode)` → `<return default>` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 352 | server.nim:1004 | RVR | `return none(JsonNode)` → `<return default>` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 353 | server.nim:1018 | RVR | `return content.outputProblems(version, s` → `<return default>` | 2 | `outputProblems` が空の列を返すと、outputSchema に合わない結果がそのまま通る。 | test_structured_tool_output: Given a version before 2026-07-28, when structuredContent is not an object, then the server answers with an internal error; 2026-07-28 accepts any JSON ほか |
| 354 | server.nim:1032 | RVR | `return none(JsonRpcError)` → `<return default>` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 355 | server.nim:1035 | RVR | `return none(JsonRpcError)` → `<return default>` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 356 | server.nim:1044 | RVR | `return ""` → `<return default>` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 358 | server.nim:1073 | RVR | `return newJsonRpcErrorResponse(request.i` → `<return default>` | 2 | 不正な filter のときの invalid params が既定の応答になる。 | test_subscriptions: Given a request without a usable notifications filter, when it arrives, then it is invalid params |
| 359 | server.nim:1092 | RVR | `return newJsonRpcResponse(request.id, li` → `<return default>` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 360 | server.nim:1099 | RVR | `return ctx.clientCapabilities` → `<return default>` | 2 | `declaredCapabilities` の 3 つの枝 (リクエスト自身の宣言、initialize の extensions、`and` の短絡)。 | test_extensions: Given a handler that uses ctx.requireClientExtension ... / Given a legacy client that declared an extension in initialize ... |
| 361 | server.nim:1102 | RVR | `return %*{"extensions": known.clientCapa` → `<return default>` | 2 | `declaredCapabilities` の 3 つの枝 (リクエスト自身の宣言、initialize の extensions、`and` の短絡)。 | test_extensions: Given a handler that uses ctx.requireClientExtension ... / Given a legacy client that declared an extension in initialize ... |
| 362 | server.nim:1120 | RVR | `return newJsonRpcErrorResponse(request.i` → `<return default>` | 2 | 拡張メソッドの missing-capability の答え、成功の答え、dispatchExtension への経路。 | test_extensions: Given a client that does not declare the extension, when it calls an extension method, then it gets the missing-capability error naming the extension ほか |
| 363 | server.nim:1124 | RVR | `return malformed.get` → `<return default>` | 3 | 拡張メソッドの handler がオブジェクトでない値を返したときの内部エラーにテストが無かった。 | test_extensions: Given an extension method whose handler returns something that is not an object, when it answers, then it is an internal error (MCP-EXT-17) |
| 364 | server.nim:1125 | RVR | `return newJsonRpcResponse(request.id, an` → `<return default>` | 2 | 拡張メソッドの missing-capability の答え、成功の答え、dispatchExtension への経路。 | test_extensions: Given a client that does not declare the extension, when it calls an extension method, then it gets the missing-capability error naming the extension ほか |
| 365 | server.nim:1133 | RVR | `return answer.get` → `<return default>` | 3 | `addRequestInterceptor` の契約 (順序、最初の答えで終わる、none なら続行) が Tasks 拡張越しにしか検査されていなかった。 | test_request_hooks: Given interceptors, when a request is served, then they run in the order added, the first answer ends the matter and none lets the server carry on (MCP-HOOKS-2) |
| 372 | server.nim:1155 | RVR | `return missingParam(request, "uri")` → `<return default>` | 3 | 必須の文字列パラメーター (uri / name) が無い・文字列でないときの invalid params にテストが無かった。 | test_server_resources_prompts / test_server_errors: Given a read or a get whose required string parameter is missing or not a string ... / Given a call whose name is missing or not a string ... (MCP-RESOURCES-14) |
| 377 | server.nim:1178 | RVR | `return newJsonRpcResponse(request.id, ne` → `<return default>` | 3 | 成功の応答 (空の result) を既定の応答に替えても、通信路の符号化が空の result を補うので、どのテストも気付かなかった。応答は jsonrpc "2.0" を持つ、という JSON-RPC の規則を harness の responseTo で検査するようにした。 | tests/server_harness.nim の responseTo (test_server_notifications、test_server_logging が落ちる) |
| 378 | server.nim:1182 | RVR | `return notSupported(request)` → `<return default>` | 2 | `subscriptions/listen` の旧版での method not found と、modern での listen の応答。 | test_subscriptions: Given a version without subscriptions/listen, when it is requested, then it is method not found ほか |
| 379 | server.nim:1183 | RVR | `return await server.listen(request, ctx)` → `<return default>` | 2 | `subscriptions/listen` の旧版での method not found と、modern での listen の応答。 | test_subscriptions: Given a version without subscriptions/listen, when it is requested, then it is method not found ほか |
| 380 | server.nim:1187 | RVR | `return notSupported(request)` → `<return default>` | 3 | capability を宣言していない・handler が無いときの method not found の答え。 | test_server_errors: Given the tools capability but no call handler, when a tool is called, then the method is not found |
| 383 | server.nim:1202 | RVR | `return notSupported(request)` → `<return default>` | 3 | capability を宣言していない・handler が無いときの method not found の答え。 | test_server_errors: Given the tools capability but no call handler, when a tool is called, then the method is not found |
| 384 | server.nim:1205 | RVR | `return missingParam(request, "name")` → `<return default>` | 3 | 必須の文字列パラメーター (uri / name) が無い・文字列でないときの invalid params にテストが無かった。 | test_server_resources_prompts / test_server_errors: Given a read or a get whose required string parameter is missing or not a string ... / Given a call whose name is missing or not a string ... (MCP-RESOURCES-14) |
| 386 | server.nim:1215 | RVR | `return newJsonRpcErrorResponse(request.i` → `<return default>` | 2 | 食い違いの答えが既定の応答になると、400 の header mismatch にならない。 | test_param_headers_http: Given a Base64 header without its padding, when posted, then the answer is 400 header mismatch ほか |
| 394 | server.nim:1255 | RVR | `return missingParam(request, "name")` → `<return default>` | 3 | 必須の文字列パラメーター (uri / name) が無い・文字列でないときの invalid params にテストが無かった。 | test_server_resources_prompts / test_server_errors: Given a read or a get whose required string parameter is missing or not a string ... / Given a call whose name is missing or not a string ... (MCP-RESOURCES-14) |
| 395 | server.nim:1261 | RVR | `return malformed.get` → `<return default>` | 3 | prompts/get の handler がオブジェクトでない値を返したときの内部エラーにテストが無かった (tools/call には既にあった)。 | test_server_errors: Given a prompt handler whose result is not an object, when the prompt is requested, then the answer is an internal error (MCP-PROMPTS-5) |
| 403 | server.nim:1287 | RVR | `return newJsonRpcResponse(request.id, ne` → `<return default>` | 3 | 成功の応答 (空の result) を既定の応答に替えても、通信路の符号化が空の result を補うので、どのテストも気付かなかった。応答は jsonrpc "2.0" を持つ、という JSON-RPC の規則を harness の responseTo で検査するようにした。 | tests/server_harness.nim の responseTo (test_server_notifications、test_server_logging が落ちる) |
| 404 | server.nim:1291 | RVR | `return await server.dispatchExtension(re` → `<return default>` | 2 | 拡張メソッドの missing-capability の答え、成功の答え、dispatchExtension への経路。 | test_extensions: Given a client that does not declare the extension, when it calls an extension method, then it gets the missing-capability error naming the extension ほか |

### ジョブへの追記

`tests/mutation/server.json` の testCommand の末尾に追記した (この順): `test_subscriptions`、`test_extensions`、`test_request_hooks`、
`test_param_headers_http`、`test_structured_tool_output`、`test_tasks_end_to_end`。どれも、上の表の変異のどれかを 1 本で検出することを確かめてある。
`specs/tests.map` と `specs/*.feature` には、追加したテストに対応する行 (MCP-SUBSCRIBE-13、MCP-EXT-12 の追加行・MCP-EXT-16・17、MCP-HOOKS-2、
MCP-RESOURCES-13・14、MCP-TOOLS-6、MCP-PROMPTS-5、MCP-TASKS-14 の追加行、MCP-SERVERREQ-10) を足した。

### 残っているもの

- 分類 6 (許容) の 3 件 (id 248, 252, 257): 標準エラーへ出す診断行の文面。
- 分類 4 の 1 件 (id 127): `withoutInvalidParamHeaders` の 953〜957 行の早期 return は、呼び出し元が `listPage` の結果だけなので届かない。
  削除するかどうかはリードの判断に任せる (削除すると 64 の変異の意味も変わる)。
- 上のほかは、テストを足したか、ジョブに既存のテストを足して検出を確かめた。

## src/server/server.nim の 1302 行以降

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5。担当は `src/server/server.nim` の 1302 行から末尾の生き残りと、server.nim の timeout 2 件 (id 239 と 296)。
総数はリードが g2-server.md にまとめる。ここでは担当分の 55 件 + timeout 2 件を 1 件ずつ記録する。

分類の件数 (timeout 2 件を含む 57 行):

| 分類 | 件数 |
|---|---:|
| 1 | 4 |
| 2 | 24 |
| 3 | 19 |
| 4 | 1 |
| 6 | 9 |

分類 2 と 3 は、変異を 1 件ずつ手で当ててテストが落ちる (または止まる) ことを確かめた (id 239 の行は 917 行目)。分類 1 は式と不変条件から読んだ。

| id | file:line | mutator | 原文 → 変異 | 分類 | 理由 | 検出するテスト |
|---:|---|---|---|---|---|---|
| 274 | server.nim:1302 | SDL | `stderr.writeLine(...)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 275 | server.nim:1303 | SDL | `newJsonRpcErrorResponse(...)` → discard | 2 | `input_required` を返せない場合の内部エラー応答が空になる | test_mrtr: handler asks for nothing など |
| 406 | server.nim:1305 | RVR | `return defect(...)` → 既定値 | 2 | 版が複数往復を持たないときの内部エラー | test_mrtr: version without multi round-trips |
| 407 | server.nim:1307 | RVR | `return defect(...)` → 既定値 | 2 | 許されないメソッドの内部エラー | test_mrtr: request that does not support input_required |
| 408 | server.nim:1310 | RVR | `return defect(problem.get)` → 既定値 | 2 | 何も尋ねない handler の内部エラー | test_mrtr: handler that asks for nothing |
| 72 | server.nim:1312 | ROR | `payloadProblems.len > 0` → `>= 0` | 2 | 常に真になり正常な尋ね返しが内部エラーになる | test_mrtr: tool that needs input |
| 409 | server.nim:1313 | RVR | `return defect(payloadProblems.join)` → 既定値 | 2 | 規則違反の input request の内部エラー | test_mrtr: input request breaks the rules |
| 73 | server.nim:1315 | ROR | `missing.len > 0` → `>= 0` | 2 | 常に真になり正常な尋ね返しが capability 欠落になる | test_mrtr: tool that needs input |
| 410 | server.nim:1318 | RVR | `return newJsonRpcErrorResponse(...)` → 既定値 | 2 | capability 欠落エラー | test_mrtr: client that did not declare |
| 273 | server.nim:1325 | SDL | `newJsonRpcResponse(...)` → discard | 2 | input_required の応答そのもの | test_mrtr: tool that needs input |
| 413 | server.nim:1342 | RVR | `return inputRequiredResponse(...)` → 既定値 | 2 | `McpInputRequired` の応答 | test_mrtr: tool that needs input |
| 416 | server.nim:1359 | RVR | `return none(...)` → 既定値 | 1 | `Option[JsonRpcResponse]` の既定値は none で、同じ値を返す |  |
| 417 | server.nim:1361 | RVR | `return some(error)` → 既定値 | 3 | resultType が文字列でないときの内部エラーを確かめるテストが無かった | test_extensions: Given a tool whose result has a resultType that is not a string |
| 418 | server.nim:1365 | RVR | `return none(...)` → 既定値 | 1 | 同上 (既定値が none) |  |
| 419 | server.nim:1370 | RVR | `return some(internal error)` → 既定値 | 2 | どの拡張も定義しない resultType の内部エラー | test_extensions: handler that returns a resultType no extension defines |
| 420 | server.nim:1375 | RVR | `return some(missing capability)` → 既定値 | 3 | 宣言していない拡張の resultType への -32021 が未検査だった | test_extensions: Given a tool whose result carries an extension's resultType ... |
| 276 | server.nim:1376 | SDL | 末尾の `none(...)` → discard | 1 | `result` の既定値が none で、同じ値を返す |  |
| 425 | server.nim:1401 | RVR | `return newJsonRpcErrorResponse(...)` → 既定値 | 2 | inputResponses / requestState の型違いは invalid params | test_mrtr: inputResponses or requestState of the wrong type |
| 150 | server.nim:1413 | LOR | `isNil or kind != JObject` → `and` | 3 | handler の結果が object でない (nil / 配列) とき 2026-07-28 は内部エラー。標準の handler は途中で検査済みで、この守りに届くのはフィルターなどが差し替えた結果だけだった | test_request_hooks: Given a filter that turns a 2026-07-28 result into something that is not an object |
| 426 | server.nim:1414 | RVR | `return newJsonRpcErrorResponse(...)` → 既定値 | 3 | 同上 | 同上 |
| 427 | server.nim:1418 | RVR | `return unusable.get` → 既定値 | 2 | 使えない resultType の応答を返す | test_extensions: handler that returns a resultType no extension defines |
| 281 | server.nim:1454 | SDL | `handling.addCallback(finished = true)` → 削除 | 3 | 応答済みの detached 要求に cancel しても ctx が cancelled にならない、が未検査だった | test_server_progress_cancel: Given a detached request that has been answered, when it is cancelled ... |
| 170 | server.nim:1454 | BLR | `finished = true` → false | 3 | 同上 | 同上 |
| 151 | server.nim:1457 | LOR | `not finished and not cancelled` → `or` | 3 | 2 回目の cancel と応答後の cancel が何も変えないことが未検査だった | test_server_progress_cancel: detached request ... cancelled twice / answered |
| 171 | server.nim:1458 | BLR | `ctx.cancelled = true` → false | 2 | tasks/cancel で tool が停止を知らされる | test_tasks_server: Given a working task, when cancelled, then ... the tool is told |
| 282 | server.nim:1460 | SDL | `ctx.cancelSignal.complete()` → discard | 2 | 同上 | test_tasks_server: Given a working task, when cancelled ... |
| 284 | server.nim:1471 | SDL | `cancelSignal.completesWith(settled)` → 削除 | 3 | 取り消された要求の待ちが、止められない handler の終了まで続く。transport への通知が handler の終了後になる | test_server_progress_cancel: Given a request in flight, when the client cancels it, then the transport is told at once ... |
| 286 | server.nim:1476 | SDL | 放棄した handler の `addCallback` → discard | 6 | コールバックの効果は中の診断行だけ。診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 288 | server.nim:1478 | SDL | `stderr.writeLine(cancelled ... ended with)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 287 | server.nim:1480 | SDL | `stderr.writeLine(... cancelled; no response sent)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 289 | server.nim:1486 | SDL | `stderr.writeLine(... failed with)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 79 | server.nim:1492 | ROR | `getOrDefault(key) == ctx` → `!=` | 3 | 同じ id が再利用されたとき、先の要求の終了が後の要求の登録を消してしまう | test_server_progress_cancel: Given a request id used again while the first request runs ... |
| 290 | server.nim:1493 | SDL | `server.inFlight.del(key)` → discard | 4 | 消さない効果は private な表 `inFlight` の肥大だけ。完了済みの項目は `cancelRequest` が finished で拒むので公開 API からは見えない。観測用の公開手続き (`subscriptionCount` の類) が無いと検査できない。リードに報告 (公開 API の追加になるため触れない) |  |
| 291 | server.nim:1495 | SDL | `transport.requestDropped(...)` → discard | 3 | 取り消した要求を transport が知らされることが未検査だった (SessionedTransport に記録を追加) | test_server_progress_cancel: transport is told at once |
| 296 | server.nim:1526 | SDL | `server.resolveResponse(...)` → discard (timeout) | 2 | timeout: 応答がサーバーの待ちに届かず、サーバー発の要求を待つテストが終わらない | test_server_requests など (timeout として検出済み) |
| 239 | server.nim:917 | SDL | `waiting.complete(response)` → discard (timeout) | 2 | timeout: 同上。待ちの future が完了しないので、答えを待つテストが終わらない | 同上 |
| 299 | server.nim:1532 | SDL | `server.cancelSession(session)` → discard | 3 | transport が閉じたとき処理中の要求が cancelled になることが未検査だった (待ちの失敗は `failPending(none)` が代行するので隠れていた) | test_server_progress_cancel: Given a transport that closes, when a request is in flight, then it is cancelled |
| 298 | server.nim:1533 | SDL | `failPending(none, e)` (McpTransportClosedError 節) → discard | 1 | 直前のループで `cancelSession` が全セッションの `failPending(some(session))` を済ませる。待ちの表の鍵のセッションは必ず `server.sessions` にある (`request` は operational なセッションにしか出さず、`endSession` は cancelSession の後で消す) ので、ここは常に空振り |  |
| 300 | server.nim:1536 | SDL | `failPending(none, e)` (CatchableError 節) → discard | 3 | transport が close 以外の失敗をしたとき、サーバーの待ちが失敗することが未検査だった (SessionedTransport に `breakDown` を追加) | test_server_requests: Given a transport that fails while the server waits ... |
| 301 | server.nim:1537 | SDL | `stderr.writeLine(transport loop ended with)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 304 | server.nim:1550 | SDL | `server.endSession(session)` → discard | 3 | transport がセッションを終えたとき、要求の cancel とクライアントの忘却が未検査だった | test_server_progress_cancel: Given a transport that ends a session ... |
| 307 | server.nim:1575 | SDL | `stderr.writeLine(could not send ... session)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 308 | server.nim:1593 | SDL | `await transport.sendNotification(notification)` → discard | 2 | 購読ストリームへの配信 | test_subscriptions: tool list changes ... tagged with its id |
| 309 | server.nim:1595 | SDL | `stderr.writeLine(could not send ... subscription)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 310 | server.nim:1606 | SDL | `deliverToSubscribers(...)` → discard (`notifySubscribers`) | 3 | 拡張が購読者に通知する公開手続きを呼ぶテストが無かった。変異すると nil の future を返し、テストは SIGSEGV で落ちる | test_subscriptions: Given an open subscription, when an extension notifies the subscribers ... |
| 312 | server.nim:1619 | SDL | `await deliverToSubscribers(...)` (deliverAll) → discard | 2 | list_changed が購読ストリームにも届く | test_subscriptions: tool list changes ... |
| 154 | server.nim:1642 | LOR | `resources.isSome and ...subscribe` → `or` | 3 | resources を宣言しないサーバーで notifyResourceUpdated が何も送らず、投げないことが未検査だった | test_request_hooks: Given a server that declared no tools, prompts or resources ... |
| 155 | server.nim:1660 | LOR | tools `isSome and listChanged` → `or` | 2 | listChanged 無しの tools では送らない | test_request_hooks: Given a list the server did not declare listChanged for ... |
| 156 | server.nim:1662 | LOR | prompts `and` → `or` | 3 | prompts / resources の同じ守りは tools でしか検査されていなかった | test_request_hooks: Given prompts and resources declared without listChanged ... |
| 157 | server.nim:1664 | LOR | resources `and` → `or` | 3 | 同上 | 同上 |
| 316 | server.nim:1668 | SDL | `deliverAll(...)` (notifyListChanged) → discard | 2 | params 付きの list_changed | test_request_hooks: notifyListChanged carries params |
| 174 | server.nim:1697 | BLR | `tornDown = true` → false | 3 | endSubscriptions を続けて 2 回呼んでも、取り消しと応答は 1 回だけであることが未検査だった | test_subscriptions: Given a stdio server that ends its subscriptions twice in a row ... |
| 82 | server.nim:1698 | ROR | `kind == mtkStdio` → `!=` | 2 | stdio だけが notifications/cancelled を送る | test_subscriptions: stdio ... notifications/cancelled |
| 321 | server.nim:1703 | SDL | `await sendNotification(cancelled)` → discard | 2 | 同上 | test_subscriptions: Given a stdio server, when it ends a subscription ... |
| 322 | server.nim:1705 | SDL | `stderr.writeLine(could not cancel subscription)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 320 | server.nim:1707 | SDL | `subscription.closed.complete()` → discard | 2 | listen の応答が返らず、テストが終わらない (止まる = 検出) | test_subscriptions: ends a subscription (止まる) |
| 84 | server.nim:1721 | ROR | `level >= known.logLevel.get` → `>` | 3 | クライアントが設定した水準そのものの配信が未検査だった | test_server_logging: Given a client whose level is error, when the server logs at error ... |

### ジョブへの追記 (tests/mutation/server.json の testCommand)

`test_mrtr` / `test_extensions` / `test_request_hooks` / `test_tasks_server` / `test_subscriptions` を末尾に追記した。

### 他の共有ファイルへの追記

- `tests/sessioned_transport.nim`: `dropped` と `requestDropped`、`breakDown` を追加。
- `specs/tests.map` と `specs/*.feature`: MCP-EXT-5、MCP-HOOKS-2 (新)、MCP-CANCEL-1/3/7 (7 は新)、MCP-SERVERREQ-6、MCP-LISTCHANGED-1、MCP-SUBSCRIBE-3/6、MCP-LOGGING-2 に行を追加。

### 残っているもの

- id 290 (`server.nim:1493`、分類 4): `inFlight` の肥大は公開 API から観測できない。`inFlight` の件数を返す公開手続きを足せば検査できる。2026-10-12 に、足さないと決めた。
- id 296 と 239 (917 行) は timeout として検出済み。
- 診断行 (分類 6) の 9 件は文面だけの差で、許容した。

## server.nim 以外 (pagination / completion / log_level、および削除した resources / prompts)

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5 (2026-10-07)。担当は `resources.nim`、`prompts.nim`、`pagination.nim`、`completion.nim`、`log_level.nim`。`server.nim` は別の記録 (リードが `g2-server.md` にまとめる)。

| ファイル | survived | killed | compileError |
|---|---:|---:|---:|
| `src/server/resources.nim` | 56 | 0 | 0 |
| `src/server/prompts.nim` | 4 | 0 | 0 |
| `src/server/pagination.nim` | 6 | 8 | 3 |
| `src/server/completion.nim` | 3 | 14 | 0 |
| `src/protocol/log_level.nim` | 1 | 2 | 0 |

runError はない。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 6 |
| 2 ジョブに無い既存のテストが検出 | 0 |
| 3 穴 (テストを追加) | 4 |
| 4 到達しない・冗長なコード | 60 |
| 5 欠陥 | 0 |
| 6 許容 | 0 |

分類 3 の 4 件は、変異を手で当てて、追加したテストだけが落ちる (または異常終了する) ことを確かめた。分類 1 は式から読んだ。

### resources.nim と prompts.nim: 1 件も検出されなかった理由

どちらのモジュールも、SDK のどこからも import されていない。`src/`、`examples/`、`tests/`、`docs/`、`templates/`、下流の `build/ws/ds-*/src`、`products/*/src` を、エクスポートされた全 proc 名 (`createResourceInfo`、`detectMimeType`、`readFileAsResource`、`createPromptInfo`、`createTextContent` ほか) で検索して、定義以外の出現は 0 件だった。`src/mcp.nim` が import するのは `client/resources` と `client/prompts` で、サーバー側の同名ファイルではない。サーバーの resources / prompts は `server.nim` のハンドラ経由で動いていて、これらのヘルパーを使わない。

変異したコードはどのテストのコンパイルにも入らないので、テストが何であっても変異は検出されない。さらに `resources.nim` は**コンパイルできない**: 173 行の `pattern \!= "*"` に余計なバックスラッシュがあり、`Error: undeclared identifier: '\!='` になる (単独でコンパイルして確認した)。`prompts.nim` は通るが、未使用 import の警告が 3 件 (`asyncdispatch`、`options`、`sequtils`) 出る。使われていないので表に出なかった。

テストは書かない (死んだコードのテストは何も守らない)。リードの判断を待つ。提案は、2 ファイルを削除し、`tests/mutation/server.json` の `sources` から外すこと。

### 分類 4: resources.nim と prompts.nim の 60 件

理由はすべて同じ (上の節): どこからも import されず、`resources.nim` はコンパイルもできない。

| id | file:line | mutator | 変異 |
|---|---|---|---|
| 4 | `server/prompts.nim:11` | ROR | `arguments.len > 0` → `<> -> >=>` |
| 7 | `server/prompts.nim:14` | BLR | `false` → `true` |
| 5 | `server/prompts.nim:20` | ROR | `description.len > 0` → `<> -> >=>` |
| 6 | `server/prompts.nim:28` | ROR | `description.len > 0` → `<> -> >=>` |
| 447 | `server/resources.nim:11` | ROR | `description.len > 0` → `<> -> >=>` |
| 448 | `server/resources.nim:14` | ROR | `mimeType.len > 0` → `<> -> >=>` |
| 449 | `server/resources.nim:17` | ROR | `size >= 0` → `<>= -> >>` |
| 450 | `server/resources.nim:40` | ROR | `description.len > 0` → `<> -> >=>` |
| 451 | `server/resources.nim:43` | ROR | `mimeType.len > 0` → `<> -> >=>` |
| 452 | `server/resources.nim:46` | ROR | `arguments.len > 0` → `<> -> >=>` |
| 461 | `server/resources.nim:49` | BLR | `false` → `true` |
| 453 | `server/resources.nim:55` | ROR | `description.len > 0` → `<> -> >=>` |
| 464 | `server/resources.nim:63` | RVR | `return "text/plain"` → `<return default>` |
| 465 | `server/resources.nim:65` | RVR | `return "text/markdown"` → `<return default>` |
| 466 | `server/resources.nim:67` | RVR | `return "text/html"` → `<return default>` |
| 467 | `server/resources.nim:69` | RVR | `return "text/css"` → `<return default>` |
| 468 | `server/resources.nim:71` | RVR | `return "application/javascript"` → `<return default>` |
| 469 | `server/resources.nim:73` | RVR | `return "application/json"` → `<return default>` |
| 470 | `server/resources.nim:75` | RVR | `return "application/xml"` → `<return default>` |
| 471 | `server/resources.nim:77` | RVR | `return "application/pdf"` → `<return default>` |
| 472 | `server/resources.nim:79` | RVR | `return "image/png"` → `<return default>` |
| 473 | `server/resources.nim:81` | RVR | `return "image/jpeg"` → `<return default>` |
| 474 | `server/resources.nim:83` | RVR | `return "image/gif"` → `<return default>` |
| 475 | `server/resources.nim:85` | RVR | `return "image/svg+xml"` → `<return default>` |
| 476 | `server/resources.nim:87` | RVR | `return "audio/mpeg"` → `<return default>` |
| 477 | `server/resources.nim:89` | RVR | `return "audio/wav"` → `<return default>` |
| 478 | `server/resources.nim:91` | RVR | `return "video/mp4"` → `<return default>` |
| 479 | `server/resources.nim:93` | RVR | `return "video/webm"` → `<return default>` |
| 480 | `server/resources.nim:95` | RVR | `return "application/zip"` → `<return default>` |
| 481 | `server/resources.nim:97` | RVR | `return "application/x-tar"` → `<return default>` |
| 482 | `server/resources.nim:99` | RVR | `return "application/gzip"` → `<return default>` |
| 483 | `server/resources.nim:101` | RVR | `return "text/x-nim"` → `<return default>` |
| 484 | `server/resources.nim:103` | RVR | `return "text/x-python"` → `<return default>` |
| 485 | `server/resources.nim:105` | RVR | `return "text/x-c"` → `<return default>` |
| 486 | `server/resources.nim:107` | RVR | `return "text/x-c++"` → `<return default>` |
| 487 | `server/resources.nim:109` | RVR | `return "text/x-c-header"` → `<return default>` |
| 488 | `server/resources.nim:111` | RVR | `return "text/x-rust"` → `<return default>` |
| 489 | `server/resources.nim:113` | RVR | `return "text/x-go"` → `<return default>` |
| 490 | `server/resources.nim:115` | RVR | `return "text/x-java"` → `<return default>` |
| 491 | `server/resources.nim:117` | RVR | `return "text/x-csharp"` → `<return default>` |
| 492 | `server/resources.nim:119` | RVR | `return "text/x-typescript"` → `<return default>` |
| 493 | `server/resources.nim:121` | RVR | `return "text/x-ruby"` → `<return default>` |
| 494 | `server/resources.nim:123` | RVR | `return "text/x-php"` → `<return default>` |
| 495 | `server/resources.nim:125` | RVR | `return "text/x-shellscript"` → `<return default>` |
| 496 | `server/resources.nim:127` | RVR | `return "text/x-bat"` → `<return default>` |
| 497 | `server/resources.nim:129` | RVR | `return "text/x-powershell"` → `<return default>` |
| 498 | `server/resources.nim:131` | RVR | `return "text/x-sql"` → `<return default>` |
| 499 | `server/resources.nim:133` | RVR | `return "application/octet-stream"` → `<return default>` |
| 500 | `server/resources.nim:136` | RVR | `return mimeType.startsWith("text/") or mimeType == "applicat` → `<return default>` |
| 459 | `server/resources.nim:136` | LOR | `mimeType.startsWith("text/") or mimeType == "application/jso` → `<or -> and>` |
| 454 | `server/resources.nim:137` | ROR | `mimeType == "application/json"` → `<== -> !=>` |
| 458 | `server/resources.nim:137` | LOR | `mimeType.startsWith("text/") or mimeType == "application/jso` → `<or -> and>` |
| 455 | `server/resources.nim:138` | ROR | `mimeType == "application/javascript"` → `<== -> !=>` |
| 457 | `server/resources.nim:138` | LOR | `mimeType.startsWith("text/") or mimeType == "application/jso` → `<or -> and>` |
| 456 | `server/resources.nim:139` | ROR | `mimeType == "application/xml"` → `<== -> !=>` |
| 501 | `server/resources.nim:152` | RVR | `return createTextResourceContent(uri, text, mimeType)` → `<return default>` |
| 502 | `server/resources.nim:157` | RVR | `return createBinaryResourceContent(uri, encoded, mimeType)` → `<return default>` |
| 460 | `server/resources.nim:173` | LOR | `"*" and not name.match(pattern)` → `<and -> or>` |
| 462 | `server/resources.nim:182` | SDL | `result.add(createResourceInfo(uri, name, "", mimeType, size.` → `discard` |
| 463 | `server/resources.nim:184` | SDL | `result.add(createResourceInfo(uri, name, "Directory", "inode` → `discard` |

### pagination.nim、completion.nim、log_level.nim の 10 件

| id | file:line | mutator | 変異 | 分類 | 理由 | 検出するテスト |
|---|---|---|---|---|---|---|
| 23 | `pagination.nim:31` | RVR | `return none(int)` → `return default` | 1 | `default(Option[int])` は `none(int)` と同じ値 (`has` が false) | |
| 24 | `pagination.nim:33` | RVR | 同上 | 1 | 同上 | |
| 25 | `pagination.nim:38` | RVR | 同上 | 1 | 同上 | |
| 26 | `pagination.nim:40` | RVR | 同上 | 1 | 同上 | |
| 12 | `pagination.nim:39` | ROR | `offset < 1` → `offset <= 1` | 3 | ページサイズ 1 の 2 ページ目のカーソルは `offset:1`。変異するとこのカーソルが無効になる。既存のテストはページサイズ 2 だけで、オフセットは 2 と 4 しか使わなかった | `test_server_pagination.nim` "Given a page size of 1, when the pages are followed, ..." |
| 13 | `pagination.nim:39` | ROR | `offset >= itemCount` → `offset > itemCount` | 3 | 末尾そのもの (`offset:5`、5 件) は発行されないカーソルで、無効でなければならない。既存のテストは 50 だけ試していた | `test_server_pagination.nim` "Given a cursor nobody issued, ..." に `b2Zmc2V0OjU=` を追加 |
| 439 | `completion.nim:24` | LOR | `node.isNil or node.kind != JObject` → `and` | 1 | `requiredString` の呼び出しは `reference` と `argument` だけで、どちらも直前に非 nil の JObject と確かめてある。しかも `node{key}` は nil と非オブジェクトに nil を返す (std/json) ので、ガード自体が冗長 (分類 4 としても読める。削除はしない) | |
| 441 | `completion.nim:33` | LOR | `params.isNil or params.kind != JObject` → `and` | 3 | `params` が nil のとき変異は nil の `kind` を読んで SIGSEGV。非オブジェクトの params では結果が同じ (`{}` が nil を返す) | `test_server_completion.nim` "Given a request without params, ..." |
| 438 | `completion.nim:71` | ROR | `values.len > MaxCompletionValues` → `>=` | 3 | ちょうど 100 件のとき、変異は `hasMore: true` を足す。仕様の上限は 100 件で、100 件に収まるなら続きがあるとは言えない | `test_server_completion.nim` "Given exactly 100 values, ..." |
| 2 | `log_level.nim:24` | SDL | `none(McpLogLevel)` → `discard` | 1 | 関数の最後の式。`discard` にすると `result` が既定値になり、`default(Option[McpLogLevel])` は `none` と同じ | |

### 追記したもの (リードが統合する)

- `tests/mutation/server.json`: なし (追加したテストは `test_server_pagination.nim` と `test_server_completion.nim` で、どちらも既に testCommand に入っている)。
- `specs/tests.map`: `MCP-PAGINATION-1`、`MCP-COMPLETION-1`、`MCP-COMPLETION-4` に各 1 行。

### 残っているもの

- `resources.nim` と `prompts.nim` (分類 4、60 件): 解消済み。どこからも import されていなかったので、`refactor(server): remove two modules nothing imported and a branch initialize cannot reach` で削除した。
- 分類 1 の 6 件は式から読んだだけで、実行していない。439 は冗長なガードで、削除するかどうかはリードが決める。

## 測り直し (本線 76a08c6a、2026-10-10)

36a4c8a5 の測定のあとに足したテストと修正を入れたコミットで、同じジョブを測り直した。変異 442、検出 371、時間切れ 5、コンパイル不能 27、**生き残り 39** (前回 237)。

前回の生き残りとの突き合わせは変異の指紋で行った。39 件のうち 37 件は前回も生き残っていて、この文書に分類と理由がある (行番号は 2〜7 行ずれている)。前回「穴」(分類 3) としてテストを足した変異は、1 件も残っていない。

| 分類 | 件数 | 内訳 |
|---|---|---|
| 1 同値 | 19 | `return none(T)` → `return default` と、末尾の `none(T)` → `discard` (どちらも `Option` の既定値は none)。`log_level.nim:24`、`completion.nim:24`、`pagination.nim` の 5 件、`server.nim` の 12 件 |
| 4 到達しない・冗長 | 3 | id 127 (`withoutInvalidParamHeaders` の早期 return)、id 290 (`inFlight.del`)、下の新規 1 件 |
| 6 許容 | 17 | stderr への診断の出力と、その文言 (`reason.len > 0`) |

新しく現れた 2 件 (どちらも測定のあとに足した行):

| 場所 | 変異 | 分類 | 理由 |
|---|---|---|---|
| `pagination.nim:43` | RVR `return none(int)` → `return default` | 1 | `default(Option[int])` は `none(int)`。同じ手続きのほかの 4 件と同じ |
| `server.nim:504` | SDL `doAssert negotiated.isSome, …` → `discard` | 4 | 握手を持つ版を 1 つも話さないサーバーは、ここに来る前に `initialize` へエラーを返している。表明は、その前提が崩れたときに止めるためのもので、テストから真にできない |

2026-10-12 に、id 290 (`inFlight` の件数を外から見えるようにするか) は、公開 API を足さないと決めた。次の測定でも生き残る。
