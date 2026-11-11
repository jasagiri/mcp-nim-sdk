# G2 変異検出: sampling_tools ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/sampling_tools.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。
状態: 測定済み。生き残りは前の 2 回の測定 (id 163・142) と同じ 2 件で、新しいものは無い。時間切れは無い。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 168 | 163 | 0 | 2 | 0 | 3 |

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/protocol/sampling_tools.nim:RVR:0c511227513989c7:0` | sampling_tools.nim:230 | `return none(string)` → `return default` (`samplingToolsUnavailable` の早い戻り) | equivalent | 戻り値の型は `Option[string]` で、`default(Option[string])` は none。元の戻り値と同じ値が返る (リテラルの反転には当たらない)。 | 無し |
| `src/protocol/sampling_tools.nim:SDL:2413a04126052c00:0` | sampling_tools.nim:235 | 末尾の式 `none(string)` → `discard` | equivalent | 末尾の式が消えると関数は `result` の初期値を返す。`Option[string]` の初期値は none で、元の値と同じ。そこに届く前の 2 つの分岐は `return some(...)` で抜けるので、`result` はほかで書き換えられない。 | 無し |

以下は前の測定の記録 (行番号は古い)。

測定: `nim-muter`、ジョブ `tests/mutation/sampling_tools.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/protocol/sampling_tools.nim` の 1 ファイルで、測定後に変わっていない (行番号は報告書と一致する)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 168 | 129 | 0 | 36 | 0 | 3 |

生き残り 36 件の分類。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 2 |
| 3 穴 (テストを追加) | 34 |
| 2 / 2b / 4 / 5 / 6 | 0 |

分類 3 の 34 件は、変異を 1 件ずつ手で当てて (`original` は部分式なので、その部分式だけを置き換えた)、下に挙げたテストが落ちるのを確かめ、そのつど `jj restore` で戻した。
追加したテストはすべて `tests/test_sampling_tools_payload.nim` にあり、このファイルは既にジョブの `testCommand` に入っているので、ジョブの変更は要らない。
`-d:mcpDefaultProtocolVersion=2024-11-05` と `=2025-11-25` でも、追加分を含むこのファイルは全件通り、警告も出ない。

## 判断

生き残りは 2 つの原因に集まる。

1. **既存のテストは `mentions("...")` で「その語を含む問題がある」としか見ていなかった。** 規則が 1 つ破れた入力で、問題が「ちょうど 1 件」であることを見ないので、別の規則の問題に紛れて、その規則の `result.add` が消えても気づけない (SDL、`return` の変更)。追加したテストは、規則を 1 つだけ破る入力を作り、`problems.len == 1` と、その部分の名前の言及を確かめる。
2. **欠けた値・オブジェクトでない値の入力が無かった。** `or` を `and` に変えた変異は、`nil`・キーの欠落・文字列などのときだけ結果が変わる。その入力 (`nil` の params / answer、`content` の無いメッセージ、`type` の無いブロック) を足した。

### 同値 (分類 1)

- id 163 (`sampling_tools.nim:231`、`return none(string)` → `return default`): `Option[string]` の `default` は `none` なので、返す値が同じ。
- id 142 (`sampling_tools.nim:236`、末尾の `none(string)` → `discard`): `result` は初期値が `none` で、その行は何も足さない。上の 163 と同じく、この 2 行は冗長だが、`some(...)` を返す 2 つの分岐と並べて「理由なしは none」と読めるので、消さずに残す (リードの判断に委ねる)。

### 穴 (分類 3)

追加したテスト (ファイルは全て `tests/test_sampling_tools_payload.nim`)。

| 記号 | テスト名 |
|---|---|
| T1 | Given no params, no answer or an answer without content, when asked for tool uses, then there are none |
| T2 | Given content blocks without a usable type, when asked for tool uses, then they are not tool uses |
| T3 | Given params that are not an object, when checked, then that is the only problem |
| T4 | Given a result that is not an object, when checked, then that is the only problem |
| T5 | Given a message that is not an object or has no content, when checked, then that message is the only problem |
| T6 | Given an array of content whose entry is not a content block, when checked, then that entry is the only problem |
| T7 | Given a tool choice that is not an object, when checked, then it is the only problem |
| T8 | Given a tool_use without an id, with an empty id, without a name or without an input object, when a result holds it, then that field is the only problem |
| T9 | Given a tool_result without a toolUseId, when checked, then the field is reported |
| T10 | Given a tool_result whose content is missing, not an array or not content blocks, when checked, then that is the only problem |
| T11 | Given a tool_result with structuredContent or isError of the wrong kind, when checked, then that field is the only problem |
| T12 | Given a tool_result with structuredContent as an object and isError as a boolean, when checked, then there is nothing to report |
| T13 | Given tool uses followed by a message that is not their results, when checked, then that message is the only problem |
| T14 | Given two tool results for one id, when checked, then the repeat is the only problem |
| T15 | Given array content or an unknown content type in a result, when checked, then the version and the block decide |
| T16 | Given a result that completes without a tool use, when the tool choice is not required, then it is valid |
| T17 | Given tool choice required and a message without content, when a result completes without a tool use, then the absence of a tool use is reported |

Scenario は `MCP-SAMPLING-TOOLS-9` (欠けた値・種類違いの値、T1〜T7)、`-2` (tool_use / tool_result の必須項目、T8〜T12)、`-3` (対応の違反は 1 回だけ、T13・T14)、`-4` (answer の content、T15〜T17)。リードが採番し直す。

| id | file:line | mutator | original → replacement | 分類 | 理由 | 落ちたテスト |
|---|---|---|---|---|---|---|
| 55 | sampling_tools.nim:35 | LOR | `not params.isNil and params.kind == JObject` → `or` | 3 | `nil` の params を「ツールを使わない」と読む規則。変異は `nil.kind` を踏む | T1 (SIGSEGV) |
| 59 | :58 | LOR | `answer.isNil or answer.kind != JObject` → `and` | 3 | `nil` の answer からは tool_use が取れない | T1 (SIGSEGV) |
| 58 | :58 | LOR | 3 項の外側の `or` → `and` | 3 | `content` の無い answer からは tool_use が取れない。変異は `answer["content"]` で KeyError | T1 |
| 57 | :41 | LOR | `block0.kind == JObject and block0.isString("type")` → `or` | 3 | 同値ではなかった。`type` の無いオブジェクトのブロックで、変異は `block0["type"]` の KeyError。`isString` は非オブジェクトで偽なので、非オブジェクトの側は同値 | T2 (KeyError) |
| 60 | :66 | LOR | `block0.kind != JObject or not block0.isString("type")` → `and` | 3 | `type` の無いブロックは「type を持つブロックではない」と報告する。変異は KeyError | T6 (KeyError) |
| 153 | :67 | RVR | `return @[... is not a content block with a type]` → `return` | 3 | 配列 content の中のオブジェクトでない要素 (`"x"`) の報告。単独の content は先に別の規則 (119 行) で弾かれるので、配列の中身でしか届かない | T6 |
| 63 | :83 | LOR | `not isString("id") or id.len == 0` → `and` | 3 | tool_use の id は文字列で空でない。id が無い・空のとき報告する | T8 (KeyError) |
| 107 | :84 | SDL | `result.add ...: tool_use without an id` → `discard` | 3 | 同上。問題が 1 件であること | T8 |
| 108 | :86 | SDL | `...: tool_use without a name` → `discard` | 3 | name の欠落 | T8 |
| 109 | :88 | SDL | `...: tool_use without an input object` → `discard` | 3 | input が無い・オブジェクトでない | T8 |
| 110 | :91 | SDL | `...: tool_result without a toolUseId` → `discard` | 3 | toolUseId の欠落は、他の問題 (対応する tool_use が無い) に紛れていた。名前の言及を確かめる | T9 |
| 65 | :92 | LOR | `content.isNil or content.kind != JArray` → `and` | 3 | tool_result の content は配列。無い・文字列のとき報告する | T10 (KeyError) |
| 111 | :93 | SDL | `...: tool_result without a content array` → `discard` | 3 | 同上 | T10 |
| 66 | :96 | LOR | `entry.kind != JObject or not entry.isString("type")` → `and` | 3 | content の要素が `type` の無いオブジェクトのとき報告する (非オブジェクトの要素は `and` でも報告されるので、その側は同値) | T10 |
| 112 | :97 | SDL | `...: tool_result content holds something that is not a content block` → `discard` | 3 | 同上 | T10 |
| 14 | :99 | ROR | `structuredContent.kind != JObject` → `==` | 3 | structuredContent はオブジェクト。正しいものを通し、違うものを報告する | T11, T12 |
| 113 | :100 | SDL | `...: structuredContent is not an object` → `discard` | 3 | 同上 | T11 |
| 15 | :101 | ROR | `isError.kind != JBool` → `==` | 3 | isError は真偽値 | T11, T12 |
| 114 | :102 | SDL | `...: isError is not a boolean` → `discard` | 3 | 同上 | T11 |
| 156 | :115 | RVR | `return @[... is not an object]` → `return` | 3 | オブジェクトでないメッセージ (`"x"`) の報告。変異は後続の `message["content"]` で AssertionDefect | T5 |
| 70 | :119 | LOR | `content.isNil or content.kind notin {JObject, JArray}` → `and` | 3 | `content` の無いメッセージ。変異は `nil.kind` を踏む | T5 (SIGSEGV) |
| 30 | :159 | ROR | `results.len > 0` → `>=` | 3 | tool_result が無いメッセージには「結果で答えよ」の 1 件だけを出す。変異は「結果が無い」の問題を重ねて 2 件にする | T13 |
| 125 | :164 | SDL | `...: two tool results for '<id>'` → `discard` | 3 | 同じ id に 2 つの tool_result | T14 |
| 81 | :203 | LOR | `params.isNil or params.kind != JObject` → `and` | 3 | `nil` の params は変異で `nil.kind`、配列の params は他の問題 2 件に化ける | T3 (SIGSEGV) |
| 162 | :204 | RVR | `return @["params is not an object"]` → `return` | 3 | オブジェクトでない params の報告 | T3 |
| 140 | :219 | SDL | `result.add "toolChoice is not an object"` → `discard` | 3 | 文字列の toolChoice。後続の `choice.has("mode")` は文字列で偽なので、他の問題に紛れず 0 件になる | T7 |
| 163 | :231 | RVR | `return none(string)` → `return default` | 1 | `default(Option[string])` は `none` | 無し (同値) |
| 142 | :236 | SDL | `none(string)` → `discard` | 1 | `result` の初期値が `none` | 無し (同値) |
| 85 | :243 | LOR | `answer.isNil or answer.kind != JObject` → `and` | 3 | `nil` の answer を変異は `nil.kind` で踏む | T4 (SIGSEGV) |
| 166 | :244 | RVR | `return @["the result is not an object"]` → `return` | 3 | オブジェクトでない answer の報告 | T4 |
| 43 | :252 | ROR | `content.kind == JArray` → `!=` | 3 | 配列 content は 2025-11-25 から。それ以前の版では、配列を報告し、単独のブロックは通す。変異は逆になる | T15 |
| 168 | :253 | RVR | `return result & ("array content is not part of ...")` → `return` | 3 | 同上、報告そのもの | T15 |
| 145 | :255 | SDL | `result.add blockProblems("content[...]", ...)` → `discard` | 3 | answer の content の各ブロックの検査。未知の type や、必須項目の欠けた tool_use が通ってしまう | T8, T15 |
| 95 | :273 | LOR | `mode == "required" and not params.isNil` → `or` | 3 | toolChoice が required でないとき、tool_use の無い完了は有効。変異は「required なのに tool が使われていない」を誤って出す (`not params.isNil` は `mode == "required"` が真なら常に真なので、`and` の右はこの変異でだけ意味を持つ) | T15 (T16 も対象) |
| 94 | :273 | LOR | 外側の `and` → `or` | 3 | 同上。params が `nil` なら `nil{"messages"}.kind` も踏む | T15 (T16 も対象) |
| 97 | :276 | LOR | `message.kind == JObject and not message{"content"}.isNil` → `or` | 3 | `content` の無いメッセージを `required` の判定で読み飛ばす。変異は `message["content"]` で KeyError (非オブジェクトのメッセージの側は同値) | T17 (KeyError) |

compileError 3 件 (id 102、103、149) は変異が型に合わない (`discard` に置き換えた式が値を返す) ので、検出の対象外。

## 残っているもの

- id 163 と 142 は同値で、変異は生き残る。2 行とも、消しても振る舞いは変わらない (冗長) が、`samplingToolsUnavailable` の 3 つの結果を並べて読める形を優先して残した。消すかどうかはリードが決める。
- 95 と 94 は T15 が落ちるのを見た。T16 は同じ変異を狙って書いたが、T16 単独で落ちるかは確認していない (T15 で足りるので追加の確認はしていない)。
- 他の 32 件は、表に書いたテストが落ちるのを確認した。確認できていない id は無い。
- 分類 4 (到達しない・冗長) と 5 (欠陥) は無い。

## リードの判断

- id 163、142 (`samplingToolsUnavailable` の先頭と末尾の `none(string)`): 同値。「冗長な 2 行」という指摘は採らない。
  先頭の `return none(string)` は「tools を使わない要求には当てはまらない」という早期の戻りで、末尾は関数の値そのもの。
  どちらも消すと意味が読めなくなる。残す。


## 測り直し (本線 76a08c6a、2026-10-10)

36a4c8a5 の測定のあとに足したテストと修正を入れたコミットで、同じジョブを測り直した。変異 168、検出 163、時間切れ 0、コンパイル不能 3、**生き残り 2** (前回 36)。

前回の生き残りとの突き合わせは変異の指紋で行った (指紋が変わった行は、ファイル・変異の文面・3 行以内の行番号で合わせた)。2 件はどちらも前回も生き残っていて、この文書に分類と理由がある。新しく現れた生き残りは無い。
