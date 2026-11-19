# G2 変異検出: modern ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: 変異検査の道具 0.2.15、ジョブ `tests/mutation/modern.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 94 | 80 | 0 | 6 | 0 | 8 |

状態: 測定済み。生き残り 6 件はすべて `equivalent` (変異後の値が型の既定値と同じ)。足すテストは無い。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/protocol/modern.nim:SDL:ac1cdc5394dff63c:0` | modern.nim:121 | `validateModernRequest` の末尾の式 `none(JsonRpcError)` → `discard` | equivalent | 断る経路はすべて手前の `return some(...)` で抜ける。末尾の式を消すと暗黙の `result` が返り、`Option[JsonRpcError]` の既定値は none なので `none(JsonRpcError)` と同じ値になる。 | 無し |
| `src/protocol/modern.nim:RVR:f4c12547f4c7a4df:0` | modern.nim:139 | `resultKind` の `return rkComplete` → `return default(ResultKind)` | equivalent | 列挙値を返す return なので変異は `default(ResultKind)` になる。`ResultKind` は穴の無い列挙で最初の値 (序数 0) が `rkComplete` なので、返る値は同じ。 | 無し |
| `src/protocol/modern.nim:RVR:0c511227513989c7:0` | modern.nim:235 | `decodeHeaderValue` の `return none(string)` (詰め物の形が不正) → `return default(Option[string])` | equivalent | `Option[string]` の既定値は none で、`none(string)` と同じ値。呼び手 (`checkRequestHeaders` の `decoded.isNone`) から見える違いは無い。 | 無し |
| `src/protocol/modern.nim:RVR:0c511227513989c7:1` | modern.nim:239 | `decodeHeaderValue` の `return none(string)` (`base64.decode` の `ValueError`) → `return default(Option[string])` | equivalent | 同上。`Option[string]` の既定値は none。 | 無し |
| `src/protocol/modern.nim:RVR:0c511227513989c7:2` | modern.nim:251 | `headerNameSource` の `return none(string)` (名前を持たないメソッド、params がオブジェクトでない) → `return default(Option[string])` | equivalent | 同上。`Option[string]` の既定値は none で、呼び手 (`modernRequestHeaders` の `name.isSome`、`checkRequestHeaders` の `bodyName.isNone`) の分岐は変わらない。 | 無し |
| `src/protocol/modern.nim:SDL:ac1cdc5394dff63c:1` | modern.nim:315 | `checkRequestHeaders` の末尾の式 `none(JsonRpcError)` → `discard` | equivalent | 食い違いの経路はすべて手前の `return headerMismatch(...)` で抜ける。末尾の式を消すと暗黙の `result` (`Option[JsonRpcError]` の既定値 = none) が返り、同じ値になる。 | 無し |

測定: 変異検査の道具、ジョブ `tests/mutation/modern.json` (`src/protocol/modern.nim`)、本線の 36a4c8a5 (2026-10-07)。
行番号は 36a4c8a5 のもの。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 106 | 72 | 0 | 26 | 0 | 8 |

生き残り 26 件: 同値 (1) 9 件、穴 (3) 17 件。ほかの分類は 0 件。
分類 3 の 17 件は、変異を 1 件ずつ手で当てて、追加したテストが落ちることを確かめた (落ち方が「検査の失敗」でなく nil 参照の SIGSEGV / RangeDefect の件は、表に書いた)。
追加したテストはどれも `tests/test_modern_protocol.nim` にあり、ジョブの `testCommand` に既に入っている。ジョブの変更は無い。

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 67 | modern.nim:120 | SDL | `none(JsonRpcError)` → `discard` | 1 同値 | `func` の戻り値の既定値が `none`。文を消しても同じ値を返す。 |
| 88 | modern.nim:138 | RVR | `return rkComplete` → `return default` | 1 同値 | `ResultKind` の既定値 (序数 0) が `rkComplete`。 |
| 59 | modern.nim:235 | BLR | `strip(leading = false` → `true` | 1 同値 | 先頭に `=` があるとき、変異後の `isPaddedBase64` は真を返すが、続く標準ライブラリの `base64.decode` が先頭以外の `=` を `ValueError` で断り、`decodeHeaderValue` は結局 `none`。手で当てて確かめた (落ちるテスト無し、結果は同じ)。 |
| 94 | modern.nim:237 | RVR | `return false` → `return default` | 1 同値 | `bool` の既定値が `false`。 |
| 95 | modern.nim:240 | RVR | `return false` → `return default` | 1 同値 | 同上。 |
| 96 | modern.nim:248 | RVR | `return none(string)` → `return default` | 1 同値 | `Option[string]` の既定値が `none`。 |
| 98 | modern.nim:252 | RVR | 同上 | 1 同値 | 同上。 |
| 99 | modern.nim:264 | RVR | 同上 | 1 同値 | 同上。 |
| 80 | modern.nim:328 | SDL | `none(JsonRpcError)` → `discard` | 1 同値 | 67 と同じ。 |
| 37 | modern.nim:135 | LOR | `resultNode.isNil or resultNode.kind != JObject` の `or` → `and` | 3 穴 | `resultKind(nil)` が `rkComplete` (nil の結果は完了)。変異後は nil を参照して SIGSEGV。`Given no result or a result that is not an object, when classified, then it is complete` |
| 69 | modern.nim:152 | SDL | `doAssert ...` → `discard` | 3 穴 | 結果がオブジェクトでなければ `AssertionDefect`。変異後は `payload.copy()` 以降で nil を参照して SIGSEGV。`Given a result that is not a JSON object, when completed, then it is refused as a programming error` |
| 38 | modern.nim:152 | LOR | `not payload.isNil and payload.kind == JObject` の `and` → `or` | 3 穴 | 同じテスト (nil で SIGSEGV)。 |
| 44 | modern.nim:206 | LOR | `startsWith(prefix) and endsWith(suffix) and ...` の最初の `and` → `or` | 3 穴 | 前置だけ、または後置だけが封印に似た値は平文のまま。`Given values that only partly look like the sentinel, ...` (変異後は `RangeDefect`)。 |
| 18 | modern.nim:208 | ROR | `value.len >= ...` → `>` | 3 穴 | 空の中身の封印 `=?base64??=` (11 バイト) は封印。`Given the sentinel around an empty payload, ...` |
| 1 | modern.nim:208 | AOR | `prefix.len + suffix.len` → `prefix.len - suffix.len` | 3 穴 | `=?base64?=` (10 バイト) は封印ではなく平文。`Given values that only partly look like the sentinel, ...` (変異後は `RangeDefect`)。 |
| 90 | modern.nim:213 | RVR | `return true` → `return default` | 3 穴 | 空の値は平文。`Given the empty value, when encoded and decoded, then it stays plain` |
| 54 | modern.nim:213 | BLR | `return true` の `true` → `false` | 3 穴 | 同じテスト。 |
| 60 | modern.nim:237 | BLR | `return false` の `false` → `true` | 3 穴 | 詰め物 `=` が 3 個以上なら不正 (`SA======` は標準ライブラリが受け付けてしまう)。`Given a sentinel with more than two pad characters, ...` |
| 61 | modern.nim:240 | BLR | `return false` の `false` → `true` | 3 穴 | URL 安全な文字 (`-` `_`) は標準ライブラリが受け付けるが、RFC 4648 第 4 節では不正。`Given a sentinel whose payload uses the URL-safe alphabet, ...` |
| 48 | modern.nim:263 | LOR | `key.len == 0 or params.isNil` の `or` → `and` | 3 穴 | params が nil なら `none` (nil で SIGSEGV)。空のキーを持つ params でも、`Mcp-Name` を要しないメソッドでは `none`。`Given params that do not hold a string where Mcp-Name mirrors, ...` と `Given a method that carries no Mcp-Name, ...` |
| 47 | modern.nim:263 | LOR | `params.isNil or params.kind != JObject` の `or` → `and` | 3 穴 | 同じ (nil で SIGSEGV)。 |
| 49 | modern.nim:266 | LOR | `node.isNil or node.kind != JString` の `or` → `and` | 3 穴 | 項目が無い、文字列でないなら `none`。`Given params that do not hold a string where Mcp-Name mirrors, ...` (SIGSEGV)。 |
| 63 | modern.nim:274 | BLR | `extensionMethodServed = false` → `true` | 3 穴 | 拡張を提供しているとは言わないなら、`tasks/*` に `Mcp-Name` は要らない。`Given the extension methods, when asked without saying the extension is served, ...` |
| 51 | modern.nim:278 | LOR | `extensionMethodServed and methodName in ...` の `and` → `or` | 3 穴 | 拡張を提供していても `tools/list` は `Mcp-Name` を要しない。同じテスト。 |
| 52 | modern.nim:286 | LOR | `not version.isNil and version.kind == JString` の `and` → `or` | 3 穴 | `_meta` に文字列の版が無ければ版ヘッダを足さない。`Given a _meta without a string protocol version, when headers are built, then there is no version header` (SIGSEGV)。 |
| 64 | modern.nim:298 | BLR | `checkRequestHeaders` の既定値 `false` → `true` | 3 穴 | `Given a tasks/get with no Mcp-Name, when checked without saying the extension is served, then the headers agree` |

## 残っているもの

分類 4・5・6 は無い。分類 1 の 9 件は読んで決めた (59 だけは手で当てて確かめた)。
