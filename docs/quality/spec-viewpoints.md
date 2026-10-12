# 仕様 ID ごとの観点の表 (本線の系列)

2026-10-13。本線のコミット `37b1e2faef5f` で、仕様 ID (`specs/*.feature` の `@spec:<ID>`、469 件) に結ばれた外部仕様テスト (E テスト) を、正常系・エッジケース・エラー・境界・回帰の 5 観点に分けた記録。
**読むだけの作業で、テストも仕様も書き換えていない。** 拡張と下書きの系列は対象にしていない。

- [spec-viewpoints.tsv](spec-viewpoints.tsv): 仕様 ID ごとに 1 行。観点ごとの本数、または本数が 0 の理由。
- [spec-viewpoints-tests.tsv](spec-viewpoints-tests.tsv): テストと仕様 ID の組ごとに 1 行 (1469 行)。付けた観点と注記。

E テストは、`specs/tests.map` の行のうち、[test-classification.tsv](test-classification.tsv) が I とも足場ともしていないもの。テスト 1443 本、仕様 ID との組 1469 行、E テストのある仕様 ID 421 件。

## 観点

1 本のテストに複数の観点が付く (その観点の検証が 1 つでもあれば付けた)。

| 観点 | 意味 |
|---|---|
| 正常系 `normal` | 正しい入力・正しい相手で、仕様どおりの結果になる |
| エッジケース `edge` | 正しいが珍しい状況で、数の境目ではないもの (任意の欄が無い、順序、重複、同時、途中で切れる、表記の違い、版による形の違い) |
| エラー `error` | 誤った入力、壊れたメッセージ、失敗する相手、許されない操作を、仕様どおりに拒否する・エラーにする・無視する |
| 境界 `boundary` | 仕様が決めている範囲・上限・下限・長さ・個数・時間の境目の値 (ちょうど上限、1 つ上、0、空、最大) |
| 回帰 `regression` | テストの名前か注釈が、過去の欠陥を固定するために書いたと言っているもの |

## 結果

| 観点 | 本数 (組) | 1 本以上ある仕様 ID | 該当なし | テストが無い | テストが無い (迷い) |
|---|---:|---:|---:|---:|---:|
| 正常系 | 675 | 291 | 113 | 6 | 11 |
| エッジケース | 439 | 235 | 110 | 17 | 59 |
| エラー | 738 | 286 | 125 | 3 | 7 |
| 境界 | 146 | 77 | 307 | 15 | 22 |
| 回帰 | 7 | 3 | 記録なし 418 | | |

ほかに、E テストが 1 本も結ばれていない仕様 ID が 48 件ある (TSV では全観点が `no-e`。一覧は [test-classification.md](test-classification.md))。

TSV の観点の欄の値:

- 数字: その観点の E テストの本数。
- `na` (該当なし): その Scenario が約束していることに、その観点が当てはまらない。理由は `<観点>_note` の欄。
- `gap`: 当てはまるのに E テストが無い。何を確かめるテストが無いかは `<観点>_note` の欄。
- `gap?`: 同じだが、判定した担当が迷いを付けたもの。Scenario が約束していない場合を想像で挙げたものが混ざっている (下の「確かめていない範囲」)。
- `no-record` (回帰だけ): 過去の欠陥を固定すると言っているテストが無い。この仕様に過去の欠陥があったかどうかは調べていないので、「該当なし」とも「テストが無い」とも書いていない。
- `no-e`: E テストが 1 本も無い。

## 確かめ方と、確かめていない範囲

- 1 段目 (テストごとの観点): ワーカー (Claude Sonnet) 5 人。全員が「担当のテストのファイルを全文読み、全行を本体を読んで決めた」と報告している。リードは 10 件を、テストの本体と並べて読んだ (明らかな誤りは無かった)。
- 2 段目 (本数が 0 の観点 795 か所の判定): ワーカー 3 人。**Scenario の Given / When / Then と、1 段目の注記だけで決めていて、feature の原文の前後やテストの本体はほとんど開いていない** (開いたのは 3 人で 30 件ほど)。リードは 26 件を Scenario と並べて読んだ (「該当なし」18 件は妥当だった)。
- **確かめていない範囲と、ぶれ**:
  - 1 段目の 1469 行は、抜き取り 10 件のほかはリードが読んでいない。
  - 「エッジケース」と「境界」の線引きは担当の読みによる。たとえば「版によって形が違う」をエッジケースに、「空の入力」「最後のページ」を境界に入れている。
  - 2 段目は担当によって厳しさが違う。「テストが無い」の割合は、担当ごとに 8%、17%、28%。
  - `gap?` は、Scenario が約束していない場合 (たとえば id が 0 や 2^53 を超える整数) を担当が想像して挙げたものを含む。仕様の穴というより、仕様に足すかどうかの問いである。
  - 「該当なし」の理由のうち「通る場合は別の仕様 ID が述べている」は、名指しした仕様 ID の中身を担当が確かめていないものがある。
  - 回帰は、名前と注釈に書いてあるものしか数えていない。過去の修正の履歴 (コミット、`docs/quality/` の記録) とは突き合わせていない。7 件のうち 5 件は、個々のテストの注釈ではなく suite 名 (`malformed keywords that were skipped or crashed`) を根拠にした。
  - 版ごとに展開されるテストは、対応表の 1 行を 1 本と数えている。

## 当てはまるのに E テストが無い観点 (迷いの無いもの、41 か所)

`gap?` の 99 か所は TSV にある。

| 仕様 ID | 観点 | Scenario | 無いテスト |
|---|---|---|---|
| MCP-AUTH-32 | エラー | The challenge says what is wrong and no more | reject された token に invalid_token と説明を、scope 不足に insufficient_scope を返すことを確かめるテストが無い (いまの 2 本は説明を付けない・scopes_supported を省く側の edge)。 |
| MCP-AUTH-12 | 正常系 | From 2025-06-18 the client finds the authorization server through the resource's metadata | challenge が resource_metadata を名指したときその URL を使う正常系を確かめるテストが無い。 |
| MCP-AUTH-12 | エッジケース | From 2025-06-18 the client finds the authorization server through the resource's metadata | host の大文字小文字や末尾の slash だけが違う resource を受理することを確かめるテストが無い。 |
| MCP-AUTH-14 | 正常系 | The client finds and checks the authorization server metadata | path 付き・無しの issuer から RFC 8414 の URL を組み立てる正常系 (suffix の位置、末尾 slash 除去、候補 2 つ) を確かめるテストが無い。 |
| MCP-AUTH-14 | エッジケース | The client finds and checks the authorization server metadata | 末尾 slash を持つ issuer や path の無い issuer が候補 2 つになる珍しい形を確かめるテストが無い。 |
| MCP-AUTH-16 | 境界 | The client does not fetch metadata from where it should not | authorization server metadata の大きさの上限を約束しているのに、上限ちょうどと 1 つ上のテストが無い。 |
| MCP-AUTH-18 | 境界 | The authorization code flow uses PKCE S256, state and a redirect URI that is safe | code_verifier が 43 文字の unreserved 文字であると言っているのに、長さ 43 と使える文字の境目を確かめるテストが無い。 |
| MCP-AUTH-23 | 正常系 | A 403 insufficient_scope is answered by a step-up from 2025-11-25 | 403 insufficient_scope に対して challenge された scope を求め直し要求が成功する正常系を確かめるテストが無い。 |
| MCP-AUTH-23 | エッジケース | A 403 insufficient_scope is answered by a step-up from 2025-11-25 | 2026-07-28 で以前の scope と challenge の scope の和集合を求める版による違いを確かめるテストが無い。 |
| MCP-COMPLETION-5 | エッジケース | A client asks for completions | context を持たない版では要求に context を載せないことを確かめるテストが無い。 |
| MCP-SCHEMA-6 | 境界 | The remaining keywords follow the dialect | minContains と maxContains の個数の境目 (ちょうど・1 つ上・0) を確かめるテストが無い (いまは contains の無い場合だけ)。 |
| MCP-ICONS-6 | 正常系 | An icon is fetched the way the security considerations ask | 許された型の icon を資格情報なし・同一 origin で取得できる正常系を確かめるテストが無い。 |
| MCP-ICONS-6 | エッジケース | An icon is fetched the way the security considerations ask | 同一 origin 内の redirect を辿ることと、宣言された MIME と実際の bytes が食い違う場合に bytes で判定することを確かめるテストが無い。 |
| MCP-ICONS-6 | 境界 | An icon is fetched the way the security considerations ask | 大きさを制限すると言っているのに、上限ちょうどと 1 つ上の icon を確かめるテストが無い。 |
| MCP-ELICIT-DEFAULT-2 | 境界 | A default that does not fit its property is refused | default が下限・上限・長さの範囲外なら拒否と言っているのに、境目ちょうどの受理と 1 つ外の拒否を確かめるテストが無い。 |
| MCP-HTTPSTREAM-17 | 境界 | A transport is made only for a version the build speaks | 話せる版の範囲の下限・上限ちょうど (作れる) と、その 1 つ外 (ValueError) の組を確かめるテストが無い。 |
| MCP-SEC-SCHEMA-5 | 境界 | Validation stops at its depth, work and regular expression limits instead of exhausting the process | 深さ・作業量・正規表現の予算という上限を約束しているのに、上限ちょうどは通り 1 つ上で SchemaLimitError になることを確かめるテストが無い。 |
| MCP-SEC-SCHEMA-8 | 境界 | A malformed keyword is reported, never skipped, and no schema makes the validator raise something else | $ref の添字が範囲の最後の有効値では通り 1 つ先で InvalidSchemaError になること、multipleOf の商が double に収まる最大と超える値の境目を確かめるテストが無い。 |
| MCP-SEC-HTTP-7 | 境界 | What a peer chose is made harmless before it is written to a diagnostic | 1 メッセージの上限の長さちょうど (切らない) と 1 バイト超 (切って省いた数を示す) を確かめるテストが無い。 |
| MCP-SEC-WIRE-6 | 正常系 | Loopback is reachable only for a server the user chose | 利用者自身の server が loopback にあるときは loopback の URL を許す (ローカル開発) という And を確かめるテストが無い。 |
| MCP-SEC-WIRE-6 | エッジケース | Loopback is reachable only for a server the user chose | loopback の綴り (localhost、127.0.0.2、[::1]、IPv4 射影の IPv6) の違いでも拒否・許可が変わらないことを確かめるテストが無い。 |
| MCP-SEC-WIRE-8 | エッジケース | An icon is fetched only from an address its server's spelling allows | 名前が複数の住所に解決され一部だけ private な場合や、IPv6 の loopback・IPv4 射影の住所でも拒否されることを確かめるテストが無い。 |
| MCP-SEC-WIRE-8 | 境界 | An icon is fetched only from an address its server's spelling allows | private の範囲の境目 (172.15 と 172.16、172.31 と 172.32、169.254 の端) が拒否・許可に分かれることを確かめるテストが無い。 |
| MCP-SEC-TASKS-4 | エッジケース | One owner cannot make the store keep without limit | 多数の所有者が同時に上限へ達する場合と、task が終わったか期限切れかで再び作れるようになる違いを確かめる E テストが無い。 |
| MCP-SEC-WIRE-9 | 正常系 | Text of a peer is decoded as base64 only when it has the shape of base64 | base64 の形をした cursor や data URI の本文が拒否されず decoder へ渡ることを確かめる E テストが無い。 |
| MCP-SEC-WIRE-9 | 境界 | Text of a peer is decoded as base64 only when it has the shape of base64 | 末尾の = が 0・1・2 個の境目、= が末尾の 1 つ手前に来る場合、空文字列を確かめるテストが無い。 |
| MCP-SEC-SCHEMA-9 | 境界 | A pattern may hold any character | U+007F と U+0080、および最大の U+10FFFF という文字の範囲の境目の文字がリテラルとして通ることを確かめるテストが無い。 |
| MCP-CLIENTREQ-1 | エッジケース | A client answers a sampling request through its handler | temperature や modelPreferences などの任意の欄が無い要求を handler が受け取れることを確かめるテストが無い。 |
| MCP-HTTP-1 | 境界 | The endpoint accepts well-formed JSON-RPC POSTs only | body が上限ちょうどなら通り 1 バイト超えると 413 になることを確かめるテストが無い。 |
| MCP-HTTP-2 | エッジケース | Requests from a foreign Origin are refused | Origin の欄が無い要求、"null" の Origin、[::1] や localhost:ポート という loopback の綴りの違いを確かめるテストが無い。 |
| MCP-HTTP-3 | エラー | Answers carry the security headers and notifications get 202 | 404・405・413 などの拒否の答えにも security header が付くことを確かめるテストが無い。 |
| MCP-HTTP-7 | エッジケース | A client mirrors the body into headers | Mcp-Name を持たない method (tools/list など) では Mcp-Name が付かないことを確かめるテストが無い (「where the method has one」)。 |
| MCP-HTTP-15 | エッジケース | GET and DELETE exist only where a spoken version has them | server が話す版の組 (旧版だけ、2026-07-28 だけ、両方) によって 400 と 405 と Allow が変わることを、組ごとに確かめるテストが無い。 |
| MCP-HTTP-21 | 境界 | A server that speaks 2026-07-28 alone refuses batches and accepts notifications | 空の batch ([]) と 1 件だけの batch が、2026-07-28 だけの server で 400 invalid request になることを確かめるテストが無い。 |
| MCP-HTTP-38 | エッジケース | Authorization is retried at most three times per request | hook が「改善しなかった」と答えた場合は再試行せずに失敗することを確かめるテストが無い。 |
| MCP-HTTP-30 | エラー | A POST stream is resumed from the last event id, however often it breaks while the server is working | 再試行が尽きたとき (id が進まない切断が続くとき) に失敗として報告されることを確かめるテストが無い。 |
| MCP-SUBSCRIBE-7 | エッジケース | A malformed filter is invalid params | filter が無い・型が違う・空のオブジェクトなど、「usable でない」filter の種類ごとに invalid params になることを確かめるテストが無い。 |
| MCP-SUBSCRIBE-13 | エッジケース | An extension takes part in the acknowledgment through a listen filter hook | hook が 1 つも無いとき、または hook が filter を空にしたり何も足さなかったりするとき、確認応答に何が載るかを確かめるテストが無い。 |
| MCP-TASKS-20 | エッジケース | A tool elicits input inside a task | ctx.elicitUrl を使う場合 (Scenario が ctx.elicit と並べて挙げている) の input_required と related-task _meta を確かめるテストが無い。 |
| MCP-TOOLS-5 | エッジケース | An inputSchema that cannot be checked passes nothing as valid | dialect を名指す場合と、未対応の keyword を使う場合 (Given の 2 つ) を、それぞれ internal error・handler 不実行で確かめるテストが無い。 |
| MCP-VERSION-10 | 境界 | A build whose version settings are not a range of released versions does not compile | oldest と default が同じ版 (版が 1 つだけの build) は通り、oldest が default より 1 つ新しいと止まる境目を確かめるテストが無い。 |

