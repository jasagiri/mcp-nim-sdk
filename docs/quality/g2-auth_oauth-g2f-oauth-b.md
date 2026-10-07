# G2 変異検出: `src/auth/oauth/` の後半 (authcode / jsonfield / metadata / registration / tokens)

測定: `nim-muter`、ジョブ `tests/mutation/auth_oauth.json`、mainline の 36a4c8a5 (2026-10-07)。
ジョブ全体の数字は次のとおり。この文書は、そのうち下の 5 ファイルの survived 37 件を扱う (残りの `challenge.nim`、`discovery.nim`、`fetch.nim`、`urls.nim`、`sha256.nim` は別の文書)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 333 | 228 | 5 | 81 | 0 | 19 |

## survived 37 件

分類は、1 = 同値、3 = 穴 (新しい外部仕様テストを足した)、4 = 到達しないコード。内訳は 1 が 11 件、3 が 21 件、4 が 5 件。
クラス 3 の 21 件は、変異を手で当てて下に書いたテストが落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは `jj restore` で戻した)。
足したテストは `tests/test_auth_oauth_basics.nim` と `tests/test_security_auth_tokens.nim` の末尾の suite `(mutation review, g2f-oauth-b)` にある。2 本ともジョブの `testCommand` に入っているので、ジョブの変更は要らない。
Scenario は `MCP-AUTH-g2f-oauth-b-1` から `-5` (`specs/authorization.feature`、対応は `specs/tests.map`)。
`SIGSEGV` と書いた行は、変異で `nil` を読むため、テストが `FAILED` を出さずに異常終了して落ちた。落ちることに変わりはない。
足したテストは `-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25`、既定の 2026-07-28 のすべてで合格する (この部分は版に依存しない)。

### jsonfield.nim

`Option[T]` の既定値は `none` なので、`return none(T)` を `<return default>` に替えても返る値は同じ (クラス 1)。
`intField` は `src/` にも `tests/` にも呼び出しが無い (呼ぶのは `strField` だけ)。そのため、`intField` の中の変異はどのテストでも観測できない (クラス 4)。

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 5 | jsonfield.nim:8 | LOR | `node.isNil or node.kind != JObject` → `and` | 3 | `nil` の JSON (本文が JSON でない応答の `errorFrom`) で `node.kind` を読む。`Given JSON that is absent, not an object, or has the key of another type, when a string is read, then there is none` (SIGSEGV)。オブジェクトでない非 nil の値は `node{key}` が `nil` を返すので、結果が変わらない。 |
| 11 | jsonfield.nim:9 | RVR | `return none(string)` → `<return default>` | 1 | `Option[string]` の既定値は `none`。 |
| 12 | jsonfield.nim:12 | RVR | `return none(string)` → `<return default>` | 1 | 同上。 |
| 13 | jsonfield.nim:17 | RVR | `return none(int)` → `<return default>` | 1 | `Option[int]` の既定値は `none`。 |
| 14 | jsonfield.nim:20 | RVR | `return none(int)` → `<return default>` | 1 | 同上。 |
| 7 | jsonfield.nim:16 | LOR | `node.isNil or node.kind != JObject` → `and` | 4 | `intField` は呼び出し元が無い。 |
| 3 | jsonfield.nim:16 | ROR | `node.kind != JObject` → `==` | 4 | 同上。 |
| 8 | jsonfield.nim:19 | LOR | `value.isNil or value.kind != JInt` → `and` | 4 | 同上。 |
| 4 | jsonfield.nim:19 | ROR | `value.kind != JInt` → `==` | 4 | 同上。 |
| 10 | jsonfield.nim:21 | SDL | `some(value.getInt())` → `discard` | 4 | 同上。 |

### metadata.nim

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 90 | metadata.nim:33 | LOR | `node.isNil or node.kind == JNull` → `and` | 3 | `registration_endpoint` の無い文書で `nil` を読む (null のときは文字列でないとして拒否してしまう)。`Given a registration endpoint that is missing or null, when parsed, then the server offers no registration` (SIGSEGV)。 |
| 104 | metadata.nim:34 | RVR | `return none(string)` → `<return default>` | 1 | `Option[string]` の既定値は `none`。 |
| 105 | metadata.nim:48 | RVR | `return none(seq[string])` → `<return default>` | 1 | `Option[seq[string]]` の既定値は `none`。 |
| 101 | metadata.nim:109 | SDL | `checkFetchUrl(authorizationEndpoint, ...)` → `discard` | 3 | 認可エンドポイントが遠隔ホストへの平文 http でも通ってしまう。`Given metadata with a plain http authorization or registration endpoint on a remote host, when parsed, then it is rejected` (`FAILED`)。 |
| 103 | metadata.nim:113 | SDL | `checkFetchUrl(registrationEndpoint.get, ...)` → `discard` | 3 | 登録エンドポイントについて同上。同じテスト (`FAILED`)。 |

### registration.nim

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 142 | registration.nim:53 | ROR | `description.len > 0` → `>=` | 3 | 説明の無い OAuth エラーの文面が `... (` `)` つきになる。`Given an OAuth error answer, when the error is built, then the description follows only when there is one` (`FAILED`)。診断の文面だが、利用者が読む唯一の理由なので、説明が付くのは与えられたときだけという事実として固定した。 |
| 144 | registration.nim:70 | LOR | `clientId.isNone or clientId.get.len == 0` → `and` | 3 | client_id の無い応答で `UnpackDefect`、空の client_id は受け入れてしまう。`Given a registration response without a client_id or with an empty one, when read, then registration fails` (`Expect Failed, UnpackDefect was thrown`)。 |

### authcode.nim

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 159 | authcode.nim:35 | LOR | `hostname.len == 0 or anchor.len > 0` → `and` | 3 | フラグメントつき (RFC 6749 3.1.2) とホストの無い `https:///cb` のリダイレクト URI が通る。`Given redirect URIs with a fragment, no host, plain http to a remote host or another scheme, when checked, then they are refused` (`FAILED`)。 |
| 167 | authcode.nim:54 | SDL | `checkRedirectUri(redirectUri)` → `discard` | 3 | 認可リクエストが遠隔ホストへの平文 http のリダイレクト URI で作られる。`Given a plain http redirect URI to a remote host, when an authorization request is made, then no request is made` (`FAILED`)。 |
| 160 | authcode.nim:80 | LOR | `difference or (a[i].ord xor b[i].ord)` → `and` | 3 | 長さが同じなら どの `state` も一致扱いになる (偽造された応答を受け入れる)。`Given a response whose state has the length of the request's but differs, when the code is read, then it is refused` (`FAILED`)。 |
| 162 | authcode.nim:117 | LOR | `code.isNone or code.get.len == 0` → `and` | 3 | code の無い応答で `UnpackDefect`、空の code を返す。`Given a response with a matching state but no code or an empty one, when the code is read, then it is refused` (`FAILED`)。 |
| 164 | authcode.nim:149 | LOR | `access.isNone or access.get.len == 0` → `and` | 3 | access_token の無い応答で `UnpackDefect`、空の access_token を受け入れる。`Given a token response without an access token or with an empty one, when parsed, then it is refused` (`FAILED`)。 |

### tokens.nim

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 135 | tokens.nim:56 | SDL | `entries[].del(key)` → `discard` | 3 | メモリのストアから `remove` しても消えない。`Given a token that has been removed from a memory store, when loaded, then there is none, and the others stay` (`FAILED`)。 |
| 111 | tokens.nim:62 | AOR | `expiresAt.get - skew` → `+` | 3 | 期限の 30 秒前から期限切れとする余裕が逆向きになる。`Given an expiry inside the default skew, at its edge, outside it, or past, when asked if the token is expired, then only the outside is not` (`FAILED`)。 |
| 113 | tokens.nim:62 | ROR | `expiresAt.get - skew <= now` → `<` | 3 | ちょうど境界の瞬間に期限切れとしない。同じテストと `Given a skew of zero, when asked at the very second of the expiry, then the token is expired, and a second earlier it is not` (`FAILED` 2 件)。 |
| 127 | tokens.nim:75 | LOR | `body.isNil or body.kind != JObject` → `and` | 3 | `nil` の本文で `kind` を読む。`Given no JSON object at all, when a lifetime is read, then it is unknown` (SIGSEGV)。`parseTokenResponse` は `parseJson` の結果しか渡さないので、`nil` は `tokenExpiry` を直接呼んだときだけ届く (公開 proc の約束「無ければ none」を確かめる)。 |
| 137 | tokens.nim:76 | RVR | `return none(Time)` → `<return default>` | 1 | `Option[Time]` の既定値は `none`。 |
| 138 | tokens.nim:79 | RVR | 同上 | 1 | 同上。 |
| 139 | tokens.nim:93 | RVR | 同上 | 1 | 同上。 |
| 140 | tokens.nim:105 | RVR | 同上 | 1 | 同上。 |
| 141 | tokens.nim:113 | RVR | 同上 | 1 | 同上。 |
| 116 | tokens.nim:83 | ROR | `getBiggestInt() < 0` → `<=` | 3 | `expires_in` が整数の 0 (すぐ期限切れ) を拒否してしまう。`Given an expires_in of zero, as an integer or a float, when the response is parsed, then the token expires at once` (`OAuthError: expires_in is negative: 0`)。 |
| 118 | tokens.nim:90 | ROR | `f < 0.0` → `<=` | 3 | 小数の 0.0 について同上。同じテスト (`expires_in is negative: 0.0`)。 |
| 119 | tokens.nim:92 | ROR | `f > MaxTokenLifetimeSeconds` → `>=` | 3 | 上限ちょうどの小数が「期限不明」になる。`Given an expires_in of exactly the largest lifetime as a float, when the response is parsed, then it still counts` (`FAILED`)。 |
| 122 | tokens.nim:100 | ROR | `text.len > 1` → `>=` | 3 | 文字列 `"-"` が「負」と報告される (正しくは数でない)。例外の型は同じ `OAuthError` なので、文面で見分ける。`Given a lone minus sign, when the response is parsed, then it is refused as not a number rather than as a negative one` (`FAILED`)。 |
| 132 | tokens.nim:102 | LOR | `text.len == 0 or not allCharsInSet(Digits)` → `and` | 3 | `"+3600"`、`"1_000"`、空白つきの文字列を `parseBiggestInt` が受け入れてしまう (数字だけの文字列、という約束が崩れる)。`Given strings that are not a number of seconds in digits, when the response is parsed, then each is refused` (`FAILED`)。空文字列と `"soon"` は `parseBiggestInt` の `ValueError` で同じ `OAuthError` になるので、この 2 つだけでは見分けられない。 |
| 124 | tokens.nim:104 | ROR | `text.len > 18` → `>=` | 3 | 18 文字の数字列は、先頭に 0 が付くと値は小さい (`"000000000000003600"`) が「期限不明」になる。`Given a digit string of eighteen characters with leading zeros, when the response is parsed, then it counts by its value` (`FAILED`)。 |

## 残っているもの

- **クラス 4 (リードの判断待ち)**: `jsonfield.nim:15-21` の `intField` (id 7, 3, 8, 4, 10)。呼び出し元が無く、テストも無い。消すのが素直だと思うが、公開 proc (`*`) なので、消すか、将来使うなら E テストを足すかはリードが決める。私は消していない。
- **欠陥ではないと判断したが、記録しておく点**: `tokens.nim:96-105` のコメントは「どの寿命より長い数字列は変換せずに上限超過とみなす」と書くが、19 文字以上で先頭に 0 が付く数字列 (`"0000000000000003600"`) は値が小さくても「期限不明」になる。期限不明は 401 で補正される安全側の扱いで、そのような応答を送る認可サーバーも想定しにくいので、直さず、テストも足していない (18 文字ちょうどの境界は上の id 124 のテストが固定する)。
- 上の 37 件のうち、確かめていないものは無い (クラス 3 の 21 件は、すべて手で当てて落ちることを見た)。クラス 1 と 4 は読解による分類で、変異は当てていない。
