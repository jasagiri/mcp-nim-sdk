# G2 変異検出: ext_auth ジョブ (認可の拡張)

測定: `nim-muter`、ジョブ `tests/mutation/ext_auth.json`、拡張ブランチの c9b5c264 (初回の測定。比べる記録はない)。
対象は `src/ext/auth_client_credentials.nim`、`src/ext/auth_enterprise_managed.nim`、`src/ext/auth_shared.nim`、
`src/auth/oauth/grants.nim`、`src/auth/oauth/jwt.nim`。
2026-10-12 に `src/auth/oauth/jwt.nim` を変えた (`decodeSegment` の埋めるループを消した)。次の測定で測り直す。
同じ日に `src/ext/auth_enterprise_managed.nim` の `newEnterpriseManagedAuth` と `checkIdentityAssertionGrant` の `raises` から `OAuthSecurityError` を外した (親の `OAuthError` が覆う。`XCannotRaiseY` の Hint が出ることを Nim 2.2.12 で確かめた)。次の測定で測り直す。
2026-10-15 に登録の版の確かめを `official_common.requireTargetSpoken` (公式拡張ごとの対象の版) に替えたので、それ以後の行番号はずれている (`g2-protocol-versions.md` の「未測定 (公式拡張の対象の版)」)。`requireExtensionsCapability` (ビルドの既定の版を見ていた) は消え、宣言は側の上限の版で確かめる。下の「分類 2」は消す前の記録である。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 204 | 139 | 2 | 50 | 0 | 13 |

生き残り 50 件の分類 (ファイル別の内訳は表の各行にある)。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 7 |
| 2 別のビルドで検出される (ジョブの `testCommand` に足した) | 4 |
| 3 穴 (テストを追加。全件で変異を手で当てて落ちるのを確認) | 38 |
| 4 到達しない・冗長 | 1 |
| 5 不具合 | 0 |
| 6 許容 | 0 |
| 計 | 50 |

トークン・署名・発行者・audience の受け入れを決める検査 (`checkIdentityAssertionGrant` の `iss` と `client_id`、
期限の境界、JWT の署名部と `alg`、`clientAssertion` の `client_id` / `aud`) の生き残りは、すべて分類 3 とし、テストを足した。
分類 6 は 1 件もない。

## 変異の当て方についての注意

nim-muter は `a or b or c` の `or` を 1 つずつ `and` にする。構文木の上では内側の `or` を変えると `(a and b) or c`、
外側を変えると `(a or b) and c` になる。文字列として `a or b and c` と書くと `and` が強く結ぶので別の式になる。
手で当てるときは括弧を付けて両方を試した (id 118 / 119、60 / 61、121、198、52、48)。
`RVR` の `return false` は `return true` として当てた。`BLR` の `false` → `true` と同じ編集なので、
同じ行の RVR と BLR (146 と 122、147 と 123、148 と 124、98 と 66、99 と 67、100 と 68) は 1 回の実行で両方を確かめた。

## 分類 1: 同値

`authorizationHeader` と `claimStrings` の `return none(...)` は、`RVR` が `default(Option[T])` に替える。
`Option[T]` の既定値は `none` で、`return none(...)` と同じ値になる (リテラルではないので、`return false` のような反転は起きない)。

| id | 場所 | mutator | 元 → 変異 | 理由 |
|---|---|---|---|---|
| 142 | `auth_client_credentials.nim:177` | RVR | `return none(string)` → 既定値 | `default(Option[string])` は `none(string)` |
| 143 | `auth_client_credentials.nim:181` | RVR | 同上 | 同上 |
| 144 | `auth_client_credentials.nim:188` | RVR | 同上 | 同上 |
| 90 | `auth_enterprise_managed.nim:170` | RVR | `return none(seq[string])` → 既定値 | `default(Option[seq[string]])` は `none` |
| 94 | `auth_enterprise_managed.nim:343` | RVR | `return none(string)` → 既定値 | 同上 |
| 95 | `auth_enterprise_managed.nim:347` | RVR | 同上 | 同上 |
| 96 | `auth_enterprise_managed.nim:355` | RVR | 同上 | 同上 |

## 分類 2: 別のビルドで検出される

`requireExtensionsCapability` は、`extensions` capability を持つ版を話さないビルドでだけ `ValueError` を出す。
既定のビルド (2026-07-28) では呼んでも何も起きないので、文を消してもテストは落ちない。
該当のテスト「Given a build that speaks no version with the extensions capability, ...」は両ファイルに既にあり、
`-d:mcpDefaultProtocolVersion=2025-11-25` でコンパイルしたときだけ中身が走る。変異を当ててこの版のビルドで実行し、落ちるのを確認した。
ジョブの `testCommand` に、その 2 ファイルを同じフラグで走らせる 2 本を足した (`test(mutation)`)。

| id | 場所 | mutator | 元 → 変異 | 検出するテスト |
|---|---|---|---|---|
| 133 | `auth_client_credentials.nim:236` | SDL | `requireExtensionsCapability(...)` → `discard` | `test_ext_auth_client_credentials.nim` の「Given a build that speaks no version with the extensions capability, ...」 (2025-11-25 のビルド) |
| 135 | `auth_client_credentials.nim:245` | SDL | 同上 | 同上 |
| 85 | `auth_enterprise_managed.nim:404` | SDL | 同上 | `test_ext_auth_enterprise_managed.nim` の同名のテスト (2025-11-25 のビルド) |
| 87 | `auth_enterprise_managed.nim:413` | SDL | 同上 | 同上 |

## 分類 3: 穴 (追加したテスト)

追加したテストはどれも、変異を手で当てて落ちるのを見て、元に戻して通るのを確認した。
ファイルは `tests/test_ext_auth_grants.nim` (G)、`tests/test_ext_auth_client_credentials.nim` (C)、`tests/test_ext_auth_enterprise_managed.nim` (E)。
`handleChallenge` は公開の手続きなので、403 / 500 / 見出しの無い 401 のようにトランスポートからは作りにくい入力は直接呼んで確かめた。

### grants.nim と jwt.nim

| id | 場所 | mutator | 元 → 変異 | 検出するテスト |
|---|---|---|---|---|
| 151 | `grants.nim:103` | ROR | `auth.lifetime > DurationZero` → `>=` | G「Given a private_key_jwt client without a lifetime, ... the assertion lives one minute」 (寿命 0 だと `exp` = `iat`。サーバーが拒み、`exp - iat == 60` も崩れる) |
| 152 | `grants.nim:118` | ROR | `scopes.len > 0` → `>=` | G「Given a client secret sent in the body, ...」に足した `scope` が無いことの検査 |
| 153 | `grants.nim:130` | ROR | 同上 | G「Given an ID-JAG like assertion, ...」に足した同じ検査 |
| 170 | `grants.nim:131` | SDL | `fields.add ("scope", ...)` → `discard` | G「Given scopes, when the JWT bearer grant is requested, ...」 (この `scope` は拡張の経路では常に空なので、直接の呼び出しでだけ確かめられる) |
| 161 | `grants.nim:179` | ROR | `request.scopes.len > 0` → `>=` | G「Given a subject token and no scopes, when exchanged, ...」 |
| 195 | `jwt.nim:57` | LOR | `sign.isNil or alg.len == 0` → `and` | G「Given a signer with no signing function or no algorithm, ...」 (関数が無いまま呼んで落ちる = SIGSEGV で検出) |
| 196 | `jwt.nim:76` | LOR | `segment.len == 0 or not allCharsInSet` → `and` | G「Given a JWT whose signature is empty or not base64url, ...」 (空の署名部、`+`、`=`) |
| 187 | `jwt.nim:91` | ROR | `token.len > MaxJwtLength` → `>=` | G「Given a JWT of exactly the largest accepted length and one a byte longer, ...」 |
| 198 | `jwt.nim:106` | LOR | `alg` が無い / 文字列でない / 空 の判定の `or` → `and` | G「Given a header whose alg is missing, not a string or empty, ...」 (内側を変えると `alg` 欠落で落ち、外側を変えると `alg: ""` で落ちる。報告に残っていたのは外側) |
| 200 | `jwt.nim:117` | LOR | `clientId.len == 0 or audience.len == 0` → `and` | G「Given a client assertion without a client_id or without an audience, ...」 |

### auth_client_credentials.nim

| id | 場所 | mutator | 元 → 変異 | 検出するテスト |
|---|---|---|---|---|
| 126 | `:94` | SDL | 既定の `now` の `getTime()` → `discard` | C「Given the default clock, when a signing client requests a token, ...」 (時刻 0 の assertion は `exp` が過去でサーバーが拒む) |
| 128 | `:187` | SDL | `tokenStore.remove(...)` → `discard` | C「Given an expired token and an authorization server that now refuses the client, ...」 (更新が拒まれた後の次の要求で、トークン要求が 1 回か 2 回かを数える) |
| 119 | `:197` | LOR | 内側の `or` → `and` | C「Given a 403 that is no insufficient_scope challenge, or a status that is no challenge, ...」 (見出し無しの 403 で `none` の値を取り出して落ちる) |
| 118 | `:197` | LOR | 外側の `or` → `and` | 同上 (同じ入力で落ちる。`error="invalid_token"` の 403 は、この変異では要求を続けてしまうので、同じテストの 3 つ目の検査が別に捉える) |
| 146、122 | `:198` | RVR、BLR | `return false` → `true` | 同上 (戻り値が `true`) |
| 147、123 | `:200` | RVR、BLR | `return false` → `true` | 同上 (状態 500 の戻り値が `true`。トランスポートは 401 と 403 でしか呼ばないので、直接の呼び出しで確かめた) |
| 121 | `:211` | LOR | `scopeFromChallenge and bearer.isSome and ...` の最初の `and` → `or` | C「Given a 401 without any challenge header, when handled, ...」 (見出し無しの 401。変異では `none` から取り出して落ちる) |
| 148、124 | `:218` | RVR、BLR | `return false` → `true` | C「Given a 403 that names a scope already requested, ...」 (戻り値が `true` になり、新しいトークンを求めない規則が崩れる) |

### auth_enterprise_managed.nim

| id | 場所 | mutator | 元 → 変異 | 検出するテスト |
|---|---|---|---|---|
| 70 | `:134` | SDL | 既定の `now` の `getTime()` → `discard` | E「Given the default clock, when a request is sent, then the ID-JAG is judged against now and accepted」 (時刻 0 だと `exp` が「10 年より先」になり拒まれる) |
| 48 | `:218` | LOR | `iss` が無い / 文字列でない の `or` → `and` | E「Given an ID-JAG without iss or without client_id, ...」 (`iss` 欠落で `nil` を読んで SIGSEGV) |
| 52 | `:224` | LOR | `client_id` について同じ | 同上 |
| 25 | `:234` | ROR | `exp <= now` → `<` | E「Given an ID-JAG that expires at this very second, ...」 |
| 8 | `:282` | AOR | `expiresAt - 30 s` → `+` | E「Given an access token that expires when the ID-JAG has 31 or 30 seconds left, ...」 (残り 30 秒のとき、元は新しく交換し、変異は同じ ID-JAG を出す) |
| 31 | `:282` | ROR | `expiresAt - 30 s > now` → `>=` | 同上 (残りちょうど 30 秒の境界) |
| 35 | `:331` | ROR | `issued.scopes.len == 0` → `!=` | E「Given an authorization server that grants a narrower scope than was asked, ...」と「... names no scope in its answer, ...」 (保存されるトークンの scope が、サーバーの答えのもの / 求めたもの) |
| 80 | `:354` | SDL | `tokenStore.remove(...)` → `discard` | E「Given an expired access token and an IdP that now refuses, ...」 |
| 61 | `:365` | LOR | 内側の `or` → `and` | E「Given a 403 that is no insufficient_scope challenge, or a status that is no challenge, ...」 |
| 60 | `:365` | LOR | 外側の `or` → `and` | 同上 |
| 98、66 | `:366` | RVR、BLR | `return false` → `true` | 同上 |
| 99、67 | `:368` | RVR、BLR | `return false` → `true` | 同上 |
| 63 | `:379` | LOR | `scopeFromChallenge and bearer.isSome and ...` の最初の `and` → `or` | E「Given a 401 without any challenge header, when handled, ...」 |
| 100、68 | `:386` | RVR、BLR | `return false` → `true` | E「Given a 403 that names a scope already requested, ...」 |

追加したテストは 2025-06-18 (チャレンジの scope が無く、見出し無しの 401 は well-known に頼れない) と 2025-11-25 のビルドでも通る。
版で挙動が変わる検査は、隣のテストと同じく `ScopeChallenges` で分けた。

## 分類 4: 到達しない・冗長

| id | 場所 | mutator | 元 → 変異 | 理由 |
|---|---|---|---|---|
| 186 | `jwt.nim:80` | ROR | `standard.len mod 4 != 0` → `==` | `decodeSegment` が `=` で埋める 2 行 (80-81) は、標準ライブラリの `base64.decode` が入力の末尾の `=` をすべて切り落としてから復号する (Nim 2.2.8 の `lib/pure/base64.nim:249`) ため、埋めても埋めなくても結果が変わらない。変異は長さが 4 の倍数のときに `=` を 1 つ足すだけで、これも切り落とされる。**決定 2026-10-12**: 2 行を消した。Nim 2.2.12 の `base64.decode` が、埋めた入力と埋めない入力で同じ結果になることを、4 の倍数でない長さ 0 から 12 の乱数列 (各長さ 2 万本、`-_+/` を含む) で比べて確かめた (違いは 0 件)。E テスト 2 本を足した (`MCP-EXT-AUTH-7`: 長さの 3 を法とする余りごとに埋め無しの本文と署名が戻ること、4 で割って 1 余る長さの扱い)。確かめたのは 2.2.12 だけで、`requires nim` が 2.2.12 に上がるまでの下限 (2.0.0) の版では確かめていない |

## timeout 2 件

どちらも `decodeSegment` の埋めるループを終わらなくする変異で、テストが無制限に待つのではなく、変異が無限ループを作っている。
- id 179 (`jwt.nim:80` AOR): `standard.len mod 4` → `div`。長さが 4 以上なら条件が真のまま、`=` を足し続ける (長さは増えるばかり)。
- id 202 (`jwt.nim:81` SDL): `standard.add '='` → `discard`。長さが変わらないので条件が偽にならない。

どちらも timeout として検出される扱いでよい。手では当てていない (ループが終わらないため。240 秒の上限に頼るのは機械の負担になる)。

## 残っているもの

分類 4 の 1 件 (id 186) は 2026-10-12 に消した (上の表)。それ以外に、許容も未確認も残っていない。

4 で割って 1 余る長さの断片は、`base64.decode` が最後の 1 文字を捨てて読む。本文と見出しでは JSON にならず拒否されるが、署名では `YWJjZ` が `abc` になって受け入れられる (埋めていたときも同じ)。テストで現状を固定した。拒否すべきかは決めていない。
