# G2 変異検出: `src/transport/stdio.nim`

測定: `nim-muter`、ジョブ `tests/mutation/stdio.json`、mainline の 36a4c8a5 (2026-10-07)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 64 | 20 | 15 | 26 | 0 | 3 |

## timeout 15 件

id 4, 10, 12, 14, 15, 26, 27, 28, 30, 31, 38, 41, 42, 46, 48。どれも変異で読み取り側が非ブロッキングでなくなる、行が読み取りの結果に入らない、
または要求が相手に書かれないために、テストが「来るはずの行・応答」を待ち続けて止まったもの。待っている相手が実際に来ないのだから、検出として数えてよい。
個別の調査はしていない。

## survived 26 件

分類は、1 = 同値、2 = 別テストで検出、3 = 穴 (新しい外部仕様テストを足した)、6 = 受け入れ。
クラス 3 の行は、変異を手で当てて `tests/test_stdio.nim` が落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは戻した)。

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 7 | stdio.nim:51 | ROR | `newline < 0` → `<= 0` | 3 | 先頭が空行の入力で、空行が行として取り出されなくなる。`Given blank lines, CRLF, several lines in one write and a last line without a newline, ...` |
| 56 | stdio.nim:52 | RVR | `return none(string)` → 既定値 | 1 | `Option[string]` の既定値は none で、元の戻り値と同じ。 |
| 25 | stdio.nim:55 | SDL | `line.removeSuffix('\r')` → 削除 | 1 | `line` の使い道は `strip()` と `parseJson` だけで、どちらも `\r` を空白として読む。CRLF の行は変異ありでも同じ JSON になる (手で当てて、25 件すべて通ることを確かめた)。 |
| 8 | stdio.nim:64 | ROR | `buffer.len == 0` → `!= 0` | 3 | 入力の終わりで、最後の改行なしの行が失われ、空の行が返り続ける。`Given blank lines, CRLF, ...` ほか 4 件 |
| 58 | stdio.nim:65 | RVR | `return none(string)` → 既定値 | 1 | id 56 と同じ。 |
| 59 | stdio.nim:69 | RVR | `return some(rest)` → none | 3 | 改行のない最後の行が失われる。`Given blank lines, CRLF, ...` |
| 9 | stdio.nim:70 | ROR | `>` → `>=` | 3 | 上限ちょうどの長さのメッセージが、改行が遅れて届くだけで拒否される。`Given a message of exactly the size limit that is completed by its newline only later, ...` |
| 17 | stdio.nim:75 | BLR | `atEnd = true` → `false` | 3 | 入力の終わりに達しても終わりを報告せず、読み取りが止まらない。`Given blank lines, CRLF, ...` ほか 4 件 |
| 18 | stdio.nim:88 | BLR | `answersParseErrors: true` → `false` (descriptors 版) | 3 | stdin 版のサーバーが JSON でない行に parse error を返さなくなる。`Given a line that is not JSON on a server's stdin, when it reads, then it answers a parse error with a null id and reads on` |
| 32 | stdio.nim:93 | SDL | `reader.file.close()` → 削除 | 3 | close 後も stdin の記述子が開いたまま。`Given a server that closed its transport, when it looks at its stdin descriptor, then it is released` |
| 61 | stdio.nim:106 | RVR | `return none(string)` → 既定値 | 1 | id 56 と同じ。 |
| 34 | stdio.nim:109 | SDL | `output.flush()` → 削除 | 3 | 送ったメッセージが出力ストリームに押し出されない (`StringStream` の flush は何もしないので、既存のテストは見ていなかった)。`Given a message sent over a stream, when the send completes, then the stream has been flushed` |
| 35 | stdio.nim:111 | SDL | `input.close()` → 削除 | 3 | `Given a transport over streams, when it is closed, then both streams are closed` |
| 36 | stdio.nim:112 | SDL | `output.close()` → 削除 | 3 | 同上。 |
| 20 | stdio.nim:117 | BLR | `while true` → `while false` | 3 | 子の stderr を転送せず、子が詰まる。`Given a child that fills its stderr, when the client connects, then the child is not stalled and its diagnostics appear on the client's stderr` |
| 11 | stdio.nim:119 | ROR | `chunk.len == 0` → `!= 0` | 3 | 最初の塊のあとで転送をやめる (子が詰まる)。同上。 |
| 37 | stdio.nim:121 | SDL | `stderr.write(chunk)` → 削除 | 3 | 転送した診断が自分の stderr に出ない。同上。 |
| 21 | stdio.nim:145 | BLR | `answersParseErrors: false` → `true` (process 版) | 3 | クライアントが、サーバーの出力した雑音に parse error を返してしまう。`Given a server that prints a line that is not JSON, when the client reads on, then it does not answer the noise to the server` |
| 45 | stdio.nim:159 | SDL | `toChild.close()` → 削除 | 3 | 子の stdin が閉じられず、子が自分では終わらない。`Given a child that exits when its stdin closes, ...` ほか 1 件 |
| 49 | stdio.nim:181 | SDL | 「無視した行」の診断 → 削除 | 3 | 無視した行が痕跡なく消える (エラーを黙殺しない原則)。診断の全文ではなく、「無視した」と名指す句が stderr に出ることを見る。`Given a line that is not JSON, when a server reads it, then the diagnostic names the line as ignored on stderr` |
| 13 | stdio.nim:188 | ROR | `waited >= ms` → `> ms` | 6 | 待ちの上限が 20 ms (`ExitPollMs` 1 回分) 延びるだけ。時間の定数で、仕様はこの長さを定めていない。 |
| 63 | stdio.nim:189 | RVR | `return false` → 既定値 | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_stdio.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
| 23 | stdio.nim:189 | BLR | `return false` → `return true` | 3 | 猶予が切れても終了したことにされ、terminate も kill もされない。`Given a child that ignores the closing of its stdin, ...` ほか 1 件 |
| 54 | stdio.nim:198 | SDL | `terminate()` → 削除 | 3 | `Given a child that ignores the closing of its stdin, when the client closes the transport, then the child is terminated` (SIGTERM でなく SIGKILL で終わる) |
| 55 | stdio.nim:200 | SDL | `kill()` → 削除 | 3 | `Given a child that also ignores SIGTERM, when the client closes the transport, then the child is killed` |
| 53 | stdio.nim:202 | SDL | `process.close()` → 削除 | 3 | 子のパイプの記述子が閉じられない。`Given a client, when it closes the transport, then the descriptors of the child's pipes are released` |

## 追加したテストと仕様

- `tests/test_stdio.nim`: 14 件を追加 (前回の未完のパッチを元に、1 件ずつ変異で確かめたもの + id 18、34、49 のための 3 件)。
- `specs/stdio_transport.feature` に MCP-STDIO-5 (サーバーが自分の記述子を読み書きする) と MCP-STDIO-6 (クライアントが起動した子の面倒を見る) を追加し、`specs/tests.map` に対応を書いた。
- `tests/mutation/stdio.json` の `testCommand` は変更なし (`test_stdio` を既に含む)。

## 残っているもの

- id 13 (受け入れ): 待ちの上限が `ExitPollMs` 1 回分ずれるだけの時間定数。
- 同値 (id 25, 56, 58, 61, 63) は上表の理由のとおり。
- 子が終了を拒むテスト (`--sstubborn`、`--sdeaf`) は、最悪の場合に 4 秒 (猶予 2 秒 × 2) かかる。
- 他に未決のものはない。

## 未測定（2026-10-17）

- `newProcessTransport` の `env`・`workingDir` と `defaultServerEnvironment`（MCP-STDIO-13）は、上の測定のあとに足した。E テストは `tests/external/test_stdio.nim` の 4 件。push の前にまとめて測る。
