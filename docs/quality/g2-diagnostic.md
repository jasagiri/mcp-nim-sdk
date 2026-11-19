# G2 変異検出: diagnostic ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: 変異検査の道具 0.2.15、ジョブ `tests/mutation/diagnostic.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 37 | 5 | 0 | 32 | 0 | 0 |

状態: 測定済み。仕分けは test_owed 30 件、equivalent 1 件、undecided 1 件。

`peerText` は公開の入口 (`src/mcp.nim`) から export されていない (`plainMessage` だけが `server/errors` 経由で出ている)。
外から確かめる道は診断の行で、いちばん素直なのは `src/server/server.nim` の `resolveResponse` が書く
`[mcp-server] response to unknown request id '<peerText(id)>' ignored` である (版に依らない。今の E テストの 2 本目と同じ道)。
id は JSON の文字列で、長さも文字種も相手が決める。受け取る側に UTF-8 の検査は無い (`transport.nim` の `requireUtf8` は送る側だけ) ので、
不正なバイトもそのまま `peerText` に届く。`peerText` を呼ぶ箇所はどれも `maxLen` を渡さないので、上限は常に 200 バイト。
今の E テスト 3 本は ASCII の `\n` と ESC しか入れておらず、ASCII でない文字・不正なバイト・CR・タブ・`\`・200 バイトを超える長さを通るものが無い。
以前それらを殺していたテストは `tests/internal/test_security_diagnostic_internal.nim` に移っている。

変異の形は木の上で読んだ: `a or b or c` の 2 つ目の `or` を `and` にした変異は `(a or b) and c` である (一覧の「元の式」が左からの入れ子を示している)。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/protocol/diagnostic.nim:ROR:f62a603f6f9989e5:0` | diagnostic.nim:17 | `c < 0x20` → `<=` | undecided | 違いが出るのは `isUnsafe` に 0x20 が届くときだけで、それは過剰に長い 3・4 バイトの符号化 (`\xe0\x80\xa0`) でしか作れない。`validateUtf8` はこれを通す (断るのは 2 バイトの `\xc0`・`\xc1` だけ) ので外から届き、元は生のバイトを、変異後は `\u{0020}` を出す。仕様は「不正な UTF-8 はエスケープ」なので、仕様どおりのテスト (`\xe0\x80\xa0` と出る) は元のコードでも落ちる。下の「見つけたこと」の扱いが決まるまで分類できない。前の記録の「到達不能」は 3・4 バイトの過剰な符号化を見落としている。 | MCP-SEC-HTTP-7 (2 つ目の Then)。実装の扱いが決まってから。 |
| `src/protocol/diagnostic.nim:LOR:fcb0f213fea5eeda:0` | diagnostic.nim:17 | `c < 0x20 or c in 0x7F..0x9F` → `and` | test_owed | C1 の制御文字 (U+0080〜U+009F) が危険と判定されなくなり、生のまま出る。 | MCP-SEC-HTTP-7。T-A。 |
| `src/protocol/diagnostic.nim:LOR:fa4e730b52ed8737:0` | diagnostic.nim:17 | `(… or C1) or c in 0x2028..0x2029` → `and` | test_owed | C1 と行区切り (U+2028・U+2029) が生のまま出る。 | MCP-SEC-HTTP-7。T-A。 |
| `src/protocol/diagnostic.nim:LOR:70124a7496d6cde1:0` | diagnostic.nim:17 | `(…) or c in 0x202A..0x202E` → `and` | test_owed | C1・行区切り・双方向の上書き (U+202A〜U+202E) が生のまま出る。 | MCP-SEC-HTTP-7。T-A。 |
| `src/protocol/diagnostic.nim:LOR:1875a78402bde8c6:0` | diagnostic.nim:18 | `(…) or c in 0x2066..0x2069` → `and` | test_owed | 上に加えて双方向の分離 (U+2066〜U+2069) が生のまま出る。 | MCP-SEC-HTTP-7。T-A。 |
| `src/protocol/diagnostic.nim:LOR:4db97eab93bd210d:0` | diagnostic.nim:18 | `(…) or c in 0x200E..0x200F` → `and` | test_owed | 上に加えて方向の印 (U+200E・U+200F) が生のまま出る。 | MCP-SEC-HTTP-7。T-A。 |
| `src/protocol/diagnostic.nim:LOR:4a79c915cd9887d5:0` | diagnostic.nim:18 | `(…) or c == 0x061C` → `and` | test_owed | `isUnsafe` が常に偽になり、危険な符号位置がどれも生のまま出る。 | MCP-SEC-HTTP-7。T-A。 |
| `src/protocol/diagnostic.nim:ROR:e517dd59b589c0bd:0` | diagnostic.nim:19 | `c == 0x061C` → `!=` | test_owed | U+061C が生のまま出て、ほかの ASCII でない文字 (日本語など) がすべて `\u{…}` になる。 | MCP-SEC-HTTP-7。T-A (U+061C) と T-B のどちらでも落ちる。 |
| `src/protocol/diagnostic.nim:ROR:0b5bb378a98ab5b1:0` | diagnostic.nim:28 | `result.len >= maxLen` → `>` | test_owed | 201 バイトの id で、元は 200 バイトと `...(1 more bytes)`、変異後は 201 バイトを出して印が付かない。 | MCP-SEC-HTTP-7 (3 つ目の Then)。T-E。 |
| `src/protocol/diagnostic.nim:SDL:bedba8565d355504:0` | diagnostic.nim:29 | `result.add "...(" & … & " more bytes)"` → `discard` | test_owed | 切られるが、省いたバイト数が出ない。仕様が「省いたバイト数を添える」と定めている。 | MCP-SEC-HTTP-7 (3 つ目の Then)。T-E。 |
| `src/protocol/diagnostic.nim:AOR:6b522035e597db10:0` | diagnostic.nim:29 | `text.len - i` → `+` | test_owed | 省いたバイト数が誤る (201 バイトで 1 が 401 になる)。 | MCP-SEC-HTTP-7 (3 つ目の Then)。T-E (数を厳密に比べる)。 |
| `src/protocol/diagnostic.nim:ROR:48b5b1e65fb8be17:0` | diagnostic.nim:32 | `byte < 0x80` → `<=` | test_owed | 単独の 0x80 が ASCII の枝に入り、生のバイトのまま出る (元は `\x80`)。 | MCP-SEC-HTTP-7 (2 つ目の Then)。T-C。 |
| `src/protocol/diagnostic.nim:SDL:43108caf3797537b:0` | diagnostic.nim:35 | `result.add "\\r"` → `discard` | test_owed | CR が `\r` と出ずに消える。 | MCP-SEC-HTTP-7 (1 つ目の Then)。T-D。 |
| `src/protocol/diagnostic.nim:SDL:05907b3a8a88873d:0` | diagnostic.nim:36 | `result.add "\\t"` → `discard` | test_owed | タブが `\t` と出ずに消える。 | MCP-SEC-HTTP-7 (1 つ目の Then)。T-D。 |
| `src/protocol/diagnostic.nim:SDL:040de086e4543697:0` | diagnostic.nim:37 | `result.add "\\\\"` → `discard` | test_owed | 打たれた `\` が消え、相手が書いた文字が黙って欠ける。Scenario の文は `\` を名指していないが、`\` を重ねないと「エスケープで示す」が読み分けられない (打たれた `\n` と本物の改行)。`specs/tests.map` も内部側の `Given tab and backslash …` をこの ID に結んでいる。 | MCP-SEC-HTTP-7。T-D。 |
| `src/protocol/diagnostic.nim:ROR:7bb30c62fcdcda1c:0` | diagnostic.nim:44 | `byte >= 0xF0` → `>` | test_owed | 0xF0 で始まる 4 バイトの文字 (絵文字など) が幅 3 と読まれ、正しい文字が `\xf0\x9f\x98\x80` に崩れる。 | MCP-SEC-HTTP-7。T-B。 |
| `src/protocol/diagnostic.nim:ROR:dbf4729dd5d1e62b:0` | diagnostic.nim:44 | `byte >= 0xE0` → `>` | test_owed | 0xE0 で始まる 3 バイトの文字 (U+0800〜U+0FFF) が幅 2 と読まれ、`\xNN` に崩れる。 | MCP-SEC-HTTP-7。T-B。 |
| `src/protocol/diagnostic.nim:ROR:28550222ab53f681:0` | diagnostic.nim:44 | `byte >= 0xC0` → `>` | equivalent | 違うのは先頭が 0xC0 のときだけ。元は幅 2 を取るが、末尾なら長さの検査で、そうでなければ `validateUtf8` (0xC2 未満の先頭を断る) で断られ、変異後は幅 0 で断られる。どちらも `\xc0` を出して 1 バイト進む。 | — |
| `src/protocol/diagnostic.nim:ROR:8799fc3d224eccb1:0` | diagnostic.nim:45 | `width == 0` → `!=` | test_owed | 幅のある先頭バイトがすべて `\xNN` になり、正しい文字が崩れる。続きのバイトは断られずに先へ進み、`i` が進まない (0x80〜0x9F は `\u{…}` を上限まで繰り返す。0xA0〜0xBF は止まらない)。 | MCP-SEC-HTTP-7。T-B (変異後は止まらないので時間切れで落ちる)。 |
| `src/protocol/diagnostic.nim:LOR:de6a8860a5052e97:0` | diagnostic.nim:45 | `width == 0 or i + width > text.len` → `and` | test_owed | 幅 0 のバイトが断られなくなる: 単独の 0x80 は `\x80` ではなく `\u{0080}` の繰り返しになる。末尾で切れた文字は範囲外の切り出しで IndexDefect になる。 | MCP-SEC-HTTP-7 (2 つ目の Then)。T-C。 |
| `src/protocol/diagnostic.nim:AOR:fdd68f222fb279b6:0` | diagnostic.nim:45 | `i + width > text.len` の `+` → `-` | test_owed | 長さの検査が常に偽になり、末尾で切れた文字 (`\xe3\x81`) で `text[i ..< i + width]` が範囲外になって IndexDefect で落ちる (元は `\xe3\x81` と出す)。 | MCP-SEC-HTTP-7 (2 つ目の Then)。T-C (末尾を切れた文字にする)。 |
| `src/protocol/diagnostic.nim:ROR:128914bf1f19073b:0` | diagnostic.nim:45 | `i + width > text.len` → `>=` | test_owed | 文字列の最後にある正しい文字が `\xNN` に崩れる。 | MCP-SEC-HTTP-7。T-B (id の最後を ASCII でない文字にする)。 |
| `src/protocol/diagnostic.nim:LOR:a2ccf15b9a50e7b7:0` | diagnostic.nim:45 | `(width == 0 or i + width > text.len) or validateUtf8(…) != -1` → `and` | test_owed | 長さが足りていて中身が不正な列 (`\xc3` の後が ASCII) が断られず生のまま出る。単独の 0x80 は `\u{0080}` の繰り返しになる。 | MCP-SEC-HTTP-7 (2 つ目の Then)。T-C。 |
| `src/protocol/diagnostic.nim:AOR:1382231a9c1cfae9:0` | diagnostic.nim:46 | `text[i ..< i + width]` の `+` → `-` | test_owed | 検査に渡す切り出しの長さが負になる。検査つきのビルドでは正しい文字でも RangeDefect で落ち、落ちない設定では空文字列が常に「正しい」となって不正な列が生のまま出る。 | MCP-SEC-HTTP-7。T-B と T-C (どちらの設定でも片方が落ちる)。 |
| `src/protocol/diagnostic.nim:ROR:027dbfbca2e39cc2:0` | diagnostic.nim:46 | `validateUtf8(…) != -1` → `==` | test_owed | 正しい文字が `\xNN` に崩れ、不正な列が生のまま出る。 | MCP-SEC-HTTP-7。T-B と T-C のどちらでも落ちる。 |
| `src/protocol/diagnostic.nim:SDL:4013ad9dd59379cc:1` | diagnostic.nim:47 | `result.add "\\x" & toHex(byte, 2).toLowerAscii()` → `discard` | test_owed | 不正なバイトがエスケープで示されずに消える。 | MCP-SEC-HTTP-7 (2 つ目の Then)。T-C。 |
| `src/protocol/diagnostic.nim:SDL:c7f896b75934631c:1` | diagnostic.nim:48 | `inc i` → `discard` | test_owed | 不正なバイトで `i` が進まず、同じ `\xNN` を上限まで繰り返して切れる (止まる。無限ループではない)。 | MCP-SEC-HTTP-7 (2 つ目の Then)。T-C。 |
| `src/protocol/diagnostic.nim:SDL:82106f2368aa9ccc:0` | diagnostic.nim:51 | `fastRuneAt(text, i, r, doInc = false)` → `discard` | test_owed | `r` が 0 のままで `isUnsafe` が常に真になり、正しい文字がすべて `\u{0000}` と出る。 | MCP-SEC-HTTP-7。T-B。 |
| `src/protocol/diagnostic.nim:BLR:250308d303f8b8b0:0` | diagnostic.nim:51 | `doInc = false` → `true` | test_owed | `i` が 2 回進み、文字を 1 つおきに飛ばす (次の文字を出すか、範囲外で IndexDefect)。 | MCP-SEC-HTTP-7。T-B (ASCII でない文字を 2 つ以上続ける)。 |
| `src/protocol/diagnostic.nim:SDL:22125ada0be2b99c:0` | diagnostic.nim:53 | `result.add "\\u{" & … & "}"` → `discard` | test_owed | 危険な符号位置が `\u{…}` で示されずに消える。仕様は「エスケープで示す」。 | MCP-SEC-HTTP-7 (1 つ目の Then)。T-A。 |
| `src/protocol/diagnostic.nim:SDL:6e2e25fc43b76a80:0` | diagnostic.nim:55 | `result.add text[i ..< i + width]` → `discard` | test_owed | 正しい ASCII でない文字がすべて消える。 | MCP-SEC-HTTP-7。T-B。 |
| `src/protocol/diagnostic.nim:AOR:bdd8bd961580b77e:0` | diagnostic.nim:55 | `text[i ..< i + width]` の `+` → `-` | test_owed | 出す切り出しの長さが負になり、正しい文字が出ない (検査つきのビルドでは RangeDefect で落ちる)。 | MCP-SEC-HTTP-7。T-B。 |

### 足すテストの案 (T-A 〜 T-E)

どれも `tests/external/test_security_diagnostic.nim` の 2 本目と同じ形: loopback でつないだサーバーに
`{"jsonrpc": "2.0", "id": <文字列>, "result": {}}` を入れ、stderr の `response to unknown request id '…' ignored` の行を見る。
行は 1 行であること (`logged.count('\n') == 1`) も併せて見る。

- **T-A 危険な符号位置**: id に U+0085・U+2028・U+202E・U+2066・U+200E・U+061C を ASCII の字で挟んで入れ、
  `\u{0085}`・`\u{2028}`・`\u{202e}`・`\u{2066}`・`\u{200e}`・`\u{061c}` がその順で出ること。
- **T-B 正しい文字はそのまま**: id を `é` (2 バイト)・`\xe0\xa0\x80` (U+0800、0xE0 で始まる最小)・`\xf0\x9f\x98\x80` (0xF0 で始まる)・`日本語` を続けたものにし、
  最後を ASCII でない文字で終える。行に id がそのまま含まれること。
- **T-C 不正なバイト**: id を `a\x80b\xc3cd\xe3\x81` (単独の続きのバイト・後ろが ASCII の先頭バイト・末尾で切れた文字) にし、
  `a\x80b\xc3cd\xe3\x81` がエスケープの文字として出ること。単独の続きのバイトは 0x80〜0x9F から選ぶ (0xA0 以上だと、変異 `de6a8860…`・`a2ccf15b…` が止まらなくなる)。
- **T-D CR・タブ・`\`**: id を CR・タブ・打たれた `\n` (2 文字) を含むものにし、`\r`・`\t`・`\\n` と出ること。
- **T-E 長さ**: id が `x` 200 個なら切られず印も無い。201 個なら `x` 200 個と `...(1 more bytes)`。225 個なら `...(25 more bytes)`。

### 見つけたこと (実装。仕分けの外)

`peerText` は、不正な UTF-8 の一部を生のバイトのまま出す。`validateUtf8` (Nim 2.2.14 の `lib/pure/unicode.nim` で確かめた) が断る過剰な符号化は
2 バイトの `\xc0`・`\xc1` だけで、3・4 バイトの過剰な符号化 (`\xe0\x80\xa0` など)、サロゲート (`\xed\xa0\x80`)、U+10FFFF を超える列 (`\xf4\x90\x80\x80`) は通る。
サロゲートを通すことは `src/transport/transport.nim` の `isUtf8` の注記にも書かれ、送る側はそれを補っているが、`peerText` は補っていない。
過剰な符号化で書いた制御文字 (`\xe0\x80\x9b` = ESC) は、復号した値が `isUnsafe` の `c < 0x20` に当たって `\u{001b}` になるので生では出ない。
つまり前の記録が「決して真にならない」とした `c < 0x20` の項は、いまこの穴を塞いでいる。
MCP-SEC-HTTP-7 の 2 つ目の Then (「不正な UTF-8 のバイトはエスケープで示す」) とは食い違う。直すかどうか、直すなら `isUtf8` と検査を 1 つにするかは、実装担当と司会の判断。

測定: 変異検査の道具、ジョブ `tests/mutation/diagnostic.json` (`src/protocol/diagnostic.nim`: `peerText`)、本線の 36a4c8a5 (2026-10-07)。
行番号は 36a4c8a5 のもの (`diagnostic.nim` はその後変わっていない)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 37 | 28 | 0 | 9 | 0 | 0 |

生き残り 9 件: 同値・到達不能 (1 と 4) 各 1 件ずつの計 2 件、穴 (3) 7 件。ほかの分類は 0 件。
`peerText` は相手が選んだ文字列をログに書くための関数なので、制御文字、不正なバイト、長さの上限を変える変異は 1 件も許容に回していない。
境界の変異は、それぞれ境界の上に載る入力を見つけてテストにした。
分類 3 の 7 件は、変異を 1 件ずつ手で当てて、追加したテストが落ちることを確かめた。
分類 1 と 4 の 2 件は、2 件を同時に当てても `test_security_diagnostic.nim` が全部 (13 件) 通ることを確かめた。
テストはすべて `tests/test_security_diagnostic.nim` にあり (ジョブの `testCommand` に既に入っている。ジョブの変更は無い)、版に依らない (`-d:mcpDefaultProtocolVersion=2024-11-05` でも通る)。
Scenario は既存の `MCP-SEC-HTTP-7` に結んだ。

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 5 | diagnostic.nim:17 | ROR | `c < 0x20` → `<=` | 4 到達不能 | `isUnsafe` に届くのは 2 バイト以上の列が正しく読めたルーンだけで (ASCII は 32 行の分岐が先に扱う)、0x20 以下のルーンは過剰に長い符号化でしか作れない。それは `validateUtf8` が断るので、`c < 0x20` の項は決して真にならない。`Given an overlong encoding of a control character ...` が、`\xc0\x80` が `\\xc0\\x80` になることを確かめている。項を消すかどうかはリードが決める (この関数は ESC などを ASCII 側の分岐で扱うので、消しても振る舞いは変わらない)。 |
| 12 | diagnostic.nim:44 | ROR | `byte >= 0xC0` → `>` | 1 同値 | 0xC0 は有効な符号列の先頭にならない (過剰な長さの符号化)。元のコードは幅 2 を取って `validateUtf8` に断られ、変異後は幅 0 になる。どちらも `\xc0` を出して 1 バイト進む。 |
| 8 | diagnostic.nim:28 | ROR | `result.len >= maxLen` → `>` | 3 穴 | 出力がちょうど上限に達したら、残りがあるとき切る (変異後は 1 文字多く出し、残りの印が出ない)。`Given text of exactly the limit and one byte more ..., then only the longer one is cut` (ちょうど上限の長さは切らないことも確かめる) |
| 1 | diagnostic.nim:29 | AOR | `text.len - i` → `text.len + i` | 3 穴 | 残りのバイト数 (`...(15 more bytes)`) を厳密に確かめる。同じテスト。 |
| 9 | diagnostic.nim:32 | ROR | `byte < 0x80` → `<=` | 3 穴 | 0x80 は ASCII ではなく、単独では何の文字も始めない。`\x80` は `\\x80` と出る (変異後はそのままのバイトが出る)。`Given a lone continuation byte ..., then it is shown as an escape` |
| 30 | diagnostic.nim:36 | SDL | `result.add "\\t"` → `discard` | 3 穴 | タブは `\t` と出る (変異後は消える)。`Given tab and backslash ...` |
| 31 | diagnostic.nim:37 | SDL | `result.add "\\\\"` → `discard` | 3 穴 | 文字どおりの `\` は `\\` と出る。そうしないと、打たれた `\n` と本物の改行がログで区別できない。同じテスト。 |
| 10 | diagnostic.nim:44 | ROR | `byte >= 0xF0` → `>` | 3 穴 | 0xF0 は 4 バイトの文字 (U+10000 以上、絵文字など) の最小の先頭。変異後は幅 3 になり、有効な文字が `\xNN` に崩れる。`Given characters of three and four bytes ...` が `\xf0\x9f\x98\x80` を確かめる。 |
| 11 | diagnostic.nim:44 | ROR | `byte >= 0xE0` → `>` | 3 穴 | 0xE0 は 3 バイトの文字の最小の先頭 (U+0800 以上)。変異後は幅 2 になり、有効な文字が崩れる。同じテストが `\xe0\xa0\x80` を確かめる。 |

## 残っているもの

id 5 は到達不能な項 (分類 4) で、コードは変えていない。`isUnsafe` の `c < 0x20` を消すか残すかはリードが決める。ほかには何も残っていない。

## 到達しないコードの扱い (リードの判断、2026-10-07: 残す)

- id 5 (`isUnsafe` の `c < 0x20`): `peerText` の中では ASCII が手前の分岐で処理されるので届かないが、`isUnsafe` は「この符号位置を表示してよいか」を
  単体で答える関数で、制御文字の範囲を落とすと意味が欠ける。次の測定でも生き残る。
