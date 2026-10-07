# G2 変異検出: auth_oauth ジョブ、前半 (g2f-oauth-a)

測定: `nim-muter`、ジョブ `tests/mutation/auth_oauth.json`、本線の 36a4c8a5 (2026-10-07)。
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

「ハング」は、変異後のプログラムが `while` から出なくなり、テストが終わらないことを指す (nim-muter では timeout で検出)。
`header[i]` は `i == header.len` でも `IndexDefect` になる (Nim の string は添字検査が `< len`) ので、`i <= header.len` への変異は、入力がその位置で終わるときに落ちる。

## challenge.nim

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

## discovery.nim

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

## fetch.nim

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 326 | fetch.nim:36 | BLR | `followRedirects = false` → `true` | 3 穴 | 転送は追わず、報告する。`Given an endpoint that answers 302, when requested, then the redirect is reported and its target is never requested` (転送先への要求が 0 件)。 |
| 323 | fetch.nim:75 | ROR | `result.code != 304` → `== 304` | 3 穴 | 302 は転送として報告され、304 (条件付き要求への答え) は何も動かさず返る。上のテストと `Given an endpoint that answers 304 to a conditional request, when requested, then the 304 is the reply`。 |
| 327 | fetch.nim:37 | SDL | `defer: response.close()` → `discard` | 3 穴 | 本文のある答えは配線 (`http_wire`) が読み終えたとき自分で閉じるので、本文の無い答え (204、`Content-Length: 0`) だけが `close` を要る。`Given a keep-alive answer without a body, when the request is done, then the client has closed the connection` (サーバー側で相手の切断を見る)。最初に書いた「本文のある keep-alive」のテストは変異後も通ったので、書き換えた。 |
| 328 | fetch.nim:48 | SDL | `checkFetchUrl(url, policy, what)` → `discard` | 3 穴 | 名前の解決先がループバックでも、URL の文面が名前なら http は断る。`Given plain http to a host name that resolves to loopback, when requested, then it is refused and nothing is sent` (要求が 0 件)。 |
| 330 | fetch.nim:58 | SDL | `open.response.close()` → `discard` | 3 穴 | 時間切れのあと接続を閉じる。`Given an endpoint that never answers, when the time runs out, then the connection is closed as well as reported` (サーバー側で相手の切断を見る)。 |

## sha256.nim

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 57 | sha256.nim:49 | ROR | `data.len - offset >= 64` → `> 64` | 1 同値 | ちょうど 64 バイトが残る場合、変異後はそれを末尾の 128 バイトの埋め草に入れて 2 ブロック処理する。FIPS 180-4 5.1.1 の埋め草を付けたメッセージは、64 バイトを 1 ブロックで処理してから 64 バイトの埋め草を付けるのと同じ列になり、ダイジェストは同じ。 |

## urls.nim

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

## 見つかった欠陥 (分類 5)

`discovery.nim` の `discoverProtectedResource` と `discoverAuthorizationServer` は、試した URL ごとの失敗を `e.msg` のまま `failures` に集めて `join("; ")` していた。
デバッグビルドの asyncdispatch は、future を通った例外のメッセージに `\nAsync traceback:` 以下を足し、メッセージが再び伸びるときは最初のその印より前だけを残す。
そのため、最初の失敗が future 越しだと、その追跡文が 2 番目以降の失敗を切り落とし、エラーは最初の URL の理由しか言わなかった (リリースビルドでは起きない。ビルドの違いで診断が変わる)。
`Given no document at either well-known URL, when probing, then the failure lists both with their status` を先に書いて落ちることを見てから、`oauth/errors.nim` に `plainMessage` を足し (サーバー側の `server/errors.nim` の同名の関数と同じ 1 行。認可がサーバーの層に依存しないよう、重ねて置いた)、`discovery.nim` の 4 か所で使った。
コミット `fix(auth): keep every failure of a discovery in the error that lists them`。
変異 199 と 200 のテストは、この修正のあとでだけ意味を持つ (修正前は 200 のテストが落ちる)。

## 残っているもの

- 分類 4 の 4 件 (305、271、280、313) は、`parseChallenges` の「迷い文字は 1 つ進める」規則 (45–47 行) が、区切りの読み飛ばし、`=` のパディング、閉じ引用符をすでに引き受けているために、観測できない。コードを消すかどうかはリードが決める (消すと `parseChallenges` が短くなる。ただしパディングの `while` は読みやすさのための明示でもある)。
- 分類 1 の 6 件は理由を上の表に書いた。
- 205 は診断の文面 (どの URL を断ったかの名前) だけを確かめている。拒否そのものは `getJson` の検査と重なっていて、`discoverOrDefault` の `checkFetchUrl` は、名前以外の振る舞いを足していない。
- `plainMessage` が `server/errors.nim` と `auth/oauth/errors.nim` の 2 か所にある。共有の置き場所が要るならリードが決める (認可がサーバーに依存しない形にするため、今は重ねた)。
