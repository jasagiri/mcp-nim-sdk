# G2 変異検出: extensions ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/extensions.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 86 | 67 | 1 | 5 | 0 | 13 |

仕分けはコードとテストを読んで行った。変異を手で当てて流してはいない。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/client/extensions.nim:RVR:3ac2bd94b4efe6f7:0` | client/extensions.nim:55 | `return none(JsonNode)` → `return default` | equivalent | 戻り値の型は `Option[JsonNode]` で、`default(Option[JsonNode])` は `none(JsonNode)` と同じ値。`serverExtension` は変異の前後で同じ値を返す。前の仕分け (id 24) と同じ判断 | なし |
| `src/client/extensions.nim:RVR:3ac2bd94b4efe6f7:1` | client/extensions.nim:66 | `return none(JsonNode)` → `return default` | equivalent | 同上 (`serverCapability`。前の仕分けの id 25) | なし |
| `src/protocol/extensions.nim:ROR:048f9da66bbc8bda:0` | protocol/extensions.nim:56 | `slash < 0` → `<=` | accepted | 違いが出るのは `/` で始まる識別子 (`/tasks`、slash = 0) だけ。元でも接頭辞が空のラベルとして次の検査が断り、変異後も断る。変わるのは返す理由の文 (「接頭辞が要る」と「ラベルは文字で始まる」) だけで、呼び手 (`declareExtension`、`registerExtension`) はその文を `ValueError` に載せるだけで読んで分岐しない。失敗の文面は契約ではない (代表の決定 2026-10-23) | なし |
| `src/protocol/extensions.nim:SDL:2413a04126052c00:0` | protocol/extensions.nim:67 | 末尾の式 `none(string)` → `discard` | equivalent | `validateExtensionId` の `result` は `Option[string]` で、代入しなければ既定値の `none(string)`。正しい識別子に対して返す値は変わらない。前の仕分け (id 55) と同じ判断 | なし |
| `src/protocol/extensions.nim:RVR:3ac2bd94b4efe6f7:0` | protocol/extensions.nim:82 | `return none(JsonNode)` → `return default` | equivalent | `settingsOf` の戻り値の型は `Option[JsonNode]` で、既定値は `none(JsonNode)` (前の仕分けの id 64) | なし |

### 時間切れの見立て

| 指紋 | file:line | 変異 | 見立て | 止まる理由 |
|---|---|---|---|---|
| `src/client/extensions.nim:BLR:bfc665f021bc6cc8:0` | client/extensions.nim:73 | 既定値 `clientDeclares = true` → `false` | テストが止まることで検出 | 「Given a client that did not declare the extension, when it calls an extension method, then it raises McpUnsupportedError」(MCP-EXT-8) で、宣言していないクライアントの要求が送られ、答えないピア (`startPeer(nil, ...)`) の応答を既定の 60 秒待つ (版ごと)。明けても `McpTimeoutError` で期待と違う。負荷による偽の時間切れは疑わない。前の測定 (36a4c8a5 の id 13) でも同じ変異が時間切れだった |

時間切れに頼らずに落とすなら、そのテストに `check peer.requestsFor("widgets/make").len == 0` と短い `timeoutMs` を足すことになるが、検出はできているので、ここでは求めない。

測定: `nim-muter`、ジョブ `tests/mutation/extensions.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/protocol/extensions.nim`、`src/server/extensions.nim`、`src/client/extensions.nim`。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 86 | 47 | 1 | 25 | 0 | 13 |

timeout の 1 件は id 13 (`src/client/extensions.nim:73`、`clientDeclares = true` の既定値を `false` に): 既定で呼ぶ `callExtension` が応答を待ち続けて止まる。検出済みとして数える。

生き残り 25 件の分類。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 4 |
| 2b 測定より後に足されたテストが検出 | 5 |
| 3 穴 (テストを追加) | 15 |
| 4 到達しない・冗長なコード | 0 |
| 5 欠陥 | 0 |
| 6 許容 | 1 |

## 分類 2b について

分類 2b は、測定した 36a4c8a5 より後に足されたテストが検出するもの。5 件 (id 8、9、3、78、77) について、検出するテストが測定時点の `tests/test_extensions.nim` に無かったこと (`jj file show -r owwryuxn` で名前の一部が 0 件) と、変異を手で当てるとそのテストが落ちることを確かめた。報告に誤りは無い。

分類 3 の 15 件は、追加したテストが変異で落ちることを 1 件ずつ手で確かめた。追加前のテストで落ちないことを手で確かめたのは id 23 だけで、他の 14 件はその点を報告の「生き残り」に頼っている (報告の測定時点より後に足されたテストが検出する可能性は、この 14 件では調べていない)。

確かめた版は、`tests/test_extensions.nim` を既定の版と `-d:mcpDefaultProtocolVersion=2025-11-25` で流して、変異なしで通ること (40 件)。追加したテストは版に依存する部分を `versionsWith` / `versionsWithout` で囲んでいる。

## 生き残り

| id | file:行 | 変異 | 元 → 変異 | 分類 | 理由 | 検出するテスト |
|---:|---|---|---|---|---|---|
| 24 | client/extensions.nim:55 | RVR | `return none(JsonNode)` → 既定値 | 1 | `Option[T]` の既定値は `none` で、返す値が変わらない。 | |
| 25 | client/extensions.nim:66 | RVR | `return none(JsonNode)` → 既定値 | 1 | 同上。 | |
| 64 | protocol/extensions.nim:82 | RVR | `return none(JsonNode)` → 既定値 | 1 | 同上。 | |
| 55 | protocol/extensions.nim:67 | SDL | 末尾の `none(string)` → `discard` | 1 | 関数の `result` は `Option[string]` で、代入しなければ `none`。 | |
| 8 | client/extensions.nim:65 | LOR | `isNone or` → `and` | 2b | `additional` が none のとき `get` が `UnpackDefect` を起こす。 | 既存: 「server that declares only capabilities the core defines」 |
| 9 | client/extensions.nim:68 | LOR | `settings.isNil or` → `and` | 2b | 設定が無い名前で nil の `kind` を読み `SIGSEGV`。 | 既存: 「serverCapability returns its settings and only those」 |
| 3 | client/extensions.nim:68 | ROR | `kind != JObject` → `==` | 2b | オブジェクトの設定を捨て、無い名前で `get` が失敗する。 | 同上 |
| 78 | server/extensions.nim:94 | LOR | 最初の `or` → `and` | 2b | 同じ名前の二重登録が通ってしまう。 | 既存: 「method of a specification that asks nothing of the client」 |
| 77 | server/extensions.nim:94 | LOR | 2 つ目の `or` → `and` | 2b | コアのメソッド名 (`tools/call`) の登録が通ってしまう。 | 同上 |
| 23 | client/extensions.nim:81 | SDL | `client.requireFeature(ftExtensions, methodName)` → `discard` | 3 | 2026-07-28 より前の接続で、両側が旧 initialize で拡張を宣言していると、要求が送られてしまう。他の 2 つの検査 (クライアントの宣言、サーバーの宣言) は通る。 | 「legacy connection on which both sides declared the extension」 |
| 35 | protocol/extensions.nim:42 | ROR | `entry.extensionId == extensionId` → `!=` | 3 | tasks 拡張が `tasks/get` を引き継げなくなる。`takesOver` を呼ぶテストが無かった。 | 「tasks extension and another one … take over those two」 |
| 44 | protocol/extensions.nim:42 | LOR | `and` → `or` | 3 | 他の拡張が `tasks/get` を、tasks 拡張が `tools/call` を引き継げてしまう。 | 同上 |
| 36 | protocol/extensions.nim:42 | ROR | `entry.methodName == methodName` → `!=` | 3 | tasks 拡張が `tasks/list` などコアの別のメソッドを引き継げてしまう。 | 同上 |
| 59 | protocol/extensions.nim:43 | RVR | `return true` → 既定値 (false) | 3 | 引き継ぎが常に拒否される。 | 同上 |
| 54 | protocol/extensions.nim:43 | BLR | `true` → `false` | 3 | 同上。 | 同上 |
| 27 | protocol/extensions.nim:48 | AOR | `label[^1] in Letters + Digits` の `+` → `-` | 3 | 数字で終わるラベル (`ex2`) を拒否する。 | 「labels and names with digits and hyphens in every position」 |
| 29 | protocol/extensions.nim:49 | AOR | 内側の `Letters + Digits` の `+` → `-` | 3 | ラベルの途中の数字 (`a1-b2`) を拒否する。 | 同上 |
| 28 | protocol/extensions.nim:49 | AOR | `... + {'-'}` の `+` → `-` | 3 | ラベルの途中のハイフンを拒否する。 | 同上 |
| 31 | protocol/extensions.nim:63 | AOR | `name[0] notin Letters + Digits` の `+` → `-` | 3 | 数字で始まる名前 (`2fa`) を拒否する。 | 同上 |
| 38 | protocol/extensions.nim:56 | ROR | `slash < 0` → `<=` | 6 | `/tasks` (接頭辞が空) は、元でも空ラベルとして拒否される。変わるのは理由の文だけ (「接頭辞が要る」と「ラベルは文字で始まる」)。診断文の文言を固定するテストは書かない。 | |
| 51 | protocol/extensions.nim:72 | LOR | `isNil or` → `and` | 3 | nil の能力を渡すと nil の `kind` を読み `SIGSEGV`。nil でない非オブジェクトでは差が出ない (`{}` は nil を返す)。 | 「capabilities that are nil, lack the extension or hold settings that are not an object」 |
| 53 | protocol/extensions.nim:84 | LOR | `settings.isNil or` → `and` | 3 | 宣言に無い id で `SIGSEGV`。 | 同上 |
| 67 | server/extensions.nim:39 | ROR | `owner != id` → `==` | 3 | 他の拡張の結果型の横取りが通り、自分の再登録が拒否される。 | 「result type that one extension registered, when another extension registers it」 |
| 76 | server/extensions.nim:80 | LOR | `not nil and` → `or` | 3 | 設定なしの `registerTopLevelCapability` が ValueError になる。呼ぶテストが無かった。 | 「top-level capability registered with settings, with none …」 |
| 68 | server/extensions.nim:80 | ROR | `kind != JObject` → `==` | 3 | オブジェクトの設定が拒否される。 | 同上 |

## 残っているもの

- id 38 だけが許容 (診断文の文言)。それ以外の 24 件は、同値の説明、既存テストの検出、追加したテストのいずれかで決まっている。
- `src/server/extensions.nim` の `registerTopLevelCapability` は、他の本体の行 (名前の検査など) も含めて、追加するまで呼ぶテストが無かった。追加したテストは、設定の有無・非オブジェクト・コアの名前・discover への出力を確かめる。
