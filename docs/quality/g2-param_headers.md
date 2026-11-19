# G2 変異検出: `src/protocol/param_headers.nim`

## 測り直し (拡張ブランチの 2b8a56aa、2026-10-25)

測定: 変異検査の道具 0.2.11、ジョブ `tests/mutation/param_headers.json` (テストは `tests/external/` に移した後の 2 本)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 84 | 75 | 0 | 5 | 0 | 4 |

`survivors.json` に同期した結果: test_owed だった 11 件 (2026-10-12 以後の測定で残り、E テストを足したもの) はすべて検出され、台帳から消えた。残った 5 件は前と同じ変異で、分類と理由もそのまま (unreached 2、equivalent 2、accepted 1)。新しい生き残りは 0 件。

## 初回の測定 (mainline の 36a4c8a5、2026-10-07)

測定: 変異検査の道具、ジョブ `tests/mutation/param_headers.json`、mainline の 36a4c8a5 (2026-10-07)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 84 | 67 | 0 | 13 | 0 | 4 |

## survived 13 件

分類は、1 = 同値、3 = 穴 (新しい外部仕様テストを足した)、4 = 冗長なコード、6 = 受け入れ。
クラス 3 の 8 件は、変異を手で当てて下に書いたテストが落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは戻した)。
足したテストはすべて `tests/test_param_headers.nim` にあり、ジョブの `testCommand` に入っているので、ジョブの変更は要らない。
Scenario は `MCP-HTTP-24` と `-2` (`specs/streamable_http.feature`、対応は `specs/tests.map`)。
`-d:mcpDefaultProtocolVersion=2024-11-05` と `=2025-11-25` でも `test_param_headers.nim` は 42 件とも通る (この部分は純関数で、版に依存しない)。

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 70 | param_headers.nim:49 | RVR | `return false` → `<return default>` | 4 | **訂正 (2026-10-10)**: 同値ではない。変異検査の道具 の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てても 2 本のテストは通る。`isToken` の呼び出しは 1 か所で、その前に空の名前を断っている (`must be a non-empty string`) ので、この行に届く入力が無い。`1*tchar` の定義として残す。 |
| 40 | param_headers.nim:49 | BLR | `return false` → `return true` | 4 | `isToken("")` は private で、呼び出しは 112 行目だけ。その前の 109 行目が空の名前を `len == 0` で先に退けるので、`isToken` に空文字列は届かない。109 行目の検査と 48 行目の検査が重なっている。消すかどうかはリードが決める。 |
| 2 | param_headers.nim:57 | ROR | `path.len == 0` → `!=` | 3 | 理由の文面で、根を「the schema root」、それ以外を `'a.b'` と書き分けている。それが逆になる。T: `Given an invalid declaration, when declarations are read, then the reason names where it was found` (`'target.zone'` を含むことを見て落ちる)。理由は tools/list を出さなかった旨とともに stderr に出て、ツールの作者が場所を探す手がかりになる。 |
| 3 | param_headers.nim:66 | ROR | `key == ParamHeaderKeyword` → `!=` | 3 | 注釈の無い `items` などの中の `type: string` までが「注釈」と見なされ、有効なツールが無効になる。T: `Given keywords that hold schemas but no annotation, when declarations are read, then the tool stays valid`。 |
| 29 | param_headers.nim:66 | LOR | `key == ... and child.kind != JObject` → `or` | 3 | 同上 (オブジェクトでない値を持つキーがすべて注釈扱い)。T: 同じテスト。 |
| 45 | param_headers.nim:70 | BLR | `false` → `true` | 3 | 注釈を含まないオブジェクトがすべて「注釈がある」になる。T: 同じテスト (`items`、`additionalProperties`、`anyOf`、`properties` に置かれた `x-mcp-header` という名前の性質を、有効のまま保つ)。 |
| 34 | param_headers.nim:109 | LOR | `annotation.kind != JString or annotation.getStr().len == 0` の `or` → `and` | 3 | 空文字列の名前が「非空の文字列でなければならない」ではなく「token でない」と報告される (結果はどちらも無効)。T: `Given an empty name, when declarations are read, then the reason says the name must not be empty`。理由は診断の文面だが、空の名前を作者が見つけるための手がかりなので、テストにした。 |
| 18 | param_headers.nim:168 | ROR | `getBiggestInt() < -MaxSafeInteger` → `<=` | 3 | -(2^53-1) が拒否される。正の境界 2^53-1 は既存のテストが通していたが、負の境界は見ていなかった。T: `Given an integer beyond the safe range, when headers are built, then the value is refused and no header is added` (-(2^53-1) の値で `Mcp-Param-N: -9007199254740991` が付くことを足した)。 |
| 62 | param_headers.nim:178 | SDL | `none(string)` → `discard` | 1 | `Option[string]` の既定値は `none` で、関数の最後の式を消しても返る値が同じ。 |
| 20 | param_headers.nim:181 | ROR | `text.len > MaxQuotedValue` → `>=` | 6 | ちょうど 64 文字の値のとき、引用が `...` を 1 つ余分に付けるかどうかだけが変わる。長い値が全文は引用されないこと (< 300 文字) は既存のテストが見ている。64 という値は SDK が決めた診断の長さで、仕様は何も言わない。境界のテストは定数を書き写すだけになる。 |
| 21 | param_headers.nim:190 | ROR | `body.kind == JInt` → `!=` | 3 | 本文が `42.0` のように小数部を持つ JSON 数のとき、`getBiggestInt()` が 0 を返し、ヘッダー `42` と一致しなくなる。T: `Given a body number written with a fraction part, when checked, then it agrees with the same integer in the header`。 |
| 50 | param_headers.nim:228 | BLR | `false` → `true` | 3 | オブジェクトや配列の引数が、どんなヘッダー値とも一致してしまう。T: `Given an object or array argument, when checked, then no header value agrees with it`。 |
| 67 | param_headers.nim:232 | SDL | `none(JsonRpcError)` → `discard` | 1 | 62 と同じ。`Option[JsonRpcError]` の既定値は `none`。 |

内訳: クラス 1 が 3 件 (70、62、67)、クラス 3 が 8 件 (2、3、29、45、34、18、21、50)、クラス 4 が 1 件 (40)、クラス 6 が 1 件 (20)。

## 残っているもの

- 40 (`param_headers.nim:49`): `isToken` の空文字列の検査は、109 行目の検査と重なっている。コードは変えていない。2026-10-12 に残すと決めた。
- 20 (`param_headers.nim:181`): 診断の引用の長さの境界。受け入れ。

## リードの判断

- id 40 (`isToken` の空文字列の検査): 残す。今の唯一の呼び出し元は空の名前を先に退けるが、「空文字列は token ではない」は
  RFC 9110 の token の定義そのもので、関数単体の意味を保つ。
- id 2、34 のテストが診断文を見る点: そのままにする。見ているのは文面の全体ではなく、「どの引数か (名前、または schema の根)」
  を名指しすること。tools/list から外したことを SDK が stderr に出すときの、作者が場所を探す唯一の手がかりになる。
  仕様の規則ではなく SDK の振る舞いで、どこにも文書化はしていない。
- id 20 (引用の 64 文字の境界): 許容のまま。

