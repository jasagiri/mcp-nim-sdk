# G2 変異検出: `src/transport/event_stream.nim`

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/event_stream.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。状態: 測定済み。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 35 | 30 | 0 | 2 | 0 | 3 |

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/transport/event_stream.nim:ROR:40a8f14bb3a39089:0` | event_stream.nim:68 | `colon < 0` → `colon <= 0` (欄の名前を切り出す側) | equivalent | 差が出るのは `colon == 0`、つまり行が `:` で始まるときだけ。その行は同じ `takeLine` の 64 行目 (`if line[0] == ':': return`) でコメントとして捨てられ、67 行目の `find` に届かない (バイトオーダーマークを取るのは 53 行目で、64 行目より前)。`feed` にどんな入力を入れても `colon` は負か 1 以上。 | なし (前の測定の id 10 と同じ判断) |
| `src/transport/event_stream.nim:ROR:fa3c38a119e9cd73:0` | event_stream.nim:69 | `colon < 0` → `colon <= 0` (欄の値を切り出す側) | equivalent | 上の行と同じ。`colon == 0` の行は 64 行目で先に return するので、69 行目で `colon` が 0 になることは無い。 | なし (前の測定の id 11 と同じ判断) |

時間切れは無い。

測定: `nim-muter`、ジョブ `tests/mutation/event_stream.json`、mainline の 36a4c8a5 (2026-10-07)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 35 | 27 | 0 | 5 | 0 | 3 |

## survived 5 件

分類は、1 = 同値、3 = 穴 (新しい外部仕様テストを足した)。
クラス 3 の行は、変異を手で当てて `tests/test_event_stream.nim` が落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは戻した)。

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 21 | event_stream.nim:52 | BLR | `p.started = true` → `false` | 3 | バイトオーダーマークが、ストリームの先頭だけでなくすべての行で取り除かれる (WHATWG は先頭の 1 回だけ)。`Given a byte order mark after the first line, when read, then it stays part of that line's field name` (`MCP-SSE-1`) |
| 22 | event_stream.nim:60 | BLR | `p.hasData = false` → `true` | 3 | イベントを送り出したあとも data バッファが空でないことになり、続く空行ごとに data のない空のイベントが出る。`Given blank lines after an event, when read, then they dispatch nothing more` (`MCP-SSE-2`)。先頭以外の BOM のテストも同時に落ちる。 |
| 10 | event_stream.nim:68 | ROR | `colon < 0` → `<= 0` | 1 | `colon == 0` になるのは行が `:` で始まるときだけで、その行は 64 行目 (`line[0] == ':'` で return) でコメントとして捨てられ、67 行目に届かない。`colon` が 0 の入力は作れない。 |
| 11 | event_stream.nim:69 | ROR | `colon < 0` → `<= 0` | 1 | id 10 と同じ。 |
| 16 | event_stream.nim:117 | ROR | `p.line.len >= p.maxLineBytes` → `>` | 3 | 上限より 1 バイト長い行 (上限 + 1 バイト) まで受け入れる。上限ちょうどの行は通り、1 バイト多い行は `SseLimitError`。`Given a line of exactly the limit, when read, then it is accepted and one byte more raises SseLimitError` (`MCP-SSE-3`) |

## 残っているもの

なし。同値 2 件 (id 10, 11) は理由を上に書いた。
