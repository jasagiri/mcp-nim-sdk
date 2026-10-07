# G2 変異検出: extensions ジョブ

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
