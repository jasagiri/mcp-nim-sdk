# G2 変異検出: ext_skills ジョブのうち frontmatter.nim 以外

測定: `nim-muter`、ジョブ `tests/mutation/ext_skills.json`、拡張ブランチの c9b5c264 (初回の測定)。この文書が扱うのは `src/ext/skills/catalog.nim`、`consumer.nim`、`model.nim` の生き残り 53 件。`frontmatter.nim` (96 件) と `src/ext/skills.nim` は `g2x-skills-fm` の担当で、ここでは触れない。

| ファイル | 全変異 | killed | timeout | survived | runError | compileError |
|---|---:|---:|---:|---:|---:|---:|
| catalog.nim | 96 | 74 | 0 | 18 | 0 | 4 |
| consumer.nim | 38 | 32 | 0 | 6 | 0 | 0 |
| model.nim | 128 | 93 | 0 | 29 | 0 | 6 |
| 計 | 262 | 199 | 0 | 53 | 0 | 10 |

timeout はこの 3 ファイルには 1 件も無い (ジョブ全体の 34 件はすべて frontmatter.nim)。

## 分類

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

## 生き残り

### model.nim

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

### catalog.nim

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

### consumer.nim

| id | 行 | 変異 | 元 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|:-:|---|
| 479 | 113 | BLR | `getSkill` の `clientDeclares = false` → `true` | 3 | 拡張を宣言しないクライアントが `getSkill` を呼ぶと McpUnsupportedError になる。仕様はクライアントに宣言を求めない。`Given a client that declared nothing, when it gets a skill by URI, then it is served` |
| 458 | 164 | AOR | `skill.retrieved + listed.get.size` → `-` | 3 | 取得済みの量を足した事前の検査が消え、上限を超える読みを要求してから退ける。事後の検査が同じ型の例外を出すので、要求の数で見分ける。`Given a listed file of 9 MiB read twice, when the second read would pass 16 MiB, then SkillsError is raised without a second request` |
| 463 | 164 | ROR | `> MaxSkillBytes` → `>=` | 3 | ちょうど 16 MiB の skill が事前の検査で拒否される。`Given a listed SKILL.md of exactly 16 MiB, when it is read, then the limit is not passed and the bytes come back` |
| 465 | 177 | ROR | `retrieved + bytes.len > MaxSkillBytes` → `>=` | 3 | 同じテスト (事後の検査で拒否される)。 |
| 475 | 216 | LOR | `entry.dynamic or current.dynamic` → `and` | 1 | 動的な entry の `contentBinding` は空文字列で、静的な entry は少なくとも SKILL.md を持つので空でない。片方だけ動的なら 2 つの binding が必ず異なり、`changed` は true のまま。両方動的なら変異後も true。両方静的なら第 1 項は元から偽。 |
| 483 | 238 | BLR | `listDirectory` の `clientDeclares = false` → `true` | 3 | 479 と同じ。`Given a client that declared nothing, when it reads a directory of a server with directoryRead, then it is served` |

## 残っているもの

- 分類 4 の 2 件 (id 118、85): `src/ext/skills/model.nim:119-121` の `except ValueError` は、標準ライブラリの `decodeUrl` が例外を出さないので到達しない。コードの削除はしていない。リードの判断: 削除する場合、`isSafeSegment` の `try` ごと消して `decoded = decodeUrl(segment, decodePlus = false)` にできる。
- 分類 6 の 1 件 (id 132、`catalog.nim:208`、`files.len + 1` → `files.len - 1`): 事前の上限検査の数え方が 2 つずれても、拒否される入力の集合は変わらない。512 を超えた最初のファイルで退けるか、2 つ読んでから退けるかの差で、後ろの `addSkill` の `checkLimits` が同じ文言で退ける。読んだファイル数に応じて文言の数が変わる (513 か、全ファイル数か) だけで、この数は仕様でも docstring の約束でもない。数を値で固定するテストは実装の写しになるので書かなかった。許容する。
- 分類 3 の 164 は、`locate` の条件が副作用の有無だけを分けているという読みに基づく。提供元を数える以外に見える違いは見つからなかった。
- 追加したテストには、nil を渡すと変異によって異常終了するものがある (id 71、79、78、77、161、173)。終了コードで検出されるが、落ちたテスト名は出ない。
- `docs/quality/g2-protocol-versions.md` の「未測定」の表は、ジョブ全体 (frontmatter.nim を含む) が終わるまで触らない。
