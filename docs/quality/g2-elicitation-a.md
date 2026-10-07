# G2: elicitation (前半) の生き残り

`src/protocol/elicitation.nim` の 1 行目から 113 行目まで。ジョブ `elicitation` (36a4c8a5 の測定) のうち、この範囲の生き残りを 1 件ずつ分類する。後半 (114 行目以降と残り 3 ファイル) は `g2e-elicit-b` の担当。

ジョブ全体の数 (報告書): 変異 324 件、killed 217、timeout 3、survived 103、runError 0、compileError 1。
この範囲の生き残りは 46 件 (下表の全行)。

## 判断

生き残りの原因は、`formatProblem` の下請け関数 (`isEmailLike` / `isUriLike` / `isDate` / `isDateTime`) の境界条件を、良い値 1 つと悪い値 1 つでしか試していなかったこと。外部仕様 (MCP の `requestedSchema` の `format` は email / uri / date / date-time の 4 つ、値は RFC 5322 / RFC 3986 / RFC 3339 に従う) の事実として、境界の良い値と悪い値の表を 1 つのテストにした。

- 追加したテスト: `tests/test_elicitation_payload.nim` の「Given edge values of each string format, when checked, then exactly the valid ones pass」(`specs/tests.map` の MCP-ELICIT-3)。デフォルト版 2026-07-28 / 2025-11-25 / 2025-06-18 の 3 つで通る。
- class 3 の 35 件はすべて、変異を 1 件ずつ当てて、このテストが落ちる (またはループが終わらずタイムアウトになる) のを確認した。変異を戻した状態では通る。落ちた箇所は、`check` の失敗か IndexDefect (小数部の添字)。id 202 だけは終わらないためタイムアウトで止めた。
- 変異は、報告書の変異と同じ式になるよう優先順位を括弧で明示して当てた (id 118, 121, 120, 125)。
- 「戻り値 `default`」の変異 (RVR) は、`bool` の `default` が `false` で、元の `return false` と同じ式になる。

## 生き残り一覧

| id | file:line | mutator | original → replacement | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 187 | elicitation.nim:48 | BLR | `else: false` → `true` | 4 | `isInteger` は 376 行目で `isNumber` を通った値にしか呼ばれない (374 行目で先に return する)。`else` 枝は到達できない。リードの判断に任せる |
| 33 | :61 | ROR | `at > 0` → `>=` | 3 | `"@b.c"` は不正。edge values テスト |
| 35 | :61 | ROR | `at < text.high` → `<=` | 3 | `"a@"` は不正。同上 |
| 36 | :67 | ROR | `colon < 1` → `<=` | 3 | `"a:b"` (コロンが 1 文字目の後) は正しい。同上 |
| 119 | :67 | LOR | `colon < 1 or colon == text.high` の `or` → `and` | 3 | `"abc"` (コロンなし) と `"a:"` が不正。実測で落ちた |
| 118 | :67 | LOR | `... or text.contains(...)` の `or` → `and` | 3 | `"a:b c"` (空白入り) が不正。同上のテスト |
| 259 | :70 | RVR | `return false` → `return default` | 1 | `bool` の `default` は `false`。式として同じ |
| 189 | :70 | BLR | `false` → `true` | 3 | `"1a:x"`, `"+a:x"` (先頭が英字でない) は不正 |
| 26 | :72 | AOR | `Letters + Digits` → `Letters - Digits` | 3 | `"a1:x"` は正しい。実測で落ちた |
| 25 | :72 | AOR | `... + {'+', '-', '.'}` の `+` → `-` | 3 | `"a+b:x"`, `"a-b:x"`, `"a.b:x"` は正しい |
| 260 | :73 | RVR | `return default` | 1 | 259 と同じ |
| 190 | :73 | BLR | `false` → `true` | 3 | `"a_b:x"` は不正 |
| 121 | :78 | LOR | `text.len != 10 or text[4] != '-'` の `or` → `and` | 3 | `"2026-10-077"` (長さ 11、区切り位置は正しい) は不正。変異では桁の検査と月日の検査を通って受理される |
| 120 | :78 | LOR | 2 つ目の `or` → `and` | 3 | 121 と同じ値で落ちる (`(A or B) and C` で C が偽) |
| 261 | :79 | RVR | `return default` | 1 | 259 と同じ |
| 192 | :79 | BLR | `false` → `true` | 3 | `"2026/10/07"` は不正 |
| 262 | :82 | RVR | `return default` | 1 | 259 と同じ |
| 193 | :82 | BLR | `false` → `true` | 3 | `"2026-1a-07"` は不正 |
| 123 | :91 | LOR | `t != 10 or not isDate(...)` の `or` → `and` | 3 | `"2026-13-40T12:00:00Z"` (T の位置は正しく、日付が存在しない) は不正 |
| 264 | :95 | RVR | `return default` | 1 | 259 と同じ |
| 195 | :95 | BLR | `false` → `true` | 3 | `"2026-10-07T12:00"` (時刻が短い) は不正 |
| 265 | :98 | RVR | `return default` | 1 | 259 と同じ |
| 196 | :98 | BLR | `false` → `true` | 3 | `"2026-10-07T1a:00:00Z"` は不正 |
| 124 | :99 | LOR | `time[2] != ':' or time[5] != ':'` の `or` → `and` | 3 | `"…T12-00:00Z"` と `"…T12:00-00Z"` (区切りの片方だけが誤り) は不正 |
| 266 | :100 | RVR | `return default` | 1 | 259 と同じ |
| 197 | :100 | BLR | `false` → `true` | 3 | 124 と同じ値 |
| 45 | :101 | ROR | `hour > 23` → `>=` | 3 | `"…T23:59:59z"` と `"…T00:00:00Z"` は正しい (23 時を許す) |
| 126 | :101 | LOR | 1 つ目の `or` → `and` | 3 | `"…T24:00:00Z"` は不正 (時だけが範囲外) |
| 46 | :101 | ROR | `minute > 59` → `>=` | 3 | `"…T12:59:00Z"` は正しい |
| 125 | :101 | LOR | 2 つ目の `or` → `and` | 3 | `"…T24:00:00Z"`, `"…T12:60:00Z"` は不正 (1 つだけ範囲外) |
| 47 | :102 | ROR | `second > 60` → `>=` | 3 | `"…T12:00:60Z"` (うるう秒) は正しい。RFC 3339 5.7 |
| 267 | :103 | RVR | `return default` | 1 | 259 と同じ |
| 198 | :103 | BLR | `false` → `true` | 3 | `"…T24:00:00Z"` などの範囲外は不正 |
| 48 | :105 | ROR | `rest.len > 0` → `>=` | 1 | 94 行目で `time.len >= 9` を確かめているので、`rest = time[8 .. ^1]` は 1 文字以上。`rest.len >= 0` も常に真で、同じ振る舞い |
| 28 | :107 | AOR | 1 つ目の `digits + 1` → `digits - 1` | 3 | `"…T12:00:00.123"` (小数部で文字列が終わる) で `rest[digits + 1]` が範囲外になり IndexDefect。小数部のあるテスト値で落ちる |
| 50 | :107 | ROR | `digits + 1 < rest.len` → `<=` | 3 | 28 と同じ値で IndexDefect。実測で落ちた |
| 128 | :107 | LOR | `and` → `or` | 3 | 28 と同じ値 (左が偽でも右の添字を評価して範囲外) |
| 29 | :107 | AOR | 2 つ目の `digits + 1` → `digits - 1` | 3 | `digits == 0` で `rest[-1]` となり IndexDefect。小数部のある正しい値 (`".5Z"`) で落ちる |
| 202 | :108 | SDL | `inc digits` → `discard` | 3 | ループが終わらない (タイムアウトで検出)。小数部のある値で。実測で、テストが終わらずタイムアウトで止まった |
| 51 | :109 | ROR | `digits == 0` → `!=` | 3 | `"…T12:00:00.Z"` は不正、`"…T12:00:00.5Z"` は正しい |
| 268 | :110 | RVR | `return default` | 1 | 259 と同じ |
| 199 | :110 | BLR | `false` → `true` | 3 | `"…T12:00:00.Z"` は不正 |
| 30 | :111 | AOR | `rest[digits + 1 .. ^1]` → `digits - 1` | 3 | 小数部のある正しい値が、`Z` を取り出せず不正になる |

## 残っているもの

- class 4: id 187 (`elicitation.nim:48`、`isInteger` の `else: false` は到達できない)。削除はしていない。リードの判断に任せる。
- 変異を当てて確かめていない class 3 は残っていない。
- `docs/quality/g2-protocol-versions.md` の「未測定」表は、このジョブの後半が済むまで触れていない。
