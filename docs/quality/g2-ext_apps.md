# G2 変異検出: ext_apps ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/ext_apps.json`、拡張ブランチの c9b5c264 (初回の測定。比べる記録は無い)。対象は `src/ext/apps/{host,messages,model,provider}.nim` と `src/ext/apps.nim`。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 315 | 250 | 1 | 51 | 0 | 13 |

生き残り 51 件の分類。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 16 |
| 2 / 2b 別のテストが検出 | 0 |
| 3 穴 (テストを追加) | 35 |
| 4 到達しない・冗長なコード | 0 |
| 5 欠陥 | 0 |
| 6 許容 | 0 |

分類 3 の 35 件はすべて、変異を手で当てて名前を挙げたテストが落ちることを確かめた (`build/one.sh` 経由、1 件ずつ、確認後に `jj restore`)。変異なしでは 4 本のテストファイルとも合格する (後述)。

## timeout の 1 件

id 137 (`host.nim:229`、`fetchUiResource` の `requireServerCapability(... resources ...)` の削除): `resources` capability を持たない相手に `resources/read` を送り、相手 (`startPeer(nil, ...)`) は答えない。クライアントの既定の要求タイムアウトは 60 秒 (`DefaultRequestTimeoutMs`) で、テスト `Given a server without the resources capability, when fetched, ...` は版ごとに 1 回ずつ待つので、`nim-muter` の制限を超える。つまり変異が「待ちが終わらない」状態を作り、テストが無制限に待つのではなく、クライアントの 60 秒で `McpTimeoutError` に落ちる。検出済みとして数える。同じ形の id 133 (`tools/list`) は、今回足したテストで `McpTimeoutError` と `requestsFor("tools/list").len == 1` の失敗を確かめた。id 137 そのものは 240 秒の待ちを避けて当てていない (同じ形の 133 からの推定)。

## 分類 1 (同値) の理由

| id | file:line | 変異 | 理由 |
|---|---|---|---|
| 224 | `messages.nim:153` | `isDisplayMode` の `isNil or kind != JString` → `and` | 呼び出しは `not mode.isNil` を確かめた後か、配列の要素 (JSON から来るので nil にならない) だけ。nil 以外の文字列でない節は `getStr()` が `""` を返し、どの `UiDisplayMode` の文字列とも一致せず `false` になる |
| 267 | `messages.nim:234` | `hostContextProblem` 末尾の `none(string)` を削除 | 暗黙の結果は `Option[string]` の既定値で、`none` と同じ |
| 63 | `model.nim:90` | `uiUriProblem` 末尾の `none(string)` を削除 | 同上 |
| 64 | `model.nim:124` | `cspProblem` 末尾の `none(string)` を削除 | 同上 |
| 65 | `model.nim:132` | `domainProblem` 末尾の `none(string)` を削除 | 同上 |
| 66 | `model.nim:144` | `metaProblem` 末尾の `none(string)` を削除 | 同上 |
| 140 | `host.nim:132` | `return none(string)` → `default(Option[string])` | 非リテラルの戻り値は `default(typeof(...))` になり、`none(string)` と同じ値 |
| 90 | `model.nim:223` | `return UiResourceMeta()` → `default(UiResourceMeta)` | 構築子に引数が無く、既定値と同じ値 |
| 91 | `model.nim:249` | `return none(UiToolMeta)` → 既定値 | 同上 (`none` は `Option` の既定値) |
| 92 | `model.nim:284` | `return none(UiToolMeta)` → 既定値 | 同上 |
| 93 | `model.nim:295` | `return none(UiClientCapability)` → 既定値 | 同上 |
| 94 | `model.nim:298` | `return none(UiClientCapability)` → 既定値 | 同上 |
| 95 | `model.nim:302` | `return none(UiClientCapability)` → 既定値 | 同上 |
| 165 | `provider.nim:143` | `return none(UiClientCapability)` → 既定値 | 同上 |
| 10 | `model.nim:99` | `isCspSource` の `schemeEnd < 0` → `<= 0` | `schemeEnd == 0` は `://` で始まる入力で、原文では次の `source[0 ..< 0]` (`""`) が `["http", "https", "ws", "wss"]` に無いので同じく `false` を返す |
| 11 | `model.nim:104` | `colon >= 0` → `> 0` | 差が出るのは `colon == 0` (`rest` が `:` で始まる) だけ。原文は `rest` を空にして `rest.len > 0` で `false`、変異は `:` を残して先頭文字の検査 (`rest[0] in Letters + Digits`) で `false` |

`return none(T)` を `default` にする変異 (140、91-95、165) は、brief の注意に従って「既定値だから」で済ませたのではなく、戻り値が非リテラルの構築子 `none(T)` / `UiResourceMeta()` であり、その既定値と一致することを型から確かめた。リテラルを返す `return` (287) は分類 3 に入れてある。

## 分類 3 (穴) と検出するテスト

テストは既存の仕様 ID に足した (`specs/tests.map` の同じ ID の隣)。新しい Scenario は無い。

| id | file:line | mutator | 原文 → 変異 | 検出するテスト |
|---|---|---|---|---|
| 133 | `host.nim:101` | SDL | `tools` capability の検査を削除 | `test_ext_apps_host`: Given a server without the tools capability, when tools are listed, then McpUnsupportedError and nothing is sent |
| 123 | `host.nim:158` | LOR | `contents.isNil or ...` → `and` | `test_ext_apps_host`: Given an answer whose contents is missing or not an array, ... (nil で実行が落ちる) |
| 111 | `host.nim:177` | ROR | `maxHtmlBytes <= 0` → `< 0` | `test_ext_apps_host`: Given a non-positive limit, ... (`must be positive` を確かめる) |
| 101 | `host.nim:141` | AOR | `encodedLen + 3` → `- 3` | `test_ext_apps_host`: Given a blob just over the limit once decoded, ... (1372 文字、制限 1024 で、復号の前に断られる) |
| 257 | `messages.nim:154` | BLR | `isDisplayMode` の `return false` → `true` | `test_ext_apps_messages`: Given a host context that is not an object or holds a section of the wrong kind, ... (`displayMode: 3`、`availableDisplayModes: [3]`) |
| 287 | `messages.nim:154` | RVR | 同じ行の `return false` → `return true` (リテラルなので反転) | 同上 (257 と同じ変異) |
| 166 | `messages.nim:150` | ROR | `node.kind == JInt` → `!=` | 同上と Given a size of zero or a number that is not finite, ... (`newJFloat(Inf)`、`newJFloat(NaN)`。`%` は非有限の小数を文字列にするので `newJFloat` で直接作る) |
| 171 | `messages.nim:173` | ROR | `modes.kind != JArray` → `==` | 同上と Given a host context with a list of modes and zero-pixel dimensions, ... |
| 292 | `messages.nim:174` | RVR | `availableDisplayModes must be an array` の `some` を `none` に | Given a host context that is not an object or holds a section of the wrong kind, ... |
| 289 | `messages.nim:164` | RVR | `hostContext must be an object` の `some` を `none` に | 同上 |
| 225 | `messages.nim:163` | LOR | `context.isNil or ...` → `and` | 同上 (nil の文脈でテストが落ちる) |
| 296 | `messages.nim:189` | RVR | `containerDimensions must be an object` | 同上 |
| 299 | `messages.nim:197` | RVR | `width` と `maxWidth` の排他 | 同上 |
| 300 | `messages.nim:201` | RVR | `safeAreaInsets must be an object` | 同上 |
| 302 | `messages.nim:208` | RVR | `deviceCapabilities must be an object` | 同上 |
| 304 | `messages.nim:216` | RVR | `styles must be an object` | 同上 |
| 305 | `messages.nim:220` | RVR | `styles.variables must be an object` | 同上 |
| 175 | `messages.nim:192` | ROR | `value.getFloat() < 0` → `<= 0` | Given a host context with a list of modes and zero-pixel dimensions, ... (0 px は有効) |
| 215 | `messages.nim:466` | ROR | 同上 (`size-changed`) | Given a size of zero or a number that is not finite, ... |
| 241 | `messages.nim:249` | LOR | `hostCapabilities.isNil or ...` → `and` | Given host capabilities that are not an object, when the result is built, then McpAppsError (nil で実行が落ちる) |
| 191 | `messages.nim:282` | ROR | `reason.len > 0` → `>= 0` (teardown) | Given no reason, when teardown is built, then params are empty |
| 276 | `messages.nim:286` | SDL | `requireValidContext(changed)` を削除 | Given a changed context that breaks the specification, when host-context-changed is built, then McpAppsError |
| 192 | `messages.nim:304` | ROR | `sandbox.len > 0` → `>= 0` | Given the ready and resource-ready messages, ... (`sandbox` キーが無いことを確かめる) |
| 247 | `messages.nim:345` | LOR | `info.isNil or ...` → `and` | Given ui/initialize without appInfo, when handled, then McpAppsError (nil で実行が落ちる) |
| 262 | `messages.nim:359` | BLR | `getBool(false)` → `true` | Given a View whose tools declaration omits listChanged, ... |
| 252 | `messages.nim:381` | LOR | `kind != JObject or type.isNil` の `or` → `and` | Given ui/message with a resource block, ... (`type` の無い object で実行が落ちる) |
| 207 | `messages.nim:391` | ROR | `resource.kind != JObject` → `==` | 同上 (正しい resource ブロックが通ることと、`resource` が文字列なら拒むこと) |
| 313 | `messages.nim:452` | RVR | `return current` → 既定値 | Given a mode the host or the View does not support, ... (`current` が `udInline` 以外) |
| 314 | `messages.nim:454` | RVR | `return current` → 既定値 | 同上 |
| 218 | `messages.nim:495` | ROR | `phase == vpReady` → `!=` (診断の語) | Given initialized sent twice or too early, when noted, then the error says which (「twice」と「before ui/initialize」) |
| 3 | `model.nim:111` | AOR | `rest[0] in Letters + Digits` → `-` | `test_ext_apps_model`: Given a host that starts, ends or continues with a digit, ... |
| 4 | `model.nim:111` | AOR | `rest[^1] in Letters + Digits` → `-` | 同上 |
| 6 | `model.nim:112` | AOR | `allCharsInSet(Letters + Digits + ...)` → `Letters - Digits` | 同上 |
| 38 | `model.nim:334` | ROR | `resourceDomains.len > 0` → `>= 0` | Given only connect origins, when the CSP is built, then the resource directives are the plain ones |
| 144 | `provider.nim:75` | ROR | `description.len > 0` → `>= 0` | `test_ext_apps_server`: Given a UI resource registered without a description, ... |

「nil で実行が落ちる」は、変異の `and` が nil の `.kind` を読んで実行が異常終了 (exit 139) し、テストの実行が失敗として数えられること。218 は診断の語に当たる。原文の `twice` と `before ui/initialize` は View に何を直すかを伝える語なので、語の取り違えを検出する価値がある。

## 変異なしでの実行

最後に変異なしで流した結果 (`build/one.sh` 経由)。

| テスト | 結果 |
|---|---|
| `tests/test_ext_apps_messages.nim` | 43 件合格、失敗 0 |
| `tests/test_ext_apps_model.nim` | 32 件合格、失敗 0 |
| `tests/test_ext_apps_server.nim` | 18 件合格、失敗 0 |
| `tests/test_ext_apps_host.nim` | 33 件合格、失敗 0 |
| `tests/test_ext_apps_end_to_end.nim` (変更なし) | 3 件合格、失敗 0 |
| `tests/test_spec_coverage.nim` | 8 件合格、失敗 0 |

## 残っているもの

- 分類 4・5 は無い。
- id 218 の診断の語 (`twice`、`before ui/initialize`) を確かめるテスト `Given initialized sent twice or too early, when noted, then the error says which` は、残すと決めた (2026-10-12)。語は View に何を直すかを伝えるので、取り違えを検出する価値がある。
- id 137 (timeout) は 133 からの推定で、当てて確かめていない。
- 同値 16 件は読解で決めた (当てても落ちるテストが無いことは測定が示している)。
