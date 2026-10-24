# G2 変異検出: ext_skills ジョブ

## 2 回目の測定 (60cbfdb5、2026-10-19)

測定: `nim-muter` 0.2.11、ジョブ `tests/mutation/ext_skills.json`、拡張ブランチの 60cbfdb5 (初回の後の修正と追加したテストをすべて含む)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 515 | 444 | 21 | 32 | 0 | 18 |

生き残り 32 件は `survivors.json` に同期し、1 件ずつ分類と理由を書いた (2026-10-24)。

| 分類 | 件数 |
|---|---:|
| equivalent | 27 |
| accepted | 1 |
| test_owed (テストを追加、変異を当てて落ちるのを確認) | 4 |

- equivalent の大半 (16 件) は、`Option` や `string` を返す `return` を `return default` にするもの、関数の最後の `none(...)` を消すもの。既定値が元の値と同じ。残りは、届く入力の範囲では条件の境界が動いても結果が変わらないもの (理由は台帳の各行)。
- accepted の 1 件は初回の id 132 (`catalog.nim:208`) と同じ変異で、判断を引き継いだ。
- test_owed の 4 件はどれも `frontmatter.nim`。`-inf` `+inf` `-nan` を浮動小数として読む変異 (行 129) と、単引用符の鍵だけの行 (`'a'`) で行末の次を読む変異 3 件 (行 193)。既存の E テスト 2 つに入力を足した。
- timeout 21 件はすべて `frontmatter.nim` で、ループの添字を進めない変異 (`inc` の削除など) と、ループの終わりの条件を変える変異。止まらないことで検出されている。

測定の後に、YAML 1.2 の core schema と違う読み方を 1 つ見つけた: `1_0` を整数 10 と読む (`parseBiggestInt` が `_` を数字の区切りとして受け付けるため。core schema では文字列)。変異の分類とは別の欠陥として扱う。

## 初回の測定 (c9b5c264、2026-10-11)

測定: `nim-muter`、ジョブ `tests/mutation/ext_skills.json`、拡張ブランチの c9b5c264 (2026-10-11、初回)。
2026-10-15 に登録の版の確かめを `official_common.requireTargetSpoken` (公式拡張ごとの対象の版) に替えたので、それ以後の行番号はずれている (`g2-protocol-versions.md` の「未測定 (公式拡張の対象の版)」)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 495 | 294 | 34 | 149 | 0 | 18 |

生き残り 149 件を 2 人で分担した。`frontmatter.nim` の 96 件と時間切れ 34 件が前半、`model.nim` `catalog.nim` `consumer.nim` の 53 件が後半。

| 分類 | frontmatter.nim | それ以外 | 計 |
|---|---:|---:|---:|
| 1 同値 | 4 | 23 | 27 |
| 3 穴 (テストを追加、全件で変異を当てて確認) | 84 | 27 | 111 |
| 4 到達しない・冗長 | 7 | 2 | 9 |
| 5 欠陥 | 1 | 0 | 1 |
| 6 許容 | 0 | 1 | 1 |
| 計 | 96 | 53 | 149 |

測定のあとに `frontmatter.nim` を直している (分類 5 の 1 件)。このジョブは、次の測定で測り直しになる。

2026-10-12 に `src/ext/skills/model.nim` (`isSafeSegment` の `try` を消した) と `src/ext/skills/frontmatter.nim` (冗長な条件と死んだ読み飛ばしを消した。さらに、行の折りたたみ、末尾のカンマ、`|+`、単引用符の鍵、ブロックスカラの中の `#` の行)。次の測定で測り直す。
さらに同じ日に、`frontmatter.nim` の `fail`、`stripComment`、`unquoteSingle`、`fold` に `{.raises: [].}` を付けた (`{.push raises: [FrontmatterError].}` の下で `XCannotRaiseY` の Hint が出ていたもの。Nim 2.2.12 で Hint が消えることを確かめた)。

## frontmatter.nim (担当 g2x-skills-fm)

測定: `nim-muter`、ジョブ `tests/mutation/ext_skills.json`、拡張ブランチの c9b5c264。このファイルが扱うのは `src/ext/skills/frontmatter.nim` の変異だけ。`catalog.nim` `consumer.nim` `model.nim` は別の担当 (g2x-skills-rest)。

| 全変異 (frontmatter.nim) | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 233 | 95 | 34 | 96 | 0 | 8 |

生き残り 96 件の分類。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 4 |
| 2 / 2b 他のテストが検出 | 0 |
| 3 穴 (テストを追加) | 84 |
| 4 到達しない・冗長なコード | 7 |
| 5 欠陥 | 1 |
| 6 許容 | 0 |

### やったこと

- 追加したテストは `tests/test_ext_skills_frontmatter.nim` (41 件)。`frontmatter` の既存の suite は `tests/test_ext_skills_model.nim` にあるが、別の担当も同じファイルを編集するので、衝突を避けて別ファイルにした。`tests/mutation/ext_skills.json` の `testCommand` に足した。`specs/tests.map` では既存の MCP-EXT-SKILLS-1 の行の隣に置いた (新しい Scenario は足していない)。
- 分類 3 の変異はすべて、手で当てて追加テストが落ちること (または止まらないものはウォッチドッグで終了コード 142 になること) を確かめ、`jj restore` で戻した。変異なしでは `test_ext_skills_frontmatter` 41 件、`test_ext_skills_model` 20 件、`test_ext_skills_client` 26 件、`test_ext_skills_server` 29 件、`test_ext_skills_end_to_end` 4 件、`test_spec_coverage` 8 件が通る。
- 報告の測定より後に足されたテストがこれらを既に検出しているかどうか (分類 2b) は調べていない。分類 3 の各行は「追加前のテストでは落ちない」ことを報告の「生き残り」に頼っている。
- 止まらない変異の確認には、`--import` で SIGALRM を 25 秒に仕掛けるだけのモジュール (リポジトリ外、`build/nimcache/g2x-skills-fm/watchdog.nim`) を使った。コミットしたテストには入っていない。
- 欠陥を 1 件直した (下の「欠陥」)。

### 生き残り

| id | 行 | 変異 | 元 → 変異 | 分類 | 理由 | 検出するテスト (`test_ext_skills_frontmatter.nim`) |
|---:|---:|---|---|---|---|---|
| 226 | 49:41 | AOR | `i - 1` → `<- -> +>` | 3 | 直前の文字を見る添字が `i - 1`。`i + 1` では `value #comment` (`#` の後が空白でない) が注釈にならず、行末では添字が範囲外。 | Given a hash after a space |
| 228 | 62:22 | AOR | `text.len - 1` → `<- -> +>` | 3 | 末尾が `\"` の二重引用符付き文字列は「バックスラッシュで終わる」として拒否する。境界を一つずらすと閉じ引用符を `"` として取り込む。 | Given escapes that are cut short |
| 229 | 72:12 | AOR | `i + digits` → `<+ -> ->` | 3 | 桁が足りない `\x` `\u` `\U` は FrontmatterError。変異では範囲外の添字になる。 | Given escapes that are cut short |
| 230 | 76:35 | AOR | `i + 1` → `<+ -> ->` | 3 | 切り出す範囲 `text[i+1 .. i+digits]` が桁そのもの。変異では切り出しが空・逆順・`\` 込みになる。 | Given hexadecimal escapes |
| 231 | 76:44 | AOR | `i + digits` → `<+ -> ->` | 3 | 切り出す範囲 `text[i+1 .. i+digits]` が桁そのもの。変異では切り出しが空・逆順・`\` 込みになる。 | Given hexadecimal escapes |
| 233 | 90:30 | AOR | `i + 1` → `<+ -> ->` | 4 | `unquoteSingle` の `i + 1 < text.len - 1` は冗長。`i + 1 == text.len - 1` のとき `text[i + 1]` は閉じ引用符で、この場合は引用符 1 個を足して終わるのと `` を畳むのとで結果が同じ。三つの変異 (`<=`・`i - 1`・`len + 1`) を手で当て、40 件すべて通ることを確かめた。行 90。 | - |
| 234 | 90:45 | AOR | `text.len - 1` → `<- -> +>` | 4 | `unquoteSingle` の `i + 1 < text.len - 1` は冗長。`i + 1 == text.len - 1` のとき `text[i + 1]` は閉じ引用符で、この場合は引用符 1 個を足して終わるのと `` を畳むのとで結果が同じ。三つの変異 (`<=`・`i - 1`・`len + 1`) を手で当て、40 件すべて通ることを確かめた。行 90。 | - |
| 237 | 182:11 | AOR | `j + 1` → `<+ -> ->` | 3 | 二重引用符のキーは `\n` を改行、単引用符のキーは文字どおり。`j + 1` を `j - 1` にするとコロンの位置を誤る。 | Given quoted keys |
| 242 | 224:28 | AOR | `owned.len - 1` → `<- -> +>` | 3 | 末尾の空行を落とす `setLen`。消す・伸ばすと空行がある限り止まらない。ループを進める文を消すので、変異ありでは入力を読み終えず止まる (ウォッチドッグで 142 を確認)。 | Given blank lines after a block scalar, when chomped |
| 243 | 231:34 | AOR | `1 + trailing` → `<+ -> ->` | 3 | `\|+` は末尾の改行を全部残す: `1 + 空行数`。 | Given blank lines after a block scalar, when chomped |
| 245 | 327:20 | AOR | `i + 1` → `<+ -> ->` | 3 | タブ字下げの行番号 `i + 1`。 | Given a refusal, when its message is read |
| 246 | 331:60 | AOR | `i + 1` → `<+ -> ->` | 4 | 空行の `Line.number` はどこでも読まれない (診断は空でない行の番号しか使わない)。変異 (`i - 1`) を当てて通ることを確認。行 331。 | - |
| 248 | 333:86 | AOR | `i + 1` → `<+ -> ->` | 3 | 空でない行の行番号 `i + 1` (重複キー・コロン無しの行で使う)。 | Given a refusal, when its message is read |
| 251 | 44:12 | ROR | `c == quote` → `<== -> !=>` | 3 | 引用符の中の `#` を注釈と読まない規則。変異では引用符が開かない・閉じないので `"a #` で切れる。 | Given a hash inside quotes |
| 252 | 47:12 | ROR | `i == 0` → `<== -> !=>` | 3 | 引用符は語頭 (空白・`[`・`,`・`:` の直後) でだけ開く。語中の `"` で開く変異は注釈を飲み込む。 | Given a quote in the middle of a plain scalar |
| 254 | 49:26 | ROR | `i == 0` → `<== -> !=>` | 3 | `#` は直前が空白のときだけ注釈。`a#b` は値。 | Given a hash, when it does not follow a space |
| 257 | 62:10 | ROR | `i >= text.len - 1` → `<>= -> >>` | 3 | 末尾が `\"` の二重引用符付き文字列は「バックスラッシュで終わる」として拒否する。境界を一つずらすと閉じ引用符を `"` として取り込む。 | Given escapes that are cut short |
| 258 | 71:32 | ROR | `text[i] == 'x'` → `<== -> !=>` | 3 | `\x` は 2 桁、`\u` は 4 桁、`\U` は 8 桁。直後に 16 進数字が続く文字列で桁数の取り違えが出る。 | Given hexadecimal escapes |
| 259 | 71:55 | ROR | `text[i] == 'u'` → `<== -> !=>` | 3 | `\x` は 2 桁、`\u` は 4 桁、`\U` は 8 桁。直後に 16 進数字が続く文字列で桁数の取り違えが出る。 | Given hexadecimal escapes |
| 260 | 72:21 | ROR | `i + digits >= text.len` → `<>= -> >>` | 3 | 桁が足りない `\x` `\u` `\U` は FrontmatterError。変異では範囲外の添字になる。 | Given escapes that are cut short |
| 261 | 79:15 | ROR | `code < 0` → `<< -> <=>` | 3 | `\x00` は NUL として受理する (`code < 0` が拒否の境界)。 | Given hexadecimal escapes |
| 262 | 79:27 | ROR | `code > 0x0010FFFF` → `<> -> >=>` | 3 | U+10FFFF は受理、U+110000 とサロゲート U+D800 は拒否。 | Given last code point |
| 265 | 90:34 | ROR | `i + 1 < text.len - 1` → `<< -> <=>` | 4 | `unquoteSingle` の `i + 1 < text.len - 1` は冗長。`i + 1 == text.len - 1` のとき `text[i + 1]` は閉じ引用符で、この場合は引用符 1 個を足して終わるのと `` を畳むのとで結果が同じ。三つの変異 (`<=`・`i - 1`・`len + 1`) を手で当て、40 件すべて通ることを確かめた。行 90。 | - |
| 273 | 104:17 | ROR | `text.len < 2` → `<< -> <=>` | 3 | `""` と `''` は空文字列。`len < 2` を `<= 2` にすると拒否する。 | Given empty quoted scalars |
| 276 | 108:17 | ROR | `text.len < 2` → `<< -> <=>` | 3 | `""` と `''` は空文字列。`len < 2` を `<= 2` にすると拒否する。 | Given empty quoted scalars |
| 280 | 124:35 | ROR | `text.find({'.', 'e', 'E'}) >= 0` → `<>= -> >>` | 3 | `.5` は先頭が小数点で `find` が 0 を返す。`> 0` では文字列になる。 | Given numbers and words that look like numbers |
| 282 | 133:15 | ROR | `text.len < 2` → `<< -> <=>` | 3 | `[]` は空配列、`[a]` は 1 要素。 | Given empty, single and several items |
| 288 | 157:23 | ROR | `item.strip().len > 0` → `<> -> >=>` | 3 | `[]` は空配列、`[a]` は 1 要素。 | Given empty, single and several items |
| 289 | 157:40 | ROR | `items.len > 0` → `<> -> >=>` | 3 | `[]` は空配列、`[a]` は 1 要素。 | Given empty, single and several items |
| 290 | 173:15 | ROR | `text.len > 0` → `<> -> >=>` | 4 | `splitKey` は `parseMapping` からしか呼ばれず、渡す `line.text` は空でない。`text.len > 0` は常に真。変異 (`>= 0`) を当てて通ることを確認。行 173。 | - |
| 291 | 176:13 | ROR | `j < text.len` → `<< -> <=>` | 3 | 引用符付きキーの閉じ忘れ・引用符の後が `:` でない・コロンの無い行はすべて FrontmatterError。変異では範囲外の添字 (IndexDefect) か受理に変わる。 | Given lines that are not a key and a value |
| 292 | 176:36 | ROR | `text[j] != quote` → `<!= -> ==>` | 3 | 二重引用符のキーは `\n` を改行、単引用符のキーは文字どおり。`j + 1` を `j - 1` にするとコロンの位置を誤る。 | Given quoted keys |
| 293 | 178:10 | ROR | `j >= text.len` → `<>= -> >>` | 3 | 引用符付きキーの閉じ忘れ・引用符の後が `:` でない・コロンの無い行はすべて FrontmatterError。変異では範囲外の添字 (IndexDefect) か受理に変わる。 | Given lines that are not a key and a value |
| 294 | 181:20 | ROR | `quote == '\"'` → `<== -> !=>` | 3 | 二重引用符のキーは `\n` を改行、単引用符のキーは文字どおり。`j + 1` を `j - 1` にするとコロンの位置を誤る。 | Given quoted keys |
| 295 | 183:10 | ROR | `i >= text.len` → `<>= -> >>` | 3 | 引用符付きキーの閉じ忘れ・引用符の後が `:` でない・コロンの無い行はすべて FrontmatterError。変異では範囲外の添字 (IndexDefect) か受理に変わる。 | Given lines that are not a key and a value |
| 296 | 183:33 | ROR | `text[i] != ':'` → `<!= -> ==>` | 3 | 引用符付きキーの閉じ忘れ・引用符の後が `:` でない・コロンの無い行はすべて FrontmatterError。変異では範囲外の添字 (IndexDefect) か受理に変わる。 | Given lines that are not a key and a value |
| 297 | 186:13 | ROR | `i < text.len` → `<< -> <=>` | 3 | 引用符付きキーの閉じ忘れ・引用符の後が `:` でない・コロンの無い行はすべて FrontmatterError。変異では範囲外の添字 (IndexDefect) か受理に変わる。 | Given lines that are not a key and a value |
| 301 | 188:10 | ROR | `i >= text.len` → `<>= -> >>` | 3 | 引用符付きキーの閉じ忘れ・引用符の後が `:` でない・コロンの無い行はすべて FrontmatterError。変異では範囲外の添字 (IndexDefect) か受理に変わる。 | Given lines that are not a key and a value |
| 306 | 210:14 | ROR | `r.at < r.lines.len` → `<< -> <=>` | 3 | 最後の項目がブロックスカラのとき、`r.at <= len` では範囲外を読む。 | Given a block scalar that is the last field |
| 309 | 218:20 | ROR | `blockIndent < 0` → `<< -> <=>` | 1 | `blockIndent` は -1 か 1 以上 (行は `parentIndent` (0 以上) より深い)。0 にはならないので `< 0` と `<= 0` は同じ。 | - |
| 310 | 223:19 | ROR | `owned.len > 0` → `<> -> >=>` | 3 | 行の無いブロックスカラは空文字列。`owned[^1]` を空配列に当てない境界と、`clip` が改行を足さない境界。 | Given a block scalar with no lines |
| 313 | 233:18 | ROR | `owned.len > 0` → `<> -> >=>` | 3 | 行の無いブロックスカラは空文字列。`owned[^1]` を空配列に当てない境界と、`clip` が改行を足さない境界。 | Given a block scalar with no lines |
| 319 | 258:18 | ROR | `next < r.lines.len` → `<< -> <=>` | 3 | 最後が `key:` のとき (または `key:` の後が空行だけ) の範囲外の読み取りを防ぐ。 | Given a key with nothing after it at the end |
| 321 | 260:15 | ROR | `next < r.lines.len` → `<< -> <=>` | 3 | 最後が `key:` のとき (または `key:` の後が空行だけ) の範囲外の読み取りを防ぐ。 | Given a key with nothing after it at the end |
| 323 | 261:32 | ROR | `r.lines[next].indent == indent` → `<== -> !=>` | 3 | キーと同じ字下げの `- x` を値の並びとして読む。 | Given a sequence written at the indent of its key, last field |
| 327 | 274:37 | ROR | `r.lines[r.at].text.len > 0` → `<> -> >=>` | 5 | 報告のみ、修正しない。続き行の空行 (`a: x`・空行・`  y`) は YAML では改行 1 個として折りたたまれる。この読み取りは空行を無視して `"x y"` を返す。変異 (`>= 0`) は空行ごとに空白が 1 個増えるだけで、この仕様の食い違いを直さない限りどちらが正しいかを決められない。書いたテストは無い。 | - |
| 332 | 291:77 | ROR | `line.text == "-"` → `<== -> !=>` | 3 | 同じ字下げで `- ` で始まらない行 (`  ab`) と深すぎる行 (`    - y`) は拒否する。 | Given a line in a sequence that is not an item or is indented further |
| 334 | 295:41 | ROR | `item.find(": ") >= 0` → `<>= -> >>` | 3 | `- : x` はキーの空な対応で、スカラの項目ではない。`find` が 0 を返す。 | Given a sequence item that is not a scalar |
| 339 | 320:14 | ROR | `closing < 0` → `<< -> <=>` | 1 | `closing` は -1 か 1 以上 (探索は 1 から始まる)。0 にならないので `< 0` と `<= 0` は同じ。 | - |
| 342 | 337:22 | ROR | `line.text.len > 0` → `<> -> >=>` | 3 | コメントと空行だけのブロックは項目なし。`hasContent` が常に真だと `lines[0]` を空行の後で読む。 | Given only comments and blank lines |
| 343 | 341:21 | ROR | `reader.at < reader.lines.len` → `<< -> <=>` | 4 | `reader.at < len` は冗長。`hasContent` が真なら空でない行が必ずあるので、先頭の空行の読み飛ばしは `len` に届く前に止まる。変異 (`<=`) で全件通ることを確認。行 341。 | - |
| 347 | 347:77 | ROR | `reader.lines[reader.at].text.len == 0` → `<== -> !=>` | 3 | `parseBlock` が返したあとに残る行を読み飛ばさず「unexpected content」にする。`!=` にすると残りを黙って捨てる。 | Given content left of the first field's indent |
| 349 | 47:17 | LOR | `i == 0 or text[i - 1] in {' ', '[', ',', ':'}` → `<or -> and>` | 3 | 引用符の中の `#` を注釈と読まない規則。変異では引用符が開かない・閉じないので `"a #` で切れる。 | Given a hash inside quotes |
| 352 | 79:38 | LOR | `code < 0 or code > 0x0010FFFF or code in 0x0000D800 .. 0x0000DFFF` → `<or -> and>` | 3 | U+10FFFF は受理、U+110000 とサロゲート U+D800 は拒否。 | Given last code point |
| 353 | 79:19 | LOR | `code < 0 or code > 0x0010FFFF` → `<or -> and>` | 3 | U+10FFFF は受理、U+110000 とサロゲート U+D800 は拒否。 | Given last code point |
| 356 | 99:71 | LOR | `text.len == 0 or text == "~" or text == "null" or text == "Null" or; text == "NULL"` → `<or -> and>` | 3 | `""` (空) `~` `null` `Null` `NULL` を null と読む。`or` を `and` にすると各綴りが文字列になる。 | Given every spelling of null |
| 357 | 99:53 | LOR | `text.len == 0 or text == "~" or text == "null" or text == "Null"` → `<or -> and>` | 3 | `""` (空) `~` `null` `Null` `NULL` を null と読む。`or` を `and` にすると各綴りが文字列になる。 | Given every spelling of null |
| 358 | 99:35 | LOR | `text.len == 0 or text == "~" or text == "null"` → `<or -> and>` | 3 | `""` (空) `~` `null` `Null` `NULL` を null と読む。`or` を `and` にすると各綴りが文字列になる。 | Given every spelling of null |
| 359 | 99:20 | LOR | `text.len == 0 or text == "~"` → `<or -> and>` | 3 | `""` (空) `~` `null` `Null` `NULL` を null と読む。`or` を `and` にすると各綴りが文字列になる。 | Given every spelling of null |
| 361 | 108:21 | LOR | `text.len < 2 or text[^1] != '\''` → `<or -> and>` | 3 | 閉じていない `'abc` を拒否する (二重引用符には既存の例があり、単引用符には無かった)。 | Given quoted scalars that do not end on their line |
| 363 | 124:40 | LOR | `text.find({'.', 'e', 'E'}) >= 0 and text[0] in {'0' .. '9', '-', '+', '.'}` → `<and -> or>` | 3 | `and` を `or` にすると `parseFloat` を呼ばずに 0.0 を返す語 (`1e3` `v1.2` `example.com`) が出る。 | Given numbers and words that look like numbers |
| 364 | 133:19 | LOR | `text.len < 2 or text[^1] != ']'` → `<or -> and>` | 3 | `[a, b` のように閉じていない並びを拒否する。 | Given a sequence that does not close on its line or nests |
| 365 | 157:27 | LOR | `item.strip().len > 0 or items.len > 0` → `<or -> and>` | 3 | `[a]` (1 要素) で最後の要素が落ちる。 | Given empty, single and several items |
| 367 | 176:24 | LOR | `j < text.len and text[j] != quote` → `<and -> or>` | 3 | 引用符付きキーの閉じ忘れ・引用符の後が `:` でない・コロンの無い行はすべて FrontmatterError。変異では範囲外の添字 (IndexDefect) か受理に変わる。 | Given lines that are not a key and a value |
| 368 | 183:22 | LOR | `i >= text.len or text[i] != ':'` → `<or -> and>` | 3 | 引用符付きキーの閉じ忘れ・引用符の後が `:` でない・コロンの無い行はすべて FrontmatterError。変異では範囲外の添字 (IndexDefect) か受理に変わる。 | Given lines that are not a key and a value |
| 370 | 186:48 | LOR | `text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ')` → `<and -> or>` | 3 | キーはコロン+空白で終わる。`my key: v` の空白で切れてはいけない。 | Given a key with a space or a colon not followed by a space |
| 381 | 291:29 | LOR | `line.indent > indent or not (line.text.startsWith("- ") or line.text == "-")` → `<or -> and>` | 3 | 同じ字下げで `- ` で始まらない行 (`  ab`) と深すぎる行 (`    - y`) は拒否する。 | Given a line in a sequence that is not an item or is indented further |
| 386 | 313:19 | LOR | `all.len == 0 or all[0].strip(leading = false) != Fence` → `<or -> and>` | 3 | 先頭が `---` でないファイルは拒否する。`all.len == 0` は `splitLines` が少なくとも 1 要素を返すので常に偽で、`or` を `and` にすると拒否が消える。 | Given text before the opening fence |
| 390 | 50:44 | BLR | `false` → `true` | 1 | `stripComment` の三つの呼び出し側 (254・275・294 行) はどれも結果をもう一度 `.strip()` する。先頭側を削るかどうかは観測できない。 | - |
| 392 | 115:41 | BLR | `false` → `true` | 3 | `false` `False` `FALSE` を偽と読む (同じ文を指す RVR と BLR で、同じ変異を 1 回当てた)。 | Given every spelling of a boolean |
| 393 | 313:45 | BLR | `false` → `true` | 3 | `---` の前に空白があるものは開きの囲みではない。 | Given text before the opening fence |
| 394 | 317:31 | BLR | `false` → `true` | 3 | 開きの囲みの検査で、行頭の空白も落とすようになる。字下げした `---` で始まるファイルが受け入れられる。 | Given text before the opening fence, when read, then it is refused (2026-10-11 に変異を当て直して確かめた。以前の記載は閉じの囲みのテストを挙げていて誤り) |
| 395 | 325:50 | BLR | `false` → `true` | 3 | 字下げ判定に使う `leading` は先頭の空白だけ数える。末尾の空白まで数えると、末尾のタブを字下げと取り違える (`a:\t\t\t`)。 | Given whitespace after the content, when it is a tab |
| 397 | 329:41 | BLR | `false` → `true` | 1 | `text` は直前の行 328 で末尾の空白を取り除いてあるので、`trimmed` でもう一度末尾を削っても同じ。 | - |
| 401 | 61:5 | SDL | `inc i` → `discard` | 3 | バックスラッシュの後と各エスケープの後で `i` を進める。消すと次の文字を読み直して余分な文字が入る。 | Given escapes of a double-quoted scalar |
| 402 | 85:5 | SDL | `inc i` → `discard` | 3 | バックスラッシュの後と各エスケープの後で `i` を進める。消すと次の文字を読み直して余分な文字が入る。 | Given escapes of a double-quoted scalar |
| 405 | 65:19 | SDL | `result.add '\n'` → `discard` | 3 | `\n` `\t` `\r` `\0` `\"` `\\` `\/` をそれぞれ別の文字として検査する。 | Given escapes of a double-quoted scalar |
| 406 | 66:19 | SDL | `result.add '\t'` → `discard` | 3 | `\n` `\t` `\r` `\0` `\"` `\\` `\/` をそれぞれ別の文字として検査する。 | Given escapes of a double-quoted scalar |
| 407 | 67:19 | SDL | `result.add '\r'` → `discard` | 3 | `\n` `\t` `\r` `\0` `\"` `\\` `\/` をそれぞれ別の文字として検査する。 | Given escapes of a double-quoted scalar |
| 408 | 68:19 | SDL | `result.add '\x00'` → `discard` | 3 | `\n` `\t` `\r` `\0` `\"` `\\` `\/` をそれぞれ別の文字として検査する。 | Given escapes of a double-quoted scalar |
| 409 | 69:30 | SDL | `result.add text[i]` → `discard` | 3 | `\n` `\t` `\r` `\0` `\"` `\\` `\/` をそれぞれ別の文字として検査する。 | Given escapes of a double-quoted scalar |
| 410 | 81:13 | SDL | `result.add Rune(code).toUTF8` → `discard` | 3 | 変異ではエスケープが結果に入らない。 | Given hexadecimal escapes |
| 422 | 177:7 | SDL | `inc j` → `discard` | 3 | `inc j` を消すと引用符付きキーの走査が止まらない。ループを進める文を消すので、変異ありでは入力を読み終えず止まる (ウォッチドッグで 142 を確認)。 | Given quoted keys |
| 428 | 213:12 | SDL | `owned.add ""` → `discard` | 3 | ブロックスカラ内の空行を保持する。`owned.add ""` を消す、または空行を `Line` として積まないと消える。 | Given a literal block with a blank line inside |
| 429 | 214:7 | SDL | `inc r.at` → `discard` | 3 | 空行で `inc r.at` を消すと同じ行を読み続ける。ループを進める文を消すので、変異ありでは入力を読み終えず止まる (ウォッチドッグで 142 を確認)。 | Given a literal block with a blank line inside |
| 430 | 224:17 | SDL | `owned.setLen(owned.len - 1)` → `discard` | 3 | 末尾の空行を落とす `setLen`。消す・伸ばすと空行がある限り止まらない。ループを進める文を消すので、変異ありでは入力を読み終えず止まる (ウォッチドッグで 142 を確認)。 | Given blank lines after a block scalar, when chomped |
| 431 | 225:5 | SDL | `inc trailing` → `discard` | 3 | `\|+` は末尾の改行を全部残す: `1 + 空行数`。 | Given blank lines after a block scalar, when chomped |
| 434 | 231:15 | SDL | `text.add '\n'.repeat(1 + trailing)` → `discard` | 3 | `\|+` は末尾の改行を全部残す: `1 + 空行数`。 | Given blank lines after a block scalar, when chomped |
| 437 | 242:7 | SDL | `inc r.at` → `discard` | 3 | 値が引用符・`[…]` のときは続き行の走査に入らないので、次の行頭の空行を `parseMapping` が自分で読み飛ばす。`inc r.at` を消すと止まらない。(コメント行も空行扱い) | Given blank and comment lines between fields |
| 438 | 259:9 | SDL | `inc next` → `discard` | 3 | `key:` の後ろの空行を数え飛ばす `inc next`。消すと止まらない。 | Given a blank line between a key and its nested mapping |
| 443 | 287:7 | SDL | `inc r.at` → `discard` | 3 | 並びの項目の間の空行。`inc r.at` を消すと止まらない。ループを進める文を消すので、変異ありでは入力を読み終えず止まる (ウォッチドッグで 142 を確認)。 | Given a sequence indented under its key, blank lines between items |
| 446 | 331:19 | SDL | `reader.lines.add Line(indent: 0, text: "", number: i + 1)` → `discard` | 3 | ブロックスカラ内の空行を保持する。`owned.add ""` を消す、または空行を `Line` として積まないと消える。 | Given a literal block with a blank line inside |
| 448 | 342:7 | SDL | `inc reader.at` → `discard` | 3 | 先頭のコメント行を読み飛ばす。`inc reader.at` を消すと止まらない。ループを進める文を消すので、変異ありでは入力を読み終えず止まる (ウォッチドッグで 142 を確認)。 | Given a comment before an indented mapping |
| 449 | 348:7 | SDL | `inc reader.at` → `discard` | 4 | 行 347-348 の読み飛ばしは死んでいる: `parseMapping` / `parseSequence` は空行を先に消費してから字下げを調べるので、返った時点の `reader.at` は空でない行か末尾。`inc reader.at` を消しても何も変わらない (確認済み)。ループごと削れるが、ソースは消していない。 | - |
| 451 | 100:5 | RVR | `return newJNull()` → `<return default>` | 3 | `~` の値が `nil` になる。変異では読み取りが segfault (終了コード 139) で止まる。 | Given every spelling of null |
| 455 | 115:33 | RVR | `return %false` → `<return default>` | 3 | `false` `False` `FALSE` を偽と読む (同じ文を指す RVR と BLR で、同じ変異を 1 回当てた)。 | Given every spelling of a boolean |

### timeout 34 件

id: 239 (行 186), 244 (行 325), 247 (行 333), 272 (行 103), 275 (行 107), 278 (行 111), 300 (行 186), 302 (行 191), 314 (行 239), 316 (行 244), 317 (行 246), 324 (行 272), 325 (行 272), 326 (行 273), 335 (行 301), 336 (行 313), 337 (行 313), 344 (行 341), 345 (行 345), 346 (行 347), 348 (行 349), 366 (行 173), 369 (行 186), 371 (行 186), 378 (行 272), 388 (行 341), 389 (行 347), 404 (行 59), 413 (行 95), 425 (行 187), 427 (行 221), 436 (行 253), 439 (行 279), 441 (行 293)。

走らせてはいない。変異した文を読んで分けた。

- ループを進める文を消したもので、読み取りが終わらない: 404 (`unquoteDouble` の `inc i`)、413 (`unquoteSingle`)、425 (`splitKey` の `inc i`)、427 (`blockScalar` の `inc r.at`)、439 (`parseMapping` の続き行の `inc r.at`)、441 (`parseSequence` の `inc r.at`、同じ項目を足し続ける)。
- ループの条件を一つずらしたもので、末尾を越えて読む: 314、324、325、378、346、348、388、389、369、316 (`<=` や `and`→`or`)。これらは止まらないのではなく範囲外の添字になる。
- どんな有効なファイルも拒否するようになるもの: 272 275 278 (先頭の文字の判定を反転)、366 371 239 300 302 (キーの走査と空キーの判定)、317 335 336 337 345 (字下げ・`-` ・囲み・型の判定)、244 247 (`leading` と `indent` の計算)、326、436 (`inc r.at` を消すと同じキーをもう一度読んで「重複キー」になる)、344。これらも止まらないわけではない。クライアントとサーバーの試験は FrontmatterError を返信に変える代わりにハンドラの外に投げるため、応答が来ず待ち続ける、というのが一番ありそうな理由だが、確かめていない。

どの timeout も検出済みとして数えてよい (有効なファイルが読めなくなるか読み取りが止まる)。無限ループは 6 件。他は、テストが待つ側で止まったとみられる。

### 欠陥

- **直した**: 字下げなしの並び (`words:` の次の行が `- x`) の後に別のキーが続くと「expected a sequence item」で拒否していた (`src/ext/skills/frontmatter.nim` の `parseSequence`)。`parseMapping` はこの書き方を始めるのに、次のキーで終われなかった。失敗するテスト (`Given a sequence written at the indent of its key, when other fields follow it, then they are read`) を先に書き、`parseSequence` が自分の字下げの「項目でない行」で止まるように直した。深すぎる行は従来どおり拒否し、メッセージは「unexpected indentation」にした。この修正はこのファイルの生き残り 381・332 とは別の話で、2 件とも修正前の `parseSequence` で確認済み。修正後も同じテストが通る。

### 残っているもの

- id 327 (行 274)。分類 5。続き行の空行と、折りたたみ形 `>` の空行は YAML の行の折りたたみどおりに読むと決めた (2026-10-12、折りたたむ側。サブセットの外として拒否はしない)。空行 n 個は改行 n 個、空行の無い改行は空白 1 個。Scenario `MCP-EXT-SKILLS-25` とそのテストを足した。
- 読んでいて見つけた 4 件 (`[a, ]`、行の無い `|+`、`'it''s'` の鍵、ブロックスカラの中の `#` の行) も YAML どおりに直すと決めた (2026-10-12)。Scenario `MCP-EXT-SKILLS-26` から `-29` とそのテストを足した。
- 2026-10-13 に直した (利用者の決定): フロー列の空の要素 (`[a,,]`、`[,]`、`[,a]`) は FrontmatterError で拒否する。`MCP-EXT-SKILLS-30`。二重引用符の鍵の中のエスケープは、値と同じ規則で読む (`"a\"b": v` の鍵は `a"b`)。`MCP-EXT-SKILLS-31`。
- 2026-10-13 に直した (利用者の決定。上で「決めかねて今の挙動を保った」としていた 3 点): どれも YAML どおりに読む。
  - `>` の中の、より深く字下げした行は、前後の改行を保つ (その前後の空行 n 個は改行 n+1 個)。つないだ文字列の `  ` を ` ` にする置き換えは消した。`MCP-EXT-SKILLS-32`。
  - 注釈は plain スカラを終わらせる (注釈だけの行も、値の行の末尾の注釈も)。そのあとに続き行が来たら FrontmatterError。`MCP-EXT-SKILLS-33`。
  - ブロックスカラは、中身より字下げが浅い最初の行で終わる。そこにある `#` の行は注釈で、空行には数えない。そのあとに深い字下げの行が来たら FrontmatterError。`#` でない浅い行 (`|` の次が 4 字下げ、その次が 2 字下げ) も同じ規則で拒否になった (従来は中身として読んでいた)。`MCP-EXT-SKILLS-34`。
  - 確かめ方: 期待値は PyYAML 6.0.2 の `safe_load` の結果から取った。直したあと、ブロックスカラ・続き行・注釈・空行を組み合わせた 4772 文書を PyYAML と突き合わせ、値も拒否も食い違い 0 (突き合わせの道具は捨てた。コミットしていない)。この読み取りが拒否する部分集合の外 (鍵の次の行から始まる plain スカラ、重複した鍵) は突き合わせから除いた。
  - `frontmatter.nim` はこの修正でも変わった。次の測定で測り直す。
- 今の挙動を保ったもの:
  - 空行だけで中身の無い `|+` は、空行 n 個が改行 n 個 (従来は n+1 個)。YAML の例 8.6 に合わせた。

- 上の欠陥と 327 を除いて、受け入れた (分類 6) ものは無い。
- 分類 4 は 233・234・265 (行 90)、290 (行 173)、246 (行 331)、343 (行 341)、449 (行 348)。2026-10-12 に消すと決め、消した。読んで確かめたこと: `unquoteSingle` の条件は、満たさない場合も同じ 1 個の `'` を足して読み終わるので結果が同じ。`splitKey` に渡る行は空でない。空行と注釈行の `Line.number` は読まれない (空行の番号は読まない)。字下げの無い行の読み飛ばしは、`parseBlock` が空行を読み切るか非空行で止まるので、あとの飛ばしは動かない。`hasContent` の中の `reader.at < reader.lines.len` は、中身のある行が必ずあるので常に真。

## model.nim / catalog.nim / consumer.nim (担当 g2x-skills-rest)

測定: `nim-muter`、ジョブ `tests/mutation/ext_skills.json`、拡張ブランチの c9b5c264 (初回の測定)。この文書が扱うのは `src/ext/skills/catalog.nim`、`consumer.nim`、`model.nim` の生き残り 53 件。`frontmatter.nim` (96 件) と `src/ext/skills.nim` は `g2x-skills-fm` の担当で、ここでは触れない。

| ファイル | 全変異 | killed | timeout | survived | runError | compileError |
|---|---:|---:|---:|---:|---:|---:|
| catalog.nim | 96 | 74 | 0 | 18 | 0 | 4 |
| consumer.nim | 38 | 32 | 0 | 6 | 0 | 0 |
| model.nim | 128 | 93 | 0 | 29 | 0 | 6 |
| 計 | 262 | 199 | 0 | 53 | 0 | 10 |

timeout はこの 3 ファイルには 1 件も無い (ジョブ全体の 34 件はすべて frontmatter.nim)。

### 分類

| 分類 | 件数 |
|---|---:|
| 1 同値 | 23 |
| 2 / 2b 別のテストが検出 | 0 |
| 3 穴 (テストを追加) | 27 |
| 4 到達しない・冗長なコード | 2 |
| 5 欠陥 | 0 |
| 6 許容 | 1 |

分類 3 の 27 件は、変異を 1 件ずつ手で当て、名前を挙げたテストが落ちる (または落ちる代わりに実行が異常終了する、後述) ことを確かめた。未確認は 0 件。追加したテストは、変異なしで通ることを `test_ext_skills_model` (27 件)、`test_ext_skills_server` (38 件、既定の版と 2025-11-25、2024-11-05 の 3 通り)、`test_ext_skills_client` (30 件。2025-11-25 では 2026-07-28 専用の suite が動かないので 0 件) で確かめた。`tests/test_spec_coverage.nim` も通る。

「異常終了」と書いた行は、変異によってテスト実行が NilAccessDefect 相当で落ちた (終了コード 139) もの。`testCommand` は終了コードで判定するので検出される。ただしテスト名が出ないので、どのケースで落ちたかは個別には確かめていない (nil の入力を渡すケースが原因であることは、変異の構造から)。

### 生き残り

#### model.nim

| id | 行 | 変異 | 元 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|:-:|---|
| 16 | 85 | ROR | `rune.int < 128` → `<= 128` | 1 | 差が出る唯一の rune は U+0080。ASCII 側の分岐は `char(128) notin {...}` で、非 ASCII 側の分岐は `isAlpha` が偽で、どちらも同じ文言 `some("a skill name holds letters, digits and hyphens only")` を返す。 |
| 115 | 89 | RVR | `return some("…")` → `none` | 3 | 英字でない非 ASCII 文字 (`€`、NBSP、絵文字) を含む名前が受理される。`Given a name with a character that is neither ASCII nor a letter, when validated, then it is refused` |
| 94 | 90 | SDL | 最後の式 `none(string)` を削除 | 1 | 値を返さない関数の `result` は既定値で、`Option[string]` の既定値は none。 |
| 19 | 105 | ROR | `scheme.len > 0` → `>= 0` | 1 | `isSchemeName` の唯一の呼び出し元 `splitResourceUri` は `marker <= 0` を先に退けるので、`scheme` は空にならない。 |
| 3 | 106 | AOR | `Letters + Digits` → `Letters - Digits` | 3 | 数字を含む scheme (`s3`) が拒否される。`Given schemes with digits, plus, hyphen and dot, when a URI is split, then the scheme is accepted` |
| 2 | 106 | AOR | `… + {'+','-','.'}` → `- {…}` | 3 | `git+ssh`、`a.b-c` が拒否される。同上 |
| 23 | 113 | ROR | `c < ' '` → `<=` | 3 | 空白を含む区間 (`my file.md`) が拒否される。`Given segments with a space, a percent escape of a plain character and a control character, when a URI is split, then only the control character and the escaped dot are refused`。`Given a label and a path segment with a space, …%20` も落ちる。 |
| 84 | 119 | BLR | `decodePlus = false` → `true` | 1 | 違いは `+` が空白に変わることだけ。直後の検査は `.`、`..`、`/`、`\`、NUL との比較で、`+` や空白からそのどれにもならない。 |
| 118 | 121 | RVR | `return false` → `true` | 4 | `except ValueError` に入る経路が無い。`decodeUrl` は `func` で、不正な `%xx` は例外にせず元の文字のまま残す (Nim 2.2.8 の `lib/pure/uri.nim`、ドキュメント: "If xx is not a valid hexadecimal value, it is left intact")。`model.nim:118-121` は到達しない。 |
| 85 | 121 | BLR | `false` → `true` | 4 | 同上 (118 と同じ文)。 |
| 25 | 122 | ROR | `decoded == "."` → `!=` | 3 | `%2e` だけの区間が受理され、`b%20c` のような普通の区間が拒否される。同じテスト (`…escaped dot are refused`) |
| 27 | 132 | ROR | `marker <= 0` → `< 0` | 1 | `marker == 0` (`://x`) では `scheme` が空になり、`isSchemeName("")` が偽で同じ none を返す。 |
| 120 | 133 | RVR | `return none(tuple…)` → 既定値 | 1 | 非リテラルなので変異後は `default(Option[…])` で、それは none。以下 121-126 も同じ。 |
| 121 | 137 | RVR | 同上 | 1 | 同上 |
| 122 | 140 | RVR | 同上 | 1 | 同上 |
| 123 | 148 | RVR | `return none(string)` → 既定値 | 1 | 同上 |
| 124 | 151 | RVR | 同上 | 1 | 同上 |
| 125 | 159 | RVR | 同上 | 1 | 同上 |
| 126 | 163 | RVR | 同上 | 1 | 同上 |
| 88 | 182 | BLR | `encodeUrl(serverLabel, usePlus = false)` → `true` | 3 | 空白を含むラベルの保存先が `my+server` になる。`Given a label and a path segment with a space, when a storage path is computed, then each is percent-encoded with %20`。ディスク上の配置は一度決めたら変えない約束なので、配置を値で固定した。 |
| 89 | 183 | BLR | scheme 側の `usePlus = false` → `true` | 1 | `usePlus` が変えるのは空白だけで、`isSchemeName` を通った scheme に空白は無い。 |
| 90 | 185 | BLR | 区間側の `usePlus = false` → `true` | 3 | 空白を含む区間が `my+file.md` になる。88 と同じテスト。 |
| 127 | 212 | RVR | `return ""` → 文字列リテラルは `""` に | 1 | 元から `""`。変異後のプログラムは同一。 |
| 71 | 226 | LOR | `node.isNil or node.kind != JObject` → `and` | 3 | nil は `kind` で落ちる。非オブジェクトは別の文言になる。`Given nothing or a value that is not an object, when an entry is parsed, then SkillsError names the rule` (nil で異常終了)。 |
| 79 | 276 | LOR | 1 つ目の `or` → `and` | 3 | `uri` が無い・文字列でない resource。`Given resources that lack a string uri or digest, when an entry is parsed, then the error says what a resource needs` (異常終了) |
| 78 | 276 | LOR | 2 つ目の `or` → `and` | 3 | 同上 (異常終了) |
| 77 | 276 | LOR | 3 つ目の `or` → `and` | 3 | 同上 (異常終了) |
| 48 | 282 | ROR | `size.getBiggestInt() < 0` → `<= 0` | 3 | 大きさ 0 の (空の) ファイルが拒否される。`Given a file of size 0, when an entry is parsed, then it is accepted` |
| 108 | 303 | SDL | `none(SkillResource)` を削除 | 1 | 94 と同じ。`Option` の既定値は none。 |

#### catalog.nim

| id | 行 | 変異 | 元 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|:-:|---|
| 130 | 86 | AOR | `Letters + Digits` → `-` | 3 | `newSkillCatalog(scheme = "s3")` が拒否される。`Given schemes with digits, plus, hyphen and dot, when a catalog is made, then they are accepted` |
| 129 | 86 | AOR | `… + {'+','-','.'}` → `-` | 3 | `git+ssh` が拒否される。同上 |
| 161 | 177 | LOR | `frontmatter.isNil or kind != JObject` → `and` | 3 | `addDynamicSkill` に nil を渡すと SkillsError でなく異常終了 (非オブジェクトは文言が変わる)。`Given a dynamic skill with no frontmatter or one that is not an object, when it is added, then SkillsError says it must be an object` |
| 144 | 183 | ROR | `skill.path == skillPath` → `!=` | 3 | 動的な skill を 2 つ足すと 2 つ目が「既に提供中」になり、同じものを 2 度足しても通る。`Given two dynamic skills and a dynamic skill added twice, when they are added, then the two are served and the repeat is refused` |
| 192 | 208 | SDL | `checkLimits(skillPath, files.len + 1, total)` を削除 | 3 | docstring が約束する「大きすぎるディレクトリは中身を読む前に退ける」が消える (その後 `addSkill` が同じ上限で退けるので、読めるファイルでは結果が同じ)。読めない 16 MiB 超のファイルで、読む前なら SkillsError、読むなら IOError になる。`Given a file beyond 16 MiB that cannot be read, when its directory is added, then SkillsError names the limit before any read` |
| 132 | 208 | AOR | `files.len + 1` → `files.len - 1` | 6 | 下の「残っているもの」。 |
| 212 | 249 | RVR | `return none(Found)` → 既定値 | 1 | `Option[Found]` の既定値は none。 |
| 164 | 254 | LOR | `not skill.files.isNil and path.startsWith(…)` → `or` | 3 | 動的な skill が 1 つでもあれば、どの skill も提供しない URI を読むたびに提供元が呼ばれる。`generatedFiles` は全動的 skill を束ねるので、見つかる結果は変わらず、変わるのは提供元の呼び出し (副作用・コスト・不正な path での例外) だけ。`Given a dynamic skill beside fixed ones, when a URI no skill serves is read, then the provider is not called` |
| 215 | 259 | RVR | `return none(Found)` → 既定値 | 1 | 212 と同じ。 |
| 198 | 260 | SDL | 最後の `none(Found)` を削除 | 1 | 212 と同じ (`result` の既定値が none)。 |
| 165 | 263 | LOR | `(…text/… or …json…) and validateUtf8` → `or` | 3 | UTF-8 でないバイトの `text/markdown` が `text` で返る。バイナリの MIME でも、中身が UTF-8 なら `text` になる。`Given text files with bytes that are not UTF-8 and a binary file whose bytes are valid UTF-8, when read, then each is a blob` |
| 150 | 287 | ROR | `slash < 0` → `<= 0` | 1 | `slash == 0` は `rest` が `/` で始まる場合で、`stored` と生成された path は `safeFilePath` と `splitResourceUri` を通っていて、空の区間が無い。 |
| 178 | 342 | BLR | `directoryRead = false` → `true` | 3 | 既定で directoryRead が宣言され、メソッドも答える。既存のテストは引数を明示していた。`Given a server registered without saying anything about directoryRead, when a client discovers it, then the setting is absent and the method is unknown` |
| 210 | 361 | SDL | `methods.add DirectoryReadMethod` を削除 | 3 | `resources/directory/read` が定義済みの server で、拡張を宣言した後に失敗し、server が中途半端な状態で残る。`Given a server that already defines resources/directory/read, when skills are registered with directoryRead, then ValueError is raised and nothing is declared` |
| 221 | 387 | RVR | `return none(JsonRpcResponse)` → 既定値 | 1 | `Option` の既定値は none。 |
| 173 | 389 | LOR | `uri.isNil or uri.kind != JString` → `and` | 3 | uri の無い `resources/read` で nil の `kind` を読んで異常終了する。非文字列の uri は結果が変わらない (空文字列の URI として探して見つからず、同じ none)。`Given a resources/read without a string uri, when a client sends it, then the server's own handler answers invalid params` |
| 222 | 390 | RVR | `return none(JsonRpcResponse)` → 既定値 | 1 | 221 と同じ。 |
| 223 | 393 | RVR | 同上 | 1 | 同上 |

#### consumer.nim

| id | 行 | 変異 | 元 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|:-:|---|
| 479 | 113 | BLR | `getSkill` の `clientDeclares = false` → `true` | 3 | 拡張を宣言しないクライアントが `getSkill` を呼ぶと McpUnsupportedError になる。仕様はクライアントに宣言を求めない。`Given a client that declared nothing, when it gets a skill by URI, then it is served` |
| 458 | 164 | AOR | `skill.retrieved + listed.get.size` → `-` | 3 | 取得済みの量を足した事前の検査が消え、上限を超える読みを要求してから退ける。事後の検査が同じ型の例外を出すので、要求の数で見分ける。`Given a listed file of 9 MiB read twice, when the second read would pass 16 MiB, then SkillsError is raised without a second request` |
| 463 | 164 | ROR | `> MaxSkillBytes` → `>=` | 3 | ちょうど 16 MiB の skill が事前の検査で拒否される。`Given a listed SKILL.md of exactly 16 MiB, when it is read, then the limit is not passed and the bytes come back` |
| 465 | 177 | ROR | `retrieved + bytes.len > MaxSkillBytes` → `>=` | 3 | 同じテスト (事後の検査で拒否される)。 |
| 475 | 216 | LOR | `entry.dynamic or current.dynamic` → `and` | 1 | 動的な entry の `contentBinding` は空文字列で、静的な entry は少なくとも SKILL.md を持つので空でない。片方だけ動的なら 2 つの binding が必ず異なり、`changed` は true のまま。両方動的なら変異後も true。両方静的なら第 1 項は元から偽。 |
| 483 | 238 | BLR | `listDirectory` の `clientDeclares = false` → `true` | 3 | 479 と同じ。`Given a client that declared nothing, when it reads a directory of a server with directoryRead, then it is served` |

### 残っているもの

- 分類 4 の 2 件 (id 118、85): `src/ext/skills/model.nim:119-121` の `except ValueError` は、標準ライブラリの `decodeUrl` が例外を出さないので到達しない。コードの削除はしていない。2026-10-12 に消すと決め、`isSafeSegment` の `try` ごと消して `let decoded = decodeUrl(segment, decodePlus = false)` にした (`{.raises: [].}` のままコンパイルできる。`decodeUrl` が例外を出さないことの確認)。
- 分類 6 の 1 件 (id 132、`catalog.nim:208`、`files.len + 1` → `files.len - 1`): 事前の上限検査の数え方が 2 つずれても、拒否される入力の集合は変わらない。512 を超えた最初のファイルで退けるか、2 つ読んでから退けるかの差で、後ろの `addSkill` の `checkLimits` が同じ文言で退ける。読んだファイル数に応じて文言の数が変わる (513 か、全ファイル数か) だけで、この数は仕様でも docstring の約束でもない。数を値で固定するテストは実装の写しになるので書かなかった。許容する。
- 分類 3 の 164 は、`locate` の条件が副作用の有無だけを分けているという読みに基づく。提供元を数える以外に見える違いは見つからなかった。
- 追加したテストには、nil を渡すと変異によって異常終了するものがある (id 71、79、78、77、161、173)。終了コードで検出されるが、落ちたテスト名は出ない。
- `docs/quality/g2-protocol-versions.md` の「未測定」の表は、ジョブ全体 (frontmatter.nim を含む) が終わるまで触らない。
