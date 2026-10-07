# G2 変異検出: elicitation ジョブ (後半: `protocol/elicitation.nim` 114 行目以降と他のファイル)

測定: `nim-muter`、ジョブ `tests/mutation/elicitation.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/protocol/elicitation.nim`、`src/protocol/payload.nim`、`src/server/elicit.nim`、`src/client/elicitation.nim`。`protocol/elicitation.nim` の 113 行目までは `g2e-elicit-a` の担当で、`docs/quality/g2-elicitation-a.md` にある。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 324 | 217 | 3 | 103 | 0 | 1 |

このファイルが扱うのは 63 件: `protocol/elicitation.nim` の 114 行目以降の生き残り 47 件、他の 3 ファイルの生き残り 10 件 (client 3、payload 3、server 4)、`server/elicit.nim` の timeout 3 件。

生き残り 60 件の分類と timeout 3 件。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 5 (24, 201, 210, 283, 284) |
| 2 検出扱いの timeout (311, 312, 314) | 3 |
| 3 穴 (テストを追加) | 52 |
| 4 到達しない・冗長なコード | 2 (182, 309) |
| 5 欠陥 | 0 |
| 6 許容 | 1 (13) |

分類 3 のうち、変異を手で当てて追加したテストが落ちる (または止まる) ところまで見たのは次の id: 10, 56, 57, 101, 136, 141, 147, 150, 153, 161, 162, 180, 183, 206, 215, 219, 229, 241, 271, 278, 299, 303, 306, 313, 315, 324, 97。残りは、同じテストの別の表明が同じ条件を破ることを読んで判断した (手では当てていない)。

追加したテストは `tests/test_elicitation_payload.nim` の新しい suite 2 つ、`tests/test_server_elicitation.nim`、`tests/test_client_elicitation.nim`、`tests/test_tasks_end_to_end.nim` に各 1 件以上。Scenario は `specs/elicitation.feature` の `MCP-ELICIT-g2e-elicit-b-1` から `-5` (リードが採番し直す)。ジョブの `testCommand` に `tests/test_tasks_end_to_end.nim` を追記した。既定の版・2025-06-18・2025-11-25 の 3 通りで、変異なしで通ることを確かめた (`test_tasks_end_to_end` は 2025-11-25 以降だけ中身がある)。

## 一覧

| id | 場所 | mutator | 変異 | 分類 | 理由 | 検出するテスト |
|---|---|---|---|---|---|---|
| 10 | `client/elicitation.nim:83` | LOR | `or → and` | 3 | elicitationId のない完了通知は無視される (変異では nil を参照して落ちる) | `test_client_elicitation` の「Given an accepted URL request, when a completion arrives without a string id」 |
| 13 | `client/elicitation.nim:73` | SDL | `stderr への診断行を削除` | 6 | ハンドラの答えが送られなかったことの stderr の文。クライアントの応答 (-32603) は既存のテストが確かめている。文面を固定するテストは実装の写しになる。 |  |
| 24 | `client/elicitation.nim:96` | RVR | `return none → 既定値` | 1 | `Option` の既定値は none。 |  |
| 52 | `protocol/elicitation.nim:114` | ROR | `rest.len == 6 → !=` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 53 | `protocol/elicitation.nim:114` | ROR | `rest[3] == ':' → !=` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 54 | `protocol/elicitation.nim:116` | ROR | `<= 23 → >` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 55 | `protocol/elicitation.nim:116` | ROR | `<= 59 → >` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 56 | `protocol/elicitation.nim:131` | ROR | `result.len == 0 → !=` | 3 | 下限が上限を超える schema は報告される (欠けている min>max の検査が通っていた) | 「Given a string or number bound that is not a number or is inverted」 |
| 57 | `protocol/elicitation.nim:132` | ROR | `> → >=` | 3 | 下限と上限が等しい schema は有効 | 「Given a string or number bound that is not a number or is inverted」 |
| 68 | `protocol/elicitation.nim:163` | ROR | `< 0 → <= 0` | 3 | 0 は有効な件数 | 「Given minItems or maxItems that is not a non-negative integer」 |
| 70 | `protocol/elicitation.nim:166` | ROR | `> → >=` | 3 | minItems == maxItems は有効 | 「Given minItems or maxItems that is not a non-negative integer」 |
| 97 | `protocol/elicitation.nim:367` | ROR | `< → <=` | 3 | 長さが minLength ちょうどなら有効 | 「Given values at the limits of their bounds」 |
| 98 | `protocol/elicitation.nim:369` | ROR | `> → >=` | 3 | 長さが maxLength ちょうどなら有効 | 「Given values at the limits of their bounds」 |
| 101 | `protocol/elicitation.nim:380` | ROR | `> → >=` | 3 | 値が maximum ちょうどなら有効 | 「Given values at the limits of their bounds」 |
| 129 | `protocol/elicitation.nim:116` | LOR | `and → or (分 <= 59)` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 130 | `protocol/elicitation.nim:116` | LOR | `and → or (時 <= 23)` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 131 | `protocol/elicitation.nim:115` | LOR | `and → or (rest[5])` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 132 | `protocol/elicitation.nim:115` | LOR | `and → or (rest[4])` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 133 | `protocol/elicitation.nim:115` | LOR | `and → or (rest[2])` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 134 | `protocol/elicitation.nim:114` | LOR | `and → or (rest[1])` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 135 | `protocol/elicitation.nim:114` | LOR | `and → or (コロン)` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 136 | `protocol/elicitation.nim:114` | LOR | `and → or (len と符号)` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 141 | `protocol/elicitation.nim:137` | LOR | `or → and` | 3 | 空の enum は報告される (非配列では `len` が 0 なので、差が出るのは空配列だけ) | 「Given a plain enum that is empty or holds a non-string」 |
| 147 | `protocol/elicitation.nim:163` | LOR | `or → and` | 3 | 整数でない (`"1"`) 件数上限は報告される | 「Given minItems or maxItems that is not a non-negative integer」 |
| 150 | `protocol/elicitation.nim:165` | LOR | `and → or` | 3 | maxItems だけを持つ schema が KeyError にならず有効 | 「Given minItems or maxItems that is not a non-negative integer」 |
| 153 | `protocol/elicitation.nim:220` | LOR | `or → and` | 3 | items のない複数選択は `items is missing` と報告される (nil の参照で落ちる) | 「Given a multi-select with no items or with an enum that breaks the rules」 |
| 161 | `protocol/elicitation.nim:270` | LOR | `and → or` | 3 | form でも url でもない文字列の mode は拒否される | 「Given a mode that is a string but neither form nor url」(`is not an elicitation mode` で比べる。以前は "mode" を含むかだけで、version の報告にも含まれていた) |
| 162 | `protocol/elicitation.nim:279` | LOR | `or → and` | 3 | オブジェクトでない params は `params is not an object` だけを返す | 「Given params that are not an object」 |
| 180 | `protocol/elicitation.nim:405` | LOR | `or → and` | 3 | オブジェクトでない content は `content is not an object` | 「Given a result or content that is not an object」 |
| 182 | `protocol/elicitation.nim:413` | LOR | `or → and` | 4 | `contentProblems` は `requestedSchemaProblems` を通った schema にだけ使う (doc comment)。通った schema の properties は必ずオブジェクトなので、この防御は働かない。 |  |
| 183 | `protocol/elicitation.nim:421` | LOR | `or → and` | 3 | オブジェクトでない result は `the result is not an object` | 「Given a result or content that is not an object」 |
| 201 | `protocol/elicitation.nim:125` | BLR | `false → true (formatProblem の else)` | 1 | `formatProblem` が呼ばれるのは `requestedSchemaProblems` を通った schema だけで、その format は `StringFormats` の 4 つのどれか。else には到達しない。 |  |
| 203 | `protocol/elicitation.nim:130` | SDL | `not a number の追記を削除` | 3 | 非数値の下限・上限は名指しで報告される | 「Given a string or number bound that is not a number or is inverted」 |
| 204 | `protocol/elicitation.nim:133` | SDL | `is above の追記を削除` | 3 | 下限が上限を超える schema は報告される | 「Given a string or number bound that is not a number or is inverted」 |
| 206 | `protocol/elicitation.nim:149` | SDL | `enumNames の名前が文字列でない報告を削除` | 3 | enumNames に文字列でないものがあれば報告される | 「Given a plain enum that is empty or holds a non-string」 |
| 207 | `protocol/elicitation.nim:164` | SDL | `not a non-negative integer の追記を削除` | 3 | 負の件数は報告される | 「Given minItems or maxItems that is not a non-negative integer」 |
| 210 | `protocol/elicitation.nim:184` | SDL | `none(seq[JsonNode]) を削除` | 1 | `Option` の既定値は none で、`result` はその値のまま返る。 |  |
| 215 | `protocol/elicitation.nim:207` | SDL | `string の boundsProblems を削除` | 3 | minLength / maxLength の不正は報告される | 「Given a string or number bound that is not a number or is inverted」 |
| 217 | `protocol/elicitation.nim:212` | SDL | `number の boundsProblems を削除` | 3 | minimum / maximum の不正は報告される | 「Given a string or number bound that is not a number or is inverted」 |
| 219 | `protocol/elicitation.nim:225` | SDL | `items の plainEnumProblems を削除` | 3 | 空の items.enum は報告される | 「Given a multi-select with no items or with an enum that breaks the rules」 |
| 220 | `protocol/elicitation.nim:224` | SDL | `items の enum に type string が要る報告を削除` | 3 | type のない items.enum は報告される | 「Given a multi-select with no items or with an enum that breaks the rules」 |
| 229 | `protocol/elicitation.nim:256` | SDL | `required is not an array の追記を削除` | 3 | 配列でない required は報告される | 「Given required that is not an array」 |
| 241 | `protocol/elicitation.nim:341` | SDL | `エントリの elicitationParamsProblems を削除` | 3 | -32042 の data の各エントリが URL 要求の規則に従うこと | 「Given error data whose entry is a URL request that breaks the rules」 |
| 270 | `protocol/elicitation.nim:138` | RVR | `return 報告 → 空` | 3 | 同上 | 「Given a plain enum that is empty or holds a non-string」 |
| 271 | `protocol/elicitation.nim:141` | RVR | `return 報告 → 空` | 3 | enum に文字列でない値があれば報告される | 「Given a plain enum that is empty or holds a non-string」 |
| 278 | `protocol/elicitation.nim:192` | RVR | `return 報告 → 空` | 3 | オブジェクトでない property は名指しで報告される | 「Given a property that is not an object or has no type」(メッセージ全体 `property 'x' is not an object` / `type is missing` で比べる。以前の期待は "y" を含むかだけで、"type" の y に一致していた) |
| 279 | `protocol/elicitation.nim:194` | RVR | `return 報告 → 空` | 3 | type のない property は名指しで報告される | 「Given a property that is not an object or has no type」(メッセージ全体 `property 'x' is not an object` / `type is missing` で比べる。以前の期待は "y" を含むかだけで、"type" の y に一致していた) |
| 283 | `protocol/elicitation.nim:267` | RVR | `return emForm → 既定値` | 1 | `ElicitMode` の最初の値が emForm で、既定値と同じ。 |  |
| 284 | `protocol/elicitation.nim:269` | RVR | `return emForm → 既定値` | 1 | 同上 |  |
| 287 | `protocol/elicitation.nim:280` | RVR | `return 報告 → 空` | 3 | 同上 | 「Given params that are not an object」 |
| 296 | `protocol/elicitation.nim:406` | RVR | `return 報告 → 空` | 3 | 同上 | 「Given a result or content that is not an object」 |
| 297 | `protocol/elicitation.nim:422` | RVR | `return 報告 → 空` | 3 | 同上 | 「Given a result or content that is not an object」 |
| 299 | `protocol/elicitation.nim:427` | RVR | `return e.problems → 空` | 3 | 未知の mode への answer は mode を報告する | 「Given an answer to params with an unknown mode」 |
| 303 | `protocol/payload.nim:12` | ROR | `> 0 → >= 0` | 3 | 同上 | 「Given no problem, when an error is built」「Given several problems, when an error is built」 |
| 305 | `protocol/payload.nim:12` | SDL | `doAssert を削除` | 3 | 問題 0 件の PayloadError を作るのは契約違反 (AssertionDefect)。削除すると IndexDefect になり別の例外 | 「Given no problem, when an error is built」「Given several problems, when an error is built」 |
| 306 | `protocol/payload.nim:16` | SDL | `"; " & problems[i] の追記を削除` | 3 | メッセージは文脈と全問題を `; ` でつなぐ | 「Given no problem, when an error is built」「Given several problems, when an error is built」 |
| 309 | `server/elicit.nim:20` | LOR | `or → and` | 4 | `state != operational` で `negotiatedVersion` が Some の状態 (initialize 後、initialized 前) は、`server.request` が同じ `McpCapabilityError` を送信前に投げる。変わるのはメッセージの文だけ。 |  |
| 311 | `server/elicit.nim:31` | LOR | `or → and` | 2 | timeout (検出扱い)。能力を宣言していないクライアントに要求が送られ、答えが来ずに止まる。または `declared.get` が落ちる。 | `test_server_elicitation` の「Given a client without the elicitation capability」ほか |
| 312 | `server/elicit.nim:44` | SDL | `requireElicitation(emForm) を削除` | 2 | timeout (検出扱い)。能力のないクライアントに要求が送られ、答えを待って止まる。 | 同上 |
| 313 | `server/elicit.nim:60` | SDL | `ctx.endInput() を削除 (form)` | 3 | 答えが来たら task は input_required から working に戻る。戻らなければ working の確認が落ちる | `test_tasks_end_to_end` の「Given a tool that elicits in form or url mode inside a task, when the client has answered, then the task is working again while the tool goes on」(ジョブの testCommand に追記) |
| 314 | `server/elicit.nim:69` | SDL | `requireElicitation(emUrl) を削除` | 2 | timeout (検出扱い)。url モードを宣言していないクライアントに送られて止まる。 | `test_server_elicitation` の「Given a client that declared only the form mode, when the server asks in url mode」 |
| 315 | `server/elicit.nim:83` | SDL | `ctx.endInput() を削除 (url)` | 3 | 同上 | `test_tasks_end_to_end` の「Given a tool that elicits in form or url mode inside a task, when the client has answered, then the task is working again while the tool goes on」(ジョブの testCommand に追記) |
| 324 | `server/elicit.nim:80` | RVR | `return await ... → 既定値` | 3 | `ctx.elicitUrl` はクライアントの答えを返す | `test_server_elicitation` の「Given a handler that asks in url mode, when a tool is called」 |

## 残っているもの

- 13 (`client/elicitation.nim:73`): 許容。stderr の診断文だけが変わる。
- 182 (`protocol/elicitation.nim:413`) と 309 (`server/elicit.nim:20`): 冗長な防御。リードの判断に任せる (削除はしていない)。309 は `server.request` が同じ検査を持っている。
- 1 の同値 (24, 201, 210, 283, 284): 理由は一覧のとおり。
