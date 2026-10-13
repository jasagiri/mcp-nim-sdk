# 規格の文と仕様 ID の突き合わせ (本線の系列)

2026-10-13。MCP の規格の本文 (上流 `modelcontextprotocol/modelcontextprotocol` のコミット `3778656b2e0b`、2026-10-12) の規範的な文を 1 文ずつ一覧にし、本線のコミット `37b1e2faef5f` の仕様 ID (`specs/*.feature` の `@spec:<ID>`、469 件) と結んだ記録。
**読むだけの作業で、仕様もテストも実装も書き換えていない。** 拡張と下書きの系列は対象にしていない。

1 行ごとの表は [spec-traceability.tsv](spec-traceability.tsv) (2788 行。列は版・ファイル・節・行・水準・拾い方・文・判定・仕様 ID・相手・検証・注記)。

## 結果

5 版の本文から拾った文は 2788 行。版をまたいで同じ文を 1 つに数えると 1505 文。

| 判定 | 文 (重複を除く) | うち MUST の水準 | 意味 |
|---|---:|---:|---|
| 結ばれた | 706 | 394 | 文が求めることを述べる Scenario がある |
| 一部だけ | 170 | 104 | Scenario は文の一部しか述べていない (何が無いかは注記) |
| SDK への求めで仕様が無い | 202 | 89 | クライアントかサーバーの実装への求めで、当たる Scenario が無い。**仕様の漏れの候補** |
| SDK を使う側への求め | 245 | 59 | 利用者の画面・運用・ハンドラの中身への求めで、SDK だけでは決められない |
| SDK が実装しない相手への求め | 78 | 43 | 認可サーバーなど |
| 求めになっていない | 104 | 14 | 小文字の語の叙述、変更履歴、将来の予告など |
| 計 | 1505 | 703 | |

「MUST の水準」は、文が MUST / MUST NOT / SHALL / REQUIRED を含むもの (導入文から引き継いだ箇条書きの項目を含む)。

版ごと (その版の本文に載っている行の数):

| 版 | 行 | 結ばれた | 一部だけ | SDK への求めで仕様が無い | SDK を使う側への求め | SDK が実装しない相手への求め | 求めになっていない |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2024-11-05 | 226 | 76 | 25 | 43 | 71 | 0 | 11 |
| 2025-03-26 | 350 | 131 | 42 | 59 | 81 | 20 | 17 |
| 2025-06-18 | 441 | 179 | 54 | 60 | 110 | 11 | 27 |
| 2025-11-25 | 777 | 346 | 97 | 90 | 167 | 27 | 50 |
| 2026-07-28 | 994 | 417 | 126 | 126 | 217 | 28 | 80 |

仕様 ID の側: 469 件のうち、規格の文が 1 つでも結ばれたものは 270 件、**どの文にも結ばれなかったものは 199 件**。下の「規格の文に結ばれない仕様 ID」に一覧がある。

## 読み方の注意

- **「結ばれない仕様 ID」は「独自の仕様」と同じではない。** この作業が拾ったのは、規範の語 (MUST など) を含む文だけである。規格は、メッセージの形をスキーマの型で決めていて、そこには規範の語が無い。`content.feature` のように型の形を確かめる仕様は、規格に根拠があってもここでは結ばれない。`security.feature` は冒頭で、規格ではなく SDK 自身の安全の要件だと書いている。
- **「仕様の漏れの候補」は、SDK が規格に反しているという意味ではない。** Scenario が無い、というだけで、実装がどう振る舞うかは見ていない (テストも実装も読んでいない)。
- 「SDK を使う側への求め」と「仕様が無い」の線引きは、担当の読みによる。SDK が口を用意すべきだと読める求めは「仕様が無い」に寄せるよう指示した。
- `[要判断]` と注記した文が 32 件ある (結ぶか決めきれず、結んでいない)。

## 文の拾い方と、拾えていないもの

- 拾い方: 本文 (`docs/specification/<版>/**/*.mdx`) を段落・箇条書きの項目・表の行に分け、文に切り、次のどれかに当たる文を残した。コードの囲みと frontmatter は読んでいない。
  - `keyword`: 大文字の MUST / MUST NOT / SHALL / SHALL NOT / SHOULD / SHOULD NOT / REQUIRED / RECOMMENDED / NOT RECOMMENDED / MAY / OPTIONAL を含む文 (1971 行)。
  - `inherited`: 「… MUST:」のように規範の語を含みコロンで終わる導入文に続く、箇条書きの項目。水準は導入文のもの (478 行)。
  - `lowercase`: 小文字の must / must not / should / should not / cannot / is required / are required / is not allowed / not permitted / prohibited / forbidden / needs to / has to / shall を含む文 (339 行)。
- スキーマの頁 (`schema.mdx`、2025-06-18 以降) は typedoc が生成した HTML なので、型と欄の説明文 (`<p>`、`<li>`) だけを読んだ。
- 本文にある大文字の規範の語 2113 個のうち 2110 個が、拾った文に入っている。入っていない 3 個は識別子の一部で、文ではない (`MISSING_REQUIRED_CLIENT_CAPABILITY` の見出しと署名、コードの囲みの中の `URL_ELICITATION_REQUIRED`)。
- **拾えていないもの**:
  - 規範の語を使わずに求めている文 (「The server responds with …」のような叙述の形)。数は数えていない。
  - 小文字の `may`、`can`、`will` (叙述との区別が機械的に付かないので拾っていない)。
  - スキーマの型そのもの (欄の有無、型、列挙値)。`schema.ts` / `schema.json` は読んでいない。
  - 図、コードの例、例の中の注釈。
  - 規格が参照する外の文書 (OAuth 2.1、RFC 8414、RFC 9728、SSE の仕様など) の文。
- 拾い方が粗い箇所: 導入文と項目が別の行になるので、項目だけでは主語が分からない行がある (判定のときは本文を開いて補うよう指示した)。表の行は 1 行を 1 文として拾っている。「MUST:」に続く項目の中の MAY の項目が MUST の水準を引き継ぐ箇所がある。

## 確かめ方と、確かめていない範囲

- 1 回目: ワーカー (Claude Sonnet) 5 人が、文を 1 文ずつ読んで仕様 ID を結んだ。スキーマの頁は、拾い方を直したあと 6 人目が判定し直した (107 文、全部について規格の該当箇所を開いた、との報告)。
- 2 回目: 1 回目に結ばれた 1205 組 (文と仕様 ID の 1 対 1) を、別のワーカー 4 人が 1 回目の注記を見ずに判定し直した。結果は「当たる」823、「一部」336、「当たらない」46。
- リードが読んだもの: 「当たらない」の 46 組すべて (46 組とも結びを外した。それで結びが無くなった文は 9 文)。ほかに抜き取りで 1 回目の結び 21 件、「仕様が無い」30 件、「使う側への求め」12 件、「求めになっていない」6 件、「相手への求め」4 件。
- **確かめていない範囲**:
  - 「当たる」「一部」の 1159 組は、リードは抜き取りでしか読んでいない。
  - 結ばれなかった文 (629 文) は 2 回目の検証にかけていない。結べる Scenario を見落としている可能性がある。
  - スキーマの頁の結び 56 文は 2 回目の検証にかけていない (TSV の `checked` が `unverified`)。
  - ワーカーが規格の本文を開いて前後を読んだ割合は、報告によれば担当ごとに 1 回目が 0〜80%、2 回目が 1〜15% ほど。残りは一覧の文と節の名前だけで決めている。指示は「断片は必ず本文を開く」だったが、守られていない担当がある。
  - 抜き取りで見つけた質の問題: 注記が文と合っていない行 (判定は妥当) が 1 件、「相手への求め」の中にサーバーへの求めらしい行が 2 件。直していない。
  - 「仕様が無い」と判定した文について、実装とテストは見ていない。

## 仕様の漏れの候補: MUST の水準で、当たる Scenario が無い文 (89 文)

SHOULD の水準 (76 文)、MAY (29 文)、小文字 (8 文) は TSV にある (`status` が `sdk`)。

| 規格のファイル | 版 | 文 | 相手 | 注記 |
|---|---|---|---|---|
| `basic/authorization.mdx` | 2025-03-26 | Clients MUST securely store tokens following OAuth 2.0 best practices | client | [要判断] トークンの安全な保管。永続ストアはあるが (AUTH-29) 保管の安全性を述べる Scenario は無い |
| `basic/authorization.mdx` | 2025-06-18〜2025-11-25 | Clients and servers MUST implement secure token storage and follow OAuth best practices, as outlined in [OAuth 2.1, Section 7.1](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1-13#section-7.1). | both | [要判断] 安全なトークン保管。AUTH-29 の永続ストアはあるが保管の安全性を述べる Scenario は無い |
| `basic/authorization.mdx` | 2025-06-18〜2025-11-25 | The MCP server MUST NOT pass through the token it received from the MCP client. | server | 受け取ったトークンを素通しで上流へ渡さない。述べる Scenario は無い |
| `basic/authorization/security-considerations.mdx` | 2026-07-28 | Clients and servers MUST implement secure token storage and follow OAuth best practices, as outlined in [OAuth 2.1, Section 7.1](https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1-13#section-7.1). | both | [要判断] 安全なトークン保管。AUTH-29 の永続ストアはあるが保管の安全性を述べる Scenario は無い |
| `basic/authorization/security-considerations.mdx` | 2026-07-28 | The MCP server MUST NOT pass through the token it received from the MCP client. | server | 受け取ったトークンを素通しで上流へ渡さない。述べる Scenario は無い |
| `basic/index.mdx` | 2025-03-26〜2026-07-28 | Requests MUST include a string or integer ID. | both | 要求 id が文字列か整数であること (送る側) を述べる Scenario が無い。CLIENTREQ-5 は応答が id の型を保つ点のみ |
| `basic/index.mdx` | 2025-03-26〜2026-07-28 | Unlike base JSON-RPC, the ID MUST NOT be `null`. | both | 要求 id が null でないことを述べる Scenario が無い |
| `basic/index.mdx` | 2025-03-26〜2025-11-25 | The request ID MUST NOT have been previously used by the requestor within the same session. | both | 同一セッション内で要求 id を再利用しないことを述べる Scenario が無い (CANCEL-3 は再利用された id の扱いのみ) |
| `basic/index.mdx` | 2025-03-26〜2025-06-18 | A response MUST NOT set both. | both | result と error を両方設定しないことを述べる Scenario が無い (TRANSPORT-3 は「どちらも無い」場合のみ) |
| `basic/index.mdx` | 2025-03-26〜2025-06-18 | Results MAY follow any JSON object structure, while errors MUST include an error code and message at minimum. | both | エラー応答が整数の code と message を必ず持つことを述べる Scenario が無い (TRANSPORT-3 は結果もエラーも無い応答のみ) |
| `basic/index.mdx` | 2025-03-26〜2026-07-28 | Error codes MUST be integers. | both | エラー code が整数であることを述べる Scenario が無い |
| `basic/index.mdx` | 2025-03-26〜2026-07-28 | Notifications MUST NOT include an ID. | both | 通知が id を持たないこと (送る側) を述べる Scenario が無い (TRANSPORT-2 は受信時の分類のみ) |
| `basic/index.mdx` | 2025-06-18〜2026-07-28 | Certain key names are reserved by MCP for protocol-level metadata, as specified below; implementations MUST NOT make assumptions about values at these keys. | both | 予約キーの値について仮定を置かないことを述べる Scenario が無い |
| `basic/index.mdx` | 2025-11-25〜2026-07-28 | Error responses MUST include an `error` field with a `code` and `message`. | both | エラー応答が code と message を持つことを述べる Scenario が無い |
| `basic/index.mdx` | 2026-07-28 | The request ID MUST NOT match the ID of any other request the sender has issued and not yet received a response for. | both | 進行中の要求 id と重ならないことを述べる Scenario が無い |
| `basic/index.mdx` | 2026-07-28 | New codes MUST NOT be allocated in this sub-range, and new implementations SHOULD NOT use codes from this sub-range at all. | both | 予約された -32000 帯の符号を新たに出さない/意味を仮定しない、を述べる Scenario が無い |
| `basic/index.mdx` | 2026-07-28 | Apart from `-32002` (see below), receivers MUST NOT assume any specific meaning for these codes. | both | 予約された -32000 帯の符号を新たに出さない/意味を仮定しない、を述べる Scenario が無い |
| `basic/index.mdx` | 2026-07-28 | Implementations MUST NOT emit any code from this sub-range that is not defined by this specification and MUST use defined codes only with their specified meanings. | both | 定義外の符号を出さない、定義済みの符号を定義どおりの意味でのみ使う、を述べる Scenario が無い (使われる符号ごとの Scenario はある) |
| `basic/index.mdx` | 2026-07-28 | (項目) `-32042` — URL elicitation required (2025-11-25 only). | server | 2026-07-28 で -32042 を出さない、を述べる Scenario が無い |
| `basic/index.mdx` | 2026-07-28 | Implementations MUST NOT automatically dereference `$ref` values that resolve to a network URI. | both | [要判断] ネットワーク URI を指す $ref を自動で取りに行かない。SCHEMA-3 は「何も指さない $ref」の拒否のみで、取得しないことを述べる Scenario は無い |
| `basic/index.mdx` | 2026-07-28 | Implementations MAY offer an opt-in mode that fetches non-local `$ref`s but it MUST be disabled by default and SHOULD enforce an allowlist of hosts or at minimum reject loopback, link-local, and private network addresses, apply timeouts and size limits, and… | both | opt-in の外部 $ref 取得 (既定では無効)。SDK がその方式を持つかを述べる Scenario は無い |
| `basic/lifecycle.mdx` | 2024-11-05〜2025-11-25 | (項目) Client implementation information | client | initialize に clientInfo を載せることを述べる Scenario が無い (LIFECYCLE-1 はサーバーが clientInfo を検証する側のみ) |
| `basic/messages.mdx` | 2024-11-05 | Requests MUST include a string or integer ID. | both | 要求 id が文字列か整数であること (送る側) を述べる Scenario が無い。CLIENTREQ-5 は応答が id の型を保つ点のみ |
| `basic/messages.mdx` | 2024-11-05 | Unlike base JSON-RPC, the ID MUST NOT be `null`. | both | 要求 id が null でないことを述べる Scenario が無い |
| `basic/messages.mdx` | 2024-11-05 | The request ID MUST NOT have been previously used by the requestor within the same session. | both | 同一セッション内で要求 id を再利用しないことを述べる Scenario が無い (CANCEL-3 は再利用された id の扱いのみ) |
| `basic/messages.mdx` | 2024-11-05 | A response MUST NOT set both. | both | result と error を両方設定しないことを述べる Scenario が無い (TRANSPORT-3 は「どちらも無い」場合のみ) |
| `basic/messages.mdx` | 2024-11-05 | Error codes MUST be integers. | both | 通知が id を持たないこと (送る側) を述べる Scenario が無い (TRANSPORT-2 は受信時の分類のみ) |
| `basic/messages.mdx` | 2024-11-05 | Notifications MUST NOT include an ID. | both | 通知が id を持たないこと (送る側) を述べる Scenario が無い (TRANSPORT-2 は受信時の分類のみ) |
| `basic/patterns/cancellation.mdx` | 2026-07-28 | Servers MUST NOT send `notifications/cancelled` for any other purpose. | server | cancelled を subscriptions/listen 以外の目的で送らない規則の Scenario が無い |
| `basic/patterns/mrtr.mdx` | 2026-07-28 | `inputRequests` keys are server assigned identifiers and MUST be unique within the scope of the request. | server | [要判断] inputRequests の鍵の一意性を述べる Scenario が無い (JSON の map では鍵は自然に一意だが、SDK が重複を拒む・作らない保証は無い) |
| `basic/patterns/mrtr.mdx` | 2026-07-28 | `inputRequests` values are request objects that MUST be one of [`ElicitRequest`](/specification/2026-07-28/schema#elicitrequest), [`CreateMessageRequest`](/specification/2026-07-28/schema#createmessagerequest), or [`ListRootsRequest`](/specification/2026-07… | server | [要判断] MRTR-1 は型の一致、MRTR-16 は方法ごとの規則を述べるが、Elicit / CreateMessage / ListRoots 以外の値を作らない・拒むとは述べない |
| `basic/patterns/mrtr.mdx` | 2026-07-28 | Servers MUST NOT assume that clients will fulfill the `inputRequests` or retry the original request. | server | [要判断] 「クライアントが応じる・再試行するとは限らない」。SDK が状態を持たない旨は MRTR 冒頭の文にあるが、それを検証する Scenario が無い |
| `basic/patterns/mrtr.mdx` | 2026-07-28 | They MUST NOT be used for any other request that the client may be sending in parallel. | client | inputRequests / requestState を並行する別の要求に使わない、を述べる Scenario が無い |
| `basic/patterns/progress.mdx` | 2026-07-28 | Progress tokens can be chosen by the client using any means, but MUST be unique across all active requests. | client | token を能動中の要求の間で一意に選ぶ規則の Scenario が無い (PROGRESS-5 は token を載せる点のみ) |
| `basic/patterns/subscriptions.mdx` | 2026-07-28 | On stdio, if the connection is terminated and then re-established, the client MUST re-send `subscriptions/listen` to re-establish its subscriptions — the server holds no subscription state across reconnections. | client | stdio の再接続後に subscriptions/listen を再送する Scenario が無い |
| `basic/transports.mdx` | 2024-11-05〜2025-11-25 | The server MUST NOT write anything to its `stdout` that is not a valid MCP message. | server | stdout に MCP メッセージ以外を書かない規則の Scenario が無い (診断は stderr: SEC-HTTP-7, TRANSPORT-3 が間接的) |
| `basic/transports.mdx` | 2024-11-05〜2025-11-25 | The client MUST NOT write anything to the server's `stdin` that is not a valid MCP message. | client | 子の stdin に MCP メッセージ以外を書かない規則の Scenario が無い |
| `basic/transports.mdx` | 2025-03-26〜2025-11-25 | JSON-RPC messages MUST be UTF-8 encoded. | both | JSON-RPC メッセージを UTF-8 とする規則の Scenario が無い (SEC-HTTP-7 の不正 UTF-8 は診断出力のみ) |
| `basic/transports.mdx` | 2025-03-26〜2025-11-25 | Every JSON-RPC message sent from the client MUST be a new HTTP POST request to the MCP endpoint. | client | 検証で結びを外した (MCP-HTTPCLIENT-1)。一部: 各メッセージを POST にする点は暗黙 |
| `basic/transports.mdx` | 2025-03-26〜2025-11-25 | The client MUST use HTTP POST to send JSON-RPC messages to the MCP endpoint. | client | 検証で結びを外した (MCP-HTTPCLIENT-1)。 |
| `basic/transports.mdx` | 2025-03-26〜2025-11-25 | The server MUST NOT send a JSON-RPC _response_ on the stream unless [resuming](#resumability-and-redelivery) a stream associated with a previous client request. | server | GET ストリームに応答を送らない規則 (再開を除く) の Scenario が無い |
| `basic/transports.mdx` | 2025-03-26〜2025-11-25 | The session ID MUST only contain visible ASCII characters (ranging from 0x21 to 0x7E). | server | session ID を可視 ASCII に限る規則の Scenario が無い |
| `basic/transports.mdx` | 2025-03-26〜2025-11-25 | When a client receives HTTP 404 in response to a request containing an `Mcp-Session-Id`, it MUST start a new session by sending a new `InitializeRequest` without a session ID attached. | client | 404 を受けて session ID なしで再 initialize する Scenario が無い (HTTPSTREAM-9 は再開が 404 で止まる点のみ) |
| `basic/transports.mdx` | 2025-11-25 | The client MUST handle the session ID in a secure manner, see [Session Hijacking mitigations](/specification/2025-11-25/basic/security_best_practices#session-hijacking) for more details. | client | クライアントが session ID を安全に扱う規則の Scenario が無い (SEC-HTTP-2 はサーバー側の主体への束縛) |
| `basic/transports/index.mdx` | 2026-07-28 | JSON-RPC messages MUST be UTF-8 encoded. | both | JSON-RPC メッセージを UTF-8 とする規則の Scenario が無い |
| `basic/transports/stdio.mdx` | 2026-07-28 | The server MUST NOT write anything to its `stdout` that is not a valid MCP message. | server | stdout に MCP メッセージ以外を書かない規則の Scenario が無い |
| `basic/transports/stdio.mdx` | 2026-07-28 | The client MUST NOT write anything to the server's `stdin` that is not a valid MCP message. | client | 子の stdin に MCP メッセージ以外を書かない規則の Scenario が無い |
| `basic/transports/stdio.mdx` | 2026-07-28 | The client MUST NOT write JSON-RPC _responses_. | client | 2026-07-28 の stdio クライアントが response を書かない Scenario が無い (SERVERREQ-9 は要求を受けても method not found で答える点) |
| `basic/transports/streamable-http.mdx` | 2026-07-28 | Every JSON-RPC message sent from the client MUST be a new HTTP POST request to the MCP endpoint. | client | 検証で結びを外した (MCP-HTTPCLIENT-1,MCP-HTTP-7)。 |
| `basic/transports/streamable-http.mdx` | 2026-07-28 | The client MUST use HTTP POST to send JSON-RPC messages. | client | 検証で結びを外した (MCP-HTTPCLIENT-1,MCP-HTTP-7)。 |
| `basic/transports/streamable-http.mdx` | 2026-07-28 | The client MUST NOT send JSON-RPC _responses_. | client | クライアントが response を POST しない規則の Scenario が無い |
| `basic/transports/streamable-http.mdx` | 2026-07-28 | These notifications MUST relate to the originating client request. | server | 検証で結びを外した (MCP-HTTPSTREAM-2)。 |
| `basic/transports/streamable-http.mdx` | 2026-07-28 | If the `Mcp-Name` source value cannot be safely represented as a plain ASCII header value, clients MUST encode it using the Base64 sentinel format described in [Value Encoding](#value-encoding). | client | Mcp-Name を Base64 sentinel で符号化する Scenario が無い (HTTP-12 は Mcp-Param) |
| `basic/transports/streamable-http.mdx` | 2026-07-28 | These markers are case-sensitive and MUST appear exactly as shown (lowercase). | client | [要判断] sentinel の標識が小文字であることを個別に述べる Scenario が無い (HTTP-12 は「規格のとおり」) |
| `basic/transports/streamable-http.mdx` | 2026-07-28 | To avoid ambiguity, clients MUST also Base64-encode any plain-ASCII value that matches the sentinel pattern (i.e., starts with `=?base64?` and ends with `?=`). | client | [要判断] sentinel に似た平文値を Base64 にする規則を個別に述べる Scenario が無い (HTTP-12 は「規格のとおり」) |
| `basic/transports/streamable-http.mdx` | 2026-07-28 | Clients and servers MUST use case-insensitive comparisons for header names. | both | ヘッダ名の大文字小文字を区別しない規則の Scenario が無い |
| `basic/utilities/progress.mdx` | 2024-11-05〜2025-11-25 | Progress tokens can be chosen by the sender using any means, but MUST be unique across all active requests. | client | token を能動中の要求の間で一意に選ぶ規則の Scenario が無い |
| `basic/utilities/progress.mdx` | 2025-11-25 | For [task-augmented requests](./tasks), the `progressToken` provided in the original request MUST continue to be used for progress notifications throughout the task's lifetime, even after the `CreateTaskResult` has been returned. | server | task の寿命を通じて元の progressToken を使い続ける Scenario が無い (TASKS-22 は task の進捗がどのストリームに載るか) |
| `basic/utilities/progress.mdx` | 2025-11-25 | Progress notifications for tasks MUST use the same `progressToken` that was provided in the initial task-augmented request | server | task の進捗が元の progressToken を使う Scenario が無い (TASKS-22 は載るストリームのみ) |
| `basic/utilities/progress.mdx` | 2025-11-25 | Progress notifications for tasks MUST stop after the task reaches a terminal status (`completed`, `failed`, or `cancelled`) | server | task が終端状態になったら進捗を止める Scenario が無い (PROGRESS-3 は要求の応答後の話) |
| `client/elicitation.mdx` | 2025-11-25〜2026-07-28 | The `url` parameter MUST contain a valid URL. | server | [要判断] url が正しい URL であることの検査を述べる Scenario が無い |
| `client/elicitation.mdx` | 2025-11-25〜2026-07-28 | Servers MUST bind elicitation requests to the client and user identity | server | 検証で結びを外した (MCP-ELICIT-URL-4)。一部: 通知を発端の client にだけ送る点だけ。要求を利用者の同一性に結ぶのは述べない |
| `client/roots.mdx` | 2024-11-05〜2026-07-28 | This MUST be a `file://` URI in the current specification. | both | roots の uri が file:// である検査を述べる Scenario が無い |
| `client/sampling.mdx` | 2026-07-28 | Sampling messages MUST contain a `role` field of `"user"` or `"assistant"`; and a `content` field representing the message data. | both | [要判断] SAMPLING-TOOLS-9 は欠けた・object でない message の報告を述べるが、role が user か assistant であることの検査は述べない |
| `schema.mdx` | 2025-11-25 | The client MUST treat this ID as an opaque value. | client | elicitationId を不透明な値として扱う Scenario は無い。ELICIT-URL-4 は id で通知を照合するのみ |
| `schema.mdx` | 2026-07-28 | Certain key names are reserved by MCP for protocol-level metadata; implementations MUST NOT make assumptions about values at these keys. | both | 予約キーの値に仮定を置かないことを述べる Scenario は無い |
| `schema.mdx` | 2026-07-28 | Optional — if specified, MUST be a series of labels separated by dots (.), followed by a slash (/). | both | _meta キーの接頭辞の書式を検査する Scenario は無い。EXT-1 は拡張の識別子のみ |
| `schema.mdx` | 2026-07-28 | Labels MUST start with a letter and end with a letter or digit. | both | _meta キーの label の書式を検査する Scenario は無い。EXT-1 は拡張の識別子のみ |
| `schema.mdx` | 2026-07-28 | Unless empty, MUST start and end with an alphanumeric character ([a-z0-9A-Z]). | both | _meta キーの name の書式を検査する Scenario は無い |
| `server/prompts.mdx` | 2024-11-05〜2026-07-28 | The image data MUST be base64-encoded and include a valid MIME type. | server | image の base64 と MIME type を送る側が保つ・検査する Scenario が無い |
| `server/prompts.mdx` | 2024-11-05〜2026-07-28 | Resources can contain either text or binary (blob) data and MUST include: | server | prompt に埋め込む resource の必須項目を述べる Scenario が無い (RESOURCES-1 は resources/read の contents であり prompt の埋め込みではない) |
| `server/prompts.mdx` | 2024-11-05〜2026-07-28 | (項目) A valid resource URI | server | 埋め込み resource の uri を求める Scenario が無い (RESOURCES-1 は resources/read の contents) |
| `server/prompts.mdx` | 2024-11-05〜2026-07-28 | (項目) The appropriate MIME type | server | [要判断] CONTENT-FIELDS-2 は mimeType の無い埋め込み resource をそのまま書き戻すとしており、MIME type を求める Scenario ではない。SDK が緩く扱う方針かは Scenario から読めない |
| `server/prompts.mdx` | 2024-11-05〜2026-07-28 | (項目) Either text content or base64-encoded blob data | server | 埋め込み resource が text か blob のどちらかを持つことを求める Scenario が無い (RESOURCES-1 は resources/read の contents) |
| `server/resources.mdx` | 2024-11-05〜2026-07-28 | Binary data MUST be properly encoded | server | blob を base64 にすることを保つ・検査する Scenario が無い (CONTENT-FIELDS-1 は blob が文字列であることのみ) |
| `server/tools.mdx` | 2025-11-25〜2026-07-28 | MUST be a valid JSON Schema object (not `null`) | server | [要判断] 登録・一覧の時に inputSchema が JSON Schema の object (null でない) であることを検査する Scenario が無い (TOOLS-3 は inputSchema 無しを handler に任せる、SCHEMA-3 は検証器の側) |
| `server/utilities/caching.mdx` | 2026-07-28 | (項目) `server/discover` | server | [要判断] CACHE-1 は tools/list だけを述べ、server/discover の結果に cache hint を付けることは Scenario から読めない |
| `server/utilities/caching.mdx` | 2026-07-28 | (項目) `prompts/list` | server | [要判断] CACHE-1 は tools/list だけを述べ、この操作の結果に cache hint を付けることは Scenario から読めない |
| `server/utilities/caching.mdx` | 2026-07-28 | (項目) `resources/list` | server | [要判断] CACHE-1 は tools/list だけを述べ、この操作の結果に cache hint を付けることは Scenario から読めない |
| `server/utilities/caching.mdx` | 2026-07-28 | (項目) `resources/templates/list` | server | [要判断] CACHE-1 は tools/list だけを述べ、この操作の結果に cache hint を付けることは Scenario から読めない |
| `server/utilities/caching.mdx` | 2026-07-28 | (項目) `resources/read` | server | [要判断] CACHE-1 は tools/list だけを述べ、この操作の結果に cache hint を付けることは Scenario から読めない |
| `server/utilities/caching.mdx` | 2026-07-28 | Clients MUST NOT serve a cached response for a request whose method or parameters differ from the request that produced it. | client | [要判断] client 側のキャッシュを述べる Scenario が無い。SDK の client がキャッシュを持つか自体が Scenario から読めない |
| `server/utilities/caching.mdx` | 2026-07-28 | Results produced by retrying a request through the [multi round-trip requests](/specification/2026-07-28/basic/patterns/mrtr) mechanism&mdash;that is, requests carrying `inputResponses` or `requestState`&mdash;MUST NOT be cached, as they depend on inputs th… | client | [要判断] client 側のキャッシュを述べる Scenario が無い (inputResponses・requestState つきの結果を保存しない) |
| `server/utilities/caching.mdx` | 2026-07-28 | Servers MUST provide a `ttlMs` value that is `>= 0`. | server | ttlMs が 0 以上であることを保つ・検査する Scenario が無い (CACHE-1 は policy の値をそのまま載せる) |
| `server/utilities/caching.mdx` | 2026-07-28 | Implementations that do choose to poll MUST apply jitter and backoff. | client | polling するときの jitter と backoff を述べる Scenario が無い |
| `server/utilities/caching.mdx` | 2026-07-28 | \| `"private"` \| The response contains private data that is not meant to be shared between callers. Cached responses MAY be reused for the same authorization context. Caches MUST NOT be shared across authorization contexts (e.g. a different access token requ… | client | 認可の文脈をまたいでキャッシュを共有しない client の振る舞いを述べる Scenario が無い (CACHE-1 は server が private を付けることのみ) |
| `server/utilities/caching.mdx` | 2026-07-28 | Servers MUST apply the same `cacheScope` to all response pages for a given list request. | server | 全ページに同じ cacheScope を付けることを述べる Scenario が無い (CACHE-1 は tools/list の1回の結果のみ) |
| `server/utilities/caching.mdx` | 2026-07-28 | For example, if the first page of a `tools/list` response has `cacheScope: "private"`, all subsequent pages for that request MUST also be `"private"`. | server | 全ページに同じ cacheScope を付けることを述べる Scenario が無い |
| `server/utilities/completion.mdx` | 2024-11-05〜2026-07-28 | (項目) Implement appropriate rate limiting | both | completion の rate limit を述べる Scenario が無い |

## 規格の文に結ばれない仕様 ID (199 件)

上の「読み方の注意」のとおり、独自の仕様の候補であって、独自だと確かめたものではない。

| feature | 件数 | 仕様 ID |
|---|---:|---|
| `security.feature` | 44 / 56 | MCP-SEC-AUTH-5, MCP-SEC-HTTP-2, MCP-SEC-HTTP-3, MCP-SEC-HTTP-5, MCP-SEC-HTTP-6, MCP-SEC-HTTP-7, MCP-SEC-HTTP-8, MCP-SEC-SCHEMA-1, MCP-SEC-SCHEMA-2, MCP-SEC-SCHEMA-4, MCP-SEC-SCHEMA-6, MCP-SEC-SCHEMA-7, MCP-SEC-SCHEMA-8, MCP-SEC-SCHEMA-9, MCP-SEC-SCHEMA-10, MCP-SEC-SCHEMA-11, MCP-SEC-SCHEMA-12, MCP-SEC-SCHEMA-13, MCP-SEC-SCHEMA-14, MCP-SEC-SWEEP-3, MCP-SEC-SWEEP-5, MCP-SEC-SWEEP-6, MCP-SEC-TASKS-1, MCP-SEC-TASKS-3, MCP-SEC-TASKS-5, MCP-SEC-WIRE-1, MCP-SEC-WIRE-2, MCP-SEC-WIRE-3, MCP-SEC-WIRE-4, MCP-SEC-WIRE-5, MCP-SEC-WIRE-6, MCP-SEC-WIRE-7, MCP-SEC-WIRE-9, MCP-SEC-WIRE-10, MCP-SEC-WIRE-11, MCP-SEC-WIRE-12, MCP-SEC-WIRE-13, MCP-SEC-WIRE-14, MCP-SEC-WIRE-15, MCP-SEC-WIRE-16, MCP-SEC-WIRE-18, MCP-SEC-WIRE-19, MCP-SEC-WIRE-20, MCP-SEC-WIRE-21 |
| `content.feature` | 29 / 45 | MCP-AUDIO-1, MCP-AUDIO-2, MCP-AUDIO-4, MCP-CONTENT-FIELDS-1, MCP-CONTENT-FIELDS-3, MCP-CONTENT-FIELDS-4, MCP-CONTENT-FIELDS-5, MCP-CONTENT-FIELDS-6, MCP-CONTENT-FIELDS-8, MCP-ICONS-1, MCP-ICONS-2, MCP-ICONS-3, MCP-ICONS-5, MCP-IMPL-1, MCP-IMPL-2, MCP-IMPL-3, MCP-RESLINK-2, MCP-RESLINK-3, MCP-SCHEMA-4, MCP-SCHEMA-5, MCP-STRUCTOUT-1, MCP-STRUCTOUT-2, MCP-STRUCTOUT-4, MCP-STRUCTOUT-6, MCP-TITLE-1, MCP-TITLE-2, MCP-TITLE-4, MCP-TOOLANN-1, MCP-TOOLANN-2 |
| `streamable_http.feature` | 16 / 41 | MCP-HTTP-5, MCP-HTTP-19, MCP-HTTP-20, MCP-HTTP-22, MCP-HTTP-23, MCP-HTTP-27, MCP-HTTP-28, MCP-HTTP-30, MCP-HTTP-32, MCP-HTTP-33, MCP-HTTP-34, MCP-HTTP-35, MCP-HTTP-38, MCP-HTTP-39, MCP-HTTP-40, MCP-HTTP-41 |
| `http_sse.feature` | 12 / 18 | MCP-HTTPSSE-3, MCP-HTTPSSE-4, MCP-HTTPSSE-5, MCP-HTTPSSE-8, MCP-HTTPSSE-9, MCP-HTTPSSE-12, MCP-HTTPSSE-13, MCP-HTTPSSE-14, MCP-HTTPSSE-15, MCP-HTTPSSE-16, MCP-HTTPSSE-17, MCP-HTTPSSE-18 |
| `http_streams.feature` | 11 / 35 | MCP-HTTPGET-3, MCP-HTTPGET-7, MCP-HTTPGET-8, MCP-HTTPSTREAM-6, MCP-HTTPSTREAM-8, MCP-HTTPSTREAM-11, MCP-HTTPSTREAM-12, MCP-HTTPSTREAM-14, MCP-HTTPSTREAM-15, MCP-HTTPSTREAM-17, MCP-HTTPSTREAM-18 |
| `extensions.feature` | 10 / 18 | MCP-EXT-3, MCP-EXT-7, MCP-EXT-11, MCP-EXT-12, MCP-EXT-13, MCP-EXT-14, MCP-EXT-15, MCP-EXT-16, MCP-EXT-17, MCP-EXT-18 |
| `elicitation.feature` | 9 / 20 | MCP-ELICIT-2, MCP-ELICIT-6, MCP-ELICIT-8, MCP-ELICIT-9, MCP-ELICIT-DEFAULT-1, MCP-ELICIT-DEFAULT-2, MCP-ELICIT-ENUM-1, MCP-ELICIT-ENUM-2, MCP-ELICIT-ENUM-3 |
| `resources.feature` | 9 / 16 | MCP-LISTCHANGED-2, MCP-RESOURCES-2, MCP-RESOURCES-6, MCP-RESOURCES-7, MCP-RESOURCES-9, MCP-RESOURCES-10, MCP-RESOURCES-11, MCP-RESOURCES-12, MCP-RESOURCES-13 |
| `server_requests.feature` | 8 / 17 | MCP-CLIENTREQ-2, MCP-SERVERREQ-1, MCP-SERVERREQ-2, MCP-SERVERREQ-6, MCP-SERVERREQ-8, MCP-SERVERREQ-10, MCP-SERVERREQ-11, MCP-SERVERREQ-12 |
| `authorization.feature` | 7 / 42 | MCP-AUTH-7, MCP-AUTH-16, MCP-AUTH-28, MCP-AUTH-31, MCP-AUTH-33, MCP-AUTH-36, MCP-AUTH-41 |
| `subscriptions.feature` | 6 / 15 | MCP-SUBSCRIBE-5, MCP-SUBSCRIBE-7, MCP-SUBSCRIBE-8, MCP-SUBSCRIBE-11, MCP-SUBSCRIBE-12, MCP-SUBSCRIBE-13 |
| `mrtr.feature` | 5 / 18 | MCP-MRTR-8, MCP-MRTR-9, MCP-MRTR-12, MCP-MRTR-15, MCP-MRTR-16 |
| `tasks.feature` | 5 / 25 | MCP-TASKS-17, MCP-TASKS-19, MCP-TASKS-21, MCP-TASKS-23, MCP-TASKS-25 |
| `request_hooks.feature` | 4 / 4 | MCP-HOOKS-1, MCP-HOOKS-2, MCP-HOOKS-3, MCP-HOOKS-4 |
| `trace_context.feature` | 4 / 5 | MCP-TRACE-2, MCP-TRACE-3, MCP-TRACE-4, MCP-TRACE-5 |
| `version_negotiation.feature` | 4 / 10 | MCP-VERSION-1, MCP-VERSION-3, MCP-VERSION-4, MCP-VERSION-10 |
| `event_stream.feature` | 3 / 3 | MCP-SSE-1, MCP-SSE-2, MCP-SSE-3 |
| `lifecycle.feature` | 3 / 17 | MCP-LIFECYCLE-7, MCP-LIFECYCLE-13, MCP-LIFECYCLE-15 |
| `sampling_tools.feature` | 3 / 12 | MCP-SAMPLING-TOOLS-1, MCP-SAMPLING-TOOLS-8, MCP-SAMPLING-TOOLS-9 |
| `progress_cancellation.feature` | 2 / 12 | MCP-CANCEL-3, MCP-CANCEL-7 |
| `completion.feature` | 1 / 6 | MCP-COMPLETION-1 |
| `logging.feature` | 1 / 9 | MCP-LOGGING-8 |
| `pagination.feature` | 1 / 5 | MCP-PAGINATION-3 |
| `prompts.feature` | 1 / 5 | MCP-PROMPTS-2 |
| `tools.feature` | 1 / 6 | MCP-TOOLS-2 |


## 2026-10-13: Scenario の無かった 378 行に Scenario を足した

上の表で「SDK への求めだが、当たる Scenario が無い」(status `sdk`) とした 378 行 (173 文) を、1 文ずつ読み直した。規格の前後と SDK の実装を読み、Scenario と外部仕様テストを書いて流した結果:

| 行き先 | 行 |
|---|---:|
| Scenario に結んだ (`linked`)。足した Scenario は 87、うち既にあった Scenario に結んだものは 11 行 | 236 |
| 読み直すと SDK への求めではなかった (`application` 24、`not-normative` 13。理由は note) | 37 |
| **SDK がその文を守っていない** (status は `sdk` のまま。note に何が起きるか) | 103 |
| 外から見える振る舞いが無い (対応する方言を文書に書く、の 2 行) | 2 |

- 足した Scenario は `specs/` の 21 のファイルにある (仕様 ID は 469 から 556 に)。確かめる外部仕様テストは `tests/external/` の `test_*_g0[a-f].nim` (39 ファイル)。
- **開いたままの 105 行は、SDK を直すか、扱いを決めるまで閉じない。** Scenario と落ちるテストは書いてあるが、仕様にはまだ入れていない (27 の Scenario)。`spec_trace` はこの 105 行を「理由の無い行」として挙げ、1 で終わる。
- 結んだ 236 行の `checked` は `unverified` である: ワーカー (Claude Sonnet) 6 人が結び、リードは件数と、足したテストが通ること・入口の外を読まないことを機械で確かめた。1 行ずつの読み直しはしていない。
- 「規則」(どんな入力でも成り立つこと) と印の付いた Scenario が 20 ほどある。テストは代表値で確かめていて、性質のテスト (nim-propcheck) にはまだ上げていない。

## 2026-10-13: SDK が守っていなかった文を直した

上の節で開いたまま残した 105 行のうち、80 行 (22 の Scenario) を、SDK を直して閉じた。利用者の決定による。

- **値を確かめずに流していたもの**: ハンドラの結果 (画像・埋め込みリソース・`blob`・ツールの `inputSchema`・`ttlMs`)、プロンプトの引数、sampling の `includeContext` と `tool_result`、MRTR の入力要求のキー、roots の URI、呼び手が選んだ要求の ID、UTF-8 でない文字列。規格に反する値は相手に送らず、ハンドラの結果なら相手に内部エラー、呼び手の引数なら例外で返す。原因は stderr に書く。
- **相手に届いていたもの**: クライアントのハンドラの例外のトレースバック。
- **規格と逆だったもの**: 2026-07-28 のクライアントは、サーバーの要求に応答を書かない (以前は method not found と答えていた。`MCP-SERVERREQ-9` を直し、`MCP-SERVERREQ-15`・`-16` に分けた)。
- 2025-03-26 のバッチの読み方、ストリームが閉じたときの局所のエラーのコード、取り消しの理由と ping の失敗のログ。
- 文書への求め (対応する JSON Schema の方言) は README に書き、README がそれを書いていることを内部の門のテストで確かめる。

利用者から見える変更は README の「Changes that break code written for earlier commits」にある。

**開いたままの 25 行** (2026-10-13 の時点):

| 文 | 行 | 状態 |
|---|---:|---|
| 初期化の応答が来る前に、ping 以外を送らない | 4 | 利用者と方針を決めた。これから直す |
| セッションが 404 になったら、初期化し直す | 3 | 同上 |
| ping を定期的に送る、頻度を設定できる | 8 | 同上 |
| 取って代わられたストリームを閉じる前に `retry` を送る | 2 | 同上 |
| 進捗・タスク操作の流量制限 (補完の流量制限は Scenario があるが、SDK は仕組みを持たない) | 6 | 同上 |
| stdio のサーバーが落ちたら再起動し、購読を張り直す | 2 | 対応しない方針 (自動の再起動は、落ち続ける相手で資源を食い潰し、不正な入力で落ちたプロセスを同じ入力で立ち上げ直す)。表への記載はこれから |

このほか、ページをまたいで `cacheScope` が食い違わないこと (2026-07-28) は、行は `MCP-LIFECYCLE` の Scenario に結んであるが、SDK は確かめていない (サーバーは要求ごとに状態を持たない)。
