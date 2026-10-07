# G2 変異検出: `src/protocol/content.nim` と `src/server/tools.nim`

測定: `nim-muter`、ジョブ `tests/mutation/content.json`、mainline の 36a4c8a5 (2026-10-07)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 101 | 73 | 0 | 26 | 0 | 2 |

## survived 26 件

分類は、1 = 同値、3 = 穴 (新しい外部仕様テストを足した)。
クラス 3 の 25 件は、変異を手で当てて下に書いたテストが落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは戻した)。
足したテストは `tests/test_structured_tool_output.nim` (S)、`tests/test_tool_annotations.nim` (A)、`tests/test_implementation_info.nim` (I) にあり、3 本ともジョブの `testCommand` に入っているので、ジョブの変更は要らない。
Scenario は `MCP-CONTENT-FIELDS-3` から `-6` (`specs/content.feature`、対応は `specs/tests.map`)。
`SIGSEGV` と書いた行は、変異で `nil` を返す (または `nil` を読む) ため、テストが `FAILED` を出さずに異常終了して落ちた。落ちることに変わりはない。

### content.nim

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 76 | content.nim:51 | RVR | `return none(T)` → `<return default>` | 1 | `T` は `string` か `bool` で、`Option[T]` の既定値は `none` なので、返る値が同じ。 |
| 23 | content.nim:71 | LOR | `node.isNil or node.kind != JObject` → `and` | 3 | オブジェクトでない annotations (null、文字列、配列) が、空の annotations になってしまう。A: `Given annotations that are not a JSON object, when they are parsed, then the protocol violation is raised` (`Expect Failed`、`nil` では SIGSEGV)。 |
| 30 | content.nim:158 | LOR | `node.isNil or node.kind != JObject` → `and` | 3 | オブジェクトでない `clientInfo` / `serverInfo` が、空の Implementation になってしまう。I: `Given an Implementation that is not a JSON object, when it is parsed, then the protocol violation is raised` (`Expect Failed`、`nil` では SIGSEGV)。 |
| 31 | content.nim:182 | LOR | `not node.isNil and node.kind == JObject` → `or` | 3 | 文字列や配列がオブジェクト扱いになり、版のフィルタが `hasKey` を呼んで `AssertionDefect`。S: `Given a value that is not a JSON object, when any version filters it, then it comes back as it is`、`Given a message without content or that is not an object, when any version sends the prompt, then the message is sent as it is`。 |
| 77 | content.nim:188 | RVR | `return item` → `<return default>` | 3 | オブジェクトでない項目が `nil` になる。S: `Given a value that is not a JSON object, when any version filters it, then it comes back as it is` (SIGSEGV)。 |
| 78 | content.nim:228 | RVR | `return blk` → `<return default>` | 3 | 同上、content block。S: 同じテスト (SIGSEGV)。 |
| 81 | content.nim:245 | RVR | `return callResult` → `<return default>` | 3 | 同上、tool result。S: 同じテスト (SIGSEGV)。 |
| 82 | content.nim:264 | RVR | `return prompt` → `<return default>` | 3 | 同上、prompt result。S: 同じテスト (SIGSEGV)。 |
| 34 | content.nim:247 | LOR | `hasKey("content") and kind == JArray` → `or` | 3 | content の無い結果で `KeyError`、配列でない content で `AssertionDefect`。S: `Given a result without content or with content that is not a list, when any version sends it, then it is sent as it is`、`Given a version without structured output, when structuredContent comes without content, then a text block carries the data`。 |
| 37 | content.nim:257 | LOR | `not hasKey("content") or kind != JArray` の `or` → `and` (全体は `(A and B) or C`) | 3 | content の無い結果で、`and` の右側が `result["content"]` を読んで `KeyError`。(content が配列でない場合は `len` が 0 になるので、結果は変わらない。) S: `Given a version without structured output, when structuredContent comes without content, then a text block carries the data`。 |
| 36 | content.nim:257 | LOR | 2 つ目の `or` → `and` (全体は `(A or B) and C`) | 3 | 空の content 配列のとき text block が足されず、structuredContent のデータが旧い版の相手に届かない。content の無い結果では `KeyError`。S: `Given a version without structured output, when structuredContent comes with an empty content list, then a text block carries the data`、`...comes without content...`。 |
| 38 | content.nim:266 | LOR | `hasKey("messages") and kind == JArray` → `or` | 3 | messages の無い prompt result で `KeyError`。S: `Given a prompt result without messages or with messages that are not a list, when any version sends it, then it is sent as it is`。 |
| 39 | content.nim:268 | LOR | `objectOnly and hasKey("content")` → `or` | 3 | content の無い message で `KeyError`、オブジェクトでない message で `AssertionDefect`。S: `Given a message without content or that is not an object, when any version sends the prompt, then the message is sent as it is`。 |
| 40 | content.nim:276 | LOR | `not objectOnly or not hasKey("structuredContent")` → `and` | 3 | structuredContent の無い結果で `KeyError`、オブジェクトでない値で `AssertionDefect`。S: `Given a result without structuredContent, when its text is serialized, then it is unchanged`、`Given a value that is not a JSON object, when any version filters it, then it comes back as it is`。 |
| 17 | content.nim:279 | ROR | `content.len > 0` → `>= 0` | 3 | structuredContent と空の content 配列のとき、text block が足されない。S: `Given a result with structuredContent and an empty content list, when its text is serialized, then the content is that one text block`。 |

### tools.nim

どれも「与えなかった任意の項目は送らない」という同じ規則で、A の 2 本が検出する。
`>` → `>=` の変異は、空の値でも項目を送ってしまう (`"title": ""`、`"icons": []`、`"required": []`、`"description": ""`)。

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 87 | tools.nim:22 | ROR | `title.len > 0` → `>= 0` | 3 | A: `Given only a name, a description and a schema, when a tool is defined, then no optional field is sent` |
| 88 | tools.nim:26 | ROR | `icons.len > 0` → `>= 0` | 3 | A: 同上 |
| 100 | tools.nim:31 | BLR | `isError: bool = false` → `true` | 3 | 既定で失敗の結果になる。A: `Given a result built without isError, when it is read, then it is not an error` |
| 92 | tools.nim:79 | ROR | `required.len > 0` → `>= 0` | 3 | `createInputSchema`。A: `Given no description and no required list, when schemas are built, then only type and shape are sent` |
| 93 | tools.nim:87 | ROR | `description.len > 0` → `>= 0` | 3 | `createStringProperty`。A: 同上 |
| 94 | tools.nim:95 | ROR | `description.len > 0` → `>= 0` | 3 | `createNumberProperty`。A: 同上 |
| 95 | tools.nim:103 | ROR | `description.len > 0` → `>= 0` | 3 | `createBooleanProperty`。A: 同上 |
| 96 | tools.nim:112 | ROR | `description.len > 0` → `>= 0` | 3 | `createArrayProperty`。A: 同上 |
| 97 | tools.nim:121 | ROR | `required.len > 0` → `>= 0` | 3 | `createObjectProperty`。A: 同上 |
| 98 | tools.nim:124 | ROR | `description.len > 0` → `>= 0` | 3 | `createObjectProperty`。A: 同上 |
| 99 | tools.nim:133 | ROR | `description.len > 0` → `>= 0` | 3 | `createEnumProperty`。A: 同上 |

## 版

足したテストは、`-d:mcpDefaultProtocolVersion` が既定 (2026-07-28)、2024-11-05、2025-11-25 のどれでも通る (3 ファイル × 3 版)。版に依存する 2 本は `versionsWithout(ftStructuredToolOutput)` で版を選び、そのほかは `SupportedProtocolVersions` の全部を回す。

## 残っているもの

なし。同値 1 件 (id 76) は理由を上に書いた。
