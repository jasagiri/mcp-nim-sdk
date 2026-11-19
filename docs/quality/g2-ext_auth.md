# G2 変異検出: ext_auth ジョブ (認可の拡張)

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: 変異検査の道具 0.2.15、ジョブ `tests/mutation/ext_auth.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。
状態: 測定済み (仕分けは 2026-11-12、コードを読んだ結論。変異を手では当てていない)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 201 | 156 | 0 | 32 | 0 | 13 |

公開の入口は `ext/auth_client_credentials` と `ext/auth_enterprise_managed`。`auth/oauth/grants` と `auth/oauth/jwt` は入口から丸ごとは export されず (型と構築子だけ)、`clientCredentialsGrant`・`jwtBearerGrant`・`exchangeToken`・`clientAssertion`・`signJwt`・`decodeJwtUnverified` には拡張の流れと `checkIdentityAssertionGrant` を通ってだけ届く (src の呼び手はどれも 1 か所)。下の「C」は `tests/external/test_ext_auth_client_credentials.nim`、「E」は `tests/external/test_ext_auth_enterprise_managed.nim`、「S」は `tests/external/test_security_ext_auth.nim`。JWT を手で作るのは `tests/external/ext_auth_fixtures.nim` の `signJwt`・`decodeJwtUnverified` で足りる (SDK の `auth/oauth/jwt` を import しなくてよい)。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/auth/oauth/grants.nim:ROR:0d63f1f293da3ba0:0` | grants.nim:103 | `auth.lifetime > DurationZero` → `>=` | test_owed | 寿命 0 の `private_key_jwt` で、元は 1 分の assertion、変異は `exp` = `iat` の assertion を送る。入口からは `ClientCredentialsConfig.assertionLifetime = DurationZero` で届く | MCP-EXT-AUTH-7。C: 署名の鍵を持つ config の `assertionLifetime` を `DurationZero` にして ping。served になり、`client_assertion` を fixtures で読むと `exp - iat == 60`。変異では fake の認可サーバーが `exp <= now` で invalid_client を返し、要求が失敗する (内部側に同じ主旨のテスト「... without a lifetime ... lives one minute」がある) |
| `src/auth/oauth/grants.nim:ROR:e173a3002d324a19:0` | grants.nim:118 | `clientCredentialsGrant` の `scopes.len > 0` → `>=` | test_owed | scope が 1 つも無いとき、変異は空の `scope=` をトークンの要求に載せる (RFC 6749 3.3 の scope は 1 つ以上の語)。fake は `.get("")` で読むので今は見えない | MCP-EXT-AUTH-7。C の「Given a 401 and a client secret, ...」に `check r.field("scope").isNone` を足す。変異では `some("")` |
| `src/auth/oauth/grants.nim:ROR:e173a3002d324a19:1` | grants.nim:130 | `jwtBearerGrant` の `scopes.len > 0` → `>=` | test_owed | 拡張は `jwtBearerGrant` に常に `@[]` を渡すので、変異は ID-JAG を出す要求のすべてに空の `scope=` を載せる | MCP-EXT-AUTH-7。E の流れのテスト (例「Given a stored token, ...」) に `check env.rasRequests[][0].field("scope").isNone` を足す。変異では `some("")` |
| `src/auth/oauth/grants.nim:SDL:44f009e404fffc90:1` | grants.nim:131 | `jwtBearerGrant` の `fields.add ("scope", scopes.join(" "))` → `discard` | unreached | この行は `scopes.len > 0` のときだけ走る。src の唯一の呼び手 `auth_enterprise_managed.acquire` は `@[]` を渡し、`jwtBearerGrant` は入口から export されていないので、入口から scope を渡す入力を作れない。`scopes` の引数そのものが入口からは使われていない (引数を消せば 130 行の分岐も消える。司会への申し送り) | |
| `src/auth/oauth/grants.nim:LOR:a275f817c5d87c0d:0` | grants.nim:147 | `token.isNone or token.get.len == 0` → `and` | test_owed | IdP の応答に `access_token` が無いとき、元は OAuthError で断り、変異は none の `get` で UnpackDefect になる (空文字列の `access_token` は、変異でも後段の `decodeJwtUnverified` が断るので文面だけの差) | MCP-EXT-AUTH-11。E: fake の IdP が `access_token` の無い 200 を返す → `failureOf` が McpTransportError を返し、`rasRequests.len == 0`。変異では Defect でテストが落ちる。下の 2 件と同じ 1 本 (欠ける欄を 3 通り) |
| `src/auth/oauth/grants.nim:LOR:192daf3ac80ad8b2:0` | grants.nim:150 | `issued.isNone or issued.get.len == 0` → `and` | test_owed | `issued_token_type` が無い応答で、元は OAuthError、変異は UnpackDefect (空文字列は後段の `issuedTokenType != TokenTypeIdJag` が断る) | MCP-EXT-AUTH-11。上と同じ 1 本 (`issued_token_type` を欠く応答) |
| `src/auth/oauth/grants.nim:LOR:ebd4fe332f70f857:0` | grants.nim:153 | `tokenType.isNone or tokenType.get.len == 0` → `and` | test_owed | `token_type` が無い応答で、元は OAuthError、変異は UnpackDefect (空文字列は後段の `N_A` との比較が断る) | MCP-EXT-AUTH-11。上と同じ 1 本 (`token_type` を欠く応答) |
| `src/auth/oauth/grants.nim:LOR:6002bd0c01bdc0ce:0` | grants.nim:168 | `request.subjectToken.len == 0 or request.subjectTokenType.len == 0` → `and` | unreached | src の唯一の呼び手 `auth_enterprise_managed.obtainGrant` が、`assertion.token.len == 0` を先に OAuthError で断り、`subjectTokenType(kind)` は列挙からの全域の関数で空を返さない。`exchangeToken` は入口から export されていないので、どちらの項も真にする入力を作れない | |
| `src/auth/oauth/grants.nim:ROR:249ccad8aa6a1ac3:0` | grants.nim:179 | `exchangeToken` の `request.scopes.len > 0` → `>=` | test_owed | scope が 1 つも無いとき、変異は IdP への交換の要求に空の `scope=` を載せる。fake は `.get("")` で読むので今は見えない | MCP-EXT-AUTH-7。E の scope を持たない流れのテストに `check env.idpRequests[][0].field("scope").isNone` を足す (130 行のものと同じテストに並べられる)。変異では `some("")` |
| `src/auth/oauth/jwt.nim:LOR:5bb02e615676ccd7:0` | jwt.nim:57 | `signer.sign.isNil or signer.alg.len == 0` → `and` | test_owed | `JwtSigner` は欄が公開の object で、入口から `JwtSigner(alg: "HS256")` (署名の関数が nil) を `newJwtSigner` を通さずに作れる。元は OAuthError「not set up」、変異は nil の関数を呼んで落ちる | MCP-EXT-AUTH-7。C: `config.signer = some(JwtSigner(alg: "HS256"))` で ping → McpTransportError、`env.requests[].len == 0`。変異では SIGSEGV (内部側に同じ主旨のテストがある)。申し送り: `JwtSigner` の欄を非公開にすれば `newJwtSigner` だけが作り手になり、この検査は届かなくなる |
| `src/auth/oauth/jwt.nim:LOR:a7266fa08d380786:0` | jwt.nim:76 | `segment.len == 0 or not segment.allCharsInSet(...)` → `and` | test_owed | 変異では検査が常に偽になり、空の署名部と、`+`・`/`・`=` を含む断片 (`base64.decode` は受ける) が通る。公開の `checkIdentityAssertionGrant` から届く | MCP-EXT-AUTH-11 (内部側の同じ主旨のテストは MCP-EXT-AUTH-7)。E の suite「checkIdentityAssertionGrant」: 正しい ID-JAG の署名部を空にしたものと `+` を混ぜたもの → `expect OAuthError`。変異では受け入れて返る |
| `src/auth/oauth/jwt.nim:ROR:0b468e35d2c0ed63:0` | jwt.nim:88 | `token.len > MaxJwtLength` → `>=` | test_owed | ちょうど 16384 バイトの JWT を、元は読み、変異は断る。`checkIdentityAssertionGrant` から届く。上限の値は Scenario の文面には無いが、`specs/tests.map` が内部側の境界のテストを MCP-EXT-AUTH-7 に結んでいる | MCP-EXT-AUTH-7。E: claim を詰めて長さをちょうど 16384 にした ID-JAG は通り、1 バイト長いものは OAuthError。変異では前者も断る。`MaxJwtLength` は入口から export されていないので、テストは 16 * 1024 を数で書く |
| `src/auth/oauth/jwt.nim:LOR:b6c740b163c9d862:0` | jwt.nim:101 | `header.kind != JObject or claims.kind != JObject` → `and` | spec_question | 見出しだけがオブジェクトでないときは次の行の `alg` の検査が同じ OAuthError で断る。本文だけがオブジェクトでないとき、元は OAuthError「must be JSON objects」、変異は `checkIdentityAssertionGrant` の `iss` の検査が OAuthSecurityError「was not issued by」で断る。断ることは保たれ、変わるのは文面と例外の種類 (OAuthError → その子の OAuthSecurityError)。src にこの 2 つを見分けて動作を変える箇所は無い (`discovery.nim` の見分けは別の経路)。どの仕様 ID も例外の種類を述べていない。問い: 「形の壊れた ID-JAG」と「宛先の違う ID-JAG」を、呼び手が例外の種類で見分けられることを仕様にするか | 推奨: 仕様にしない (どちらも OAuthError として断れば足りる)。そう決まれば、文面だけの差として accepted (失敗の文面は契約ではない) に移せる |
| `src/auth/oauth/jwt.nim:LOR:b3a5663ab0317565:0` | jwt.nim:103 | `header{"alg"}.isNil or header{"alg"}.kind != JString` → `and` (内側) | test_owed | `alg` の無い見出しで、元は OAuthError、変異は nil の `kind` を読んで落ちる。`checkIdentityAssertionGrant` から届く | MCP-EXT-AUTH-11 (内部側は MCP-EXT-AUTH-7)。E の suite「checkIdentityAssertionGrant」: 見出しが `{"typ": "oauth-id-jag+jwt"}` だけの JWT を手で組む → `expect OAuthError`。変異では SIGSEGV。下の 1 件と同じ 1 本 |
| `src/auth/oauth/jwt.nim:LOR:73513c8ac17bdc3a:0` | jwt.nim:103 | `... or header{"alg"}.getStr().len == 0` → `and` (外側) | test_owed | `alg` が空文字列の見出しを、元は断り、変異は受け入れる (無い・文字列でない `alg` は変異でも断る) | MCP-EXT-AUTH-11 (内部側は MCP-EXT-AUTH-7)。上と同じ 1 本に `"alg": ""` の見出しを足す → `expect OAuthError`。変異では受け入れて返る |
| `src/auth/oauth/jwt.nim:LOR:455f7b00bd1871aa:0` | jwt.nim:114 | `clientId.len == 0 or audience.len == 0` → `and` | unreached | src の唯一の呼び手 `grants.authenticate` が空の `clientId` を先に OAuthError で断る。`audience` は、client credentials では `found.issuer` か必須の `token_endpoint` (`metadata.nim` の `requiredString`)、enterprise では `withAudience` が空を `idpIssuer` (`checkFetchUrl` 済み)・`found.issuer` で埋めるので、空にならない。`clientAssertion` は入口から export されていない | |
| `src/ext/auth_client_credentials.nim:ROR:a1a5a51b51b89aa6:0` | auth_client_credentials.nim:162 | `c.config.assertionAudience == aaIssuer` → `!=` | test_owed | 既定 (`aaIssuer`) で assertion の `aud` が token endpoint になり、`aaTokenEndpoint` で issuer になる。C の fake は `registry.audiences` に両方を入れているので見えない | MCP-EXT-AUTH-1。C: `env.registry.audiences = @[issuer]` にして既定の config で served、`@[token_endpoint]` にして `assertionAudience = aaTokenEndpoint` で served。変異ではどちらも invalid_client (内部側に同じ主旨の 2 本がある) |
| `src/ext/auth_client_credentials.nim:RVR:0c511227513989c7:0` | auth_client_credentials.nim:188 | `return none(string)` → `<return default>` | equivalent | リテラルではない return なので `default(Option[string])` になる。`Option` の既定値は none で、`none(string)` と同じ値 | |
| `src/ext/auth_client_credentials.nim:RVR:0c511227513989c7:1` | auth_client_credentials.nim:192 | `return none(string)` → `<return default>` | equivalent | 同上 (`default(Option[string])` は none) | |
| `src/ext/auth_client_credentials.nim:RVR:0c511227513989c7:2` | auth_client_credentials.nim:199 | `return none(string)` → `<return default>` | equivalent | 同上。直前の `tokenStore.remove` は変異の外で、そのまま走る | |
| `src/ext/auth_enterprise_managed.nim:RVR:e7269eed558d99df:0` | auth_enterprise_managed.nim:182 | `return none(seq[string])` → `<return default>` | equivalent | `default(Option[seq[string]])` は none で、`none(seq[string])` と同じ値 | |
| `src/ext/auth_enterprise_managed.nim:LOR:fd8d1984114a44f0:0` | auth_enterprise_managed.nim:226 | `header{"typ"}.isNil or header{"typ"}.kind != JString` → `and` | test_owed | `typ` の無い ID-JAG で、元は OAuthSecurityError、変異は nil の `kind` を読んで落ちる (文字列でない `typ` は変異でも断る) | MCP-EXT-AUTH-11。E の suite「checkIdentityAssertionGrant」: `typ` を付けずに署名した ID-JAG → `expect OAuthSecurityError`。変異では SIGSEGV |
| `src/ext/auth_enterprise_managed.nim:LOR:158eacccce0cde09:0` | auth_enterprise_managed.nim:230 | `claims{"iss"}.isNil or claims{"iss"}.kind != JString` → `and` | test_owed | `iss` の無い ID-JAG で、元は OAuthSecurityError、変異は nil の `kind` を読んで落ちる | MCP-EXT-AUTH-11。E の「Given an ID-JAG without sub, jti, iat or exp, ...」と同じ形で `behavior.drop = @["iss"]` と `@["client_id"]` → `refusedGrant` (`rasRequests.len == 0`)。変異では SIGSEGV。下の 1 件と同じ 1 本 (内部側に同じ主旨のテストがある) |
| `src/ext/auth_enterprise_managed.nim:LOR:18d9809e7aae3e6b:0` | auth_enterprise_managed.nim:236 | `claims{"client_id"}.isNil or claims{"client_id"}.kind != JString` → `and` | test_owed | `client_id` の無い ID-JAG で、元は OAuthSecurityError、変異は nil の `kind` を読んで落ちる | MCP-EXT-AUTH-11。上と同じ 1 本 (`client_id` を落とす) |
| `src/ext/auth_enterprise_managed.nim:LOR:e83d4a1bf996e377:0` | auth_enterprise_managed.nim:241 | `... or claims{required}.getStr().len == 0` → `and` (外側) | test_owed | `sub` か `jti` が空文字列の ID-JAG を、元は断り、変異は受け入れる (無い・文字列でないものは変異でも断る) | MCP-EXT-AUTH-11。E の suite「checkIdentityAssertionGrant」: `good` の `sub` を `""` にしたものと `jti` を `""` にしたもの → `expect OAuthError`。変異では受け入れて返る |
| `src/ext/auth_enterprise_managed.nim:ROR:5367ba632762c479:0` | auth_enterprise_managed.nim:246 | `exp <= float(now.toUnix)` → `<` | test_owed | `exp` がちょうど今の ID-JAG を、元は期限切れとして断り、変異は認可サーバーへ送る | MCP-EXT-AUTH-11。E: `env.behavior.lifetime = 0` → `check "expired" in env.refusedGrant()` (`rasRequests.len == 0`)。変異では認可サーバーに 1 回届く (内部側に同じ主旨のテスト「expires at this very second」がある) |
| `src/ext/auth_enterprise_managed.nim:ROR:0d3faeea190b21d6:0` | auth_enterprise_managed.nim:248 | `exp > float(now.toUnix) + float(MaxTokenLifetimeSeconds)` → `>=` | test_owed | `exp` がちょうど今 + 10 年の ID-JAG を、元は受け、変異は断る | MCP-SEC-AUTH-6。S の suite「numbers in an ID-JAG ...」(`grantChecked` の補助だけが残っている): `exp = now + MaxTokenLifetimeSeconds` は通り、1 秒先は OAuthError。変異では前者も断る。`MaxTokenLifetimeSeconds` は入口 `auth/client` が `tokens` ごと export している (内部側に同じ主旨のテストがある) |
| `src/ext/auth_enterprise_managed.nim:LOR:b34755d00d89735f:0` | auth_enterprise_managed.nim:283 | `grantTypes.isNone or GrantTypeJwtBearer notin grantTypes.get` → `and` | test_owed | プロファイルは載せるが `grant_types_supported` に jwt-bearer が無い認可サーバーに、変異は ID-JAG を取りに行って送る (欄ごと無いときは変異は UnpackDefect) | MCP-EXT-AUTH-10。E: `startEnv(rasGrantTypes = @["authorization_code"])` → `refusedBeforeAnyExchange` (`providerCalls`・`idpRequests`・`rasRequests` が 0)。変異では IdP に交換が届く (内部側に同じ主旨のテストがある) |
| `src/ext/auth_enterprise_managed.nim:ROR:4729d8b6ab5a6378:0` | auth_enterprise_managed.nim:343 | `issued.scopes.len == 0` → `!=` | test_owed | 保存されるトークンの scope が入れ替わる: 認可サーバーが狭い scope を答えたとき求めたもので上書きし、答えに scope が無いとき空のままにする。見えるのは `config.tokenStore` (公開の欄。`TokenStore` は入口 `auth/client` が export) | MCP-EXT-AUTH-9。E: `config.tokenStore` に自前の `newMemoryStore[TokenSet]()` を渡し、ping の後に `load` した `scopes` を見る。狭い scope の答え (`behavior.grantScope`) なら答えのもの、scope の無い答えなら求めたもの。変異では逆 (内部側に同じ主旨の 2 本がある) |
| `src/ext/auth_enterprise_managed.nim:RVR:0c511227513989c7:0` | auth_enterprise_managed.nim:355 | `return none(string)` → `<return default>` | equivalent | `default(Option[string])` は none で、`none(string)` と同じ値 | |
| `src/ext/auth_enterprise_managed.nim:RVR:0c511227513989c7:1` | auth_enterprise_managed.nim:359 | `return none(string)` → `<return default>` | equivalent | 同上 | |
| `src/ext/auth_enterprise_managed.nim:RVR:0c511227513989c7:2` | auth_enterprise_managed.nim:367 | `return none(string)` → `<return default>` | equivalent | 同上。直前の `c.grant = none(CachedGrant)` と `tokenStore.remove` は変異の外で、そのまま走る | |

timeout は無い。

## 初回の測定 (拡張ブランチの c9b5c264)

測定: 変異検査の道具、ジョブ `tests/mutation/ext_auth.json`、拡張ブランチの c9b5c264 (初回の測定。比べる記録はない)。
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

変異検査の道具 は `a or b or c` の `or` を 1 つずつ `and` にする。構文木の上では内側の `or` を変えると `(a and b) or c`、
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
