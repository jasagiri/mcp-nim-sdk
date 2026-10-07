# G2 変異検出: trace_context ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/trace_context.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/protocol/trace_context.nim`。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 99 | 54 | 4 | 36 | 0 | 5 |

行番号は 36a4c8a5 のもの。欠陥の修正で `isTracestateValue` に 1 行足したため、現在のファイルでは 67 行以降が 1 行ずれる。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 9 |
| 2 ジョブに無い既存のテストが検出 | 0 |
| 3 穴 (テストを追加) | 24 |
| 4 到達しない・観測できないコード | 0 (下の「残っているもの」に 1 節を足した) |
| 5 欠陥 (修正した) | 1 |
| 6 許容 (診断の文面) | 2 |

分類 3 と 5 は、変異を 1 件ずつ手で当てて、追加したテストが落ちる (または異常終了する) ことを確かめた。
`tracestate` と `tenant@system` のキーの文法を作る `and` の連鎖 (id 43〜49) は、`and` を `or` に替えた式の木のとおりに括弧を付けて当てた。
分類 1 は式と不変条件から読んだ。

追加したテスト (すべて `tests/test_trace_context.nim`、仕様 ID は `MCP-TRACE-1`)。各テストは W3C Trace Context / W3C Baggage の規則を、コメントに書いてある。

- T1 `Given traceparent fields of the wrong length or alphabet, ...`: version・trace-id・parent-id・flags の桁数と小文字 16 進。
- T2 `Given tracestate keys outside the simple-key and multi-tenant grammars, ...`: 先頭文字、256 / 241 / 14 文字の上限、tenant と system の文字種。
- T3 `Given tracestate keys at the edge of the grammars, ...`: 上限ちょうどのキーは通る (T2 が「何でも拒む」実装で通らないようにする)。
- T4 `Given a tracestate value, when its length is checked, ...`: 値は 1〜256 文字。
- T5 `Given a tracestate of 32 members, ...`: 32 個は通る (既存のテストは 33 個が拒まれることだけを見ていた)。
- T6 `Given a baggage at the size limits, ...`: 8192 バイトと 64 メンバーは通り、1 つ超えると拒まれる。
- T7 `Given blanks around the equals signs of baggage members and properties, ...`: `key OWS "=" OWS value`。
- T8 `Given a baggage property that is not a token or a token=value, ...`: 不正なプロパティ。
- T9 `Given a malformed tracestate or baggage, when a context or params are checked, ...`: `validate` と `rejectInvalidTraceContext` が tracestate と baggage も扱う。
- T10 `Given params that are absent or not an object, when a trace context is added, ...`: `withTraceContext` の入力の型。

## 生き残りと timeout

| id | file:line | 変異 | 元 → 変異後 | 分類 | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 6 | trace_context.nim:32 | ROR | `text.len > 0` → `>=` | 1 同値 | `isLowerHex` を呼ぶ 4 か所は、どれも直前に桁数 (2, 32, 16, 2) を `or` の左で検査して短絡する。空文字列は届かない。 |
| 36 | :44 | LOR | `version.len != 2 or not isLowerHex(version)` → `and` | 3 穴 | T1 (`000-…` と `0g-…`) |
| 40 | :48 | LOR | `fields[2].len != 16 or not isLowerHex(fields[2])` → `and` | 3 穴 | T1 (parent-id 17 桁、16 桁で非 16 進) |
| 62, 63, 67, 70, 71 | :54, :90, :133, :166, :182 | SDL | 末尾の `none(...)` を `discard` に | 1 同値 | 関数の `result` は `Option` の既定値で、それは `none`。末尾の式を消しても同じ値を返す。 |
| 97 | :173 | RVR | `return none(JsonRpcError)` → 既定値 | 1 同値 | 同上 (`Option` の既定値は `none`)。 |
| 15 | :59 | ROR | `at < 0` → `<=` | 1 同値 | 差が出るのは `at == 0` (キーが `@` で始まる) だけ。元は tenant が空で `len in 1 .. 241` が偽、変異後は単純キーの枝で `key[0] in {'a'..'z'}` が偽。どちらも拒む。 |
| 44 | :60 | LOR | `(len in 1 .. 256) and (key[0] in a..z)` の `and` → `or` | 3 穴 | T2 (`1a=1`、257 文字のキー、`=1` は範囲外参照で異常終了) |
| 43 | :60 | LOR | 続く `and allCharsInSet(Tail)` → `or` | 3 穴 | T2 (`1a=1` ほか) |
| 49 | :63 | LOR | `tenant.len in 1 .. 241 and tenant[0] in …` → `or` | 3 穴 | T2 (`_a@sys=1`、242 文字の tenant) |
| 48 | :63 | LOR | `… tenant[0] in … and tenant.allCharsInSet(Tail)` → `or` | 3 穴 | T2 (`aB@sys=1`) |
| 47 | :64 | LOR | tenant の検査と `system.len in 1 .. 14` の間 → `or` | 3 穴 | T2 (system が 15 文字、`t@=1`) |
| 46 | :65 | LOR | `system.len …` と `system[0] in …` の間 → `or` | 3 穴 | T2 (`t@1x=1`) |
| 45 | :65 | LOR | `system[0] in …` と `system.allCharsInSet(Tail)` の間 → `or` | 3 穴 | T2 (`t@sysTEM=1`) |
| 16 | :68 | ROR | `value.len <= 256` → `!=` | 3 穴 | T4 (256 文字は通る、257 文字は拒まれる) |
| 51 | :68 | LOR | `value.len <= 256 and (…)` → `or` | 3 穴 | T4 (257 文字)。右辺は、メンバーを前後の空白で切ってから渡されるので常に真 (下の「残っているもの」)。 |
| 17 | :68 | ROR | `value.len == 0` → `!=` | 5 欠陥 | 元のコードは空の値 (`a=`) を通していた。W3C は `value = 0*255(chr) nblk-chr` で、最後の 1 文字 (`nblk-chr`) が必須なので空の値は不正。変異後は空の値で範囲外参照になる。先に T4 の `a=` が落ちることを確かめ、`value.len in 1 .. 256` に直した (`fix(trace_context)`)。 |
| 19 | :74 | ROR | `members.len > MaxTracestateMembers` → `>=` | 3 穴 | T5 (32 個は通る) |
| 20 | :80 | ROR | `eq < 0` → `<=` | 6 許容 | 差が出るのは `=v` (キーが空) だけ。元は `tracestate key '' is not valid`、変異後は `member '=v' is not key=value`。どちらも拒むので観測できる差は診断の文面だけ。 |
| 22 | :108 | ROR | `value.len > MaxBaggageBytes` → `>=` | 3 穴 | T6 (8192 バイトちょうどは通る) |
| 86 | :109 | RVR | 8192 バイト超の `return some(...)` → 既定値 | 3 穴 | T6 (8193 バイトは拒まれる) |
| 23 | :111 | ROR | `members.len > MaxBaggageMembers` → `>=` | 3 穴 | T6 (64 メンバーは通る) |
| 87 | :112 | RVR | 64 メンバー超の `return some(...)` → 既定値 | 3 穴 | T6 (65 メンバーは拒まれる) |
| 24 | :118 | ROR | `eq < 0` → `<=` | 6 許容 | 20 と同じ。`=value` で、元は `baggage key in '=value' is not a token`、変異後は `not key=value`。どちらも拒む。 |
| 4 | :122 | AOR | `pair[eq + 1 .. ^1]` → `eq - 1` | 3 穴 | T7 (`key = value`)。値の前にキーの末尾の 1 文字と `=` が付くが、どちらも baggage の値に使える文字なので、空白を挟まない入力では差が出ない。空白が値の途中に残って拒まれる。 |
| 25 | :127 | ROR | `propEq < 0` → `<=` | 1 同値 | 差が出るのは `=x` だけ。元は `not isToken("")` の枝、変異後は `not isToken("=x")` の枝で、`=` はトークンの文字ではないのでどちらも偽、返す文面も同じ (`baggage property '…' is not valid`)。 |
| 91 | :129 | RVR | トークンでないプロパティの `return some(...)` → 既定値 | 3 穴 | T8 (`k=v;bad prop`、`k=v;`) |
| 54 | :130 | LOR | `not isToken(key) or not isBaggageValue(value)` → `and` | 3 穴 | T8 (`k=v;=x`、`k=v;p=a b`) |
| 5 | :131 | AOR | `property[propEq + 1 .. ^1]` → `- 1` | 3 穴 | T7 (`k=v;p = x`) |
| 92 | :132 | RVR | `key=value` 形のプロパティの `return some(...)` → 既定値 | 3 穴 | T8 (`k=v;bad key=1`、`k=v;p=a b`) |
| 95 | :162 | RVR | `validate` の tracestate の `return problem` → 既定値 | 3 穴 | T9 (`validate` に不正な tracestate) |
| 96 | :165 | RVR | 同 baggage | 3 穴 | T9 |
| 59 | :195 | LOR | `params.isNil or params.kind != JObject` → `and` | 3 穴 | T10 (`nil` は異常終了、文字列は表明の失敗) |
| 32 | :29 | LOR | `isEmpty` の 2 つ目の `and` → `or` | timeout | 検出に数える。 |
| 33 | :29 | LOR | `isEmpty` の 1 つ目の `and` → `or` | timeout | 検出に数える。 |
| 74 | :42 | RVR | `traceparent needs …` の `return some(...)` → 既定値 | timeout | 検出に数える。1 項目しかない値が検査を通って `fields[1]` を読む。 |
| 94 | :159 | RVR | `validate` の traceparent の `return problem` → 既定値 | timeout | 検出に数える。 |

compileError の 5 件は、型が合わず測定の対象にならない変異。

## 残っているもの

- 分類 6 の id 20 と 24: 空のキーを「キーが不正」と言うか「`key=value` でない」と言うかは診断の文面の違いで、観測できる結果 (拒む) は同じ。文面を固定するテストは書かない。
- 分類 4 の疑い (リードの判断を待つ): 修正後の `isTracestateValue` の `value[^1] != ' '` は、呼び出し元の `validateTracestate` がメンバーを前後の空白で切ってから渡すので、常に真になる。
  単体の関数としては W3C の規則 (`nblk-chr` で終わる) を表しているので消さなかった。次の測定では、この節の変異が生き残りとして出る。
