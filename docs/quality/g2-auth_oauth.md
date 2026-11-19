# G2 変異検出: auth_oauth ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: 変異検査の道具 0.2.15、ジョブ `tests/mutation/auth_oauth.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。
状態: 測定済み (仕分けは 2026-11-12、コードを読んだ結論。変異を手では当てていない)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 214 | 152 | 0 | 51 | 0 | 11 |

公開の入口は `auth/client` (`errors`・`tokens` を丸ごと、`urls` からは `FetchPolicy` と `defaultFetchPolicy` だけを export) と `auth/resource_server`。`authcode`・`discovery`・`fetch`・`jsonfield`・`metadata`・`pkce`・`sha256`・`urls` の残りには、`OAuthClient.handleChallenge`・`newOAuthClient`・`newResourceServerAuth` を通ってだけ届く。前の測定で生き残りを殺したテストの多くは、部品を直接呼ぶので内部側 (`tests/internal/test_auth_oauth_basics_internal.nim`・`test_security_auth_tokens_internal.nim`) に移っており、下の test_owed の大半は同じ主旨を入口から書き直すもの。下の「B」は `tests/external/test_auth_oauth_basics.nim`、「T」は `tests/external/test_security_auth_tokens.nim`。`src/auth/oauth/jwt.nim`・`grants.nim` はこのジョブの `sources` に無く、`g2-ext_auth.md` と同じ指紋の行は無い (`return none(...)` の RVR の判断は同じ equivalent)。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/auth/oauth/authcode.nim:SDL:601869ee54bd0b5e:0` | authcode.nim:54 | `newAuthorizationRequest` の `checkRedirectUri(redirectUri)` → `discard` | unreached | src の唯一の呼び手 `client.handleChallenge` は `c.config.redirectUri` を渡す。この値は `newOAuthClient` が同じ `checkRedirectUri` で先に断っており (client.nim:120)、`OAuthClient.config` は非公開で後から書き換えられない。`newAuthorizationRequest` は入口から export されていないので、検査を通っていない redirect URI をここへ運ぶ入力を作れない | |
| `src/auth/oauth/authcode.nim:LOR:784a5bea41348592:0` | authcode.nim:149 | `access.isNone or access.get.len == 0` → `and` | test_owed | トークンの応答に `access_token` が無いとき、元は OAuthError で断り、変異は none の `get` で UnpackDefect になる。空文字列の `access_token` は、変異では受け入れて保存する。前のテストは内部側に移った | MCP-AUTH-41。T に 1 本: `expiryAfter` の形で、token endpoint が `{"token_type":"Bearer"}` と `{"access_token":"","token_type":"Bearer"}` を返す → どちらも `expect OAuthError`。変異では前者が Defect、後者は受け入れて返る |
| `src/auth/oauth/discovery.nim:SDL:2f25dd78a30f397e:0` | discovery.nim:26 | `path.setLen(path.len - 1)` → `discard` | test_owed | `/` で終わるパスを持つ issuer を OpenID Connect も試す版 (2025-11-25 以降) で探すと、変異は末尾の `/` を減らせずループが終わらない。このジョブの外部テストの issuer はどれも `/` で終わらない (前のテストは内部側) | MCP-AUTH-35 (「the candidate URLs of an issuer path that ends in a slash have the slash dropped」)。B の suite「Authorization server discovery over a scripted server」に 1 本: resource metadata が issuer `origin & "/tenant1/"` を名指し、ほかは 404 → 失敗の文面に `origin & "/.well-known/oauth-authorization-server/tenant1: HTTP 404"`・`…/.well-known/openid-configuration/tenant1: HTTP 404`・`origin & "/tenant1/.well-known/openid-configuration: HTTP 404"` がある。変異では終わらない (timeout)。下の 1 件と `urls.nim:122` の 2 件も同じ 1 本 |
| `src/auth/oauth/discovery.nim:AOR:ee00ff16360a1b81:0` | discovery.nim:26 | `path.len - 1` → `+` | test_owed | 同じ入力で、変異は `/` を落とす代わりに NUL を足し、3 つ目の候補が `…/tenant1/\0/.well-known/openid-configuration` になる | MCP-AUTH-35。上と同じ 1 本 (3 つ目の URL の文面が合わない) |
| `src/auth/oauth/discovery.nim:ROR:9d9b07680550bfcd:0` | discovery.nim:27 | `path.len > 0` → `>=` | test_owed | パスの無い issuer で、変異は 3 つ目の候補 `origin & "/.well-known/openid-configuration"` を足す。2 つ目と同じ URL なので、見つからないとき同じ URL を 2 回取りに行く | MCP-AUTH-14 (「an issuer without a path has two candidates」)。B の同じ suite に 1 本: resource metadata が issuer `origin` (パス無し) を名指し、ほかは 404 → `server.requestLines` のうち `openid-configuration` を含むものが 1 件、`oauth-authorization-server` が 1 件。変異では前者が 2 件 |
| `src/auth/oauth/discovery.nim:SDL:f969742c2a719768:0` | discovery.nim:87 | `discoverAuthorizationServer` の `checkFetchUrl(issuer, policy, "authorization server issuer")` → `discard` | unreached | src の呼び手は 3 か所で、どれも同じ issuer を同じか狭い policy で先に断っている: `client.discover` と `ext/auth_shared` は resource metadata の `authorization_servers` から選び、その全件を `parseProtectedResourceMetadata` (metadata.nim:92) が確かめる。`ext/auth_enterprise_managed` は `config.idpIssuer` を作るときに確かめる (同 168 行)。`discoverAuthorizationServer` は入口から export されていないので、確かめていない issuer をここへ運べない。MCP-AUTH-35 の「fragment のある issuer は要求の前に断る」は、入口からは metadata.nim:92 が担う (下の行) | |
| `src/auth/oauth/fetch.nim:SDL:e5514a7ef98b6a22:0` | fetch.nim:37 | `defer: response.close()` → `discard` | test_owed | 本文のある答えは配線が読み終えたときに閉じるので、本文の無い keep-alive の答え (204) でだけ、変異は接続を開いたままにする。前のテストは内部側に移った | MCP-AUTH-36 (「a body-less keep-alive answer … the connection is closed afterwards」)。B の suite「Requests of the OAuth client over a scripted server」に 1 本: `startHolding("HTTP/1.1 204 No Content\c\LConnection: keep-alive\c\L\c\L")` を resource metadata の URL として `challengedWith` → `outcome.kind == "oauth"`、`server.closedWithin(2000)`。変異では閉じない (`startHolding` は B に既にある) |
| `src/auth/oauth/fetch.nim:SDL:b33038c87cdbb7b6:0` | fetch.nim:61 | `pending.addCallback(… stderr.writeLine("[oauth] abandoned request to " …))` → `discard` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。時間切れを OAuthError で知らせること (次の `raise`) と接続を閉じること (58 行) は変異の外で保たれる。消えるのは、見捨てた要求がどう終わったかを stderr に書く診断だけで、プログラムが読む箇所は無い | |
| `src/auth/oauth/fetch.nim:SDL:cb782010fa1010a6:0` | fetch.nim:63 | `stderr.writeLine("[oauth] abandoned request to " …)` → `discard` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。上と同じ stderr の診断の 1 行で、時間切れの報告と接続を閉じることは保たれる | |
| `src/auth/oauth/jsonfield.nim:RVR:0c511227513989c7:0` | jsonfield.nim:9 | `return none(string)` → `<return default>` | equivalent | リテラルではない return なので `default(Option[string])` になる。`Option` の既定値は none で同じ値 | |
| `src/auth/oauth/jsonfield.nim:RVR:0c511227513989c7:1` | jsonfield.nim:12 | `return none(string)` → `<return default>` | equivalent | 同上 | |
| `src/auth/oauth/metadata.nim:RVR:0c511227513989c7:0` | metadata.nim:34 | `optString` の `return none(string)` → `<return default>` | equivalent | 同上 (`default(Option[string])` は none) | |
| `src/auth/oauth/metadata.nim:RVR:e7269eed558d99df:0` | metadata.nim:48 | `optStrings` の `return none(seq[string])` → `<return default>` | equivalent | `default(Option[seq[string]])` は none で同じ値 | |
| `src/auth/oauth/metadata.nim:SDL:76dd24052a2caacc:0` | metadata.nim:92 | `checkFetchUrl(server, policy, "authorization server")` → `discard` | test_owed | 選ばれた認可サーバーは、変異でも `discoverAuthorizationServer` の検査 (discovery.nim:87) が同じ OAuthSecurityError で断る。差が出るのは、選ばれないほうに安全でない URL がある文書: 元は文書ごと断り、変異は受け入れて先頭の認可サーバーへ進む | MCP-AUTH-12 (「…or with an insecure one」)。B の suite「Protected resource metadata over a scripted server」に 1 本: `authorization_servers` が `[origin & "/tenant1", "http://auth.example.com"]` の文書を `challengedWith` → `outcome.kind == "security"`、文面に `authorization server must be https`、認可サーバーの well-known への要求が 0 件。変異では `oauth` (認可サーバーの metadata が 404) になり、要求が出る |
| `src/auth/oauth/metadata.nim:SDL:cef5f9937b0e64a2:0` | metadata.nim:112 | `checkFetchUrl(result.tokenEndpoint, policy, "token endpoint")` → `discard` | test_owed | 遠隔ホストへの平文 http の `token_endpoint` を持つ metadata を、元は読んだ時点で断る。変異は受け入れ、登録をし、利用者を認可の画面へ送ってから、トークンの要求の `httpExchange` で初めて断る | MCP-AUTH-14 (「a plain http token endpoint on a remote host are refused」)。B の既存の「Given metadata with a plain http authorization or registration endpoint on a remote host, …」の `key` の並びに `"token_endpoint"` を足す (`idleAuthorizer` は利用者が呼ばれると表明で落ちる)。加えて `authServer.registered.len == 0` を見る。変異では登録が 1 件出て、表明で落ちる |
| `src/auth/oauth/metadata.nim:SDL:38782c08a525ac9c:0` | metadata.nim:115 | `checkFetchUrl(result.registrationEndpoint.get, policy, "registration endpoint")` → `discard` | test_owed | 既存の B のテストは動的登録をする client で確かめるので、変異でも `registerClient` の `httpExchange` が同じ OAuthSecurityError で断り、見分けられない。登録を使わない client (事前登録・Client ID Metadata Document) では、元は文書を断り、変異は受け入れて利用者を認可の画面へ送る | MCP-AUTH-38 (「registration_endpoint is plain http to a remote host … the document is rejected」)。B に 1 本 (上の行のテストの隣): `config.preRegistered = some(PreRegisteredClient(clientId: "c", issuer: some(authServer.issuer)))` の client で、`registration_endpoint` が `http://auth.example.com/endpoint` → `expect OAuthSecurityError`。変異では `idleAuthorizer` の表明で落ちる |
| `src/auth/oauth/pkce.nim:ROR:2473df8ad5ad9ee1:0` | pkce.nim:24 | `verifier.len < 43` → `<=` | spec_question | `isValidCodeVerifier` は src に使い手が無い (0 か所)。入口から export もされず、公開の入口からは届かない。使い手は tests/internal の `test_auth_oauth_basics_internal.nim` の 2 本 (7 か所) だけで、tests/external と tests/fuzz には無い。`specs/tests.map` はその 2 本を MCP-AUTH-18 (「a verifier is 43 unreserved characters」) に結ぶが、SDK が作る verifier は `newCodeVerifier` で、この関数を通らない。問い: src に使い手の無い `isValidCodeVerifier` を src から消すか、RFC 7636 4.1 の verifier の検査として入口から届くようにするか | 推奨: 消す。受け取った verifier を確かめるのは認可サーバーの仕事で、クライアントの SDK に使い手は生まれない。内部テストが要るなら、同じ検査をテストの補助として持つ。MCP-AUTH-18 の「43 unreserved characters」は、`tests/external/test_auth_client_flow.nim` の「…when the token request is sent, then it carries the verifier of this request」に `code_verifier` の長さと文字種の check を足せば入口から確かめられる。「公開から外して役割のモジュールに分ける」は要らない (どの入口も export していない) |
| `src/auth/oauth/pkce.nim:LOR:7d5d03782a94b768:0` | pkce.nim:24 | `verifier.len < 43 or verifier.len > 128` → `and` | spec_question | 同上 (`isValidCodeVerifier` の中。src に使い手が無い) | 上と同じ問い・同じ推奨 |
| `src/auth/oauth/pkce.nim:ROR:7c02551d0baca4f6:0` | pkce.nim:24 | `verifier.len > 128` → `>=` | spec_question | 同上 | 上と同じ問い・同じ推奨 |
| `src/auth/oauth/pkce.nim:RVR:f09e9e232af8b35b:0` | pkce.nim:25 | `return false` → `return true` | spec_question | 同上 | 上と同じ問い・同じ推奨 |
| `src/auth/oauth/pkce.nim:BLR:6ec2d660335697fb:0` | pkce.nim:25 | `false` → `true` | spec_question | 同上 | 上と同じ問い・同じ推奨 |
| `src/auth/oauth/pkce.nim:RVR:f09e9e232af8b35b:1` | pkce.nim:28 | `return false` → `return true` | spec_question | 同上 | 上と同じ問い・同じ推奨 |
| `src/auth/oauth/pkce.nim:BLR:6ec2d660335697fb:1` | pkce.nim:28 | `false` → `true` | spec_question | 同上 | 上と同じ問い・同じ推奨 |
| `src/auth/oauth/pkce.nim:BLR:b8309a95375a2001:0` | pkce.nim:29 | `true` → `false` | spec_question | 同上 | 上と同じ問い・同じ推奨 |
| `src/auth/oauth/sha256.nim:SDL:5a90bc8d750f0eec:0` | sha256.nim:19 | `toHex` の `result.add digits[b shr 4]` → `discard` | test_owed | `toHex` は認可の流れでは使われず (PKCE は `base64UrlNoPad`)、使い手は `ext/skills/model.nim` の `digestOf` と `server/request_state.nim` の 2 か所。このジョブの testCommand のテストはどれも `toHex` を走らせない。変異は 16 進の上位の桁を落とし、ダイジェストが 32 文字になる | MCP-EXT-SKILLS-5。新しいテストは要らない: 既存の `tests/external/test_ext_skills_model.nim` の「Given the files of the specification's example, when digested, then the digests match the published ones」が検出するはず (公表された 64 文字の 16 進と比べる)。testCommand に足す。申し送り: `sha256.nim` をこのジョブの `sources` から外し、使い手のテストを持つジョブ (`ext_skills`) へ移すほうが測定と置き場が合う |
| `src/auth/oauth/sha256.nim:SDL:24fbfd09d8f0ef89:0` | sha256.nim:20 | `toHex` の `result.add digits[b and 0x0f]` → `discard` | test_owed | 同上。変異は下位の桁を落とす | MCP-EXT-SKILLS-5。上と同じ既存のテストが検出するはず。testCommand に足す |
| `src/auth/oauth/sha256.nim:LOR:8ac18ff5938e8f6e:0` | sha256.nim:20 | `b and 0x0f` → `or` | test_owed | 同上。変異は 16 以上のバイトで `digits` の範囲の外を引き IndexDefect になる (生き残ったのは、このジョブのテストが `toHex` を一度も走らせないため) | MCP-EXT-SKILLS-5。上と同じ既存のテストが検出するはず。testCommand に足す |
| `src/auth/oauth/tokens.nim:RVR:ee6041eafe65551f:0` | tokens.nim:76 | `tokenExpiry` の `return none(Time)` → `<return default>` | equivalent | `default(Option[Time])` は none で、`none(Time)` と同じ値 | |
| `src/auth/oauth/tokens.nim:RVR:ee6041eafe65551f:1` | tokens.nim:79 | `return none(Time)` → `<return default>` | equivalent | 同上 | |
| `src/auth/oauth/tokens.nim:ROR:fdd08ff0ed2d8133:0` | tokens.nim:83 | `value.getBiggestInt() < 0` → `<=` | test_owed | `expires_in` が整数の 0 (すぐ切れる) の応答を、元は「今切れる」と読み、変異は「負」として断る。前のテストは内部側に移った | MCP-AUTH-41 (「an expires_in of zero」)。T の suite「token responses: lifetimes」に 1 本 (境界の寿命): `expiryOf("0", now) == some(now)`。変異では OAuthError。下の 90・92・107 行と同じ 1 本 |
| `src/auth/oauth/tokens.nim:ROR:745c54c47eab48a2:0` | tokens.nim:90 | `f < 0.0` → `<=` | test_owed | 小数の `0.0` について同上 | MCP-AUTH-41。上と同じ 1 本に `expiryOf("0.0", now) == some(now)` |
| `src/auth/oauth/tokens.nim:ROR:5dbe1f28efd2daf1:0` | tokens.nim:92 | `f > float(MaxTokenLifetimeSeconds)` → `>=` | test_owed | 上限ちょうどの小数 (`315360000.0`) を、元は上限の寿命として読み、変異は「期限不明」にする。既存の T の「at the largest lifetime」は整数だけ | MCP-AUTH-41 (「at the bound」)。上と同じ 1 本に `expiryOf($MaxTokenLifetimeSeconds & ".0", now) == some(now + initDuration(seconds = MaxTokenLifetimeSeconds))`。変異では none |
| `src/auth/oauth/tokens.nim:RVR:ee6041eafe65551f:2` | tokens.nim:93 | `return none(Time)` → `<return default>` | equivalent | `default(Option[Time])` は none で同じ値 | |
| `src/auth/oauth/tokens.nim:ROR:9d229f0b5619e6f9:0` | tokens.nim:103 | `text.len > 1` → `>=` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。差が出るのは文字列 `"-"` だけで、元は「is not a number of seconds」、変異は「is negative」で、どちらも同じ OAuthError で応答を断る。プログラムがこの 2 つの文面を見分ける箇所は無い (前の記録の id 122 は文面で見分けるテストを足していたが、決定の後は契約ではない) | |
| `src/auth/oauth/tokens.nim:LOR:fcc11c90151f0b4e:0` | tokens.nim:105 | `text.len == 0 or not text.allCharsInSet(Digits)` → `and` | test_owed | 変異では検査が常に偽になり、`parseBiggestInt` が読める数字以外の綴り (`"+3600"`、`"1_000"`) を寿命として受け入れる。既存の T の断られる値 (`"soon"`・`""`・`"1e3"`) は `parseBiggestInt` も ValueError で断るので見分けられない | MCP-AUTH-41 (「not made of digits」)。T の既存の「Given a negative or non-numeric expires_in, …」の並びに `"\"+3600\""` と `"\"1_000\""` を足す。変異では受け入れて返り、`expect OAuthError` が落ちる |
| `src/auth/oauth/tokens.nim:ROR:9d692cd88d1a1c5d:0` | tokens.nim:107 | `text.len > 18` → `>=` | test_owed | 18 文字の数字列 (`"000000000000003600"`) を、元は値 (3600 秒) で読み、変異は「期限不明」にする | MCP-AUTH-41 (「as digits with leading zeros」)。83 行と同じ 1 本に `expiryOf("\"000000000000003600\"", now) == some(now + initDuration(seconds = 3600))`。変異では none |
| `src/auth/oauth/tokens.nim:RVR:ee6041eafe65551f:3` | tokens.nim:108 | `return none(Time)` → `<return default>` | equivalent | `default(Option[Time])` は none で同じ値 | |
| `src/auth/oauth/tokens.nim:RVR:ee6041eafe65551f:4` | tokens.nim:116 | `return none(Time)` → `<return default>` | equivalent | 同上 | |
| `src/auth/oauth/urls.nim:BLR:f59fa086407fb368:0` | urls.nim:40 | `defaultFetchPolicy` の `allowPrivateNetworks: false` → `true` | test_owed | 既定の policy が私設網の番地を通すようになる。このジョブの私設網のテスト (`test_security_address.nim` の `publicOnly`) は `allowPrivateNetworks = false` を自分で入れ直すので、既定値は見ていない | MCP-AUTH-30 (「private ranges are refused unless allowed」)。B の suite「Fetch policy」に 1 本: 既定の policy (`timeoutMs` だけ短くする) の client に `challengedWith("https://10.0.0.1/x")` → `expect OAuthSecurityError`。変異では検査を通って接続を試み、時間切れの OAuthError になる |
| `src/auth/oauth/urls.nim:ROR:82a2571577ffe944:0` | urls.nim:61 | `narrowedTo` の `host.len > 0` → `>=` | equivalent | `host` が空のとき、右の `isLoopbackHost("")` が偽になる: `classifyHost("")` は `localhost` でなく、`parseHostLiteral("")` は空を none で返し、`:` も無いので none。`and` の結果は元と同じ偽 (前の記録の id 215 と同じ判断) | |
| `src/auth/oauth/urls.nim:RVR:87aa8baa528c4cef:0` | urls.nim:112 | `originOf` の `return ""` → `<return default>` | equivalent | 文字列のリテラルの return は `""` に替わる。元と同じ値 | |
| `src/auth/oauth/urls.nim:ROR:38263dfd8c488dd6:0` | urls.nim:116 | `originOf` の `uri.port.len > 0` → `>=` | test_owed | ポートを書かない URL の origin が `https://host:` になり、正規の resource が `https://mcp.example.com:/mcp` になる。このジョブのテストの URL はどれもポートつき (`127.0.0.1:<port>`) で、ポートの無い正しい resource を通すものが無い | MCP-AUTH-21 (「the valid examples of the specification」)。B の suite「Canonical resource」に 1 本: `newResourceServerAuth(serverConfig(r))` が `https://mcp.example.com/mcp`・`https://mcp.example.com`・`https://mcp.example.com:8443`・`https://mcp.example.com/mcp?tenant=a` で例外なしに返り、`https://mcp.example.com/` と `HTTPS://MCP.example.com/mcp` は `expect ValueError` (正規の形でない)。変異では 1 つ目が ValueError。下の 142・144・145 行も同じ 1 本 |
| `src/auth/oauth/urls.nim:SDL:0c937999c23513de:0` | urls.nim:122 | `pathWithoutTrailingSlash` の `result.setLen(result.len - 1)` → `discard` | test_owed | `/` で終わるパスの issuer か resource で、変異は well-known の URL を作るループが終わらない | MCP-AUTH-35 / MCP-AUTH-14 (「a trailing slash is removed first」)。`discovery.nim:26` と同じ 1 本 (issuer `origin & "/tenant1/"`)。変異では終わらない (timeout) |
| `src/auth/oauth/urls.nim:AOR:e1fc70d51262bafd:0` | urls.nim:122 | `result.len - 1` → `+` | test_owed | 同じ入力で、変異は `/` を落とす代わりに NUL を足し、well-known の URL が `…/oauth-authorization-server/tenant1/\0` になる | MCP-AUTH-35 / MCP-AUTH-14。`discovery.nim:26` と同じ 1 本 (1 つ目と 2 つ目の URL の文面が合わない) |
| `src/auth/oauth/urls.nim:ROR:821a66dd2db19a47:0` | urls.nim:142 | `canonicalResource` の `uri.path.len > 0` → `>=` | equivalent | パスが空のとき、右の `uri.path != "/"` は真で、足されるのは空文字列。結果は変わらない (前の記録の id 229 と同じ判断) | |
| `src/auth/oauth/urls.nim:LOR:76f8556f3ba71a6a:0` | urls.nim:142 | `uri.path.len > 0 and uri.path != "/"` → `or` | test_owed | パスが `/` だけの resource で、元は `/` を落とし、変異は残す。resource metadata の `resource` が client の URL と `/` だけ違うとき、変異は別の resource として断る。resource server は `https://mcp.example.com/` を正規の形として受け入れてしまう | MCP-AUTH-21 (「no bare trailing slash」)。`urls.nim:116` と同じ 1 本 (`https://mcp.example.com/` が `expect ValueError`)。変異では受け入れて返る。client の側 (MCP-AUTH-12「a resource that differs only by … a bare slash is accepted」) も内部側にしか無いので、B の「Protected resource metadata over a scripted server」に、server の URL が `origin`、文書の `resource` が `origin & "/"` で受け入れられる 1 本を足すとよい |
| `src/auth/oauth/urls.nim:ROR:212865059112dc58:0` | urls.nim:144 | `uri.query.len > 0` → `>=` | test_owed | 問い合わせの無い resource の正規の形に `?` が付く。resource server はどの正しい `resource` も「正規の形でない」と断るようになる | MCP-AUTH-21。`urls.nim:116` と同じ 1 本 (正しい例が ValueError になる)。なお `tests/external/test_auth_resource_server.nim` のどのテストも検出するはず (正しい config で `newResourceServerAuth` を呼ぶ) だが、このジョブの testCommand には無い |
| `src/auth/oauth/urls.nim:SDL:a178fbf446f0500c:0` | urls.nim:145 | `result.add "?" & uri.query` → `discard` | test_owed | 問い合わせを持つ resource の正規の形から問い合わせが落ちる。前のテストは内部側に移った | MCP-AUTH-37 (「a canonical resource keeps its query」)。`urls.nim:116` と同じ 1 本 (`https://mcp.example.com/mcp?tenant=a` が例外なしに返る)。変異では ValueError |
| `src/auth/oauth/urls.nim:BLR:9cfbc9aab75c9fd9:0` | urls.nim:149 | `formEncode` の `usePlus = false` → `true` | test_owed | 認可の URL とトークンの要求の本文で、空白が `%20` ではなく `+` になる。外部テストはどれも `decodeQuery` で読むので、どちらの綴りも同じ値になり見えない | MCP-AUTH-37 (「a form field with a space is encoded as %20」)。B の suite「A Bearer challenge seen through the public entries」に 1 本: `consentedFor(v, "Bearer scope=\"files:read files:write\", resource_metadata=\"{prm}\"")` の `urls[0]` を復号せずに見て、`"scope=files%3Aread%20files%3Awrite" in url`。変異では `files%3Aread+files%3Awrite` |
| `src/auth/oauth/urls.nim:SDL:f3884ee08630e876:0` | urls.nim:153 | `formDecode` の `result.add (k, v)` → `discard` | spec_question | `formDecode` と `queryOf` は src に使い手が無い (`queryOf` が `formDecode` を呼ぶだけ)。入口から export もされない。tests/external は自前の同名の補助 (`auth_fixtures.nim`・`ext_auth_fixtures.nim`) を使い、tests/internal に使い手は無く、呼ぶのは `tests/fuzz/targets.nim` の 2 行だけ。どの仕様 ID にも当たらない。問い: src に使い手の無い `formDecode`・`queryOf` を消すか、仕様を持つ公開の関数にするか | 推奨: 消す (fuzz の 2 行も一緒に)。認可の応答の読み取りは `UserAuthorizer` が返す対の列で受け取るので、SDK の中に問い合わせを復号する場面が無い。「公開から外して役割のモジュールに分ける」は要らない (どの入口も export していない) |
| `src/auth/oauth/urls.nim:SDL:5335507b217f25ce:0` | urls.nim:156 | `queryOf` の `formDecode(parseUri(url).query)` → `discard` | spec_question | 同上 (`queryOf` は src にも tests/external・tests/internal にも使い手が無い) | 上と同じ問い・同じ推奨 |

timeout は無い。

測定: 変異検査の道具、ジョブ `tests/mutation/auth_oauth.json`、本線の 36a4c8a5 (2026-10-07)。
2026-10-12 に `tokens.nim` のコメントと `metadata.nim` の raises を変えた (`OAuthSecurityError` は `OAuthError` の子で、Nim 2.2.12 の `XCannotRaiseY` が重複と指した)。次の測定で測り直す。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 333 | 228 | 5 | 81 | 0 | 19 |

**2026-10-15 の注記**: `src/auth/oauth/challenge.nim` は `foundation/nim-bearer-challenge` (`src/bearer_challenge.nim`) へ移した。下の challenge.nim の 16 件は移す前の記録として残す。生き残りを殺した規則 (token68 の詰め物、`=` の前後の空白、値の無い引数、scheme より前の引数、バックスラッシュで切れた引用文字列) は、移した先の E テスト (BCH-01) に直接書き写した。次の測定はあちらで行い、このジョブの `sources` からは外した。

生き残り 81 件の分類 (2 人で分担し、下の 2 節に 1 件ずつ記録した)。

| 分類 | challenge / discovery / fetch / urls / sha256 | authcode / jsonfield / metadata / registration / tokens | 計 |
|---|---:|---:|---:|
| 1 同値 | 6 | 11 | 17 |
| 3 穴 (テストを追加、全件で変異を当てて確認) | 34 | 21 | 55 |
| 4 到達しない・冗長 | 4 | 5 | 9 |
| 計 | 44 | 37 | 81 |

## 見つかった不具合 (生き残りの変異からではなく、テストを書く途中で)

`discoverProtectedResource` と `discoverAuthorizationServer` は、試した URL ごとの失敗を 1 つのエラーに並べる。
デバッグビルドでは asyncdispatch が例外の文面に `Async traceback:` 以下を付けるので、2 番目以降の失敗がエラーから消えていた
(リリースビルドでは起きない)。落ちるテストを先に書いて修正した (`fix(auth)`)。文面から追跡を外す `plainMessage` は
`src/protocol/diagnostic.nim` の 1 か所にまとめた (それまで `server/errors.nim` にも同じ関数があった)。

## 分類 4 の扱い (リードの判断)

| id | 場所 | 内容 | 判断 |
|---|---|---|---|
| 7、3、8、4、10 | `jsonfield.nim:15-21` | `intField`。本線・拡張・下書きのどこからも呼ばれていない | **削除した** |
| 305、271、280、313 | `challenge.nim:41、42、54、67` | 区切りの読み飛ばし、終端の判定、`=` の詰め物の読み飛ばし、閉じ引用符を越える `inc i` | 残す。消しても「迷い文字は 1 つ進める」規則が同じ結果にするが、それは壊れた入力のための逃げ道で、文法どおりの入力の読み方をそこに頼らせない |

## 残っているもの

- `tokens.nim` の `expires_in`: 先頭に 0 の付いた 19 文字以上の数字列は、値が小さくても「期限不明」になる。期限不明は 401 で
  補正される安全側の扱い。2026-10-12 に、直さずコメントを挙動に合わせると決め、合わせた。
- id 205 (`discovery.nim:113`) のテストが確かめているのは診断の文面のラベルだけ (`getJson` が同じ拒否をする)。

## G2 変異検出: auth_oauth ジョブ、前半 (g2f-oauth-a)

測定: 変異検査の道具、ジョブ `tests/mutation/auth_oauth.json`、本線の 36a4c8a5 (2026-10-07)。
ジョブ全体の数: 全変異 333、killed 228、timeout 5、survived 81、runError 0、compileError 19。
このファイルは 81 件のうち、`src/auth/oauth/` の `challenge.nim` (16)、`discovery.nim` (14)、`fetch.nim` (5)、`urls.nim` (8)、`sha256.nim` (1) の 44 件を扱う。
残り (`authcode.nim`、`jsonfield.nim`、`metadata.nim`、`registration.nim`、`tokens.nim`) は g2f-oauth-b の担当で、リードが 2 つの記録を 1 つにする。
これらのファイルは測定の後に変わっていない (行番号は測定時のものと一致する)。

| 担当分 | 同値 (1) | 検出済み (2/2b) | 穴 (3) | 死んだ・重複したコード (4) | 欠陥 (5) | 許容 (6) |
|---:|---:|---:|---:|---:|---:|---:|
| 44 | 6 | 0 | 34 | 4 | 0 | 0 |

分類 5 の欠陥は生き残りの変異そのものではないが、分類 3 のテスト (下の 199・200 の行) を書く途中で見つかり、直した (後述「見つかった欠陥」)。
分類 3 の 34 件は、変異を 1 件ずつ手で当て、名指ししたテストが落ちる (落ちる、またはハングする) ことを見て、`jj restore` で戻した。
未確認の id は無い。分類 1 と 4 の 10 件は読解だけで決めた (変異は当てていない)。
テストはすべて `tests/test_auth_oauth_basics.nim` (ジョブの `testCommand` に入っている。ジョブの変更は無い) にあり、新しい Suite は末尾で、名前に `(mutation review, g2f-oauth-a)` を持つ。
認可のある版 (2025-03-26 以降) に限らず、このファイルのテストは版に依存しない部品 (チャレンジの解析、URL、ループバックの待ち受け) だけを使う。
`-d:mcpDefaultProtocolVersion=2024-11-05` と `2025-11-25` でも通ることを確かめた。

「ハング」は、変異後のプログラムが `while` から出なくなり、テストが終わらないことを指す (変異検査の道具 では timeout で検出)。
`header[i]` は `i == header.len` でも `IndexDefect` になる (Nim の string は添字検査が `< len`) ので、`i <= header.len` への変異は、入力がその位置で終わるときに落ちる。

### challenge.nim

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 304 | challenge.nim:26 | SDL | `none(string)` → `discard` | 1 同値 | `Option[string]` の既定値が `none`。 |
| 318 | challenge.nim:86 | SDL | `none(BearerChallenge)` → `discard` | 1 同値 | `Option[BearerChallenge]` の既定値が `none`。 |
| 305 | challenge.nim:41 | SDL | `skipSeparators()` → `discard` | 4 重複 | 区切り (空白、タブ、コンマ) は `TokenChars` に無いので、`readToken` が空になり、45–47 行の「迷い文字」の規則が 1 文字ずつ進める。結果は同じ。 |
| 271 | challenge.nim:42 | ROR | `i >= header.len` → `i > header.len` | 4 重複 | `i == header.len` のとき `readToken` は空で、迷い文字の規則が `i` を進めてから `i > header.len` で抜ける。結果は同じ。 |
| 280 | challenge.nim:54 | ROR | `header[i] == '='` → `header[i] != '='` | 4 重複 | 52 行の `if` で `header[i] == '='` と分かっているので、変異後の `while` は 1 回も回らない。残る `=` は迷い文字の規則が捨てる。結果は同じ。 |
| 313 | challenge.nim:67 | SDL | `inc i` (閉じ引用符) → `discard` | 4 重複 | 閉じ引用符は `TokenChars` に無く、迷い文字の規則が捨てる。 |
| 276 | challenge.nim:50 | ROR | `result.len > 0` → `result.len >= 0` | 3 穴 | 最初のチャレンジより前に `name=value` があると、変異後は空の `result[^1]` を引いて `IndexDefect`。`Given a header that starts with a parameter and no scheme, when parsed, then no challenge carries it` (RFC 9110 11.6.1 で auth-param は scheme の後ろにしか無い)。 |
| 295 | challenge.nim:54 | LOR | `i < header.len and header[i] == '='` の `and` → `or` | 3 穴 | token68 の `=` のあとの全文を読み飛ばし、末尾で `IndexDefect`。`Given a Basic challenge with token68 padding before a Bearer one, ...` と `Given a token68 whose padding ends the header, ...`。 |
| 310 | challenge.nim:55 | SDL | `inc i` (パディングの `=`) → `discard` | 3 穴 | ハング。同じ 2 つのテスト (`Basic YWJj==` はこれまでのテストに無かった)。 |
| 279 | challenge.nim:54 | ROR | `i < header.len` → `i <= header.len` | 3 穴 | パディングで終わるヘッダーで `IndexDefect`。`Given a token68 whose padding ends the header, ...` |
| 277 | challenge.nim:52 | ROR | `i < header.len` → `i <= header.len` | 3 穴 | `=` で終わるヘッダーで `IndexDefect`。`Given a parameter that ends the header, when parsed, then its value is empty` |
| 281 | challenge.nim:57 | ROR | `i < header.len` → `i <= header.len` | 3 穴 | 同上。 |
| 282 | challenge.nim:60 | ROR | `i < header.len` → `i <= header.len` | 3 穴 | 同上。 |
| 311 | challenge.nim:58 | SDL | `inc i` (`=` のあとの空白) → `discard` | 3 穴 | ハング。`Given white space around the equals sign, when parsed, then the values are the same as without it (RFC 9110 11.2 BWS)` (BWS: `=` の前後に空白を置ける)。 |
| 269 | challenge.nim:63 | AOR | `i + 1` → `i - 1` | 3 穴 | 引用文字列がバックスラッシュで切れていると、変異後は範囲外を読んで `IndexDefect`。`Given a quoted string that is cut off after a backslash, when parsed, then the backslash is kept` |
| 287 | challenge.nim:63 | ROR | `i + 1 < header.len` → `i + 1 <= header.len` | 3 穴 | 同上。 |

### discovery.nim

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 195 | discovery.nim:25 | SDL | `path.setLen(path.len - 1)` → `discard` | 3 穴 | 発行者のパスが `/` で終わると変異後はハング (OIDC を試す形式だけが通る行で、これまでのテストの発行者は `/` で終わらなかった)。`Given an issuer path that ends in a slash, when listing candidates, then the slash is dropped from every URL` |
| 176 | discovery.nim:25 | AOR | `path.len - 1` → `path.len + 1` | 3 穴 | 変異後は NUL 文字を足して URL が変わる。同じテスト。 |
| 188 | discovery.nim:43 | LOR | `reply.code != 200 or reply.document.isNone` の `or` → `and` | 3 穴 | 201 の有効な文書は使われず (RFC 9728 3.2: 成功は 200)、200 で JSON オブジェクトでない本文は失敗。変異後は前者を使い、後者は `none` の値取得で `UnpackDefect`。`Given a 201 with a valid document or a non-object 200, when fetching, then it is refused` |
| 189 | discovery.nim:92 | LOR | 同上 (`discoverAuthorizationServer`) | 3 穴 | RFC 8414 3.2 (成功は 200)。`Given a 201 with a valid document, when discovering, then it is not used and every URL tried is named with its status` と `Given a 200 whose body is not a JSON object, when discovering, then it is a failure of that URL`。 |
| 190 | discovery.nim:118 | LOR | 同上 (`discoverOrDefault`) | 3 穴 | `Given the root of an origin that answers 201 or a non-object 200, when discovering with the 2025-03-26 rules, then it fails without defaults` |
| 191 | discovery.nim:88 | BLR | `sawSecurityFailure = false` → `true` | 3 穴 | 安全の失敗が無いなら、失敗は `OAuthSecurityError` ではない。`Given a 201 with a valid document, ...`、`Given a 200 whose body is not a JSON object, ...`、`Given a document without a token endpoint, when discovering, then the failure names the field and is not a security failure`。 |
| 192 | discovery.nim:97 | BLR | `sawSecurityFailure = true` → `false` | 3 穴 | 別の発行者を名乗る文書は安全の失敗として報告される。`Given a document that names another issuer, when discovering, then the failure is a security failure that says why` |
| 199 | discovery.nim:72 | SDL | `failures.add e.msg` (安全の失敗、資源の探索) → `discard` | 3 穴 | 失敗の理由がエラーに残る。`Given a document for another resource at the first URL, when probing, then the failure is a security failure that says why` |
| 200 | discovery.nim:74 | SDL | `failures.add e.msg` (資源の探索) → `discard` | 3 穴 | `Given no document at either well-known URL, when probing, then the failure lists both with their status` (この行は欠陥の修正の証拠でもある。後述)。 |
| 201 | discovery.nim:86 | SDL | `checkFetchUrl(issuer, ...)` → `discard` | 3 穴 | 発行者に断片があると、URL は断片を落として作られるので、変異後は要求が出てしまう。`Given an issuer with a fragment, when discovering, then it is refused before any request is made` (要求の数が 0)。 |
| 202 | discovery.nim:93 | SDL | `failures.add url & ": HTTP " & ...` → `discard` | 3 穴 | エラーは試した URL とその状態を挙げる。`Given a 201 with a valid document, ...` ほか。 |
| 203 | discovery.nim:98 | SDL | `failures.add url & ": " & e.msg` (安全) → `discard` | 3 穴 | `Given a document that names another issuer, ...` |
| 204 | discovery.nim:100 | SDL | `failures.add url & ": " & e.msg` → `discard` | 3 穴 | `Given a document without a token endpoint, ...` (欠けた項目名がエラーに出る)。 |
| 205 | discovery.nim:113 | SDL | `checkFetchUrl(issuer, ..., "authorization base URL")` → `discard` | 3 穴 (診断の文面だけ) | 同じ判定は `getJson` の中の `checkFetchUrl` (同じ scheme と host の URL) も行うので、拒否そのものは冗長。変異後に変わるのは、どの URL を断ったかの名前 (`what`) だけ。`Given a server URL on plain http to a remote host, when discovering with the 2025-03-26 rules, then the error names the authorization base URL` はその名前を確かめる。 |

### fetch.nim

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 326 | fetch.nim:36 | BLR | `followRedirects = false` → `true` | 3 穴 | 転送は追わず、報告する。`Given an endpoint that answers 302, when requested, then the redirect is reported and its target is never requested` (転送先への要求が 0 件)。 |
| 323 | fetch.nim:75 | ROR | `result.code != 304` → `== 304` | 3 穴 | 302 は転送として報告され、304 (条件付き要求への答え) は何も動かさず返る。上のテストと `Given an endpoint that answers 304 to a conditional request, when requested, then the 304 is the reply`。 |
| 327 | fetch.nim:37 | SDL | `defer: response.close()` → `discard` | 3 穴 | 本文のある答えは配線 (`http_wire`) が読み終えたとき自分で閉じるので、本文の無い答え (204、`Content-Length: 0`) だけが `close` を要る。`Given a keep-alive answer without a body, when the request is done, then the client has closed the connection` (サーバー側で相手の切断を見る)。最初に書いた「本文のある keep-alive」のテストは変異後も通ったので、書き換えた。 |
| 328 | fetch.nim:48 | SDL | `checkFetchUrl(url, policy, what)` → `discard` | 3 穴 | 名前の解決先がループバックでも、URL の文面が名前なら http は断る。`Given plain http to a host name that resolves to loopback, when requested, then it is refused and nothing is sent` (要求が 0 件)。 |
| 330 | fetch.nim:58 | SDL | `open.response.close()` → `discard` | 3 穴 | 時間切れのあと接続を閉じる。`Given an endpoint that never answers, when the time runs out, then the connection is closed as well as reported` (サーバー側で相手の切断を見る)。 |

### sha256.nim

**2026-10-15 の注記**: 下の 1 件は、手で書いていた SHA-256 (圧縮関数と埋め草) の記録である。同じ日に `sha256.nim` の中身を nimcrypto の呼び出しに替え、その行は無くなった。`sha256.nim` に残るのは型と、nimcrypto を呼ぶ 2 行と `toHex` だけで、次の測定で測り直す。替える前と後に、FIPS 180-4 / RFC 6234 のベクトル (`tests/internal/test_auth_sha256.nim`) と RFC 4231 の HMAC-SHA256 のベクトル (`tests/internal/test_protocol_hmac.nim`) が通ることを確かめた。

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 57 | sha256.nim:49 | ROR | `data.len - offset >= 64` → `> 64` | 1 同値 | ちょうど 64 バイトが残る場合、変異後はそれを末尾の 128 バイトの埋め草に入れて 2 ブロック処理する。FIPS 180-4 5.1.1 の埋め草を付けたメッセージは、64 バイトを 1 ブロックで処理してから 64 バイトの埋め草を付けるのと同じ列になり、ダイジェストは同じ。 |

### urls.nim

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 215 | urls.nim:57 | ROR | `host.len > 0` → `host.len >= 0` | 1 同値 | `host` が空のとき `isLoopbackHost("")` は偽 (`classifyHost("")` は `none`: 空は `localhost` でもアドレスでもなく、`:` も含まない)。 |
| 255 | urls.nim:108 | RVR | `return ""` → `return default` | 1 同値 | `string` の既定値が `""`。 |
| 229 | urls.nim:138 | ROR | `uri.path.len > 0` → `>= 0` | 1 同値 | パスが空のとき `uri.path != "/"` は真で、足されるのは空文字列。 |
| 235 | urls.nim:70 | LOR | `uri.hostname.len == 0 or uri.scheme.len == 0` の `or` → `and` | 3 穴 | host の無い `https:///x` は絶対 URL ではない。変異後は通る。`Given URLs that name no host or no scheme, when checked, then they are refused` |
| 236 | urls.nim:74 | LOR | `username.len > 0 or password.len > 0` の `or` → `and` | 3 穴 | 利用者名だけ、またはパスワードだけの URL も資格情報つき。`Given a user name alone or a password alone, when checked, then the URL is refused for its credentials` |
| 240 | urls.nim:133 | LOR | `scheme.len == 0 or hostname.len == 0` の `or` → `and` | 3 穴 | `https:///mcp` も `//mcp.example.com/mcp` も資源として断る (変異後は後者が `://mcp.example.com/mcp` になる)。`Given a resource without a host or without a scheme, when canonicalized, then it is refused` |
| 251 | urls.nim:141 | SDL | `result.add "?" & uri.query` → `discard` | 3 穴 | 正規の資源 (RFC 8707 2) は問い合わせを保つ。`Given a resource with a query, when canonicalized, then the query is kept (RFC 8707 2)` |
| 244 | urls.nim:145 | BLR | `usePlus = false` → `true` | 3 穴 | `formEncode` は空白を `%20` にする (文書コメントの約束)。`Given a field with a space, when form-encoded, then the space is %20` |

### 見つかった欠陥 (分類 5)

`discovery.nim` の `discoverProtectedResource` と `discoverAuthorizationServer` は、試した URL ごとの失敗を `e.msg` のまま `failures` に集めて `join("; ")` していた。
デバッグビルドの asyncdispatch は、future を通った例外のメッセージに `\nAsync traceback:` 以下を足し、メッセージが再び伸びるときは最初のその印より前だけを残す。
そのため、最初の失敗が future 越しだと、その追跡文が 2 番目以降の失敗を切り落とし、エラーは最初の URL の理由しか言わなかった (リリースビルドでは起きない。ビルドの違いで診断が変わる)。
`Given no document at either well-known URL, when probing, then the failure lists both with their status` を先に書いて落ちることを見てから、`oauth/errors.nim` に `plainMessage` を足し (サーバー側の `server/errors.nim` の同名の関数と同じ 1 行。認可がサーバーの層に依存しないよう、重ねて置いた)、`discovery.nim` の 4 か所で使った。
コミット `fix(auth): keep every failure of a discovery in the error that lists them`。
変異 199 と 200 のテストは、この修正のあとでだけ意味を持つ (修正前は 200 のテストが落ちる)。

### 残っているもの

- 分類 4 の 4 件 (305、271、280、313) は、`parseChallenges` の「迷い文字は 1 つ進める」規則 (45–47 行) が、区切りの読み飛ばし、`=` のパディング、閉じ引用符をすでに引き受けているために、観測できない。コードを消すかどうかはリードが決める (消すと `parseChallenges` が短くなる。ただしパディングの `while` は読みやすさのための明示でもある)。
- 分類 1 の 6 件は理由を上の表に書いた。
- 205 は診断の文面 (どの URL を断ったかの名前) だけを確かめている。拒否そのものは `getJson` の検査と重なっていて、`discoverOrDefault` の `checkFetchUrl` は、名前以外の振る舞いを足していない。
- `plainMessage` が `server/errors.nim` と `auth/oauth/errors.nim` の 2 か所にある。共有の置き場所が要るならリードが決める (認可がサーバーに依存しない形にするため、今は重ねた)。

## G2 変異検出: `src/auth/oauth/` の後半 (authcode / jsonfield / metadata / registration / tokens)

測定: 変異検査の道具、ジョブ `tests/mutation/auth_oauth.json`、mainline の 36a4c8a5 (2026-10-07)。
ジョブ全体の数字は次のとおり。この文書は、そのうち下の 5 ファイルの survived 37 件を扱う (残りの `challenge.nim`、`discovery.nim`、`fetch.nim`、`urls.nim`、`sha256.nim` は別の文書)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 333 | 228 | 5 | 81 | 0 | 19 |

### survived 37 件

分類は、1 = 同値、3 = 穴 (新しい外部仕様テストを足した)、4 = 到達しないコード。内訳は 1 が 11 件、3 が 21 件、4 が 5 件。
クラス 3 の 21 件は、変異を手で当てて下に書いたテストが落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは `jj restore` で戻した)。
足したテストは `tests/test_auth_oauth_basics.nim` と `tests/test_security_auth_tokens.nim` の末尾の suite `(mutation review, g2f-oauth-b)` にある。2 本ともジョブの `testCommand` に入っているので、ジョブの変更は要らない。
Scenario は `MCP-AUTH-38` から `-5` (`specs/authorization.feature`、対応は `specs/tests.map`)。
`SIGSEGV` と書いた行は、変異で `nil` を読むため、テストが `FAILED` を出さずに異常終了して落ちた。落ちることに変わりはない。
足したテストは `-d:mcpDefaultProtocolVersion=2024-11-05`、`=2025-11-25`、既定の 2026-07-28 のすべてで合格する (この部分は版に依存しない)。

#### jsonfield.nim

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

#### metadata.nim

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 90 | metadata.nim:33 | LOR | `node.isNil or node.kind == JNull` → `and` | 3 | `registration_endpoint` の無い文書で `nil` を読む (null のときは文字列でないとして拒否してしまう)。`Given a registration endpoint that is missing or null, when parsed, then the server offers no registration` (SIGSEGV)。 |
| 104 | metadata.nim:34 | RVR | `return none(string)` → `<return default>` | 1 | `Option[string]` の既定値は `none`。 |
| 105 | metadata.nim:48 | RVR | `return none(seq[string])` → `<return default>` | 1 | `Option[seq[string]]` の既定値は `none`。 |
| 101 | metadata.nim:109 | SDL | `checkFetchUrl(authorizationEndpoint, ...)` → `discard` | 3 | 認可エンドポイントが遠隔ホストへの平文 http でも通ってしまう。`Given metadata with a plain http authorization or registration endpoint on a remote host, when parsed, then it is rejected` (`FAILED`)。 |
| 103 | metadata.nim:113 | SDL | `checkFetchUrl(registrationEndpoint.get, ...)` → `discard` | 3 | 登録エンドポイントについて同上。同じテスト (`FAILED`)。 |

#### registration.nim

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 142 | registration.nim:53 | ROR | `description.len > 0` → `>=` | 3 | 説明の無い OAuth エラーの文面が `... (` `)` つきになる。`Given an OAuth error answer, when the error is built, then the description follows only when there is one` (`FAILED`)。診断の文面だが、利用者が読む唯一の理由なので、説明が付くのは与えられたときだけという事実として固定した。 |
| 144 | registration.nim:70 | LOR | `clientId.isNone or clientId.get.len == 0` → `and` | 3 | client_id の無い応答で `UnpackDefect`、空の client_id は受け入れてしまう。`Given a registration response without a client_id or with an empty one, when read, then registration fails` (`Expect Failed, UnpackDefect was thrown`)。 |

#### authcode.nim

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 159 | authcode.nim:35 | LOR | `hostname.len == 0 or anchor.len > 0` → `and` | 3 | フラグメントつき (RFC 6749 3.1.2) とホストの無い `https:///cb` のリダイレクト URI が通る。`Given redirect URIs with a fragment, no host, plain http to a remote host or another scheme, when checked, then they are refused` (`FAILED`)。 |
| 167 | authcode.nim:54 | SDL | `checkRedirectUri(redirectUri)` → `discard` | 3 | 認可リクエストが遠隔ホストへの平文 http のリダイレクト URI で作られる。`Given a plain http redirect URI to a remote host, when an authorization request is made, then no request is made` (`FAILED`)。 |
| 160 | authcode.nim:80 | LOR | `difference or (a[i].ord xor b[i].ord)` → `and` | 3 | 長さが同じなら どの `state` も一致扱いになる (偽造された応答を受け入れる)。`Given a response whose state has the length of the request's but differs, when the code is read, then it is refused` (`FAILED`)。 |
| 162 | authcode.nim:117 | LOR | `code.isNone or code.get.len == 0` → `and` | 3 | code の無い応答で `UnpackDefect`、空の code を返す。`Given a response with a matching state but no code or an empty one, when the code is read, then it is refused` (`FAILED`)。 |
| 164 | authcode.nim:149 | LOR | `access.isNone or access.get.len == 0` → `and` | 3 | access_token の無い応答で `UnpackDefect`、空の access_token を受け入れる。`Given a token response without an access token or with an empty one, when parsed, then it is refused` (`FAILED`)。 |

#### tokens.nim

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

### 残っているもの

- **クラス 4 (解消済み)**: `jsonfield.nim:15-21` の `intField` (id 7, 3, 8, 4, 10)。呼び出し元もテストも無かったので、`refactor(auth): one plainMessage for the SDK; drop the unused intField` で削除した。
- **欠陥ではないと判断したが、記録しておく点**: `tokens.nim:96-105` のコメントは「どの寿命より長い数字列は変換せずに上限超過とみなす」と書くが、19 文字以上で先頭に 0 が付く数字列 (`"0000000000000003600"`) は値が小さくても「期限不明」になる。期限不明は 401 で補正される安全側の扱いで、そのような応答を送る認可サーバーも想定しにくいので、直さず、テストも足していない (18 文字ちょうどの境界は上の id 124 のテストが固定する)。
- 上の 37 件のうち、確かめていないものは無い (クラス 3 の 21 件は、すべて手で当てて落ちることを見た)。クラス 1 と 4 は読解による分類で、変異は当てていない。

## 測り直し (本線 76a08c6a、2026-10-10)

36a4c8a5 の測定のあとに足したテストと修正を入れたコミットで、同じジョブを測り直した。変異 326、検出 280、時間切れ 8、コンパイル不能 19、**生き残り 19** (前回 81)。

前回の生き残りとの突き合わせは変異の指紋で行った (指紋が変わった行は、ファイル・変異の文面・3 行以内の行番号で合わせた)。生き残りの 19 件はすべて前回も生き残っていて、この文書に分類と理由がある。新しく現れた生き残りは無い。

時間切れ 8 件のうち 5 件は前回も時間切れ。残り 3 件は前回は生き残りで、前回のあとに足したテストがその行に届くようになり、終わらなくなったもの:

| 場所 | 変異 | 結果 | 理由 |
|---|---|---|---|
| `challenge.nim:55` | SDL `inc i` → `discard` | 時間切れ | 添字が進まず、走査のループが終わらない |
| `challenge.nim:58` | SDL `inc i` → `discard` | 時間切れ | 同上 |
| `discovery.nim:26` | SDL `path.setLen(path.len - 1)` → `discard` | 時間切れ | 末尾の `/` が減らず、取り除くループが終わらない |

どれも変異そのものが止まらないループを作る。テストの待ち方の問題ではない。
