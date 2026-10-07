# G2 変異検出: server ジョブ、server.nim の 338〜899 行

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
| 328 | `server.nim:338` | RVR | `return false` → `<return default>` | 1 | `bool` の既定値は `false`。`return false` と `return default` は同じ。 |  |
| 162 | `server.nim:338` | BLR | `false` → `true` | 3 | 未知の要求の取り消しが `true` を返さないこと (docstring の第 1 句) を直接呼んで確かめる。 | test_server_progress_cancel `cancelRequest called directly` |
| 87 | `server.nim:340` | LOR | `ctx.cancelled or ctx.finished` → `<or -> and>` | 3 | 同じ要求を 2 度取り消すと 2 度目は `false`。変異では `cancelSignal.complete()` を 2 度呼び FutureError になる。 | test_server_progress_cancel `cancelRequest called directly` |
| 329 | `server.nim:341` | RVR | `return false` → `<return default>` | 1 | 同上。 |  |
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

## 診断の行 (分類 6) の理由

id 200、205、207、223 は stderr に診断を 1 行書くだけの文、id 37 はその行の末尾 (`: reason`) を付けるかどうかの条件である。
診断は人が読むためで、プロトコルの結果にも状態にも効かない。`tests/test_security_diagnostic.nim` が検査するのは、ピアの文字列を `peerText` で無害にすること
(MCP-SEC-HTTP-7) で、この 5 行は対象に含まれない。行の有無や文言を検査するテストは、実装の文字列を写すだけになり、実装と独立な情報を持たない。

## 残っているもの

- id 197 と 335 (`server.nim:502-511`、`handleInitialize` の `negotiated.isNone` の枝): 到達しない (分類 4)。`handleInitialize` に来るのは
  `isModernPath` が偽の要求だけで、それは「サーバーの版が旧版」か「サーバーが旧版を話す」のどちらかのとき。どちらも
  `spokenVersionsUpTo(server.protocolVersion)` に旧版を 1 つ以上含み、`negotiateLegacyVersion` は旧版が 1 つでもあれば `none` を返さない。
  旧版を話さないサーバーへの旧版の initialize は `handleModernRequest` (`server.nim:1383-1387`) が -32022 で断る。枝は 10 行で、
  削除は未実施 (リードの判断を待つ)。残すなら、届かないと分かる `raiseAssert` に替える (client の id 307 と同じ扱い)。
- 分類 6 の 5 件 (上)。
