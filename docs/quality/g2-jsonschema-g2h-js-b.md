# g2h-js-b: jsonschema (json_schema_regex.nim) の生き残り 52 件

JSON Schema の `pattern` / `patternProperties` を支える正規表現エンジン (`src/jsonschema/json_schema_regex.nim`) の変異検査の記録。`json_schema.nim` の生き残りは別の担当 (g2h-js-a) が `g2-jsonschema-g2h-js-a.md` に書く。リードが 2 つを 1 つの記録にまとめる。

## 測定

- 測定した版: 7d32c165 (jj change `kvonwtpk`)、ジョブ `jsonschema` 全体: 483 件、killed 332、timeout 7、survived 126、compileError 18、runError 0。
- このファイルの範囲: `json_schema_regex.nim` の survived 52 件。行番号は測定時のもの (欠陥の修正で 368 の行は消えたが、他の行は同じ)。

## 結果の要約

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

仕様 ID は `MCP-SEC-g2h-js-b-1` (クラスと略記) から `-4` (限度の境界)。デフォルト版と `-d:mcpDefaultProtocolVersion=2024-11-05` の両方で、両ファイルとも全件通る。エンジンは版に依存しない。

## 生き残りの一覧

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

## 残っているもの

リードの判断を仰ぐもの:

- 分類 4 (死んだコード): `Node.lazy` とその代入 (json_schema_regex.nim:64, 256)。読む箇所が無い。消すなら 371 は消える。
- 分類 4 (冗長): `reach` の先頭の `pending.setLen 0` (:474, 456)。消してもよい。
- 分類 4 (網羅のための枝): `matchesFrom` の `consumed` の `else: false` (:528, 378)。`case` の網羅に必要で、残すのが自然。

決められなかったもの (欠陥かどうかが仕様の読み方に依る):

- 閉じていない `{`: `a{` と `a{x}` と `a{,3}` は文字として読むが (ECMA-262 Annex B と同じ)、`a{2` と `a{2,` と `a{2x` は RegexError で拒否する。Annex B ではこれらも文字として読まれる (u フラグ付きなら、`a{` も含めてすべて構文エラー)。どちらに寄せるかが決まっていないので、現在の挙動 (拒否) を `Given a repetition that is not closed or runs backwards` で固定した。Annex B に寄せるなら、このテストと 349, 418 の検出のしかたを変える。

分類 6 (許容) はない。
