# G2 変異検出: auth_client ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: 変異検査の道具 0.2.15、ジョブ `tests/mutation/auth_client.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 77 | 62 | 0 | 11 | 0 | 4 |

状態: 測定済み。生き残り 11 件: equivalent 5、test_owed 6。timeout は無い。

test_owed の 6 件は、前の測定で検出していたテストが `tests/internal/test_auth_client_flow_internal.nim` に移ったために残った。
`tests/external/` のうち testCommand に入っていないファイル (`test_auth_oauth_basics.nim`、`test_security_auth_tokens.nim`、`test_auth_resource_server.nim` など) も読んだが、この 6 件を検出するものは無かった。testCommand に足すだけで済むものは無い。
内部に移った 5 本のうち、公開でないもの (`auth/oauth/urls` の `canonicalResource`) を使うのは保存の鍵を作るところだけで、下の案はどれもそれを使わずに `auth/client` と `tests/external/auth_fixtures.nim` だけで書ける。
MCP-AUTH-29 の Scenario の文面は「更新する」「使えなくなったら認可し直す」「保存したトークンを先に出す」までで、「使えない更新トークンを保存から消す」「資格情報は発行者にだけ送る」を文としては持たない。`specs/tests.map` がこれらのテストを MCP-AUTH-29 に結んでいるので、それに従って test_owed とした。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/auth/client.nim:RVR:0c511227513989c7:0` | client.nim:137 | `return none(string)` → `<return default>` | equivalent | リテラルではないので `default(Option[string])` になり、それは `none(string)`。保存が空のとき見出しが無い、は変わらない。 | - |
| `src/auth/client.nim:RVR:0c511227513989c7:1` | client.nim:141 | `return none(string)` → `<return default>` | equivalent | 同上 (`Option[string]` の既定値は none)。 | - |
| `src/auth/client.nim:RVR:0c511227513989c7:2` | client.nim:144 | `return none(string)` → `<return default>` | equivalent | 同上。 | - |
| `src/auth/client.nim:ROR:9e5043ed0cbe5649:0` | client.nim:149 | `creds.get.issuer != tokens.issuer` → `==` | test_owed | 変異後は、資格情報の発行者がトークンの発行者と同じ (通常) のとき更新せずに none を返し、違うときに更新トークンと資格情報を送る。通常の流れでは、見出し無しの要求に 401 が返って `handleChallenge` が更新するので、既存の「refreshed without the user」は通ってしまう。前に検出していた `Given credentials whose issuer is not the one that issued the token …` は内部に移った。 | MCP-AUTH-29。`tests/external/test_auth_client_flow.nim` の「when a stored token cannot be refreshed」の suite に足す。(a) 認可を済ませ、`env.config.credentialStore` の `env.authServer.issuer` の項の `issuer` を別の値に書き換えて保存し、時計を 5 分進めて `client.authorizationHeader()` を呼ぶ: none で、`env.tokenRequests` が増えない (変異だと更新の要求が 1 つ増える)。(b) 書き換えずに同じことをすると some で、`/token` への要求が 1 つ増える (変異だと none)。どちらか 1 つで検出できる。補助は同ファイルの `start`・`transportFor`・`ping`・`tokenRequests`。 |
| `src/auth/client.nim:RVR:0c511227513989c7:3` | client.nim:150 | `return none(string)` → `<return default>` | equivalent | 同上 (`Option[string]` の既定値は none)。 | - |
| `src/auth/client.nim:SDL:d1c59a1b624273ac:0` | client.nim:161 | `c.config.tokenStore.remove(c.tokenKey)` → `discard` | test_owed | `authorizationHeader` で更新が断られたとき、使えないトークンが保存に残る。次に見出しを求めるたびに、断られた更新トークンをまた送る。通信路を通すと次の 401 で `handleChallenge` の側 (330 行) が消すので、既存のテストでは見えない。前に検出していた `… then there is none and the spent token is forgotten` は内部に移った。 | MCP-AUTH-29。同じ suite に足す。認可を済ませ (`accessTokenLifetime = 60`)、`env.authServer.refreshTokens.clear()`、時計を 5 分進め、`client.authorizationHeader()` を 2 回呼ぶ: どちらも none で、`env.tokenRequests` の増え方が 1 (変異だと 2)。または `env.config.tokenStore.remove` を記録する閉包に替え、呼ばれたことを見る (`Store` の欄は公開)。 |
| `src/auth/client.nim:RVR:0c511227513989c7:4` | client.nim:162 | `return none(string)` → `<return default>` | equivalent | 同上 (`Option[string]` の既定値は none)。 | - |
| `src/auth/client.nim:SDL:d28df79362e7c028:0` | client.nim:163 | `c.config.tokenStore.save(c.tokenKey, tokens)` → `discard` | test_owed | 更新したトークンが保存されず、その要求には新しいトークンが付くが、次の要求で期限切れの古いトークンからもう一度更新する。既存の「refreshed without the user」は更新のあと 1 回しか要求しないので見えない。前に検出していた `Given a refresh that succeeded … is not refreshed again` は内部に移った。 | MCP-AUTH-29 (「保存したものを先に出す」)。「refreshing」の suite に足す。`accessTokenLifetime = 3600` で認可し、時計を 2 時間進め、`ping` を 2 回: `env.tokenRequests == 2` (code の交換と更新 1 回。変異だと 3 回目の要求でまた `/token` に行く)。加えて最後の `/mcp` の `bearerOf` が、その前の要求のものと同じ。保存の中身まで見るなら `tests/external/test_auth_client_g0f.nim` の `recordingStore` と同じ形の保存を渡す。 |
| `src/auth/client.nim:ROR:a9ee5c4b6705b698:0` | client.nim:205 | `parseUri(url).scheme.toLowerAscii() != "https"` → `==` | test_owed | 変異後は https の Client ID Metadata Document の URL がすべて断られる (http は直前の `checkFetchUrl` が、ループバックを許さない方針で先に断るので、元の式のこの半分は常に偽)。外部のテストは断られる場合 (経路なし・http・ループバック) だけを見ていて、正しい URL が使われる場合を見るテストは内部に移った (`Given an authorization server that supports Client ID Metadata Documents, when the client has such a URL, then it uses it and does not register`)。 | MCP-AUTH-26 (「it uses it as its client_id and does not register」)。`tests/external/test_auth_client_flow.nim` の「client registration」の suite に足す。2025-11-25 で `env.authServer.metadata["client_id_metadata_document_supported"] = %true`、`clientIdMetadataUrl = some("https://app.example.com/oauth/client-metadata.json")`、`authorizerFor(env.authServer, seen)` で認可: `ping` が通り、`seen[][0].queryValue("client_id")` がその URL で、`/register` への要求が 0 (変異だと `OAuthSecurityError` で `ping` が失敗する)。内部のテストは `auth/client` と `auth_fixtures` しか使っておらず、同じ内容で書ける。 |
| `src/auth/client.nim:RVR:069257ddf8f1c04f:0` | client.nim:240 | `return ClientCredentials(issuer: issuer, clientId: c.config.clientIdMetadataUrl.get, authMethod: "none", redirectUris: @[c.config.redirectUri])` → `<return default>` | test_owed | 構築子を返すので `default(ClientCredentials)` になり、`client_id` が空のまま認可の要求が出る (登録はしないまま)。偽の認可サーバーはどの `client_id` にも code を出すので、流れは最後まで通る。`client_id` を見るテストは内部に移った (上の行と同じテスト)。 | MCP-AUTH-26。上の行と同じ 1 本 (`client_id` が URL に等しい、の検査が検出する)。 |
| `src/auth/client.nim:SDL:d1c59a1b624273ac:1` | client.nim:330 | `c.config.tokenStore.remove(c.tokenKey)` → `discard` | test_owed | `handleChallenge` で更新が断られたあと、認可が成功すれば 346 行の `save` が上書きするので違いは出ない。認可が失敗する (利用者が拒む) と、取り消されたトークンが保存に残り、次の要求でまた出される。前に検出していた `Given a refresh token the server rejects and a user who then refuses …` は内部に移った。 | MCP-AUTH-29。「when a stored token cannot be refreshed」の suite に足す。認可を済ませ、`env.authServer.refreshTokens.clear()`、`authorize` を `denyingAuthorizer()` に替えた設定 (保存は共有) の client で `handleChallenge(401, env.resourceChallenge)` が例外。そのあと `newOAuthClient(env.config).authorizationHeader()` が none (変異だと、残った古いトークンの `Bearer …` が返る)。補助 `denyingAuthorizer`・`resourceChallenge` は外部のファイルに既にある。 |

測定: 変異検査の道具、ジョブ `tests/mutation/auth_client.json` (`src/auth/client.nim`、`src/auth/policy.nim`)、本線の 36a4c8a5 (2026-10-07)。
2026-10-12 に `client.nim` の `newOAuthClient` の raises を狭めた (`OAuthSecurityError` は `OAuthError` の子で、Nim 2.2.12 の `XCannotRaiseY` が重複と指した)。次の測定で測り直す。
行番号は 36a4c8a5 のもの (`client.nim` はその後 `resource` 指標 (`indicator`) の分だけ変わった。手で当てるときは文面で探した)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 77 | 52 | 0 | 21 | 0 | 4 |

生き残り 21 件: 同値 (1) 7 件、穴 (3) 14 件。ほかの分類は 0 件。
認可は安全に関わるコードなので、どの資格情報やトークンをどこへ送るか、どの検査が走るか、何度やり直すかを変える変異は、1 件も許容に回していない。
分類 3 の 14 件は、変異を 1 件ずつ手で当てて、追加したテストが落ちることを確かめた。
テストはすべて `tests/test_auth_client_flow.nim` にあり (ジョブの `testCommand` に既に入っている。ジョブの変更は無い)、
認可のある 4 つの版 (2025-03-26 / 2025-06-18 / 2025-11-25 / 2026-07-28) それぞれで通る。

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 61 | client.nim:134 | RVR | `return none(string)` → `return default` | 1 同値 | `Option[string]` の既定値が `none`。 |
| 62 | client.nim:138 | RVR | 同上 | 1 同値 | 同上。 |
| 63 | client.nim:141 | RVR | 同上 | 1 同値 | 同上。 |
| 64 | client.nim:147 | RVR | 同上 | 1 同値 | 同上。 |
| 65 | client.nim:159 | RVR | 同上 | 1 同値 | 同上。 |
| 74 | client.nim:300 | RVR | `return false` → `return default` | 2 | **訂正 (2026-10-10)**: 同値ではない。変異検査の道具 の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_auth_client_flow.nim` が落ちる (「Given a 403 that is not an insufficient_scope challenge …」「Given a status other than 401 or 403 …」、本線 qzktpvsz、2026-10-10)。 |
| 75 | client.nim:302 | RVR | 同上 | 2 | **訂正 (2026-10-10)**: 同値ではない。変異検査の道具 の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。`return true` を手で当てると `tests/test_auth_client_flow.nim` が落ちる (「Given a 403 that is not an insufficient_scope challenge …」「Given a status other than 401 or 403 …」、本線 qzktpvsz、2026-10-10)。 |
| 41 | client.nim:101 | SDL | 既定の時計 `getTime()` → `discard` | 3 穴 | 既定の設定の時計は実時刻。`Given a configuration made with the defaults, when its clock is read, then it is the system clock` (これまでのテストは時計を差し替えていた)。 |
| 18 | client.nim:137 | LOR | `refreshToken.isNone or metadata.isNone` の `or` → `and` | 3 穴 | 更新トークンが無い、または探索をまだしていないなら、期限切れのトークンから見出しを作らず何も送らない (変異後は `none` の値取得で例外)。`Given an expired access token without a refresh token ...` と `Given an expired access token and a client that has not discovered the server yet ...` |
| 4 | client.nim:146 | ROR | `creds.get.issuer != tokens.issuer` → `==` | 3 穴 | 資格情報の発行者がトークンの発行者と違うなら、更新トークンを送らない。`Given credentials whose issuer is not the one that issued the token ...` (送信数が増えない、を確かめる)。 |
| 44 | client.nim:158 | SDL | 更新が断られたとき `tokenStore.remove` → `discard` | 3 穴 | 使えなくなった更新トークンは保存から消える。`Given a refresh token the server rejects ..., then there is none and the spent token is forgotten` |
| 43 | client.nim:160 | SDL | 更新後の `tokenStore.save` → `discard` | 3 穴 | 更新したトークンが保存され、次の要求で再び更新しない。`Given a refresh that succeeded ..., then the refreshed token is the stored one and is not refreshed again` |
| 34 | client.nim:199 | BLR | `strict.allowLoopback = false` → `true` | 3 穴 | Client ID Metadata Document の URL がループバックなら断る。`Given a client_id URL that names a loopback or private address ...` |
| 35 | client.nim:200 | BLR | `strict.allowPrivateNetworks = false` → `true` | 3 穴 | 同 (私設アドレスと 169.254.169.254)。 |
| 45 | client.nim:201 | SDL | `checkFetchUrl(...)` → `discard` | 3 穴 | 同じテスト。 |
| 28 | client.nim:275 | LOR | `scopeFromChallenge and bearer.isSome` の `and` → `or` | 3 穴 | 2025-11-25 より前の版は、チャレンジの scope を使わない (`Given a scope in the challenge and version <version> ...`)。WWW-Authenticate が無い 401 でもクラッシュしない (`Given a 401 with no WWW-Authenticate header ...`)。 |
| 9 | client.nim:284 | ROR | `now - since > StepUpWindow` → `>=` | 3 穴 | 窓の端 (ちょうど 60 秒後) の答えは同じ窓に数える。`Given a requirement the user keeps being asked for ..., then the failure is permanent and counts the attempts` |
| 2 | client.nim:290 | AOR | `$(count - 1)` → `$(count + 1)` | 3 穴 | 診断文の試行回数。同じテストが `attempted 2 times` を確かめる。文面だけだが、何度で打ち切ったかを利用者に伝える唯一の情報なので、穴として塞いだ。 |
| 37 | client.nim:300 | BLR | 403 で `return false` の `false` → `true` | 3 穴 | insufficient_scope でない 403、または step-up の無い版の 403 は、繰り返す価値が無い。`Given a 403 that is not an insufficient_scope challenge ...` と `Given an insufficient_scope 403 and version <version> ...` |
| 38 | client.nim:302 | BLR | `status != 401` の `return false` の `false` → `true` | 3 穴 | 401・403 以外の答えは繰り返す価値が無い。`Given a status other than 401 or 403 ...` |
| 58 | client.nim:327 | SDL | `handleChallenge` で更新が断られたとき `tokenStore.remove` → `discard` | 3 穴 | 更新が断られ、そのあと利用者が認可を拒んでも、使えない更新トークンは保存から消える。`Given a refresh token the server rejects and a user who then refuses ...` |

## 残っているもの

分類 4・5・6 は無い。分類 1 の 7 件は読んで決めた (どれも `return` の値が型の既定値と同じ)。
