# G2 変異検出: jsonschema ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/jsonschema.json`、本線の 7d32c165 (2026-10-07)。
2026-10-12 に `json_schema_regex.nim` を変えた。次の測定で測り直す。
36a4c8a5 の測定ではこのジョブは 1 件も試せなかった (nim-muter の書き直しが `(inc p.pos; 8'i32)` をコンパイル不能にした。
その 1 行を直して測り直した)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 483 | 332 | 7 | 126 | 0 | 18 |

生き残り 126 件の分類 (2 人で分担し、下の 2 節に 1 件ずつ記録した)。

| 分類 | json_schema.nim | json_schema_regex.nim | 計 |
|---|---:|---:|---:|
| 1 同値 | 13 | 2 | 15 |
| 3 穴 (テストを追加、全件で変異を当てて確認) | 57 | 46 | 103 |
| 4 到達しない・冗長 | 0 | 3 | 3 |
| 5 不具合 (修正した) | 0 | 1 | 1 |
| 6 許容 | 4 | 0 | 4 |
| 計 | 74 | 52 | 126 |

## 見つかった不具合 (2 件、どちらも落ちるテストを先に書いて修正)

| 場所 | 不具合 | 修正 |
|---|---|---|
| `json_schema_regex.nim` の文字クラス | 先頭の `]` を要素とみなす POSIX の規則が入っていた。ECMA-262 では `[]` は何にも当たらない空のクラス、`[^]` は任意の 1 文字 | `fix(jsonschema): read [] as the empty class and [^] as any character` |
| `json_schema.nim` `resolveRef` | `$ref: "#/$defs/a/01"` のような先頭が 0 の添字が配列の要素として解決されていた。RFC 6901 の添字は `0` か、`1-9` で始まる数字列 | `fix(jsonschema): reject an array index with a leading zero in a $ref pointer` (id 37 の分析で見つけた) |

## 分類 4 の扱い (リードの判断)

| id | 場所 | 内容 | 判断 |
|---|---|---|---|
| 371 | `json_schema_regex.nim` `Node.lazy` | 書かれるだけで読まれない | **削除した。** 当たるかどうかは、最短一致か最長一致かで変わらない |
| 456 | `reach` 先頭の `pending.setLen 0` | 呼び出し側が毎回捨てるので冗長 | 残す。`reach` は渡された作業用の列を空から使う、を関数の中で保つ |
| 378 | `consumed` の `else: false` | 届かない | 残す。`case` の網羅 |

## 残っているもの (利用者の判断待ち)

- **閉じていない `{` の扱い**: 2026-10-12 に、ECMA-262 Annex B に揃えると決めて直した。`a{`、`a{x}`、`a{,3}`、`a{2`、`a{2,`、`a{2x`、`a{2x}` は
  文字として読む。逆順 (`a{3,2}`) は RegexError のまま。テストは `Given a repetition that runs backwards` と
  `Given a brace that is not closed or not a count` (MCP-SEC-SCHEMA-12)。id 349、418 の検出のしかたは変わるので、測り直しで突き合わせる。
  9 桁を超える数字を `{` のあとに書いたときは、閉じているかを見る前に RegexLimitError にする (今のまま)。
- **draft-07 の `dependentSchemas`** (`json_schema.nim` の 446 行付近、直していない): 方言を問わず `dependentSchemas` を適用し、
  draft-07 で `dependentSchemas` があると `dependencies` を読まない。draft-07 にこのキーワードは無いので、本来は無視して
  `dependencies` を読む。変異の指摘ではなく、読んで気づいたもの。
- 許容 4 件 (37、40、181、48)。理由は第 1 節の行。

## G2: jsonschema (`json_schema.nim`、g2h-js-a の分)

測定は commit 7d32c165 (jj change `kvonwtpk`)、対象ジョブ `jsonschema`。
全体は 483 件: killed 332 / timeout 7 / survived 126 / compileError 18 / runError 0。
このファイルは `src/jsonschema/json_schema.nim` の生き残り 74 件を扱う。`json_schema_regex.nim` の分は別担当 (g2h-js-b) の記録にある。

### 仕分けの結果

| 分類 | 件数 | 意味 |
|---|---|---|
| 1 同値 | 13 | 変異しても入力に対する振る舞いが変わらない |
| 3 穴 (テストを足した) | 57 | 外部仕様テストを足し、変異を手で適用して落ちるのを確認した |
| 6 受け入れ | 4 | 差は診断の文面か、実装の許容差の境目か、10^8 要素の配列が要る入力だけ |
| 2 / 2b / 4 | 0 | |

分類 5 (欠陥) は変異の行から見つかった 1 件: `$ref` の JSON Pointer が、先頭に 0 のある配列添字 (`00`, `01`) を要素として解決していた (RFC 6901 は添字を `0` または `1-9` で始まる数字列と定めるので、これは何も指さない)。落ちるテストを先に書き、`fix(jsonschema)` の 1 コミットで直した。id 37 の分析で見つかった。

クラス 3 の 57 件は、すべて変異を作業コピーに手で当て (`jj restore` で戻した)、記載のテストが落ちるのを見た。クラス 1 のうち 49, 156, 159, 166 は手で当てて、足したテストが通る (= 区別できない) ことも確かめた。
テストは `tests/test_json_schema.nim` と `tests/test_security_schema.nim` の末尾に、`(mutation review, g2h-js-a)` の新しい suite として足した。
仕様 ID は仮: `MCP-SCHEMA-3..4`、`MCP-SEC-SCHEMA-10` (統合時にリードが付け直す)。
各テストは既定の版と `-d:mcpDefaultProtocolVersion=2024-11-05` の両方で通した (検証器は版に依存しない)。

### 一覧

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
| 261 | json_schema.nim:170 | RVR | `return false` → `<return default>` | 検出 (測り直し) | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。測り直し (e79ebbd8) で検出された。 |  |
| 132 | json_schema.nim:170 | BLR | `false` → `true` | 3 | 配列の長さが違うとき等しいと答える | `tests/test_json_schema.nim` の "Given const arrays, ..." |
| 262 | json_schema.nim:172 | RVR | `return false` → `<return default>` | 検出 (測り直し) | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。測り直し (e79ebbd8) で検出された。 |  |
| 133 | json_schema.nim:172 | BLR | `false` → `true` | 3 | 配列の要素が違うとき等しいと答える | `tests/test_json_schema.nim` の "Given const arrays, ..." |
| 263 | json_schema.nim:175 | RVR | `return false` → `<return default>` | 検出 (測り直し) | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。測り直し (e79ebbd8) で検出された。 |  |
| 135 | json_schema.nim:175 | BLR | `false` → `true` | 3 | オブジェクトの大きさが違うとき等しいと答える | `tests/test_json_schema.nim` の "Given const objects, ..." |
| 98 | json_schema.nim:177 | LOR | `not b.hasKey(key) or not jsonEquals(value, b[key])` → `<or -> and>` | 3 | キーが無い・値が違うオブジェクトを等しいと答える (98 は無い鍵で KeyError) | `tests/test_json_schema.nim` の "Given const objects, ..." |
| 264 | json_schema.nim:177 | RVR | `return false` → `<return default>` | 検出 (測り直し) | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。測り直し (e79ebbd8) で検出された。 |  |
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

### 残っているもの

- **受け入れ (分類 6) の 4 件**: 37 (9 桁の添字、10^8 要素の配列が要る)、40 と 181 (上限超過の診断の文面が変わるだけで例外の型は同じ)、48 (multipleOf の許容差の丁度の境目)。
- **リードへ: draft-07 の `dependentSchemas`** (変異ではなく読んで気づいた点、直していない)。`checkObject` は方言によらず `dependentSchemas` を適用し、draft-07 で `dependentSchemas` があると `dependencies` を読まない。draft-07 には `dependentSchemas` という keyword は無いので、本来は無視して `dependencies` を読む。draft-07 の schema に `dependentSchemas` を書く利用者はまず居ないので、直すかどうかはリードの判断に任せる。

## g2h-js-b: jsonschema (json_schema_regex.nim) の生き残り 52 件

JSON Schema の `pattern` / `patternProperties` を支える正規表現エンジン (`src/jsonschema/json_schema_regex.nim`) の変異検査の記録。`json_schema.nim` の生き残りは別の担当 (g2h-js-a) が `g2-jsonschema-g2h-js-a.md` に書く。リードが 2 つを 1 つの記録にまとめる。

### 測定

- 測定した版: 7d32c165 (jj change `kvonwtpk`)、ジョブ `jsonschema` 全体: 483 件、killed 332、timeout 7、survived 126、compileError 18、runError 0。
- このファイルの範囲: `json_schema_regex.nim` の survived 52 件。行番号は測定時のもの (欠陥の修正で 368 の行は消えたが、他の行は同じ)。

### 結果の要約

| 分類 | 件数 |
|---|---|
| 1 同値 | 2 |
| 3 すき間 (テストを足した) | 46 |
| 4 死んだ・冗長なコード | 3 |
| 5 欠陥 (直した) | 1 |
| 2 / 2b / 6 | 0 |

分類 3 の 46 件と分類 5 の 1 件は、変異を 1 件ずつ手で当て、記載のテストが落ちること (または、IndexDefect などで RegexError の検査が落ちること) を確かめた。分類 1 と 4 の 5 件 (287, 288, 371, 456, 378) も、変異を当てて全テストが通ることを確かめた (読解だけの判断ではない)。確かめていない id はない。

テストの置き場:
- J = tests/test_json_schema.nim の新しい suite `"regular expressions of patterns (mutation review, g2h-js-b)"`
- S = tests/test_security_schema.nim の新しい suite `"regular expression limits (mutation review, g2h-js-b)"`

仕様 ID は `MCP-SEC-SCHEMA-11` (クラスと略記) から `-4` (限度の境界)。デフォルト版と `-d:mcpDefaultProtocolVersion=2024-11-05` の両方で、両ファイルとも全件通る。エンジンは版に依存しない。

### 生き残りの一覧

| id | file:line | 変異 | 元 → 変異後 | 分類 | 理由 | 検出するテスト |
|---|---|---|---|---|---|---|
| 287 | json_schema_regex.nim:111 | ROR | c <= 0x7F → c < 0x7F | 1 | U+007F (DEL) は構文のどの文字でもない。`asciiAt` の結果は `case` の枝 (すべて ASCII の印字文字) にだけ使われ、DEL を `char(0x7F)` で返しても `'\x80'` で返しても、どの枝にも当たらず `else` に落ちる。 | - |
| 288 | json_schema_regex.nim:119 | ROR | lo > next → lo >= next | 1 | `lo == next` のとき `(next, lo - 1)` という空の範囲 (hi < lo) が足されるだけで、`inRanges` は `c >= lo and c <= hi` を満たす c を持たない。補集合の意味は変わらない。 | - |
| 265 | json_schema_regex.nim:120 | AOR | lo - 1 → lo + 1 | 3 | 補集合の範囲が集合の先頭の文字まで伸びる (`\D` が "0" に、`\S` が改行に当たる)。 | J: Given the negated shorthands, when matched at the edges of their sets, ... |
| 266 | json_schema_regex.nim:121 | AOR | hi + 1 → hi - 1 | 3 | 次の範囲の始まりが集合の最後の文字に戻る (`\D` が "9" に当たる)。 | J: Given the negated shorthands, when matched at the edges of their sets, ... |
| 384 | json_schema_regex.nim:122 | SDL | 最後の範囲 (next, U+10FFFF) を足す文 → discard | 3 | 集合の上側の補集合が空になる (`\D` が "a" に、`\W` が U+3042 に当たらない)。 | J: Given the negated shorthands, when matched at the edges of their sets, ... |
| 387 | json_schema_regex.nim:130 | SDL | `\` で終わる pattern の fail → discard | 3 | 範囲の終端 `[a-\` で `parseEscapeChar` が配列の外を読む。RegexError ではなく IndexDefect になる。 | J: Given a class that is not well formed, ... |
| 290 | json_schema_regex.nim:143 | ROR | p.pos + digits > p.src.len → >= | 3 | pattern がちょうど `\x41` / `\u0041` で終わるとき、桁が足りているのに拒否される。 | J: Given a hex escape that ends the pattern, ... |
| 394 | json_schema_regex.nim:174 | SDL | `[^` の inc p.pos → discard | 3 | `^` が否定の印のまま集合の要素にもなる (`[^a]` が "^" に当たらない)。 | J: Given a class, when its members are written in the ways ECMA-262 allows, ... |
| 368 | json_schema_regex.nim:175 | BLR | `first = true` → false | 5 | 欠陥。クラスの先頭の `]` を要素とみなす POSIX の規則が入っていた。ECMA-262 では `[]` は空のクラス (何にも当たらない)、`[^]` は任意の1文字で、`[]a]` は空のクラスに続く "a]"。直前に落ちるテストを書き (`[^]` が "class is not closed" で RegexError、`[]a]` が "]" に当たる)、`first` ごと取り除いた。変異の対象 (`first`) はもう存在しない。 | J: Given an empty class, ... |
| 399 | json_schema_regex.nim:187 | SDL | クラス内 `\` で終わる fail → discard | 3 | `[\` で `classEscape(p.ascii)` が配列の外を読む。IndexDefect になる。 | J: Given a class that is not well formed, ... |
| 400 | json_schema_regex.nim:190 | SDL | `[\d]` の inc p.pos → discard | 3 | `d` が文字としてもう一度読まれ、`[\d]` が "d" に当たる。 | J: Given a class, when its members are written in the ways ECMA-262 allows, ... |
| 402 | json_schema_regex.nim:194 | SDL | `[\b]` の inc p.pos → discard | 3 | `b` がもう一度読まれ、`[\b]` が "b" に当たる。 | J: Given a class, when its members are written in the ways ECMA-262 allows, ... |
| 296 | json_schema_regex.nim:202 | ROR | p.pos + 1 < p.src.len → <= | 3 | `[a-` で配列の外を読む。IndexDefect になる。 | J: Given a class that is not well formed, ... |
| 270 | json_schema_regex.nim:202 | AOR | p.src[p.pos + 1] → p.src[p.pos - 1] | 3 | `[a-]` の末尾のハイフンが範囲の始まりと判断され、`a-]` が逆順の範囲になる。 | J: Given a class, when its members are written in the ways ECMA-262 allows, ... |
| 405 | json_schema_regex.nim:205 | SDL | 範囲の終端の `\` の inc p.pos → discard | 3 | 終端が `\` 自身 (U+005C) になり、残りの `x30` が要素に混ざる (`[\x30-\x39]` が "x" に当たる)。 | J: Given a class, when its members are written in the ways ECMA-262 allows, ... |
| 406 | json_schema_regex.nim:209 | SDL | 範囲の終端 (普通の文字) の inc p.pos → discard | 3 | 終端がもう一度始点として読まれる。`[a-c-e]` が c-e の範囲になり "d" に当たる。 | J: Given a class, when its members are written in the ways ECMA-262 allows, ... |
| 300 | json_schema_regex.nim:210 | ROR | hi < lo → <= | 3 | `[a-a]` が逆順の範囲として拒否される。 | J: Given a class, when its members are written in the ways ECMA-262 allows, ... |
| 407 | json_schema_regex.nim:211 | SDL | 逆順の範囲の fail → discard | 3 | `[b-a]` が拒否されずコンパイルできる。 | J: Given a class that is not well formed, ... |
| 474 | json_schema_regex.nim:219 | RVR | return -1 → return (0) | 3 | 桁の無い `{` が量指定子 `{0...` として読まれ、`a{,3}` / `a{x}` が文字として扱われない。 | J: Given braces, when they are not a quantifier, ... |
| 302 | json_schema_regex.nim:221 | ROR | text.len > 9 → >= | 3 | 9 桁の数 (`a{000000001}`) が桁数の限度として拒否される。 | J: Given a repetition, when its counts sit at the edges, ... |
| 414 | json_schema_regex.nim:232 | SDL | `?` の inc p.pos → discard | 3 | 直後の `?` が遅延の印として読まれるので `a?` 単独は同じ結果になるが、`a??` は2つ目の `?` が「繰り返す対象が無い」で拒否される。 | J: Given a lazy quantifier after ?, ... |
| 303 | json_schema_regex.nim:237 | ROR | min < 0 → <= | 3 | `{0}` が量指定子と認められず文字になる。 | J: Given a repetition, when its counts sit at the edges, ... |
| 305 | json_schema_regex.nim:244 | ROR | max < 0 → <= | 3 | `{n,0}` の上限 0 が「上限なし」になる (`a{0,0}` が "a" に当たり、`a{2,0}` が拒否されない)。 | J: Given a repetition, when its counts sit at the edges, ...; J: Given a repetition that is not closed or runs backwards, ... |
| 349 | json_schema_regex.nim:245 | LOR | p.atEnd or p.peek != } → and | 3 | `a{2` で配列の外を読む (IndexDefect)、`a{2x` は閉じていなくても受理される。 | J: Given a repetition that is not closed or runs backwards, ... |
| 418 | json_schema_regex.nim:246 | SDL | 閉じていない {} の fail → discard | 3 | `a{2x` が拒否されない。 | J: Given a repetition that is not closed or runs backwards, ... |
| 419 | json_schema_regex.nim:249 | SDL | 逆順の {} の fail → discard | 3 | `a{3,2}` が拒否されない。 | J: Given a repetition that is not closed or runs backwards, ... |
| 350 | json_schema_regex.nim:250 | LOR | min > maxRepeat or (...) → and | 3 | 片方の数だけが上限を超える `a{1001,}` と `a{1,1001}` が受理される。 | J: Given a repetition above the limit, ... |
| 309 | json_schema_regex.nim:250 | ROR | max != NoRepeatLimit → == | 3 | 上限なしの `a{1,}` が限度超過として拒否され、`a{1,1001}` は受理される。 | J: Given a repetition, when its counts sit at the edges, ...; J: Given a repetition above the limit, ... |
| 420 | json_schema_regex.nim:251 | SDL | 限度超過の failLimit → discard | 3 | `a{1001}` がそのまま展開される。 | J: Given a repetition above the limit, ... |
| 371 | json_schema_regex.nim:256 | BLR | lazy = true → false | 4 | `Node.lazy` は書かれるだけで、コンパイラも照合も読まない (遅延と貪欲は、一致の有無だけを答えるこのエンジンでは区別されない。モジュール冒頭の説明どおり)。フィールドとその代入が死んでいる。削除はリードの判断に任せる。観測できる違いはなく、`?` を読み進める `inc p.pos` は別 (414) で守られている。 | - |
| 271 | json_schema_regex.nim:270 | AOR | p.pos + 1 → p.pos - 1 (`(?` の判定) | 3 | `(?` で終わる pattern で配列の外を読む (IndexDefect)。 | J: Given parentheses that do not match, ... |
| 312 | json_schema_regex.nim:270 | ROR | p.pos + 1 < p.src.len → <= | 3 | 同上。 | J: Given parentheses that do not match, ... |
| 427 | json_schema_regex.nim:275 | SDL | 未対応のグループ構文の fail → discard | 3 | 拒否の型は同じ RegexError のまま、メッセージが「繰り返す対象が無い」という誤った原因になる。メッセージが原因を指すことを確かめる (`group syntax`)。 | J: Given a group syntax that is not supported, ... |
| 425 | json_schema_regex.nim:280 | SDL | dec p.depth → discard | 3 | 並んだグループが深さとして数えられ続け、70 個並べると入れ子の限度を超える。 | J: Given groups one after another, ... |
| 430 | json_schema_regex.nim:290 | SDL | `\` で終わる pattern の fail → discard | 3 | `a\` で配列の外を読む。IndexDefect になる。 | J: Given a backslash at the end of the pattern, ... |
| 432 | json_schema_regex.nim:293 | SDL | `\B` の inc p.pos → discard | 3 | `B` が文字としてもう一度読まれる (`a\Bb` が "ab" に当たらない)。 | J: Given word boundaries, when matched at both ends of the text, ... |
| 434 | json_schema_regex.nim:300 | SDL | dec p.pos → discard | 3 | 診断の位置が1つ後ろにずれる。診断が指す位置は拒否の理由を探す手がかりなので、`x|*` が position 2 を指すことを確かめる。 | J: Given a pattern that is refused, when the cause is a quantifier with nothing to repeat, ... |
| 439 | json_schema_regex.nim:357 | SDL | inc c.code.size → discard | 3 | `Regex.size` が常に 0 になり、プログラムの大きさの限度が働かない。 | S: Given a compiled pattern, when asked its size, ...; S: Given a program of exactly the size limit, ...; S: Given a pattern whose parts emit nothing, when it does as much work as the limit allows, ... |
| 320 | json_schema_regex.nim:358 | ROR | size > maxProgramSize → >= | 3 | ちょうど限度の大きさのプログラムが拒否される。 | S: Given a program of exactly the size limit, ... |
| 321 | json_schema_regex.nim:368 | ROR | work > 4 * maxProgramSize → >= | 3 | ちょうど許された仕事量の pattern が拒否される。 | S: Given a pattern whose parts emit nothing, when it does as much work as the limit allows, ... |
| 322 | json_schema_regex.nim:382 | ROR | index < n.children.high → <= | 3 | 最後の選択肢にも分岐が付き、その選択肢を飛ばせる (`^(?:a|b)$` が空文字に当たる)。 | J: Given alternatives, when matched, then the last one is as required as the others |
| 454 | json_schema_regex.nim:432 | SDL | unbalanced parenthesis の fail → discard | 3 | 余分な `)` (`a)`) が読み残されたまま受理される。 | J: Given parentheses that do not match, ... |
| 328 | json_schema_regex.nim:452 | ROR | i >= 0 → i > 0 | 3 | テキストの先頭の文字が単語の文字と数えられず、先頭の `\b` が働かない。 | J: Given word boundaries, when matched at both ends of the text, ... |
| 330 | json_schema_regex.nim:456 | ROR | run.budget < 0 → <= | 3 | ちょうど足りている予算が使い切りとして RegexLimitError になる。 | S: Given a step budget that is exactly what a match needs, ... |
| 373 | json_schema_regex.nim:465 | BLR | anchored = true → false | 3 | 先読みがその位置から始まらず、後ろのどこかで一致すれば成立する (`^a(?=b)` が "acb" に当たる)。 | J: Given a lookahead, ... |
| 456 | json_schema_regex.nim:474 | SDL | pending.setLen 0 → discard | 4 | `reach` が true を返す (`ikMatch`) とき `pending` が空でないまま残るが、呼び出し側 (`matchesFrom`) は即座に true を返して `pending` を捨てる。他の戻り方では `while pending.len > 0` が空にして終わる。入れ子の先読みは自分の `matchesFrom` と自分の `pending` を持つ。したがって先頭の `setLen 0` は冗長。 | - |
| 281 | json_schema_regex.nim:496 | AOR | i - 1 → i + 1 (`\B`) | 3 | `\B` が (i, i+1) の組を比べる。 | J: Given word boundaries, when matched at both ends of the text, ... |
| 336 | json_schema_regex.nim:496 | ROR | isWord(i-1) == isWord(i) → != | 3 | `\B` が `\b` と同じ意味になる。 | J: Given word boundaries, when matched at both ends of the text, ... |
| 466 | json_schema_regex.nim:496 | SDL | `\B` の pending.add pc + 1 → discard | 3 | `\B` が必ず失敗する。 | J: Given word boundaries, when matched at both ends of the text, ... |
| 282 | json_schema_regex.nim:496 | AOR | pc + 1 → pc - 1 (`\B`) | 3 | `\B` の次が前の命令になる (IndexDefect か誤った一致)。 | J: Given word boundaries, when matched at both ends of the text, ... |
| 472 | json_schema_regex.nim:520 | SDL | run.charge() → discard (文字を消費する側) | 3 | 消費の1回分が予算に数えられない。ちょうどの予算 (3 手) の検査で残りが 1 になる。 | S: Given a step budget that is exactly what a match needs, ... |
| 378 | json_schema_regex.nim:528 | BLR | else: false → true | 4 | `live` に入るのは `ikChar` / `ikAny` / `ikSet` だけ (`reach` の `case`)。`else` は `case` を網羅するための枝で、実行されない。 | - |

### 残っているもの

リードの判断を仰ぐもの:

- 分類 4 (死んだコード): `Node.lazy` とその代入 (json_schema_regex.nim:64, 256)。読む箇所が無い。消すなら 371 は消える。
- 分類 4 (冗長): `reach` の先頭の `pending.setLen 0` (:474, 456)。消してもよい。
- 分類 4 (網羅のための枝): `matchesFrom` の `consumed` の `else: false` (:528, 378)。`case` の網羅に必要で、残すのが自然。

決められなかったもの (欠陥かどうかが仕様の読み方に依る):

- 閉じていない `{`: `a{` と `a{x}` と `a{,3}` は文字として読むが (ECMA-262 Annex B と同じ)、`a{2` と `a{2,` と `a{2x` は RegexError で拒否する。Annex B ではこれらも文字として読まれる (u フラグ付きなら、`a{` も含めてすべて構文エラー)。どちらに寄せるかが決まっていないので、現在の挙動 (拒否) を `Given a repetition that is not closed or runs backwards` で固定した。Annex B に寄せるなら、このテストと 349, 418 の検出のしかたを変える。

分類 6 (許容) はない。

## 測り直し (本線 e79ebbd8、2026-10-11)

7d32c165 の測定のあとに足したテストと修正を入れたコミットで、同じジョブを測り直した。変異 483、検出 440、時間切れ 8、コンパイル不能 18、**生き残り 17** (前回 126)。所要 45 分。測ったコミットと本線の先端で `src/jsonschema/` に差分は無い。

変異の id と行番号は前回からずれているので、突き合わせはファイル・変異の文面・近い行で行った (下の表の「記録の行」が、この文書の上の表の id)。生き残りの 17 件はすべて前回も生き残っていて、分類と理由がある。新しい生き残りは無い。

| 今回の id | 場所 | 変異 | 記録の行 | 分類 |
|---:|---|---|---:|---|
| 134 | json_schema.nim:92 | BLR `false` → `true` | 130 | 1 |
| 14 | json_schema.nim:147 | ROR `value.fnum >= 9.2e+18` | 14 | 1 |
| 160 | json_schema.nim:211 | SDL `into.add 'd'` | 156 | 1 |
| 163 | json_schema.nim:215 | SDL `into.add 's'` | 159 | 1 |
| 170 | json_schema.nim:225 | SDL `into.add '{'` | 166 | 1 |
| 37 | json_schema.nim:251 | ROR `part.len <= 9` | 37 | 6 |
| 42 | json_schema.nim:278 | ROR `v.regexBudget < 0` | 40 | 6 |
| 185 | json_schema.nim:279 | SDL `overLimit(...)` | 181 | 6 |
| 50 | json_schema.nim:326 | ROR 許容差の `>` | 48 | 6 |
| 51 | json_schema.nim:333 | ROR `shortest >= 0` | 49 | 1 |
| 53 | json_schema.nim:335 | ROR `shortest >= 0` | 51 | 1 |
| 57 | json_schema.nim:346 | ROR `fewest >= 0` | 55 | 1 |
| 69 | json_schema.nim:402 | ROR `fewest >= 0` | 67 | 1 |
| 291 | json_schema_regex.nim:110 | ROR `c <= 0x7F` | 287 | 1 |
| 292 | json_schema_regex.nim:118 | ROR `lo > next` | 288 | 1 |
| 456 | json_schema_regex.nim:474 | SDL `pending.setLen 0` | 456 | 4 (残すと判断済み) |
| 378 | json_schema_regex.nim:528 | BLR `else: false` | 378 | 4 (残すと判断済み) |

同値 11、到達しない・冗長 2、許容 4。

未判定だった 4 行 (記録の 261〜264、`jsonEquals` の `return false`。今回の id は 265〜268、行は同じ 170 / 172 / 175 / 177) は、今回すべて検出された。未判定の行は残っていない。

時間切れの 8 件 (251、255、403、410、422、436、437、471) は、どれも変異がループを終わらなくするか、上限を外すもの: 位置や添字を進める `inc` を消す 6 件 (`inc p.pos` 4、`inc i` 1、`inc v.checks` 1)、検査の回数の上限を超えたときの `overLimit` を消す 1 件、繰り返しの中で子を足す文を消す 1 件。テストの待ちが原因のものは無い。 7 件は前回も時間切れで、471 (`json_schema_regex.nim:532` の `inc i`) だけが前回は検出、今回は時間切れになった。位置が進まなくなる変異で、どちらの結果でも生き残りではない。前回なぜ時間内に落ちたかは調べていない。
