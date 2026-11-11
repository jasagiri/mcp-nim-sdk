# G2 変異検出: ext_apps ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

状態: 測定済み。測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/ext_apps.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。仕分けはソースの読解だけで行い、変異を当てて流してはいない。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 315 | 282 | 5 | 15 | 0 | 13 |

### 生き残りの仕分け

15 件とも、初回の測定 (下の「分類 1 (同値) の理由」) で同値とした 16 件のうちの 15 件と同じ変異である (残る 1 件 `model.nim:144` は今回 timeout に入った)。前の理由を写さず、今のソースで値の流れを追い直した。

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/ext/apps/host.nim:RVR:0c511227513989c7:0` | host.nim:132 | `appCallProblem` の `return none(string)` → `return default(...)` | equivalent | 戻す式はリテラルではなく `none(string)` なので、変異は `default(Option[string])` になる。これは `none(string)` と同じ値で、呼び手が見る `isNone` は変わらない | なし |
| `src/ext/apps/messages.nim:LOR:3801248160b6c47d:0` | messages.nim:153 | `isDisplayMode` の `node.isNil or node.kind != JString` → `and` | equivalent | `isDisplayMode` は非公開で、呼び手は `hostContextProblem` の 2 か所だけ。nil でない節では `and` の左が偽になり早い `return false` を飛ばすが、文字列でない節の `getStr()` は `""` で、どの `UiDisplayMode` とも一致せず末尾の `false` に着く (同じ結果)。nil の節が来るのは `availableDisplayModes` の配列に nil を手で入れたときだけで (`displayMode` の側は `not mode.isNil` の後)、そのとき元のコードも次の `$item` で nil を読んで落ちる。どちらも実行時の異常終了で、違いは見えない | なし |
| `src/ext/apps/messages.nim:SDL:2413a04126052c00:0` | messages.nim:234 | `hostContextProblem` 末尾の `none(string)` → `discard` | equivalent | 末尾の式を消すと暗黙の `result` が返る。途中の経路はすべて `return some(...)` で `result` に書かないので、`result` は `Option[string]` の既定値 (none) のまま | なし |
| `src/ext/apps/model.nim:SDL:2413a04126052c00:0` | model.nim:90 | `uiUriProblem` 末尾の `none(string)` → `discard` | equivalent | 同上。問題のある経路はすべて `return some(...)` で、`result` に書く文は無い。既定値の none が返る | なし |
| `src/ext/apps/model.nim:ROR:20e1234ee50835ee:0` | model.nim:99 | `isCspSource` の `schemeEnd < 0` → `<= 0` | equivalent | 差が出るのは `schemeEnd == 0` (`://` で始まる入力) だけ。元のコードでも `or` の右の `source[0 ..< 0]` が `""` で、`["http", "https", "ws", "wss"]` に無いので同じ `return false` に着く | なし |
| `src/ext/apps/model.nim:ROR:51521139e55e428d:0` | model.nim:104 | `isCspSource` の `colon >= 0` → `> 0` | equivalent | 差が出るのは `colon == 0` (スキームの後ろが `:` 1 つだけを先頭に持つ) だけ。元は `rest` が空になり、ポートが不正ならそこで、正しくても末尾の `rest.len > 0` で `false`。変異はポートを切らず `rest` が `:` で始まるまま残り、`*.` でも始まらないので `rest[0] in Letters + Digits` で `false`。どちらも `false` | なし |
| `src/ext/apps/model.nim:SDL:2413a04126052c00:1` | model.nim:124 | `cspProblem` 末尾の `none(string)` → `discard` | equivalent | 問題のある経路は `return some(...)` だけで、`result` に書かない。暗黙の `result` は none | なし |
| `src/ext/apps/model.nim:SDL:2413a04126052c00:2` | model.nim:132 | `domainProblem` 末尾の `none(string)` → `discard` | equivalent | 同上 (2 つの `return some(...)` 以外は `result` に触れない) | なし |
| `src/ext/apps/model.nim:RVR:505610fcbcef47cd:0` | model.nim:223 | `parseUiResourceMeta` の `return UiResourceMeta()` → `return default(...)` | equivalent | 引数の無い構築子で、欄 (`Option`・`set`) はどれも既定値。`default(UiResourceMeta)` と同じ値 | なし |
| `src/ext/apps/model.nim:RVR:c39a9e522ef161c9:0` | model.nim:249 | `parseUiToolMeta` の `return none(UiToolMeta)` → `return default(...)` | equivalent | `default(Option[UiToolMeta])` は none。`_meta` が無い・object でない道具は、どちらでも UI 参照なしになる | なし |
| `src/ext/apps/model.nim:RVR:c39a9e522ef161c9:1` | model.nim:284 | `parseUiToolMeta` の `return none(UiToolMeta)` (`not any`) → `return default(...)` | equivalent | 同上。`return` は `result` ではなく既定値そのものを返すので、手前で組み立てた `found` は漏れない | なし |
| `src/ext/apps/model.nim:RVR:442b77d133e38a73:0` | model.nim:295 | `parseUiClientCapability` の `return none(UiClientCapability)` → `return default(...)` | equivalent | `default(Option[UiClientCapability])` は none | なし |
| `src/ext/apps/model.nim:RVR:442b77d133e38a73:1` | model.nim:298 | 同じ関数の `mimeTypes` が無い・配列でないときの `return none(...)` → `return default(...)` | equivalent | 同上 | なし |
| `src/ext/apps/model.nim:RVR:442b77d133e38a73:2` | model.nim:302 | 同じ関数の、要素が文字列でないときの `return none(...)` → `return default(...)` | equivalent | 同上。途中まで足した `capability` は局所変数で、返る値は既定値の none | なし |
| `src/ext/apps/provider.nim:RVR:442b77d133e38a73:0` | provider.nim:143 | `hostUiCapability` の `return none(UiClientCapability)` → `return default(...)` | equivalent | `default(Option[UiClientCapability])` は none。`hostSupportsApps` は `isSome` を見るので、宣言の無い相手はどちらでも偽 | なし |

公開されていて仕様 ID の無い関数にかかる生き残りは、この 15 件の中に振る舞いの変わるものが無いので、`spec_question` は立てていない。

### timeout の 5 件

読解だけの見立てで、変異を当てて流してはいない。無限ループになる経路は 5 件とも見つからなかった。

| 指紋 | file:line | 変異 | 無限ループか | 見立て |
|---|---|---|---|---|
| `src/ext/apps/host.nim:SDL:aa328c7644b7be35:0` | host.nim:101 | `listAppTools` の `requireServerCapability(... tools ...)` を削除 | 遅いだけ (終われば落ちる) | `tests/external/test_ext_apps_host.nim` の `Given a server without the tools capability, ...` は `startPeer(nil, ...)` の答えない相手に `tools/list` を送ることになり、クライアントの既定の 60 秒 (`DefaultRequestTimeoutMs`) を版ごとに 1 回ずつ待つ。待ちは有限で、終われば `expect McpUnsupportedError` と `requestsFor("tools/list").len == 0` が落ちる。測り直しても同じ長さだけ待つ |
| `src/ext/apps/host.nim:SDL:290ac38d69476902:0` | host.nim:229 | `fetchUiResource` の `requireServerCapability(... resources ...)` を削除 | 遅いだけ (終われば落ちる) | 同じ形。`Given a server without the resources capability, ...` が `resources/read` の答えを版ごとに 60 秒待ち、終われば落ちる |
| `src/ext/apps/model.nim:SDL:2413a04126052c00:3` | model.nim:144 | `metaProblem` 末尾の `none(string)` → `discard` | 遅いだけ (同値のはず) | 途中の経路は `return some(...)` と `return problem` だけで `result` に書かないので、暗黙の `result` は none。振る舞いは変わらず、繰り返しも待ちも増えない。初回の測定では同値の生き残り (id 66) だった。測り直せば survived になり、`equivalent` と見る |
| `src/ext/apps/provider.nim:RVR:15e83655371f19db:0` | provider.nim:114 | `readHandler` の `return await fallback(ctx, uri)` → `return default(...)` | 遅いだけと見る (未確認) | 変異は空の `contents` を返す。`tests/external/test_ext_apps_server.nim` の `Given a fallback read handler, ...` は `["contents"][0]` で落ちるはずで、待ちは `untilTrue` の上限つき。待ち続ける経路は読んだ範囲に無い。変異後の式に `await` が残る形 (`default(typeof(await ...))`) だと async の展開がどうなるかは、読むだけでは決められない |
| `src/ext/apps/provider.nim:BLR:18e3c696a8b17b86:0` | provider.nim:121 | `appToolInfo` の既定値 `legacyKey = false` → `true` | 遅いだけと見る | 既定で `_meta["ui/resourceUri"]` が付くだけで、繰り返しも待ちも無い。`Given legacyKey, ...` の `check not ... hasKey(LegacyResourceUriKey)` と `Given a registered resource, ...` の `_meta ==` が落ちるはず |

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
