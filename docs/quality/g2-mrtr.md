# G2 変異検出: mrtr ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: 変異検査の道具 0.2.15、ジョブ `tests/mutation/mrtr.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 129 | 98 | 0 | 20 | 0 | 11 |

状態: 測定済み。仕分けは式と呼び出し元を読んで行い、変異を当てて流してはいない (下の「足すテストの案」が実際に落ちるかは、足した後の測定で確かめる)。

仕分けの前提:

- `canonicalJson` (`src/protocol/hmac.nim`) を `src/` で呼ぶのは `server/request_state.nim` の `digestOf` だけで、`protocol/hmac` はどの公開の入口からも export されない。外から見えるのは「封印したときの salient と検証のときの salient が同じとみなされるか」だけになる。封印と検証は同じビルドの同じ関数を通るので、正準の文面が変わっても、違う値を違う文面に写すこと (単射) が保たれる変異は受け入れ・拒否を変えない。単射が壊れる変異は、別のパラメーターの要求に状態を使い回せるので穴とした。
- `tests/external/` のうち testCommand に入っていないファイルで、これらの変異を検出するものは見つからなかった (`verifyRequestState`・`sealRequestState`・`openRequestState`・`missingCapabilities` を呼ぶ外部のテストは `test_mrtr.nim` だけで、既に testCommand に入っている)。
- 前の記録の id 94・95・80 を検出していたテスト「Given a state that has no signature part, an empty body or a body that is not what the server seals…」は `tests/internal/test_mrtr_internal.nim` に移っている (`protocol/hmac` を直接 import して署名を作るため)。`specs/tests.map` の MCP-MRTR-10 のこの行も内部のテストを指している。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/protocol/hmac.nim:RVR:79d7670ba0e6d1dd:0` | hmac.nim:18 | nil のとき `return "null"` → `return ""` | spec_question | nil どうしの封印と検証は変異の前後とも通る。変わるのは、salient を省いて (nil) 封印した状態を JSON の null (`newJNull()`) の salient で検証したときで、元は受け入れ、変異は「issued for other parameters」で断る。この扱いを定める仕様 ID は無い。 | 問い: salient を省いた (nil) 封印と、JSON の null を salient にした検証を同じ要求とみなすことを仕様にしますか。しないなら nil の分岐は `$node` と区別のつかない実装の都合として同値に移します。 |
| `src/protocol/hmac.nim:ROR:20951720b0e24994:0` | hmac.nim:27 | オブジェクトの `i > 0` → `i >= 0` | equivalent | 空でないオブジェクトの文面が `{,` で始まるだけで、違う値は違う文面のまま (単射)、キーの順にも依らないまま。ダイジェストは同じビルドの封印と検証の間でしか比べないので、受け入れ・拒否は変わらない。 | — |
| `src/protocol/hmac.nim:SDL:a49fa4a3b3e69741:0` | hmac.nim:27 | オブジェクトの `result.add ','` → `discard` | equivalent | メンバーの間のカンマが消えても、次のメンバーは必ず引用符つきのキーで始まり、値 (文字列・数・リテラル・括弧つきの入れ子) の終わりは一意に決まるので、違うオブジェクトは違う文面のまま。受け入れ・拒否は変わらない (配列の側の同じ変異は数が繋がるので別の行で穴とした)。 | — |
| `src/protocol/hmac.nim:SDL:ae5a8451540aa71c:0` | hmac.nim:29 | `result.add '}'` → `discard` | test_owed | 閉じ括弧が無いと入れ子の深さが文面から消え、`{"a":{"b":1},"c":2}` と `{"a":{"b":1,"c":2}}` がどちらも `{"a":{"b":1,"c":2` になる。前者で封印した状態が後者の要求で受け入れられる。 | MCP-MRTR-10。`tests/external/test_mrtr.nim` の「sealed request state」に足す (下の案 A)。salient `{"a":{"b":1},"c":2}` で封印し `{"a":{"b":1,"c":2}}` で `verifyRequestState` → `problem` が some。変異だと none。 |
| `src/protocol/hmac.nim:ROR:20951720b0e24994:1` | hmac.nim:33 | 配列の `i > 0` → `i >= 0` | equivalent | 空でない配列の文面が `[,` で始まるだけで、単射のまま。オブジェクトの側の同じ変異と同じ理由。 | — |
| `src/protocol/hmac.nim:SDL:a49fa4a3b3e69741:1` | hmac.nim:33 | 配列の `result.add ','` → `discard` | test_owed | 要素の間のカンマが消えると数が繋がり、`[1,2]` と `[12]` がどちらも `[12]` になる。`{"arguments":[1,2]}` で封印した状態が `{"arguments":[12]}` の要求で受け入れられる。 | MCP-MRTR-10。案 A。salient `{"a":[1,2]}` で封印し `{"a":[12]}` で検証 → `problem` が some。変異だと none。 |
| `src/protocol/hmac.nim:SDL:7ae20fde9ed62b34:0` | hmac.nim:34 | `result.add canonicalJson(item)` → `discard` | test_owed | 配列の要素が文面に入らず、同じ長さの配列がすべて同じダイジェストになる (`[1,2]` も `[3,4]` も `[,]`)。配列の引数だけが違う要求に状態を使い回せる。既存のテストの salient は配列を含まない。 | MCP-MRTR-10。案 A。salient `{"a":[1,2]}` で封印し `{"a":[3,4]}` で検証 → `problem` が some。変異だと none。 |
| `src/protocol/hmac.nim:SDL:a162f0b4e9cd425c:0` | hmac.nim:35 | `result.add ']'` → `discard` | test_owed | 配列の閉じ括弧が無いと入れ子の深さが消え、`[[1],2]` と `[[1,2]]` がどちらも `[[1,2` になる。 | MCP-MRTR-10。案 A。salient `{"a":[[1],2]}` で封印し `{"a":[[1,2]]}` で検証 → `problem` が some。変異だと none。 |
| `src/protocol/mrtr.nim:SDL:2413a04126052c00:0` | mrtr.nim:73 | 末尾の `none(string)` → `discard` | equivalent | `validateInputRequests` の `result` は `Option[string]` で、代入しなければ既定値の none。末尾の式を捨てても返る値は none のまま。 | — |
| `src/protocol/mrtr.nim:SDL:2413a04126052c00:1` | mrtr.nim:92 | 末尾の `none(string)` → `discard` | equivalent | `invalidInputRequired` で上と同じ。`result` の既定値が none。 | — |
| `src/protocol/mrtr.nim:RVR:f37e8c77bd986dbd:0` | mrtr.nim:138 | `return none(JsonNode)` → 既定値 | equivalent | 構築子を返す return は `default(Option[JsonNode])` になり、それは none。 | — |
| `src/protocol/mrtr.nim:LOR:126924bca3024ea2:0` | mrtr.nim:147 | `not params.isNil and params.kind == JObject` → `or` | test_owed | params が nil でないときは、非オブジェクトでも `params{"includeContext"}` が nil を返して既定の `"none"` になるので結果は同じ。params が nil のときだけ、変異は `params.kind` で nil を読んで落ちる (元は「足りないものは無い」)。`missingCapabilities` は公開で、`params` の無い sampling の入力要求は `client/client.nim` の `missingCapabilities(%*{key: entry}, declared)` にもサーバーの結果から届く。既存のテストの sampling の要求はどれも params を持つ。 | MCP-MRTR-17 (該当する文面は MCP-SAMPLING-TOOLS-15 の「includeContext が無ければ sampling を宣言したどのクライアントにも送れる」)。案 C。`missingCapabilities(%*{"q": {"method": "sampling/createMessage"}}, %*{"sampling": {}}).len == 0`。変異だと nil の参照で落ちる。 |
| `src/protocol/mrtr.nim:SDL:f85418f42f56ae88:0` | mrtr.nim:155 | 末尾の `none(JsonNode)` → `discard` | equivalent | `undeclaredPart` の `result` の既定値が none。 | — |
| `src/protocol/mrtr.nim:RVR:0c511227513989c7:0` | mrtr.nim:192 | `return none(string)` → 既定値 | equivalent | `default(Option[string])` は none。 | — |
| `src/protocol/mrtr.nim:RVR:55560fa5ef49175d:0` | mrtr.nim:201 | `return none(JsonRpcError)` → 既定値 | equivalent | `default(Option[JsonRpcError])` は none。 | — |
| `src/protocol/mrtr.nim:SDL:ac1cdc5394dff63c:0` | mrtr.nim:215 | 末尾の `none(JsonRpcError)` → `discard` | equivalent | `rejectInvalidInputParams` の `result` の既定値が none。 | — |
| `src/server/mrtr.nim:RVR:3ac2bd94b4efe6f7:0` | server/mrtr.nim:53 | `return none(JsonNode)` → 既定値 | equivalent | `default(Option[JsonNode])` は none。 | — |
| `src/server/request_state.nim:ROR:d470e6c5a86b4fd8:0` | request_state.nim:60 | `dot <= 0` → `dot < 0` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。`.abc` のように本体が空の状態は、変異でも断られる: 署名が合わなければ「signature does not verify」、鍵の持ち主が空の本体に署名していても `parseJson("")` が失敗して「malformed」。変わるのは理由の文面だけで、その文面は `openRequestState` が stderr に書くだけで動作を分けない。 | — (前の記録の id 80 は文面を比べるテストで検出していた。そのテストは内部側に移っている) |
| `src/server/request_state.nim:RVR:2d1e0d0ec0050a35:1` | request_state.nim:69 | 本体が読めないときの `return failure("malformed")` → 既定値 | test_owed | 既定値は `(nil, none)` で、断らずに「受け入れ、payload は nil」になる。文面ではなく受け入れ・拒否が変わる。署名は正しいが本体が base64 や JSON でない状態で起きる (鍵の持ち主だけが作れる)。検出していたテストは `tests/internal/test_mrtr_internal.nim` に移っている。 | MCP-MRTR-10。案 B。鍵で署名した本体 `@@@@` と base64url の `not json` を `verifyRequestState` に渡す → `problem` が some。変異だと none。 |
| `src/server/request_state.nim:RVR:2d1e0d0ec0050a35:2` | request_state.nim:71 | 本体がオブジェクトでないときの `return failure("malformed")` → 既定値 | test_owed | 既定値の return で関数を抜け、`(nil, none)` の受け入れになる (期限・メソッド・パラメーター・主体の検査にも進まない)。署名は正しいが本体が `[1]` の状態で起きる。検出していたテストは内部側に移っている。 | MCP-MRTR-10。案 B。鍵で署名した base64url の `[1]` を `verifyRequestState` に渡す → `problem` が some。変異だと none。 |

### 足すテストの案

- 案 A (MCP-MRTR-10、`tests/external/test_mrtr.nim` の suite「sealed request state」): 「Given parameters that differ only in the items or the nesting of an array or an object, when a state sealed for one is verified for the other, then it is issued for other parameters」。同じファイルの `Key` と `sealRequestState`・`verifyRequestState` だけで書ける。4 組: `{"a":[1,2]}` / `{"a":[12]}`、`{"a":[1,2]}` / `{"a":[3,4]}`、`{"a":[[1],2]}` / `{"a":[[1,2]]}`、`{"a":{"b":1},"c":2}` / `{"a":{"b":1,"c":2}}`。hmac.nim:29・33 (SDL)・34・35 の 4 件。
- 案 B (MCP-MRTR-10、同じ suite): 内部のテストと同じことを、公開の入口だけで確かめる。署名の原始関数は公開ではないので、`tests/external/ext_auth_fixtures.nim` の `hmacSha256` (openssl を使う試験用の実装) で `body & "." & base64.encode(hmacSha256(Key, body), safe = true)` を作る。モジュールの冒頭の文書が「HMAC-SHA256 で署名し、base64url の本文に点で区切った署名を付ける」と述べているので、この形は文書にある範囲。見るのは `problem.isSome` で、文面は比べない。request_state.nim:69・71 の 2 件。足したら `specs/tests.map` の MCP-MRTR-10 の内部を指す行を、このテストに向け直す。
- 案 C (MCP-MRTR-17、`tests/external/test_mrtr.nim` の「Given a URL elicitation or sampling with tools, when compared with a client's capabilities…」に 1 行、または隣に 1 本): params の無い sampling の入力要求は、sampling を宣言したクライアントに足りないものが無い。mrtr.nim:147 の 1 件。

測定: 変異検査の道具、ジョブ `tests/mutation/mrtr.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/protocol/mrtr.nim`、`src/server/mrtr.nim`、`src/server/request_state.nim`。

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
