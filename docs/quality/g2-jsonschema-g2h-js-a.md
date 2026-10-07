# G2: jsonschema (`json_schema.nim`、g2h-js-a の分)

測定は commit 7d32c165 (jj change `kvonwtpk`)、対象ジョブ `jsonschema`。
全体は 483 件: killed 332 / timeout 7 / survived 126 / compileError 18 / runError 0。
このファイルは `src/jsonschema/json_schema.nim` の生き残り 74 件を扱う。`json_schema_regex.nim` の分は別担当 (g2h-js-b) の記録にある。

## 仕分けの結果

| 分類 | 件数 | 意味 |
|---|---|---|
| 1 同値 | 13 | 変異しても入力に対する振る舞いが変わらない |
| 3 穴 (テストを足した) | 57 | 外部仕様テストを足し、変異を手で適用して落ちるのを確認した |
| 6 受け入れ | 4 | 差は診断の文面か、実装の許容差の境目か、10^8 要素の配列が要る入力だけ |
| 2 / 2b / 4 | 0 | |

分類 5 (欠陥) は変異の行から見つかった 1 件: `$ref` の JSON Pointer が、先頭に 0 のある配列添字 (`00`, `01`) を要素として解決していた (RFC 6901 は添字を `0` または `1-9` で始まる数字列と定めるので、これは何も指さない)。落ちるテストを先に書き、`fix(jsonschema)` の 1 コミットで直した。id 37 の分析で見つかった。

クラス 3 の 57 件は、すべて変異を作業コピーに手で当て (`jj restore` で戻した)、記載のテストが落ちるのを見た。クラス 1 のうち 49, 156, 159, 166 は手で当てて、足したテストが通る (= 区別できない) ことも確かめた。
テストは `tests/test_json_schema.nim` と `tests/test_security_schema.nim` の末尾に、`(mutation review, g2h-js-a)` の新しい suite として足した。
仕様 ID は仮: `MCP-SCHEMA-g2h-js-a-1..4`、`MCP-SEC-SCHEMA-g2h-js-a-1` (統合時にリードが付け直す)。
各テストは既定の版と `-d:mcpDefaultProtocolVersion=2024-11-05` の両方で通した (検証器は版に依存しない)。

## 一覧

| id | 場所 | 変異 | 元 → 変異 | 分類 | 理由 | 検出するテスト |
|---|---|---|---|---|---|---|
| 129 | json_schema.nim:90 | BLR | `false` → `true` | 3 | `$schema` の先頭の `#` を strip する変異。先頭が `#` の名前は方言でない | `tests/test_json_schema.nim` の "Given a $schema that only contains a name after a leading #, ..." |
| 130 | json_schema.nim:92 | BLR | `false` → `true` | 1 | 比較相手は `$dialect` の文字列で、どちらも先頭が `#` ではない。先頭側の strip は何も削らない |  |
| 147 | json_schema.nim:126 | SDL | `invalid("\'" & name & "\' has the wrong type")` → `discard` | 3 | 型が違う keyword は検証前に InvalidSchemaError になる | `tests/test_json_schema.nim` の "Given a keyword of the wrong JSON type, ..." |
| 92 | json_schema.nim:129 | LOR | `node.kind == JFloat and node.fnum.classify in {fcNormal, fcZero, fcSubnormal}` → `<and -> or>` | 3 | `or` にすると無限大が integer になる (`inf == floor(inf)`)。isInteger は JInt/JFloat でしか呼ばれないので差は非有限値だけ | `tests/test_json_schema.nim` の "Given an infinite number, ..." |
| 12 | json_schema.nim:141 | ROR | `value.num < 0` → `<< -> <=>` | 3 | `minLength: 0` は有効な非負整数 | `tests/test_json_schema.nim` の "Given a count keyword, when it is 0, 2.0, 2.5 or negative, ..." |
| 14 | json_schema.nim:147 | ROR | `value.fnum >= 9.2e+18` → `<>= -> >>` | 1 | `fnum >= 9.2e18` と `>` の差は fnum が丁度 9.2e18 のときの `int(9.2e18)` と `high(int)` だけ。値は件数・長さとの大小にしか使われず、どちらもメモリに載る長さより大きい。メッセージは schema の元の数を使う |  |
| 17 | json_schema.nim:155 | ROR | `value >= -9.223372036854776e+18` → `<>= -> >>` | 3 | 2^63 の両端: 隣の整数と同じ文字列にならないこと | `tests/test_json_schema.nim` の "Given integers at the edge of 64 bits, ..." |
| 18 | json_schema.nim:156 | ROR | `value < 9.223372036854776e+18` → `<< -> <=>` | 3 | 2^63 の両端: 隣の整数と同じ文字列にならないこと | `tests/test_json_schema.nim` の "Given integers at the edge of 64 bits, ..." |
| 19 | json_schema.nim:164 | ROR | `a.kind == JInt` → `<== -> !=>` | 3 | JFloat と JInt の比較で `a.num` に触れて FieldDefect | `tests/test_json_schema.nim` の "Given 1 and 1.0, when compared by const and enum in either direction, ..." |
| 261 | json_schema.nim:170 | RVR | `return false` → `<return default>` | 1 | `return default` は `return false` と同じ (bool の既定値は false)。プログラムとして同一 |  |
| 132 | json_schema.nim:170 | BLR | `false` → `true` | 3 | 配列の長さが違うとき等しいと答える | `tests/test_json_schema.nim` の "Given const arrays, ..." |
| 262 | json_schema.nim:172 | RVR | `return false` → `<return default>` | 1 | `return default` は `return false` と同じ (bool の既定値は false)。プログラムとして同一 |  |
| 133 | json_schema.nim:172 | BLR | `false` → `true` | 3 | 配列の要素が違うとき等しいと答える | `tests/test_json_schema.nim` の "Given const arrays, ..." |
| 263 | json_schema.nim:175 | RVR | `return false` → `<return default>` | 1 | `return default` は `return false` と同じ (bool の既定値は false)。プログラムとして同一 |  |
| 135 | json_schema.nim:175 | BLR | `false` → `true` | 3 | オブジェクトの大きさが違うとき等しいと答える | `tests/test_json_schema.nim` の "Given const objects, ..." |
| 98 | json_schema.nim:177 | LOR | `not b.hasKey(key) or not jsonEquals(value, b[key])` → `<or -> and>` | 3 | キーが無い・値が違うオブジェクトを等しいと答える (98 は無い鍵で KeyError) | `tests/test_json_schema.nim` の "Given const objects, ..." |
| 264 | json_schema.nim:177 | RVR | `return false` → `<return default>` | 1 | `return default` は `return false` と同じ (bool の既定値は false)。プログラムとして同一 |  |
| 136 | json_schema.nim:177 | BLR | `false` → `true` | 3 | キーが無い・値が違うオブジェクトを等しいと答える (98 は無い鍵で KeyError) | `tests/test_json_schema.nim` の "Given const objects, ..." |
| 32 | json_schema.nim:205 | ROR | `depth <= 0` → `<<= -> <>` | 3 | uniqueItems の比較は maxDepth と同じ深さで SchemaLimitError。32 は境界 (深さ丁度)、1/2 は配列/オブジェクトで深さが減らない変異 | `tests/test_security_schema.nim` の "Given uniqueItems, when an item nests as deep as maxDepth, ..." と "..., however the nesting is built" |
| 154 | json_schema.nim:208 | SDL | `into.add 'n'` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `[null]` と `[]` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 155 | json_schema.nim:209 | SDL | `into.add (; if node.bval:; 't'; else:; 'f'; )` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `true` と `false` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 156 | json_schema.nim:211 | SDL | `into.add 'd'` → `discard` | 1 | 落としても文字列の復号が一意のまま、よって衝突が作れない。156: 数の文字列は他の型と先頭文字が違い `;` で終わる。159: 文字列は長さ付き (`長さ:本体`) で、値の位置では先頭が数字なら文字列。166: 値の位置で `}` は空オブジェクト、数字で始まれば鍵を持つオブジェクト。手で適用しても上のテストは通ることを確認した |  |
| 158 | json_schema.nim:213 | SDL | `into.add ';'` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: 数の後の `;` を落とすと `{"a":1,"ks9:0123456":2}` と `{"a":11,"k":"0123456d2"}` が同じ文字列になる | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 159 | json_schema.nim:215 | SDL | `into.add 's'` → `discard` | 1 | 落としても文字列の復号が一意のまま、よって衝突が作れない。156: 数の文字列は他の型と先頭文字が違い `;` で終わる。159: 文字列は長さ付き (`長さ:本体`) で、値の位置では先頭が数字なら文字列。166: 値の位置で `}` は空オブジェクト、数字で始まれば鍵を持つオブジェクト。手で適用しても上のテストは通ることを確認した |  |
| 160 | json_schema.nim:216 | SDL | `into.add $node.str.len` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `["x","y"]` と `["xs:y"]` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 161 | json_schema.nim:217 | SDL | `into.add ':'` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `["2",1234567890]` と `["d1234567890;"]` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 162 | json_schema.nim:218 | SDL | `into.add node.str` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `"a"` と `"b"` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 163 | json_schema.nim:220 | SDL | `into.add '['` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `[[],[]]` と `[[[]]]` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 1 | json_schema.nim:222 | AOR | `depth - 1` → `<- -> +>` | 3 | uniqueItems の比較は maxDepth と同じ深さで SchemaLimitError。32 は境界 (深さ丁度)、1/2 は配列/オブジェクトで深さが減らない変異 | `tests/test_security_schema.nim` の "Given uniqueItems, when an item nests as deep as maxDepth, ..." と "..., however the nesting is built" |
| 164 | json_schema.nim:223 | SDL | `into.add ']'` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `[[],[]]` と `[[[]]]` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 166 | json_schema.nim:225 | SDL | `into.add '{'` → `discard` | 1 | 落としても文字列の復号が一意のまま、よって衝突が作れない。156: 数の文字列は他の型と先頭文字が違い `;` で終わる。159: 文字列は長さ付き (`長さ:本体`) で、値の位置では先頭が数字なら文字列。166: 値の位置で `}` は空オブジェクト、数字で始まれば鍵を持つオブジェクト。手で適用しても上のテストは通ることを確認した |  |
| 170 | json_schema.nim:231 | SDL | `into.add $key.len` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `{"a":1,"b":2}` と `{"ad1;:b":2}` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 171 | json_schema.nim:232 | SDL | `into.add ':'` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `{"1":null,"b":"abcden"}` と `{"n1bs6:abcde":null}` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 172 | json_schema.nim:233 | SDL | `into.add key` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `{"a":1}` と `{"b":1}` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 2 | json_schema.nim:234 | AOR | `depth - 1` → `<- -> +>` | 3 | uniqueItems の比較は maxDepth と同じ深さで SchemaLimitError。32 は境界 (深さ丁度)、1/2 は配列/オブジェクトで深さが減らない変異 | `tests/test_security_schema.nim` の "Given uniqueItems, when an item nests as deep as maxDepth, ..." と "..., however the nesting is built" |
| 168 | json_schema.nim:235 | SDL | `into.add '}'` → `discard` | 3 | canonical の文字列から一部を落とすと、異なる値が同じ文字列になる: `{"a":{"b":1},"c":2}` と `{"a":{"b":1,"c":2}}` | `tests/test_json_schema.nim` の "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct" |
| 35 | json_schema.nim:251 | ROR | `result.kind == JArray` → `<== -> !=>` | 3 | 配列でない対象 (オブジェクト等) に数字の step を適用すると `[]` が AssertionDefect (35 は配列の添字も解決できなくなる) | `tests/test_json_schema.nim` の "Given a $ref whose index step names nothing, ..." と "Given a $ref into an array, ..." |
| 104 | json_schema.nim:251 | LOR | `result.kind == JArray and part.len > 0` → `<and -> or>` | 3 | 配列でない対象 (オブジェクト等) に数字の step を適用すると `[]` が AssertionDefect (35 は配列の添字も解決できなくなる) | `tests/test_json_schema.nim` の "Given a $ref whose index step names nothing, ..." と "Given a $ref into an array, ..." |
| 36 | json_schema.nim:251 | ROR | `part.len > 0` → `<> -> >=>` | 3 | 空の step は `part[0]` で IndexDefect (修正前は parseInt が ValueError) | `tests/test_json_schema.nim` の "Given a $ref whose index step names nothing, ..." |
| 37 | json_schema.nim:251 | ROR | `part.len <= 9` → `<<= -> <>` | 6 | `part.len <= 9` と `< 9` の差は丁度 9 桁で先頭が 0 でない添字だけ。10^8 要素以上の配列が要る。先頭 0 の添字は修正 (下の 5) で別の条件が拒む |  |
| 174 | json_schema.nim:255 | SDL | `invalid("$ref \'" & reference & "\' points at nothing")` → `discard` | 3 | 辿れない pointer が invalid にならないと親に解決される | `tests/test_json_schema.nim` の "Given a $ref that points at nothing inside a property, ..." |
| 40 | json_schema.nim:276 | ROR | `v.regexBudget < 0` → `<< -> <=>` | 6 | どちらも上限超過は SchemaLimitError のまま。budget が 0 以下だと次の `isMatch` が最初の `charge` で RegexLimitError を投げ、overLimit が同じ型で包み直す。違うのは診断の文面だけ ("too large to compile" か "matching spent") |  |
| 181 | json_schema.nim:277 | SDL | `overLimit("the patterns of the schema are too large to compile within the limit")` → `discard` | 6 | どちらも上限超過は SchemaLimitError のまま。budget が 0 以下だと次の `isMatch` が最初の `charge` で RegexLimitError を投げ、overLimit が同じ型で包み直す。違うのは診断の文面だけ ("too large to compile" か "matching spent") |  |
| 187 | json_schema.nim:295 | SDL | `invalid("\'type\' has the wrong type")` → `discard` | 3 | `type` の配列に文字列でない要素 | `tests/test_json_schema.nim` の "Given a type list with a member that is not a string, ..." |
| 47 | json_schema.nim:320 | ROR | `step <= 0` → `<<= -> <>` | 3 | multipleOf が 0 以下: 0 は変異で SchemaLimitError (0/0 = nan)、負は判定が出てしまう。InvalidSchemaError かつ SchemaLimitError でないことを見る | `tests/test_json_schema.nim` の "Given multipleOf, when the divisor is not above zero, ..." |
| 192 | json_schema.nim:320 | SDL | `invalid("\'multipleOf\' must be above zero")` → `discard` | 3 | multipleOf が 0 以下: 0 は変異で SchemaLimitError (0/0 = nan)、負は判定が出てしまう。InvalidSchemaError かつ SchemaLimitError でないことを見る | `tests/test_json_schema.nim` の "Given multipleOf, when the divisor is not above zero, ..." |
| 48 | json_schema.nim:324 | ROR | `abs(quotient - round(quotient)) > 1e-9 * max(1.0, abs(quotient))` → `<> -> >=>` | 6 | 許容差 `1e-9 * max(1, |q|)` の丁度の境目 (`q = 1e-9` など)。許容差は浮動小数点の誤差を吸収するための実装の定数で、仕様に境界の値は無い |  |
| 5 | json_schema.nim:324 | AOR | `1e-9 * max(1.0, abs(quotient))` → `<* -> />` | 3 | 許容差が `/` だと商が大きいとき小数の倍数 (1234.56 は 0.01 の倍数) が弾かれる | `tests/test_json_schema.nim` の "Given multipleOf with a decimal divisor, ..." |
| 49 | json_schema.nim:331 | ROR | `shortest >= 0` → `<>= -> >>` | 1 | minLength が 0 のとき: `length < 0` は成り立たないので、検査を飛ばしても行っても結果は同じ (49 は手で適用して通ることを確認) |  |
| 50 | json_schema.nim:331 | ROR | `longest >= 0` → `<>= -> >>` | 3 | `maxLength: 0` が検査されず長さ 1 の文字列を通す | `tests/test_json_schema.nim` の "Given minLength and maxLength, ..." |
| 51 | json_schema.nim:333 | ROR | `shortest >= 0` → `<>= -> >>` | 1 | minLength が 0 のとき: `length < 0` は成り立たないので、検査を飛ばしても行っても結果は同じ (49 は手で適用して通ることを確認) |  |
| 53 | json_schema.nim:335 | ROR | `longest >= 0` → `<>= -> >>` | 3 | `maxLength: 0` が検査されず長さ 1 の文字列を通す | `tests/test_json_schema.nim` の "Given minLength and maxLength, ..." |
| 55 | json_schema.nim:344 | ROR | `fewest >= 0` → `<>= -> >>` | 1 | minItems / minProperties が 0 のとき: `len < 0` は成り立たない |  |
| 56 | json_schema.nim:344 | ROR | `items.len < fewest` → `<< -> <=>` | 3 | minItems 丁度は適合 | `tests/test_json_schema.nim` の "Given minItems and maxItems, ..." |
| 57 | json_schema.nim:347 | ROR | `most >= 0` → `<>= -> >>` | 3 | `maxItems: 0` | `tests/test_json_schema.nim` の "Given minItems and maxItems, ..." |
| 115 | json_schema.nim:350 | LOR | `not unique.isNil and unique.getBool()` → `<and -> or>` | 3 | `uniqueItems: false` で重複を弾く | `tests/test_json_schema.nim` の "Given uniqueItems, when two items are the same value however spelled, ..." |
| 63 | json_schema.nim:392 | ROR | `minContains < 0` → `<< -> <=>` | 3 | `minContains: 0` が 1 に読まれる | `tests/test_json_schema.nim` の "Given contains with minContains and maxContains, ..." |
| 65 | json_schema.nim:395 | ROR | `maxContains >= 0` → `<>= -> >>` | 3 | `maxContains: 0` の検査抜け / maxContains 丁度が違反 | `tests/test_json_schema.nim` の "Given contains with minContains and maxContains, ..." |
| 66 | json_schema.nim:395 | ROR | `matching > maxContains` → `<> -> >=>` | 3 | `maxContains: 0` の検査抜け / maxContains 丁度が違反 | `tests/test_json_schema.nim` の "Given contains with minContains and maxContains, ..." |
| 67 | json_schema.nim:400 | ROR | `fewest >= 0` → `<>= -> >>` | 1 | minItems / minProperties が 0 のとき: `len < 0` は成り立たない |  |
| 118 | json_schema.nim:400 | LOR | `fewest >= 0 and instance.len < fewest` → `<and -> or>` | 3 | minProperties を満たす・丁度の入力が違反 | `tests/test_json_schema.nim` の "Given minProperties and maxProperties, ..." |
| 68 | json_schema.nim:400 | ROR | `instance.len < fewest` → `<< -> <=>` | 3 | minProperties を満たす・丁度の入力が違反 | `tests/test_json_schema.nim` の "Given minProperties and maxProperties, ..." |
| 69 | json_schema.nim:403 | ROR | `most >= 0` → `<>= -> >>` | 3 | `maxProperties: 0` の検査抜け / maxProperties 丁度が違反 | `tests/test_json_schema.nim` の "Given minProperties and maxProperties, ..." |
| 70 | json_schema.nim:403 | ROR | `instance.len > most` → `<> -> >=>` | 3 | `maxProperties: 0` の検査抜け / maxProperties 丁度が違反 | `tests/test_json_schema.nim` の "Given minProperties and maxProperties, ..." |
| 212 | json_schema.nim:408 | SDL | `invalid("\'required\' has the wrong type")` → `discard` | 3 | `required` に文字列でない要素 | `tests/test_json_schema.nim` の "Given required with a member that is not a string, ..." |
| 140 | json_schema.nim:423 | BLR | `true` → `false` | 3 | patternProperties に当たった性質に additionalProperties が掛かる | `tests/test_json_schema.nim` の "Given patternProperties, ..." |
| 124 | json_schema.nim:446 | LOR | `dependentSchemas.isNil and v.dialect == sdDraft07` → `<and -> or>` | 3 | 2020-12 で `dependencies` が効いてしまう | `tests/test_json_schema.nim` の "Given dependencies in 2020-12, ..." |
| 125 | json_schema.nim:455 | LOR | `instance.hasKey(name) and not instance.hasKey(other.getStr())` → `<and -> or>` | 3 | draft-07 の `dependencies` (名前の配列) の判定と違反の記録 | `tests/test_json_schema.nim` の "Given draft-07 dependencies as a list of names, ..." |
| 223 | json_schema.nim:456 | SDL | `v.add(path, "\'" & name & "\' requires property \'" & other.getStr() & "\'")` → `discard` | 3 | draft-07 の `dependencies` (名前の配列) の判定と違反の記録 | `tests/test_json_schema.nim` の "Given draft-07 dependencies as a list of names, ..." |
| 239 | json_schema.nim:513 | SDL | `invalid("$ref \'" & reference.getStr() & "\' leads back to itself without " &; "reading further into the instance")` → `discard` | 3 | 自己参照の `$ref` が invalid ではなく maxDepth の SchemaLimitError になる (SchemaLimitError は InvalidSchemaError の子なので型だけでは見えない) | `tests/test_json_schema.nim` の "Given a $ref that comes back to itself, ..." |
| 83 | json_schema.nim:518 | ROR | `v.dialect == sdDraft07` → `<== -> !=>` | 3 | `$ref` と同階層の keyword: 2020-12 は適用、draft-07 は無視 | `tests/test_json_schema.nim` の "Given a $ref with sibling keywords, ..." |
| 84 | json_schema.nim:545 | ROR | `v.depth > v.limits.maxDepth` → `<> -> >=>` | 3 | maxDepth 丁度は検証でき、1 つ超えると報告 | `tests/test_security_schema.nim` の "Given maxDepth, when the schema nests exactly that deep, ..." |
| 85 | json_schema.nim:547 | ROR | `v.checks > v.limits.maxChecks` → `<> -> >=>` | 3 | maxChecks 丁度は検証でき、1 つ超えると報告 | `tests/test_security_schema.nim` の "Given maxChecks, when the validation needs exactly that many ..." |
| 249 | json_schema.nim:550 | SDL | `dec v.depth` → `discard` | 3 | `dec v.depth` が無いと兄弟の schema が深さに積み上がる | `tests/test_security_schema.nim` の "Given maxDepth, when many sibling schemas are applied one after another, ..." |

## 残っているもの

- **受け入れ (分類 6) の 4 件**: 37 (9 桁の添字、10^8 要素の配列が要る)、40 と 181 (上限超過の診断の文面が変わるだけで例外の型は同じ)、48 (multipleOf の許容差の丁度の境目)。
- **リードへ: draft-07 の `dependentSchemas`** (変異ではなく読んで気づいた点、直していない)。`checkObject` は方言によらず `dependentSchemas` を適用し、draft-07 で `dependentSchemas` があると `dependencies` を読まない。draft-07 には `dependentSchemas` という keyword は無いので、本来は無視して `dependencies` を読む。draft-07 の schema に `dependentSchemas` を書く利用者はまず居ないので、直すかどうかはリードの判断に任せる。
