# G2 変異検出: server ジョブ、server.nim 901〜1291 行 (担当 g2c-server-b)

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

## 測り方についての注記

- `return <式>` を `return default` に替える RVR の変異は、応答を返す箇所では `JsonRpcResponse` の既定値になる。通信路の符号化
  (`transport.nim` の `toJson`) は result も error も無い応答を `"result": {}` にするので、**外から見える違いは `jsonrpc` が "2.0" でなくなること**
  だけになる箇所がある (成功の応答)。そこで `tests/server_harness.nim` の `responseTo` が、読んだ応答の `jsonrpc` が "2.0" であることを検査する
  ようにした (JSON-RPC 2.0 の規則)。分類 2 のうち RVR の行 (359, 362, 364, 365, 378, 379, 404) の検出は、この検査が入った状態で確かめた。
- 分類 3 の「穴」のうち 377 と 403 は、この harness の検査だけが検出する。

## 生き残り 56 件

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

## ジョブへの追記

`tests/mutation/server.json` の testCommand の末尾に追記した (この順): `test_subscriptions`、`test_extensions`、`test_request_hooks`、
`test_param_headers_http`、`test_structured_tool_output`、`test_tasks_end_to_end`。どれも、上の表の変異のどれかを 1 本で検出することを確かめてある。
`specs/tests.map` と `specs/*.feature` には、追加したテストに対応する行 (MCP-SUBSCRIBE-13、MCP-EXT-12 の追加行・MCP-EXT-16・17、MCP-HOOKS-2、
MCP-RESOURCES-13・14、MCP-TOOLS-6、MCP-PROMPTS-5、MCP-TASKS-14 の追加行、MCP-SERVERREQ-10) を足した。

## 残っているもの

- 分類 6 (許容) の 3 件 (id 248, 252, 257): 標準エラーへ出す診断行の文面。
- 分類 4 の 1 件 (id 127): `withoutInvalidParamHeaders` の 953〜957 行の早期 return は、呼び出し元が `listPage` の結果だけなので届かない。
  削除するかどうかはリードの判断に任せる (削除すると 64 の変異の意味も変わる)。
- 上のほかは、テストを足したか、ジョブに既存のテストを足して検出を確かめた。
