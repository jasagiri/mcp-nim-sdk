# G2 変異検出: auth_client ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/auth_client.json` (`src/auth/client.nim`、`src/auth/policy.nim`)、本線の 36a4c8a5 (2026-10-07)。
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
| 74 | client.nim:300 | RVR | `return false` → `return default` | 1 同値 | `bool` の既定値が `false`。 |
| 75 | client.nim:302 | RVR | 同上 | 1 同値 | 同上。 |
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
