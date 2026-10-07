# G2 変異検出: diagnostic ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/diagnostic.json` (`src/protocol/diagnostic.nim`: `peerText`)、本線の 36a4c8a5 (2026-10-07)。
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
