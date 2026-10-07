# G2 変異検出: client ジョブの `client.nim` 以外 (content / roots / sampling / tools / utilities)

測定: `nim-muter`、ジョブ `tests/mutation/client.json`、mainline の 36a4c8a5 (2026-10-07)。
この記録は `src/client/` のうち `client.nim` 以外のファイルの生存変異 15 件の分で、`client.nim` の分は別の記録 (g2-client-core) にある。
`prompts.nim` と `resources.nim` に生存変異はない。

| ファイル | survived |
|---|---|
| content.nim | 4 |
| roots.nim | 2 |
| sampling.nim | 4 |
| tools.nim | 4 |
| utilities.nim | 1 |

## survived 15 件

分類は、1 = 同値、3 = 穴 (新しい外部仕様テストを足した)、6 = 受け入れ。
クラス 3 の行は、変異を手で当てて該当テストが落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは戻した)。
`nil` を `.kind` で読む変異は、テストが nil 参照で異常終了する形で検出される (どれも変異なしでは全件通るので、異常終了も検出として数える)。

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 70 | content.nim:48 | RVR | `return none(string)` → 既定値 | 1 | `Option[string]` の既定値は none で、元の戻り値と同じ。 |
| 52 | content.nim:76 | LOR | `node.isNil or node.kind != JObject` → `and` | 3 | resource オブジェクトのない埋め込み resource ブロックが、protocol error でなく nil 参照になる。`Given an embedded resource block without its resource object, when it is parsed, then McpProtocolError is raised` (test_client_operations) |
| 53 | content.nim:85 | LOR | 同上 (`parseContentItem`) | 3 | オブジェクトでない content ブロックが protocol error にならず、未知のブロックとして通る (nil は nil 参照)。`Given a content block that is not an object, when it is parsed, then McpProtocolError is raised` (test_client_operations) |
| 40 | content.nim:120 | ROR | `mimeType.len > 0` → `>= 0` | 3 | mimeType のない埋め込み resource を書き戻すと `"mimeType": ""` が付く。`Given an embedded resource without a mimeType, when it is written back, then no mimeType key is written` (test_client_operations) |
| 310 | roots.nim:21 | SDL | `requireNotConnected("the roots provider")` → 削除 | 3 | 接続後に roots provider を足しても拒まれず、サーバーに宣言していない capability になる。`Given a connected client, when a roots provider is set, then McpError is raised` (test_client_server_requests) |
| 313 | roots.nim:35 | SDL | `requireFeature(ftRootsListChanged, ...)` → 削除 | 3 | 2026-07-28 の接続でも `notifications/roots/list_changed` を送ってしまう。`Given a 2026-07-28 connection, when the client notifies that its roots changed, then McpUnsupportedError is raised and nothing is sent` (test_client_server_requests、デフォルト版が 2026-07-28 のときだけ実行される。ほかの版のビルドでは、その版に機能があるので検査の対象がない) |
| 108 | sampling.nim:69 | RVR | `return none(float)` → 既定値 | 1 | `Option[float]` の既定値は none で、元の戻り値と同じ。 |
| 87 | sampling.nim:76 | LOR | `params.isNil or params.kind != JObject` → `and` | 3 | params が nil の `parseSamplingRequest` が protocol error でなく nil 参照になる (オブジェクトでない非 nil の params は、変異ありでも `requiredArray` が同じ例外を出すので区別できない)。`Given params that are not an object, when they are parsed as a sampling request, then McpProtocolError is raised` (test_client_server_requests) |
| 111 | sampling.nim:177 | RVR | `return newJsonRpcErrorResponse(request.id, -32602, e.msg)` → 既定値 | 3 | `createMessageParamsProblems` を通ったあとで、型の誤り (temperature が文字列) が `parseSamplingRequest` で見つかる経路。invalid params (-32602) とフィールド名を確かめる。`Given a temperature that is not a number, when the server asks, then the client answers invalid params naming the field and the handler is not called` (test_client_server_requests)。既存の「壊れた params」のテストは maxTokens だけが欠けた形で、手前の検査で止まっていた。 |
| 107 | sampling.nim:182 | SDL | 「答えを送らなかった」の診断行 → 削除 | 3 | 内部エラーを返す理由が、ローカルの開発者に何も残らない。診断の全文でなく、「the sampling handler's answer was not sent」の句が stderr に出ることを確かめる。`Given a handler that answers toolUse without a tool_use block, when the server asks, then the client says on stderr that the answer was not sent` (test_client_sampling_tools、2025-11-25 以上のデフォルト版で実行) |
| 30 | tools.nim:54 | RVR | `return McpToolAnnotations()` → 既定値 | 1 | `annotationsOf` は annotations がないとき `McpToolAnnotations()` (全フィールド未設定) を返す。型の既定値は同じ値なので、観測できる差がない。 |
| 26 | tools.nim:98 | SDL | `toolOutputSchemas.del(tool.name)` → 削除 | 3 | 再取得した一覧で outputSchema がなくなったツールの結果を、古い schema で検査し続ける。`Given a tool listed with an outputSchema, when it is listed again without one, then its results are no longer checked` (test_structured_tool_output) |
| 20 | tools.nim:111 | BLR | `getBool(false)` → `getBool(true)` | 3 | isError のない結果がエラーとして読まれる (仕様の既定は false)。`Given a tool result without isError, when it is read, then isError is false` (test_client_operations) |
| 29 | tools.nim:124 | SDL | `requireTools("tools/call")` → 削除 | 3 | tools capability のないサーバーに tools/call を送ってしまう。`Given a server without the tools capability, when a tool is called, then McpUnsupportedError is raised and nothing is sent` (test_client_operations) |
| 336 | utilities.nim:33 | LOR | `completion.isNil or completion.kind != JObject` → `and` | 3 | `completion` のない答えが protocol error でなく nil 参照になる。`Given a completion answer without a completion object, when completing, then McpProtocolError is raised` (test_client_operations) |

## 追加したテストと仕様

- `tests/test_client_operations.nim` (suite `answers that do not have the shape the specification gives them`、6 件)、`tests/test_client_server_requests.nim` (4 件)、`tests/test_structured_tool_output.nim` (1 件)、`tests/test_client_sampling_tools.nim` (1 件)。
- `specs/content.feature` に MCP-CONTENT-FIELDS-2 を追加し、MCP-STRUCTOUT-5、MCP-COMPLETION-5、MCP-CLIENTREQ-1、MCP-CLIENTREQ-4 の Scenario に 1 行ずつ足した。`specs/tests.map` に対応を書いた。
- `tests/mutation/client.json` の `testCommand` は変更なし (4 つのテストファイルを既に含む)。
- 新しいテストは、デフォルト版 2024-11-05 と 2025-11-25 でも通ることを確かめた (版による有無はテスト側のガードに従う)。

## 前回の手による検証 (build/keep/g2-hand-verified.md) との対応

前回「穴」としたもののうち、この記録の範囲は 40 (mimeType)、111 (sampling params)、26 (outputSchema)、20 (isError)。すべてテストを足して検出に変えた。30 は同値と確かめた。

## 残っているもの

- 同値 (id 70, 108, 30) は上表の理由のとおり。
- id 313 のテストは、デフォルト版が 2026-07-28 のビルドでだけ実行される (その版でだけ機能が無い)。client ジョブはデフォルト版で走るので検出される。
- 他に未決のものはない。
