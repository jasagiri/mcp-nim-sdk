# G2 変異検出: `src/transport/stdio.nim`

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: 変異検査の道具 0.2.15、ジョブ `tests/mutation/stdio.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。
状態: 測定済み。仕分けはコードと E テストを読んで行い、変異を手で当てて確かめてはいない。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 67 | 43 | 15 | 6 | 0 | 3 |

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/transport/stdio.nim:RVR:0c511227513989c7:0` | stdio.nim:52 | `return none(string)` → `return default` (`takeLine`) | equivalent | 戻り値の型は `Option[string]` で、`default(Option[string])` は none。元の戻り値と同じ値が返る (リテラルの反転には当たらない)。 | 無し |
| `src/transport/stdio.nim:SDL:6dc841eeff259190:0` | stdio.nim:55 | `line.removeSuffix('\r')` → `discard` | equivalent | `takeLine` の行の使い道は `receiveMessage` の `strip()` と `parseJson` だけで、どちらも行末の `\r` を空白として読み飛ばす。CRLF の行は変異の後も同じ JSON になり、空行の判定も変わらない。違いが出るのは JSON でない行の診断の文面の中だけ。前の測定 (id 25) でも手で当てて全件通ることを確かめている。 | 無し |
| `src/transport/stdio.nim:RVR:0c511227513989c7:1` | stdio.nim:65 | `return none(string)` → `return default` (`nextLine` の入力の終わり) | equivalent | 上の 52 行と同じ。`default(Option[string])` は none。 | 無し |
| `src/transport/stdio.nim:RVR:fdbf531f9d8a1825:0` | stdio.nim:106 | `return none(string)` → `return default` (ストリーム版の `readLine`) | equivalent | 上の 52 行と同じ。`default(Option[string])` は none。 | 無し |
| `src/transport/stdio.nim:LOR:8fbf38d7885b9d32:0` | stdio.nim:134 | `existsEnv(name) and not value.startsWith("()")` → `or` | test_owed | 変異だと、この過程に無い基本の変数 (例: `TERM` を消した状態) が空の値で表に入り、サーバーに空の変数として渡る。`()` で始まる値 (シェル関数) も渡る。既存の `tests/external/test_stdio.nim` の「only the basic variables pass」は、在る変数 (`PATH`・`HOME`) と基本でない変数しか見ていない。 | MCP-STDIO-13。`tests/external/test_stdio.nim` に 1 件: 基本の変数の 1 つ (例: `TERM`) を `delEnv` で消してから `defaultServerEnvironment()` を作り、`not env.hasKey("TERM")` を見る (後で元の値に戻す)。変異だと `env["TERM"] == ""` が入るので落ちる。補足: 「シェル関数は渡さない」は実装の doc コメントにだけあり、MCP-STDIO-13 の文には無い。仕様に足すなら、`putEnv("TERM", "() { :; }")` で `not env.hasKey("TERM")` を見る 1 件も同じ変異を殺す。 |
| `src/transport/stdio.nim:ROR:eaeea1ba334380e3:0` | stdio.nim:211 | `waited >= ms` → `>` (`exitedWithin`) | spec_question | 子が終了しないとき、terminate・kill に進むまでの待ちが 2000 ms から 2020 ms (`ExitPollMs` 1 回分) に延びる。進む順序と結果は変わらず、変わるのは時間だけ。MCP-STDIO-6 は順序を定めるが猶予の長さを定めていない。前の測定 (id 13) は「受け入れ」としたが、代表が決めた記録は無い。 | 問い: 子の終了を待つ猶予の長さ (`ExitGraceMs` = 2000 ms) を仕様の規則にしますか、それとも「猶予の長さは仕様の外」と決めてこの変異を受け入れますか。 |

### 時間切れ 15 件の見立て

15 件とも、(i) 変異そのものがテストを止める (読み書きの輪が回り続ける、または来ない行・応答を待ち続ける) と読める。(ii) 負荷による偽の時間切れと疑う理由のあるものは無い。見立てはコードを読んだもので、変異を当てて止まる場所を確かめてはいない。

前の測定 (36a4c8a5、下の「timeout 15 件」) も 15 件だが、記録は id の並びだけで、行も指紋も無いので、1 件ずつの突き合わせはできない。前の記録が挙げる 3 つの原因 (非ブロッキングでなくなる・行が結果に入らない・要求が書かれない) は、下の 15 件の原因と重なる。

| 指紋 | file:line | 変異 | 見立て | 止まる仕組み |
|---|---|---|---|---|
| `src/transport/stdio.nim:LOR:0d6691ff5530d803:0` | stdio.nim:45 | `flags == -1 or fcntl(F_SETFL) == -1` → `and` | (i) | `flags` が取れると `F_SETFL` が呼ばれず、記述子がブロッキングのまま残る。`asyncfile` の `read` は登録の前にまず直に `read` を呼ぶので、相手が黙っている間スレッドごと止まり、タイマーも送信も動かない。 |
| `src/transport/stdio.nim:LOR:94e823247a1b3d9e:0` | stdio.nim:45 | `flags or O_NONBLOCK` → `and` | (i) | `O_NONBLOCK` が立たない (立っていないフラグとの `and` は 0)。上と同じくブロッキングの `read` でスレッドが止まる。 |
| `src/transport/stdio.nim:AOR:1f7b99d4571d2325:0` | stdio.nim:54 | `newline + 1` → `newline - 1` | (i) | 行を取り出しても改行とその前の 1 文字がバッファに残り、`takeLine` が同じ 1 文字の行を返し続ける。`receiveMessage` は JSON でない行として読み飛ばし続け、待ちを挟まない無限ループになる。 |
| `src/transport/stdio.nim:SDL:9c08ad6736e9d1c4:0` | stdio.nim:56 | `some(line)` → `discard` | (i) | `takeLine` が行をバッファから消したうえで none を返す。届いた行がすべて失われ、相手が生きている間 (例: `started()` の `receiveMessage`) 次の行を待ち続ける。 |
| `src/transport/stdio.nim:ROR:e13fdd1bec09d7de:0` | stdio.nim:74 | `chunk.len == 0` → `!=` | (i) | 入力の終わりで `atEnd` が立たず、空の塊をバッファに足して読み直す。終わりの `read` はすぐ空を返すので、待ちを挟まない無限ループになる (データが届いた側は逆に「終わり」とされて捨てられる)。 |
| `src/transport/stdio.nim:SDL:69fa48aa22ccc1fa:0` | stdio.nim:77 | `reader.buffer.add chunk` → `discard` | (i) | 読んだ塊がバッファに入らず、行が 1 つもできない。相手が生きている間、行を待ち続ける。 |
| `src/transport/stdio.nim:SDL:d8baf54a9ef37a10:0` | stdio.nim:80 | `setNonBlocking(fd)` → `discard` (`asyncReader`) | (i) | 読み取りの記述子がブロッキングのまま。受信の輪が次の行を読みに行くとスレッドごと止まり、相手が待っている次の要求を送れない。 |
| `src/transport/stdio.nim:SDL:26fc844231aa356e:0` | stdio.nim:91 | `stdout.write(line & "\n")` → `discard` | (i) | サーバーの過程が stdout に何も書かない。親 (テスト) は来ない応答・通知を待ち続ける。 |
| `src/transport/stdio.nim:SDL:a294db411784cdab:0` | stdio.nim:92 | `stdout.flushFile()` → `discard` | (i) | stdout がパイプのときは全バッファリングで、書いた行が過程の終わりまで出ない。サーバーは次の入力を待ち、親は応答を待つので、互いに待ち続ける。 |
| `src/transport/stdio.nim:SDL:12488fcaf40f1ddc:0` | stdio.nim:162 | `setNonBlocking(errFd)` → `discard` | (i) | `forwardStderr` は `asyncCheck` の中で最初の `read` まで同期で進む。stderr がブロッキングだと、子が stderr に書くか終わるまで `newProcessTransport` が戻らない。子は要求を待っているので止まる。 |
| `src/transport/stdio.nim:SDL:63ff4225d06fbd96:0` | stdio.nim:173 | `toChild.writeLine(line)` → `discard` | (i) | 子に何も書かれない。クライアントは来ない応答を待ち続ける。 |
| `src/transport/stdio.nim:SDL:eede5e20983bba4e:0` | stdio.nim:174 | `toChild.flush()` → `discard` | (i) | 子の stdin へのストリームはバッファつきで、小さい要求はバッファに残ったまま子に届かない。クライアントは応答を待ち続ける。 |
| `src/transport/stdio.nim:SDL:139da2d2fbaff24e:0` | stdio.nim:186 | `await t.writeLine(encodeMessage(request))` → `discard` (`sendRequest`) | (i) | 要求が送られない。応答が来ないので、要求を出した側が待ち続ける。 |
| `src/transport/stdio.nim:SDL:9b2a27edaa28bf34:0` | stdio.nim:192 | `await t.writeLine(encodeMessage(response))` → `discard` (`sendResponse`) | (i) | 応答が送られない。相手が待ち続ける。 |
| `src/transport/stdio.nim:ROR:12e9d63086392e16:0` | stdio.nim:199 | `line.get.strip().len == 0` → `!=` | (i) | 空でない行がすべて読み飛ばされ、メッセージが 1 つも返らない。相手が生きている間 (例: `started()` の `receiveMessage`) 待ち続ける。 |

以下は前の測定の記録 (行番号は古い)。

測定: 変異検査の道具、ジョブ `tests/mutation/stdio.json`、mainline の 36a4c8a5 (2026-10-07)。

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
| 63 | stdio.nim:189 | RVR | `return false` → 既定値 | 2 | **訂正 (2026-10-10)**: 同値ではない。変異検査の道具 の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_stdio.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
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
