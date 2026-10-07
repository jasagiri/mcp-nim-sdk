# G2 変異検出: auth_oauth ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/auth_oauth.json`、本線の 36a4c8a5 (2026-10-07)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 333 | 228 | 5 | 81 | 0 | 19 |

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
  補正される安全側の扱いで、直していない。
- id 205 (`discovery.nim:113`) のテストが確かめているのは診断の文面のラベルだけ (`getJson` が同じ拒否をする)。

## G2 変異検出: auth_oauth ジョブ、前半 (g2f-oauth-a)

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

測定: `nim-muter`、ジョブ `tests/mutation/auth_oauth.json`、mainline の 36a4c8a5 (2026-10-07)。
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

- **クラス 4 (リードの判断待ち)**: `jsonfield.nim:15-21` の `intField` (id 7, 3, 8, 4, 10)。呼び出し元が無く、テストも無い。消すのが素直だと思うが、公開 proc (`*`) なので、消すか、将来使うなら E テストを足すかはリードが決める。私は消していない。
- **欠陥ではないと判断したが、記録しておく点**: `tokens.nim:96-105` のコメントは「どの寿命より長い数字列は変換せずに上限超過とみなす」と書くが、19 文字以上で先頭に 0 が付く数字列 (`"0000000000000003600"`) は値が小さくても「期限不明」になる。期限不明は 401 で補正される安全側の扱いで、そのような応答を送る認可サーバーも想定しにくいので、直さず、テストも足していない (18 文字ちょうどの境界は上の id 124 のテストが固定する)。
- 上の 37 件のうち、確かめていないものは無い (クラス 3 の 21 件は、すべて手で当てて落ちることを見た)。クラス 1 と 4 は読解による分類で、変異は当てていない。
