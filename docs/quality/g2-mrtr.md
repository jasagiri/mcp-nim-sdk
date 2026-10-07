# G2 変異検出: mrtr ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/mrtr.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/protocol/mrtr.nim`、`src/server/mrtr.nim`、`src/server/request_state.nim`。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 105 | 70 | 0 | 24 | 0 | 11 |

生き残り 24 件の分類。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 8 |
| 2 / 2b 既存または測定後のテストが検出 | 0 |
| 3 穴 (テストを追加) | 16 |
| 4 到達しない・冗長なコード | 0 |
| 5 欠陥 | 0 |
| 6 許容 | 0 |

`request_state.nim` はサーバーの状態がクライアントを経由する部分で、署名・鍵・期限・要求への結び付きを検査する。この検査を弱める変異は、受け入れずに穴として扱った。

分類 3 の 16 件は、変異を 1 件ずつ手で当てて、追加したテストが落ちることを確かめた。変異なしでは `tests/test_mrtr.nim` が既定の版と `-d:mcpDefaultProtocolVersion=2025-11-25` の両方で通る (46 件)。追加前の `test_mrtr.nim` が落ちないことを手で確かめたのは id 94、95、25、61、44、38 の 6 件で、他の 10 件はその点を報告の「生き残り」に頼っている (測定より後に足されたテストが検出する可能性は、この 10 件では調べていない)。追加したテストは版に依存しない関数と、`request_state` の純粋な検査だけなので、版の囲いは要らない。

## 分類 1 の根拠

`Option[T]` の既定値は `none` なので、`return none(T)` を既定値にしても、末尾の `none(T)` を `discard` にしても (`result` を代入しないので)、返す値は変わらない。

| id | file:行 | 変異 | 元 → 変異 |
|---:|---|---|---|
| 47 | protocol/mrtr.nim:73 | SDL | `none(string)` → `discard` |
| 48 | protocol/mrtr.nim:92 | SDL | `none(string)` → `discard` |
| 68 | protocol/mrtr.nim:138 | RVR | `return none(JsonNode)` → 既定値 |
| 52 | protocol/mrtr.nim:147 | SDL | `none(JsonNode)` → `discard` |
| 72 | protocol/mrtr.nim:184 | RVR | `return none(string)` → 既定値 |
| 73 | protocol/mrtr.nim:193 | RVR | `return none(JsonRpcError)` → 既定値 |
| 57 | protocol/mrtr.nim:207 | SDL | `none(JsonRpcError)` → `discard` |
| 105 | server/mrtr.nim:39 | RVR | `return none(JsonNode)` → 既定値 |

## 分類 3

| id | file:行 | 変異 | 元 → 変異 | 理由 | 検出するテスト |
|---:|---|---|---|---|---|
| 61 | protocol/mrtr.nim:61 | RVR | `return some("inputRequests must be an object")` → 既定値 | 配列や文字列の `inputRequests` が検査を通る。 | 「something that is not an InputRequests map」 |
| 25 | protocol/mrtr.nim:66 | LOR | `methodNode.isNil or` → `and` | `method` の無い入力要求で nil の `kind` を読み `SIGSEGV`。nil でない非文字列は `getStr` の空文字で結局拒否されるため差が出ない。 | 同上 |
| 38 | protocol/mrtr.nim:177 | LOR | `params.isNil or` → `and` | nil の params で `SIGSEGV`。nil でない非オブジェクトでは `{}` が nil を返すので差が出ない。 | 「params that are nil or not an object」 |
| 71 | protocol/mrtr.nim:178 | RVR | `return newJObject()` → 既定値 | nil の params に nil (空のオブジェクトでなく) を返す。 | 同上 |
| 40 | protocol/mrtr.nim:183 | LOR | `params.isNil or` → `and` | `requestStateOf` で 38 と同じ。 | 同上 |
| 42 | protocol/mrtr.nim:192 | LOR | `params.isNil or` → `and` | `rejectInvalidInputParams` で 38 と同じ。 | 同上 |
| 44 | protocol/mrtr.nim:216 | LOR | `original.isNil or` → `and` | nil や非オブジェクトの元の params からの再試行で `SIGSEGV` またはアサーション。 | 同上 |
| 88 | server/request_state.nim:31 | BLR | 署名の `safe = true` → `false` | 署名に `+` と `/` が入る。検証は同じ関数で署名するので往復は壊れず、状態が URL・ヘッダにそのまま載るという性質だけが失われる。 | 「payloads that make plain base64 use + and /」 |
| 89 | server/request_state.nim:45 | BLR | 本体の `safe = true` → `false` | 本体に `+` と `/` が入る (`???` と `~~~` を含む載荷で確かめる)。 | 同上 |
| 79 | server/request_state.nim:40 | ROR | `key.len < MinKeyBytes` → `<=` | ちょうど 16 バイトの鍵で封印できない。 | 「key of exactly the minimum length」 |
| 81 | server/request_state.nim:57 | ROR | 検証の `key.len < MinKeyBytes` → `<=` | ちょうど 16 バイトの鍵で検証できない。15 バイトの鍵の検証が「malformed」になることも同じテストで確かめる。 | 同上 |
| 94 | server/request_state.nim:66 | RVR | 本体が JSON として読めないときの `return failure("malformed")` → 既定値 | 署名が正しいが本体が壊れた状態が、payload nil の「受け入れ」として返る。鍵の持ち主しか作れないが、ハンドラーに nil を渡す。 | 「state that has no signature part, an empty body or a body that is not what the server seals」 |
| 95 | server/request_state.nim:68 | RVR | 本体がオブジェクトでないときの `return failure("malformed")` → 既定値 | 94 と同じ (`[1]` を署名した状態)。 | 同上 |
| 80 | server/request_state.nim:57 | ROR | `dot <= 0` → `< 0` | `.abc` のように先頭が区切りの状態を「malformed」でなく「signature does not verify」とする。判定は拒否のまま変わらない (空の本体の署名は鍵なしには作れない) が、理由が変わる。 | 同上 |
| 83 | server/request_state.nim:69 | ROR | `getBiggestInt() < int64(now)` → `<=` | 有効期限の最後の 1 秒で拒否する (より厳しい側)。「ttlSeconds のあいだ有効」を境界で確かめていなかった。 | 「sealed at a time with a lifetime」 |
| 91 | server/request_state.nim:86 | SDL | 拒否の理由を stderr に書く `stderr.writeLine(...)` → `discard` | `openRequestState` のコメントが「理由は stderr に出し、相手には出さない」と主張している。相手に出ない側は既存のテストにあったが、stderr に出る側が無かった。 | 「method and the reason go to stderr」 |

## 残っているもの

何も残っていない。分類 1 の 8 件は式から読んだ同値で、分類 3 の 16 件は追加したテストが検出する。
署名・鍵・期限・要求への結び付き (方法・パラメーター・主体) の検査を弱める変異のうち、元のテストが見逃していたものは id 94、95 (壊れた本体を受け入れる)、79、81 (鍵長の境界)、83 (期限の境界) だった。署名の検証そのもの、メソッド・パラメーター・主体の結び付きは、報告では生き残りに無い (手で当て直してはいない)。
