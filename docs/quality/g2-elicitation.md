# G2 変異検出: elicitation ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/elicitation.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。
状態: 測定済み (仕分けは 2026-11-12、コードを読んだ結論。変異を手では当てていない)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 266 | 256 | 0 | 9 | 0 | 1 |

公開の入口は `mcp` (`server/elicit`・`client/elicitation` と、その 2 つが丸ごと export する `protocol/elicitation`)。`requestedSchemaProblems`・`contentProblems`・`elicitationResultProblems`・`parseElicitationResult` は入口から直接呼べる。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/client/elicitation.nim:SDL:cf63b65dd3d0f435:0` | client/elicitation.nim:73 | `stderr.writeLine("[mcp-client] the elicitation handler's answer was not sent: " …)` → `discard` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。ハンドラの答えが要求に合わないとき、-32603 で断ることは変異でも保たれ (次の行の `return newJsonRpcErrorResponse`、既存のテストが確かめている)、消えるのは stderr の診断の 1 行だけ。プログラムがこの行を読んで動作を変える箇所は無い。前の記録 (id 13) も許容 | |
| `src/client/elicitation.nim:RVR:7363684acd3b7ee7:0` | client/elicitation.nim:96 | `return none(seq[McpElicitRequest])` → `<return default>` | equivalent | リテラルではない return なので `default(Option[seq[McpElicitRequest]])` になる。`Option` の既定値は none で、`none(...)` と同じ値 (前の記録の id 24 と同じ判断) | |
| `src/protocol/elicitation.nim:BLR:559268148d6adf9d:0` | protocol/elicitation.nim:49 | `isInteger` の `else: false` → `true` | unreached | `isInteger` は非公開で、呼び手は `valueProblems` の 1 か所だけ (335 行)。その直前の `if not value.isNumber: return` が JInt・JFloat 以外を先に返すので、`else` の枝に届く値を入口から作れない (前の記録の id 187 と同じ判断) | |
| `src/protocol/elicitation.nim:BLR:559268148d6adf9d:1` | protocol/elicitation.nim:84 | `formatProblem` の `else: false` → `true` | spec_question | 前の記録 (id 201) は「検査を通った schema の format は 4 つのどれかなので届かない」としたが、届く。`propertyProblems` は `enum` を持つ string の property では `format` を見ない (`plainEnumProblems` だけ) ので、`{"type": "string", "enum": ["a"], "format": "bogus"}` は検査を通り、答え `"a"` で `valueProblems` が `formatProblem("bogus", "a")` を呼ぶ。元は問題なし、変異は「is not a valid bogus」で、サーバーは正しい答えを McpPayloadError で捨て、クライアントは -32603 を返す。どの仕様 ID も enum の property に付いた format を述べていない (MCP-ELICIT-3 は format を持つ string だけ)。問い: enum を持つ string の property に付いた `format` (MCP の EnumSchema に無いキーワード) を、答えの検査で見るか | 推奨: 見ない。モジュールの冒頭の約束「schema が定めないキーワードは確かめない」に合わせ、`valueProblems` は enum の property では format を飛ばす。そうすれば `formatProblem` の `else` は届かなくなり (unreached)、今の「enum と既知の format (`email`) が両方あると enum の値が format で落ちる」振る舞いも消える。見ると決めるなら、未知の format の扱いを MCP-ELICIT-ENUM-2 に足して E テストを書く |
| `src/protocol/elicitation.nim:SDL:1cfc19a0e7261886:0` | protocol/elicitation.nim:143 | `allowedValues` の末尾の `none(seq[JsonNode])` → `discard` | equivalent | 関数の末尾の式が消えると `result` の既定値がそのまま返る。`Option` の既定値は none で同じ値。手前の枝はどれも `return some(...)` で抜けるので、`result` に別の値が入ったままここへ来ることも無い (前の記録の id 210 と同じ判断) | |
| `src/protocol/elicitation.nim:RVR:03da7914661f1d4b:0` | protocol/elicitation.nim:226 | `return emForm` → `<return default>` | equivalent | 列挙値の return は `default(ElicitMode)` になる。`ElicitMode` の最初の値 (序数 0) が `emForm` なので同じ値 (前の記録の id 283) | |
| `src/protocol/elicitation.nim:RVR:03da7914661f1d4b:1` | protocol/elicitation.nim:228 | `return emForm` → `<return default>` | equivalent | 同上 (前の記録の id 284) | |
| `src/protocol/elicitation.nim:LOR:b47c5833fd3e23b2:1` | protocol/elicitation.nim:372 | `contentProblems` の `properties.isNil or properties.kind != JObject` → `and` | spec_question | SDK の中の流れ (サーバーは `formElicitationParams`、クライアントは `elicitationParamsProblems` を先に通す) では `properties` は必ずオブジェクトで、差は出ない。ただし `contentProblems`・`elicitationResultProblems`・`parseElicitationResult` は入口から直接呼べ、検査していない params (`requestedSchema` の無い form、`properties` がオブジェクトでない schema) を渡すと、元は required だけを見て返り、変異は nil の `kind` を読むか `hasKey` の表明で落ちる。`contentProblems` の文書コメントは「検査を通った schema」を前提にするが、`elicitationResultProblems` は前提を書かず、未知の mode の params は落ちずに報告する (MCP-ELICIT-7)。前の記録 (id 182) の「残す」は司会の判断 (2026-10-07) で、代表の決定ではない。問い: 検査を通っていない params への答えを確かめたとき、落ちずに返ることを仕様にするか、前提違反として防御を消すか | 推奨: 仕様にする (MCP-ELICIT-7 の When に「requestedSchema が無い・properties がオブジェクトでない params への答え」を足す)。相手から来た params を先に検査せずにこの関数へ渡す使い方は入口から書けるので、落ちるより報告が安全。E テストは `test_elicitation_payload` に 1 本: `elicitationResultProblems(%*{"action": "accept", "content": {"a": 1}}, %*{"message": "m"})` と `properties` が配列の schema で、どちらも例外なしに返る。変異では落ちる。使い手: src は `protocol/elicitation.nim` の中の 1 か所 (`elicitationResultProblems`)、tests/external は `test_elicitation_payload.nim`、tests/internal は無し。公開から外す案は、`contentProblems` だけなら取れる (入口から呼ぶのはテストだけ) が、`elicitationResultProblems` を通って同じ行に届くので、この生き残りは消えない |
| `src/server/elicit.nim:LOR:a8742f6ee65f2793:0` | server/elicit.nim:20 | `known.state != mlsOperational or known.negotiatedVersion.isNone` → `and` | spec_question | 差が出るのは、`initialize` には答えたが `notifications/initialized` をまだ送っていないクライアント (`mlsInitializing` で版は決まっている) だけ。`elicit`・`elicitUrl` は、変異でも後段の `server.request` が同じ McpCapabilityError で送信の前に断る (文面だけの差。schema が規則を破るときだけ McpPayloadError が先に出る)。前の記録 (id 309) はここまでを見て「冗長」とした。しかし `notifyElicitationComplete` の後段は `server.sendNotification` で、状態を確かめない。変異では、握手の済んでいないクライアントに `notifications/elicitation/complete` が送られる (元は McpCapabilityError で何も送らない)。どの仕様 ID の Given にも「initialized を送っていないクライアント」は無い (MCP-ELICIT-4・MCP-ELICIT-URL-2 は宣言と版、MCP-SERVERREQ-4 は sampling と roots の要求)。問い: initialized を送っていないクライアントには elicitation の完了の通知も送らず、capability のエラーで断ることを仕様にするか | 推奨: 仕様にする (MCP-ELICIT-URL-2 の Given に「initialized を送っていないクライアント」を足す。MCP の lifecycle は、initialized の前にサーバーが送ってよいものを ping と logging に限る)。E テストは `test_server_elicitation` に 1 本: `initialize` (2025-11-25、url モードを宣言) だけを注入したセッションに `server.notifyElicitationComplete` → `expect McpCapabilityError`、`t.messagesOf("notifications/elicitation/complete").len == 0`。変異では通知が 1 件出る |

timeout は無い。

測定: `nim-muter`、ジョブ `tests/mutation/elicitation.json`、本線の 36a4c8a5 (2026-10-07)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 324 | 217 | 3 | 103 | 0 | 1 |

生き残り 103 件と時間切れ 3 件の分類 (2 人で分担し、下の 2 節に 1 件ずつ記録した)。

| 分類 | protocol/elicitation.nim 〜113 行 | 114 行〜と他の 3 ファイル | 計 |
|---|---:|---:|---:|
| 1 同値 | 10 | 5 | 15 |
| 3 穴 (テストを追加) | 35 | 52 | 87 |
| 4 到達しない・冗長なコード | 1 | 2 | 3 |
| 6 許容 (標準エラーの診断の文面) | 0 | 1 | 1 |
| 時間切れ (検出として数える) | 0 | 3 | 3 |

分類 3 の 87 件は、変異を 1 件ずつ手で当てて、追加したテストが落ちる (または止まる) ことを確かめた。リードが 3 件を抜き取りで当て直し、同じ結果だった。

## 到達しない・冗長なコードの扱い (リードの判断、2026-10-07: 3 件とも残す)

- id 187 (`protocol/elicitation.nim:48`、`isInteger` の `else: false`): 今の呼び出しは `isNumber` を通った値だけなので届かないが、
  `isInteger` 単体の意味 (数でなければ整数でない) を表す枝で、消すと `case` が網羅でなくなる。
- id 182 (`protocol/elicitation.nim:413`、`contentProblems` の `properties` がオブジェクトであることの確認): 検証済みの schema にしか使わないので
  今は常に真。検証を通さずに呼ぶ変更が入ったときに nil を踏まないための防御。
- id 309 (`server/elicit.nim:20`、capability の確認): `server.request` が送信の前に同じ `McpCapabilityError` を投げるので、違いはメッセージの文だけ。
  ここで先に断るほうが、何が足りないかを elicitation の言葉で言える。

どれも届かない、または結果が変わらないので、次の測定でも生き残る。

## src/protocol/elicitation.nim の 1〜113 行

`src/protocol/elicitation.nim` の 1 行目から 113 行目まで。ジョブ `elicitation` (36a4c8a5 の測定) のうち、この範囲の生き残りを 1 件ずつ分類する。後半 (114 行目以降と残り 3 ファイル) は `g2e-elicit-b` の担当。

ジョブ全体の数 (報告書): 変異 324 件、killed 217、timeout 3、survived 103、runError 0、compileError 1。
この範囲の生き残りは 46 件 (下表の全行)。

### 判断

生き残りの原因は、`formatProblem` の下請け関数 (`isEmailLike` / `isUriLike` / `isDate` / `isDateTime`) の境界条件を、良い値 1 つと悪い値 1 つでしか試していなかったこと。外部仕様 (MCP の `requestedSchema` の `format` は email / uri / date / date-time の 4 つ、値は RFC 5322 / RFC 3986 / RFC 3339 に従う) の事実として、境界の良い値と悪い値の表を 1 つのテストにした。

- 追加したテスト: `tests/test_elicitation_payload.nim` の「Given edge values of each string format, when checked, then exactly the valid ones pass」(`specs/tests.map` の MCP-ELICIT-3)。デフォルト版 2026-07-28 / 2025-11-25 / 2025-06-18 の 3 つで通る。
- class 3 の 35 件はすべて、変異を 1 件ずつ当てて、このテストが落ちる (またはループが終わらずタイムアウトになる) のを確認した。変異を戻した状態では通る。落ちた箇所は、`check` の失敗か IndexDefect (小数部の添字)。id 202 だけは終わらないためタイムアウトで止めた。
- 変異は、報告書の変異と同じ式になるよう優先順位を括弧で明示して当てた (id 118, 121, 120, 125)。
- 「戻り値 `default`」の変異 (RVR) は、`bool` の `default` が `false` で、元の `return false` と同じ式になる。

### 生き残り一覧

| id | file:line | mutator | original → replacement | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 187 | elicitation.nim:48 | BLR | `else: false` → `true` | 4 | `isInteger` は 376 行目で `isNumber` を通った値にしか呼ばれない (374 行目で先に return する)。`else` 枝は到達できない。リードの判断に任せる |
| 33 | :61 | ROR | `at > 0` → `>=` | 3 | `"@b.c"` は不正。edge values テスト |
| 35 | :61 | ROR | `at < text.high` → `<=` | 3 | `"a@"` は不正。同上 |
| 36 | :67 | ROR | `colon < 1` → `<=` | 3 | `"a:b"` (コロンが 1 文字目の後) は正しい。同上 |
| 119 | :67 | LOR | `colon < 1 or colon == text.high` の `or` → `and` | 3 | `"abc"` (コロンなし) と `"a:"` が不正。実測で落ちた |
| 118 | :67 | LOR | `... or text.contains(...)` の `or` → `and` | 3 | `"a:b c"` (空白入り) が不正。同上のテスト |
| 259 | :70 | RVR | `return false` → `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_elicitation_payload.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
| 189 | :70 | BLR | `false` → `true` | 3 | `"1a:x"`, `"+a:x"` (先頭が英字でない) は不正 |
| 26 | :72 | AOR | `Letters + Digits` → `Letters - Digits` | 3 | `"a1:x"` は正しい。実測で落ちた |
| 25 | :72 | AOR | `... + {'+', '-', '.'}` の `+` → `-` | 3 | `"a+b:x"`, `"a-b:x"`, `"a.b:x"` は正しい |
| 260 | :73 | RVR | `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_elicitation_payload.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
| 190 | :73 | BLR | `false` → `true` | 3 | `"a_b:x"` は不正 |
| 121 | :78 | LOR | `text.len != 10 or text[4] != '-'` の `or` → `and` | 3 | `"2026-10-077"` (長さ 11、区切り位置は正しい) は不正。変異では桁の検査と月日の検査を通って受理される |
| 120 | :78 | LOR | 2 つ目の `or` → `and` | 3 | 121 と同じ値で落ちる (`(A or B) and C` で C が偽) |
| 261 | :79 | RVR | `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_elicitation_payload.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
| 192 | :79 | BLR | `false` → `true` | 3 | `"2026/10/07"` は不正 |
| 262 | :82 | RVR | `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_elicitation_payload.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
| 193 | :82 | BLR | `false` → `true` | 3 | `"2026-1a-07"` は不正 |
| 123 | :91 | LOR | `t != 10 or not isDate(...)` の `or` → `and` | 3 | `"2026-13-40T12:00:00Z"` (T の位置は正しく、日付が存在しない) は不正 |
| 264 | :95 | RVR | `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_elicitation_payload.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
| 195 | :95 | BLR | `false` → `true` | 3 | `"2026-10-07T12:00"` (時刻が短い) は不正 |
| 265 | :98 | RVR | `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_elicitation_payload.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
| 196 | :98 | BLR | `false` → `true` | 3 | `"2026-10-07T1a:00:00Z"` は不正 |
| 124 | :99 | LOR | `time[2] != ':' or time[5] != ':'` の `or` → `and` | 3 | `"…T12-00:00Z"` と `"…T12:00-00Z"` (区切りの片方だけが誤り) は不正 |
| 266 | :100 | RVR | `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_elicitation_payload.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
| 197 | :100 | BLR | `false` → `true` | 3 | 124 と同じ値 |
| 45 | :101 | ROR | `hour > 23` → `>=` | 3 | `"…T23:59:59z"` と `"…T00:00:00Z"` は正しい (23 時を許す) |
| 126 | :101 | LOR | 1 つ目の `or` → `and` | 3 | `"…T24:00:00Z"` は不正 (時だけが範囲外) |
| 46 | :101 | ROR | `minute > 59` → `>=` | 3 | `"…T12:59:00Z"` は正しい |
| 125 | :101 | LOR | 2 つ目の `or` → `and` | 3 | `"…T24:00:00Z"`, `"…T12:60:00Z"` は不正 (1 つだけ範囲外) |
| 47 | :102 | ROR | `second > 60` → `>=` | 3 | `"…T12:00:60Z"` (うるう秒) は正しい。RFC 3339 5.7 |
| 267 | :103 | RVR | `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_elicitation_payload.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
| 198 | :103 | BLR | `false` → `true` | 3 | `"…T24:00:00Z"` などの範囲外は不正 |
| 48 | :105 | ROR | `rest.len > 0` → `>=` | 1 | 94 行目で `time.len >= 9` を確かめているので、`rest = time[8 .. ^1]` は 1 文字以上。`rest.len >= 0` も常に真で、同じ振る舞い |
| 28 | :107 | AOR | 1 つ目の `digits + 1` → `digits - 1` | 3 | `"…T12:00:00.123"` (小数部で文字列が終わる) で `rest[digits + 1]` が範囲外になり IndexDefect。小数部のあるテスト値で落ちる |
| 50 | :107 | ROR | `digits + 1 < rest.len` → `<=` | 3 | 28 と同じ値で IndexDefect。実測で落ちた |
| 128 | :107 | LOR | `and` → `or` | 3 | 28 と同じ値 (左が偽でも右の添字を評価して範囲外) |
| 29 | :107 | AOR | 2 つ目の `digits + 1` → `digits - 1` | 3 | `digits == 0` で `rest[-1]` となり IndexDefect。小数部のある正しい値 (`".5Z"`) で落ちる |
| 202 | :108 | SDL | `inc digits` → `discard` | 3 | ループが終わらない (タイムアウトで検出)。小数部のある値で。実測で、テストが終わらずタイムアウトで止まった |
| 51 | :109 | ROR | `digits == 0` → `!=` | 3 | `"…T12:00:00.Z"` は不正、`"…T12:00:00.5Z"` は正しい |
| 268 | :110 | RVR | `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_elicitation_payload.nim` が落ちる (本線 qzktpvsz、2026-10-10)。 |
| 199 | :110 | BLR | `false` → `true` | 3 | `"…T12:00:00.Z"` は不正 |
| 30 | :111 | AOR | `rest[digits + 1 .. ^1]` → `digits - 1` | 3 | 小数部のある正しい値が、`Z` を取り出せず不正になる |

### 残っているもの

- class 4: id 187 (`elicitation.nim:48`、`isInteger` の `else: false` は到達できない)。削除はしていない。リードの判断に任せる。
- 変異を当てて確かめていない class 3 は残っていない。
- `docs/quality/g2-protocol-versions.md` の「未測定」表は、このジョブの後半が済むまで触れていない。

## src/protocol/elicitation.nim の 114 行以降、client/elicitation.nim、protocol/payload.nim、server/elicit.nim

測定: `nim-muter`、ジョブ `tests/mutation/elicitation.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/protocol/elicitation.nim`、`src/protocol/payload.nim`、`src/server/elicit.nim`、`src/client/elicitation.nim`。`protocol/elicitation.nim` の 113 行目までは `g2e-elicit-a` の担当で、`docs/quality/g2-elicitation-a.md` にある。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 324 | 217 | 3 | 103 | 0 | 1 |

このファイルが扱うのは 63 件: `protocol/elicitation.nim` の 114 行目以降の生き残り 47 件、他の 3 ファイルの生き残り 10 件 (client 3、payload 3、server 4)、`server/elicit.nim` の timeout 3 件。

生き残り 60 件の分類と timeout 3 件。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 5 (24, 201, 210, 283, 284) |
| 2 検出扱いの timeout (311, 312, 314) | 3 |
| 3 穴 (テストを追加) | 52 |
| 4 到達しない・冗長なコード | 2 (182, 309) |
| 5 欠陥 | 0 |
| 6 許容 | 1 (13) |

分類 3 の 52 件はすべて、変異を 1 件ずつ手で当てて、追加したテストが落ちる (または止まる) ことを確かめた。`||`/`and` の連鎖 (id 129 から 136) は、変異した演算子の左右を括弧でくくって、元の構文木と同じ形で当てた (演算子の優先順位で別のプログラムにならないように)。変異を当てた状態で、ベースにあった既存のテストだけでは落ちないことは、測定の結果 (生き残り) が示している。

追加したテストは `tests/test_elicitation_payload.nim` の新しい suite 2 つ、`tests/test_server_elicitation.nim`、`tests/test_client_elicitation.nim`、`tests/test_tasks_end_to_end.nim` に各 1 件以上。Scenario は `specs/elicitation.feature` の `MCP-ELICIT-6` から `-5` (リードが採番し直す)。ジョブの `testCommand` に `tests/test_tasks_end_to_end.nim` を追記した。`test_elicitation_payload`・`test_server_elicitation`・`test_client_elicitation`・`test_tasks_end_to_end` を、既定の版・2025-06-18・2025-11-25 で、変異なしで通ることを確かめた (`test_tasks_end_to_end` は 2025-11-25 以降だけ中身がある)。

### 一覧

| id | 場所 | mutator | 変異 | 分類 | 理由 | 検出するテスト |
|---|---|---|---|---|---|---|
| 10 | `client/elicitation.nim:83` | LOR | `or → and` | 3 | elicitationId のない完了通知は無視される (変異では nil を参照して落ちる) | `test_client_elicitation` の「Given an accepted URL request, when a completion arrives without a string id」 |
| 13 | `client/elicitation.nim:73` | SDL | `stderr への診断行を削除` | 6 | ハンドラの答えが送られなかったことの stderr の文。クライアントの応答 (-32603) は既存のテストが確かめている。文面を固定するテストは実装の写しになる。 |  |
| 24 | `client/elicitation.nim:96` | RVR | `return none → 既定値` | 1 | `Option` の既定値は none。 |  |
| 52 | `protocol/elicitation.nim:114` | ROR | `rest.len == 6 → !=` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 53 | `protocol/elicitation.nim:114` | ROR | `rest[3] == ':' → !=` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 54 | `protocol/elicitation.nim:116` | ROR | `<= 23 → >` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 55 | `protocol/elicitation.nim:116` | ROR | `<= 59 → >` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 56 | `protocol/elicitation.nim:131` | ROR | `result.len == 0 → !=` | 3 | 下限が上限を超える schema は報告される (欠けている min>max の検査が通っていた) | 「Given a string or number bound that is not a number or is inverted」 |
| 57 | `protocol/elicitation.nim:132` | ROR | `> → >=` | 3 | 下限と上限が等しい schema は有効 | 「Given a string or number bound that is not a number or is inverted」 |
| 68 | `protocol/elicitation.nim:163` | ROR | `< 0 → <= 0` | 3 | 0 は有効な件数 | 「Given minItems or maxItems that is not a non-negative integer」 |
| 70 | `protocol/elicitation.nim:166` | ROR | `> → >=` | 3 | minItems == maxItems は有効 | 「Given minItems or maxItems that is not a non-negative integer」 |
| 97 | `protocol/elicitation.nim:367` | ROR | `< → <=` | 3 | 長さが minLength ちょうどなら有効 | 「Given values at the limits of their bounds」 |
| 98 | `protocol/elicitation.nim:369` | ROR | `> → >=` | 3 | 長さが maxLength ちょうどなら有効 | 「Given values at the limits of their bounds」 |
| 101 | `protocol/elicitation.nim:380` | ROR | `> → >=` | 3 | 値が maximum ちょうどなら有効 | 「Given values at the limits of their bounds」 |
| 129 | `protocol/elicitation.nim:116` | LOR | `and → or (分 <= 59)` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 130 | `protocol/elicitation.nim:116` | LOR | `and → or (時 <= 23)` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 131 | `protocol/elicitation.nim:115` | LOR | `and → or (rest[5])` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 132 | `protocol/elicitation.nim:115` | LOR | `and → or (rest[4])` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 133 | `protocol/elicitation.nim:115` | LOR | `and → or (rest[2])` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 134 | `protocol/elicitation.nim:114` | LOR | `and → or (rest[1])` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 135 | `protocol/elicitation.nim:114` | LOR | `and → or (コロン)` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 136 | `protocol/elicitation.nim:114` | LOR | `and → or (len と符号)` | 3 | 数値オフセットを持つ date-time の検査が一度も実行されていなかった (テストは `Z` だけ) | 「Given a date-time with an offset, when checked, then only a well-formed offset is accepted」(RFC 3339 の time-numoffset: `(+|-)HH:MM`、HH は 23 まで、MM は 59 まで。条件を 1 つずつだけ破る入力と、境界の有効な値) |
| 141 | `protocol/elicitation.nim:137` | LOR | `or → and` | 3 | 空の enum は報告される (非配列では `len` が 0 なので、差が出るのは空配列だけ) | 「Given a plain enum that is empty or holds a non-string」 |
| 147 | `protocol/elicitation.nim:163` | LOR | `or → and` | 3 | 整数でない (`"1"`) 件数上限は報告される | 「Given minItems or maxItems that is not a non-negative integer」 |
| 150 | `protocol/elicitation.nim:165` | LOR | `and → or` | 3 | maxItems だけを持つ schema が KeyError にならず有効 | 「Given minItems or maxItems that is not a non-negative integer」 |
| 153 | `protocol/elicitation.nim:220` | LOR | `or → and` | 3 | items のない複数選択は `items is missing` と報告される (nil の参照で落ちる) | 「Given a multi-select with no items or with an enum that breaks the rules」 |
| 161 | `protocol/elicitation.nim:270` | LOR | `and → or` | 3 | form でも url でもない文字列の mode は拒否される | 「Given a mode that is a string but neither form nor url」(`is not an elicitation mode` で比べる。以前は "mode" を含むかだけで、version の報告にも含まれていた) |
| 162 | `protocol/elicitation.nim:279` | LOR | `or → and` | 3 | オブジェクトでない params は `params is not an object` だけを返す | 「Given params that are not an object」 |
| 180 | `protocol/elicitation.nim:405` | LOR | `or → and` | 3 | オブジェクトでない content は `content is not an object` | 「Given a result or content that is not an object」 |
| 182 | `protocol/elicitation.nim:413` | LOR | `or → and` | 4 | `contentProblems` は `requestedSchemaProblems` を通った schema にだけ使う (doc comment)。通った schema の properties は必ずオブジェクトなので、この防御は働かない。 |  |
| 183 | `protocol/elicitation.nim:421` | LOR | `or → and` | 3 | オブジェクトでない result は `the result is not an object` | 「Given a result or content that is not an object」 |
| 201 | `protocol/elicitation.nim:125` | BLR | `false → true (formatProblem の else)` | 1 | `formatProblem` が呼ばれるのは `requestedSchemaProblems` を通った schema だけで、その format は `StringFormats` の 4 つのどれか。else には到達しない。 |  |
| 203 | `protocol/elicitation.nim:130` | SDL | `not a number の追記を削除` | 3 | 非数値の下限・上限は名指しで報告される | 「Given a string or number bound that is not a number or is inverted」 |
| 204 | `protocol/elicitation.nim:133` | SDL | `is above の追記を削除` | 3 | 下限が上限を超える schema は報告される | 「Given a string or number bound that is not a number or is inverted」 |
| 206 | `protocol/elicitation.nim:149` | SDL | `enumNames の名前が文字列でない報告を削除` | 3 | enumNames に文字列でないものがあれば報告される | 「Given a plain enum that is empty or holds a non-string」 |
| 207 | `protocol/elicitation.nim:164` | SDL | `not a non-negative integer の追記を削除` | 3 | 負の件数は報告される | 「Given minItems or maxItems that is not a non-negative integer」 |
| 210 | `protocol/elicitation.nim:184` | SDL | `none(seq[JsonNode]) を削除` | 1 | `Option` の既定値は none で、`result` はその値のまま返る。 |  |
| 215 | `protocol/elicitation.nim:207` | SDL | `string の boundsProblems を削除` | 3 | minLength / maxLength の不正は報告される | 「Given a string or number bound that is not a number or is inverted」 |
| 217 | `protocol/elicitation.nim:212` | SDL | `number の boundsProblems を削除` | 3 | minimum / maximum の不正は報告される | 「Given a string or number bound that is not a number or is inverted」 |
| 219 | `protocol/elicitation.nim:225` | SDL | `items の plainEnumProblems を削除` | 3 | 空の items.enum は報告される | 「Given a multi-select with no items or with an enum that breaks the rules」 |
| 220 | `protocol/elicitation.nim:224` | SDL | `items の enum に type string が要る報告を削除` | 3 | type のない items.enum は報告される | 「Given a multi-select with no items or with an enum that breaks the rules」 |
| 229 | `protocol/elicitation.nim:256` | SDL | `required is not an array の追記を削除` | 3 | 配列でない required は報告される | 「Given required that is not an array」 |
| 241 | `protocol/elicitation.nim:341` | SDL | `エントリの elicitationParamsProblems を削除` | 3 | -32042 の data の各エントリが URL 要求の規則に従うこと | 「Given error data whose entry is a URL request that breaks the rules」 |
| 270 | `protocol/elicitation.nim:138` | RVR | `return 報告 → 空` | 3 | 同上 | 「Given a plain enum that is empty or holds a non-string」 |
| 271 | `protocol/elicitation.nim:141` | RVR | `return 報告 → 空` | 3 | enum に文字列でない値があれば報告される | 「Given a plain enum that is empty or holds a non-string」 |
| 278 | `protocol/elicitation.nim:192` | RVR | `return 報告 → 空` | 3 | オブジェクトでない property は名指しで報告される | 「Given a property that is not an object or has no type」(メッセージ全体 `property 'x' is not an object` / `type is missing` で比べる。以前の期待は "y" を含むかだけで、"type" の y に一致していた) |
| 279 | `protocol/elicitation.nim:194` | RVR | `return 報告 → 空` | 3 | type のない property は名指しで報告される | 「Given a property that is not an object or has no type」(メッセージ全体 `property 'x' is not an object` / `type is missing` で比べる。以前の期待は "y" を含むかだけで、"type" の y に一致していた) |
| 283 | `protocol/elicitation.nim:267` | RVR | `return emForm → 既定値` | 1 | `ElicitMode` の最初の値が emForm で、既定値と同じ。 |  |
| 284 | `protocol/elicitation.nim:269` | RVR | `return emForm → 既定値` | 1 | 同上 |  |
| 287 | `protocol/elicitation.nim:280` | RVR | `return 報告 → 空` | 3 | 同上 | 「Given params that are not an object」 |
| 296 | `protocol/elicitation.nim:406` | RVR | `return 報告 → 空` | 3 | 同上 | 「Given a result or content that is not an object」 |
| 297 | `protocol/elicitation.nim:422` | RVR | `return 報告 → 空` | 3 | 同上 | 「Given a result or content that is not an object」 |
| 299 | `protocol/elicitation.nim:427` | RVR | `return e.problems → 空` | 3 | 未知の mode への answer は mode を報告する | 「Given an answer to params with an unknown mode」 |
| 303 | `protocol/payload.nim:12` | ROR | `> 0 → >= 0` | 3 | 同上 | 「Given no problem, when an error is built」「Given several problems, when an error is built」 |
| 305 | `protocol/payload.nim:12` | SDL | `doAssert を削除` | 3 | 問題 0 件の PayloadError を作るのは契約違反 (AssertionDefect)。削除すると IndexDefect になり別の例外 | 「Given no problem, when an error is built」「Given several problems, when an error is built」 |
| 306 | `protocol/payload.nim:16` | SDL | `"; " & problems[i] の追記を削除` | 3 | メッセージは文脈と全問題を `; ` でつなぐ | 「Given no problem, when an error is built」「Given several problems, when an error is built」 |
| 309 | `server/elicit.nim:20` | LOR | `or → and` | 4 | `state != operational` で `negotiatedVersion` が Some の状態 (initialize 後、initialized 前) は、`server.request` が同じ `McpCapabilityError` を送信前に投げる。変わるのはメッセージの文だけ。 |  |
| 311 | `server/elicit.nim:31` | LOR | `or → and` | 2 | timeout (検出扱い)。能力を宣言していないクライアントに要求が送られ、答えが来ずに止まる。または `declared.get` が落ちる。 | `test_server_elicitation` の「Given a client without the elicitation capability」ほか |
| 312 | `server/elicit.nim:44` | SDL | `requireElicitation(emForm) を削除` | 2 | timeout (検出扱い)。能力のないクライアントに要求が送られ、答えを待って止まる。 | 同上 |
| 313 | `server/elicit.nim:60` | SDL | `ctx.endInput() を削除 (form)` | 3 | 答えが来たら task は input_required から working に戻る。戻らなければ working の確認が落ちる | `test_tasks_end_to_end` の「Given a tool that elicits in form or url mode inside a task, when the client has answered, then the task is working again while the tool goes on」(ジョブの testCommand に追記) |
| 314 | `server/elicit.nim:69` | SDL | `requireElicitation(emUrl) を削除` | 2 | timeout (検出扱い)。url モードを宣言していないクライアントに送られて止まる。 | `test_server_elicitation` の「Given a client that declared only the form mode, when the server asks in url mode」 |
| 315 | `server/elicit.nim:83` | SDL | `ctx.endInput() を削除 (url)` | 3 | 同上 | `test_tasks_end_to_end` の「Given a tool that elicits in form or url mode inside a task, when the client has answered, then the task is working again while the tool goes on」(ジョブの testCommand に追記) |
| 324 | `server/elicit.nim:80` | RVR | `return await ... → 既定値` | 3 | `ctx.elicitUrl` はクライアントの答えを返す | `test_server_elicitation` の「Given a handler that asks in url mode, when a tool is called」 |

### 残っているもの

- 13 (`client/elicitation.nim:73`): 許容。stderr の診断文だけが変わる。
- 182 (`protocol/elicitation.nim:413`) と 309 (`server/elicit.nim:20`): 冗長な防御。リードの判断に任せる (削除はしていない)。309 は `server.request` が同じ検査を持っている。
- 1 の同値 (24, 201, 210, 283, 284): 理由は一覧のとおり。
