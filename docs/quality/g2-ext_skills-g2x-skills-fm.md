# G2 変異検出: ext_skills ジョブの frontmatter.nim (g2x-skills-fm)

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

## やったこと

- 追加したテストは `tests/test_ext_skills_frontmatter.nim` (41 件)。`frontmatter` の既存の suite は `tests/test_ext_skills_model.nim` にあるが、別の担当も同じファイルを編集するので、衝突を避けて別ファイルにした。`tests/mutation/ext_skills.json` の `testCommand` に足した。`specs/tests.map` では既存の MCP-EXT-SKILLS-1 の行の隣に置いた (新しい Scenario は足していない)。
- 分類 3 の変異はすべて、手で当てて追加テストが落ちること (または止まらないものはウォッチドッグで終了コード 142 になること) を確かめ、`jj restore` で戻した。変異なしでは `test_ext_skills_frontmatter` 41 件、`test_ext_skills_model` 20 件、`test_ext_skills_client` 26 件、`test_ext_skills_server` 29 件、`test_ext_skills_end_to_end` 4 件、`test_spec_coverage` 8 件が通る。
- 報告の測定より後に足されたテストがこれらを既に検出しているかどうか (分類 2b) は調べていない。分類 3 の各行は「追加前のテストでは落ちない」ことを報告の「生き残り」に頼っている。
- 止まらない変異の確認には、`--import` で SIGALRM を 25 秒に仕掛けるだけのモジュール (リポジトリ外、`build/nimcache/g2x-skills-fm/watchdog.nim`) を使った。コミットしたテストには入っていない。
- 欠陥を 1 件直した (下の「欠陥」)。

## 生き残り

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
| 394 | 317:31 | BLR | `false` → `true` | 3 | 字下げした `---` は閉じの囲みではない。 | Given a fence with trailing spaces / an indented closing fence |
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

## timeout 34 件

id: 239 (行 186), 244 (行 325), 247 (行 333), 272 (行 103), 275 (行 107), 278 (行 111), 300 (行 186), 302 (行 191), 314 (行 239), 316 (行 244), 317 (行 246), 324 (行 272), 325 (行 272), 326 (行 273), 335 (行 301), 336 (行 313), 337 (行 313), 344 (行 341), 345 (行 345), 346 (行 347), 348 (行 349), 366 (行 173), 369 (行 186), 371 (行 186), 378 (行 272), 388 (行 341), 389 (行 347), 404 (行 59), 413 (行 95), 425 (行 187), 427 (行 221), 436 (行 253), 439 (行 279), 441 (行 293)。

走らせてはいない。変異した文を読んで分けた。

- ループを進める文を消したもので、読み取りが終わらない: 404 (`unquoteDouble` の `inc i`)、413 (`unquoteSingle`)、425 (`splitKey` の `inc i`)、427 (`blockScalar` の `inc r.at`)、439 (`parseMapping` の続き行の `inc r.at`)、441 (`parseSequence` の `inc r.at`、同じ項目を足し続ける)。
- ループの条件を一つずらしたもので、末尾を越えて読む: 314、324、325、378、346、348、388、389、369、316 (`<=` や `and`→`or`)。これらは止まらないのではなく範囲外の添字になる。
- どんな有効なファイルも拒否するようになるもの: 272 275 278 (先頭の文字の判定を反転)、366 371 239 300 302 (キーの走査と空キーの判定)、317 335 336 337 345 (字下げ・`-` ・囲み・型の判定)、244 247 (`leading` と `indent` の計算)、326、436 (`inc r.at` を消すと同じキーをもう一度読んで「重複キー」になる)、344。これらも止まらないわけではない。クライアントとサーバーの試験は FrontmatterError を返信に変える代わりにハンドラの外に投げるため、応答が来ず待ち続ける、というのが一番ありそうな理由だが、確かめていない。

どの timeout も検出済みとして数えてよい (有効なファイルが読めなくなるか読み取りが止まる)。無限ループは 6 件。他は、テストが待つ側で止まったとみられる。

## 欠陥

- **直した**: 字下げなしの並び (`words:` の次の行が `- x`) の後に別のキーが続くと「expected a sequence item」で拒否していた (`src/ext/skills/frontmatter.nim` の `parseSequence`)。`parseMapping` はこの書き方を始めるのに、次のキーで終われなかった。失敗するテスト (`Given a sequence written at the indent of its key, when other fields follow it, then they are read`) を先に書き、`parseSequence` が自分の字下げの「項目でない行」で止まるように直した。深すぎる行は従来どおり拒否し、メッセージは「unexpected indentation」にした。この修正はこのファイルの生き残り 381・332 とは別の話で、2 件とも修正前の `parseSequence` で確認済み。修正後も同じテストが通る。

## 残っているもの

- id 327 (行 274)。分類 5 の報告のみ。続き行の空行と、折りたたみ形 `>` の空行 (段落の区切りは改行 1 個になるはずが、`owned.join(" ").replace("  ", " ")` で空白 1 個になる。行 228) が YAML と食い違う。どちらも何を返すべきか (折りたたむか、サブセットの外として拒否するか) の判断が要るので直していない。テストも書いていない。
- 判断のつかないもの (変異ではなく、読んでいて見つけた)。いずれもテストで固定していない。
  - `[a, ]` (末尾のカンマ) が `["a", null]` になる (行 157 の `or items.len > 0`)。YAML では `["a"]`。
  - `|+` で行の無いブロックスカラが `"\n"` になる (行 231 の `1 + trailing`)。YAML では空文字列。
  - `'it''s': v` (単引用符のキーの中の `''`) を「quoted key must be followed by ":"」で拒否する (行 176 の `splitKey` が引用符の二重化を見ない)。安全な側の失敗。
  - ブロックスカラの中の `#` で始まる行 (Markdown の見出しなど) は注釈として空行になる (行 330)。`description: |` の中身が欠ける。
- 上の欠陥と 327 を除いて、受け入れた (分類 6) ものは無い。
- 分類 4 は 233・234・265 (行 90)、290 (行 173)、246 (行 331)、343 (行 341)、449 (行 348)。ソースは消していない。
