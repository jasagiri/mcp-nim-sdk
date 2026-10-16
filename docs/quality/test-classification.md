# テストの分類: E / I / 足場 (本線の系列)

2026-10-13、コミット `f508412bc5c1 (vyvozmqp)` の `tests/test_*.nim` 88 ファイル、2080 件を、ADR-KURA-0008 の基準で 1 件ずつ分けた記録。
**この記録は一覧までで、テストの削除も書き換えもしていない。** 系列ごとにテストと仕様の数が違うので、表は系列 (本線、拡張、下書き) ごとに作り直す。

| 分類 | 件数 | 意味 |
|---|---:|---|
| E (外部仕様テスト) | 1681 | 公開の API と、通信の上で見えるものだけで確かめている |
| I (内部実装テスト) | 84 | 公開でないものを使うが、外から確かめない理由を書ける。うち 32 件は文書・台帳の整合を確かめる門 |
| 足場 (S) | 315 | どちらでもない。うち 305 件は呼び口を公開側へ移せば E になる、10 件は消してよい |

仕様 ID 469 件のうち、**E テストが 1 本も結ばれていない ID は 48 件** (うち 45 件は、結ばれたテストの呼び口を移せば E になる)。一覧は末尾。
`nimble specCoverage` の表 (g1-spec-coverage.md。2026-10-13 から追跡していない) の「469/469」は「対応表に行がある」の数で、E テストがあることまでは言っていない。この 48 件がその差である。

1 件ごとの行 (E でないテスト全部と、印の付いた E のテスト) は [test-classification.tsv](test-classification.tsv) にある。

## 分け方 (この SDK での「外」)

基準はリードが決めた。公開の範囲 (下の 1) は、E の数と上の 48 件を最も大きく動かす決定である。2026-10-13 に、利用者が「export で届くものを公開として進める」と決めた (進捗管理のセッション経由の連絡)。

1. **公開の範囲**: README が言う入口 (`import mcp`、`import auth/resource_server`、`import auth/client`) から届くもの。入口のモジュールが `*` で定義するものと、`export` で再公開するモジュールのもの。README に個別の説明があるかは問わない。README が利用者に代入させる公開フィールドの型 (`HttpClientAuth`、`HttpServerAuth` など) と、README・公開モジュールの doc が import を案内するもの (`newSseLegacyTransport`、`newAutoHttpTransport`、`server/request_state`、`RegexLimits`) は公開。doc コメントが「テスト用」「内部用」と言うもの (`heldWaiters`、`IconFetchOptions.get` など) は公開でない。
   - 入口から届かず、公開でないと判定したモジュール: `auth/oauth/*` (`auth/client` が再公開する `errors`・`tokens`・`FetchPolicy` を除く)、`transport/http_wire`、`transport/address_policy`、`transport/guarded_wire`、`transport/first_of`、`transport/sse_stream`、`protocol/param_headers`、`protocol/diagnostic`、`protocol/base64_shape`、`protocol/hmac`、`protocol/features`、`jsonschema/json_schema_regex` (`compileRegex`・`isMatch`)、`server/tools`。
2. **E**: 公開のもの (1) と、通信の上で見えるもの (メッセージ、HTTP の状態・ヘッダ・本文、stderr の行) だけで確かめている。
3. **E でない**: 公開でないものを 1 か所でも使って確かめている (補助の `check` 1 行でも)。外から確かめない理由が具体的に書ければ I、書けなければ足場。期待値が RFC や仕様から来ているかは、I と足場の区別に使っていない。
4. **文言**: エラー文と stderr の行は外から見える出力なので、文言を固定していること自体では E から外さない。Scenario の約束を超えて固定しているテストは E のまま印 `wording` (65 件)。
5. **機能表**: `protocol/features` を「どの版で何を期待するか」を選ぶためだけに使うテストは E のまま印 `features` (278 件)。機能表は README と `docs/versions.md` の版の表の元でもある。期待値の版ごとの選び方が SDK 自身の表に依っている、という弱みは残る。
6. `server/tools` の作成用の手続きをハンドラの戻り値の組み立てにだけ使うテストは E のまま印 `builder` (4 件)。
7. 文書・台帳の整合を確かめるテスト (`test_spec_coverage`、`test_docs_version`、`test_features`) は I、印 `gate`。

印: `unmapped` = E だが `specs/tests.map` に行が無い (237 件)。`movable` = 呼び口を公開側へ移せば E になる。`secondary` = 主な検証は外で、補助の検証だけが公開でないものを読む。

## 確かめたこと、確かめていないこと

- 分類はワーカー (Claude Sonnet) 5 人がテストと src の `export` 行・doc コメントを読んで付け、リードが基準を統一して当て直させた。
- リードが機械的に確かめたこと: ファイルごとの件数がテストの `test "…"` の数と一致する (88 ファイル、不一致 0)。1 件ごとの行の仕様 ID が `specs/tests.map` と一致する (958 行中、E の 1 行を除き一致)。E とされたテストの本文に公開でないモジュールのシンボルが出ていないかを名前で探し、当たった 38 件は再公開されたシンボルか、同じファイルの後ろの suite を拾った誤検出だった。
- **確かめていないこと**: 1 件ごとの分類をリードが全部読み直してはいない (抜き取りだけ)。「呼び口を移せば E になる」は、公開の API の形を読んでの見立てで、実際に書いて通してはいない。この作業ではコンパイルもテストの実行もしていない。

## 分類とは別に見つかったこと

- `server/tools` (`createToolInfo`、`createToolResult` など) は `import mcp` から届かず、`src/` の中からも呼ばれていない。`tests/` はこれを import している。公開するのか、消すのかが決まっていない。`MCP-CONTENT-FIELDS-8` はこの手続きだけを確かめている。
- E だが `specs/tests.map` に行が無いテストが 237 件ある (うち 47 件は `test_modern_protocol.nim`)。仕様 ID に結ぶか、仕様に無い振る舞いを固定しているのかは見ていない。
- `tests/test_server_errors.nim` の「name が欠けた tools/call」が `MCP-RESOURCES-14` に結ばれている (tools の話に見える。未確認)。


## ファイルごとの分類

| ファイル | テスト | E | I | 足場 | 分類 | 何を通して確かめているか | I: 外から確かめない理由 | 足場の扱い |
|---|---:|---:|---:|---:|---|---|---|---|
| `test_audio_content.nim` | 7 | 7 | 0 | 0 | E | 全件 E (うち 4 件は版の選別に protocol/features を使うだけなので印 features)。多数は E (loopback/SessionedTransport に流れる JSON-RPC と公開のクライアント API だけ。)。E でない件は版選別の protocol/features・server/tools・auth/oauth の補助・transport/auth_hook など非公開シンボルを使う (not-e.tsv 参照)。 |  |  |
| `test_auth_client_flow.nim` | 71 | 54 | 0 | 17 | mixed | 多数は E (実 StreamableHttpTransport と偽の認可・リソースサーバ間の HTTP と、公開の OAuthClient/handleChallenge の結果。)。E でない件は版選別の protocol/features・server/tools・auth/oauth の補助・transport/auth_hook など非公開シンボルを使う (not-e.tsv 参照)。 |  | 足場 17 件は呼び口を移せば E |
| `test_auth_failure.nim` | 6 | 6 | 0 | 0 | E | 多数は E (偽サーバへの HTTP と公開の McpAuthorizationError。)。E でない件は版選別の protocol/features・server/tools・auth/oauth の補助・transport/auth_hook など非公開シンボルを使う (not-e.tsv 参照)。 |  |  |
| `test_auth_http_methods.nim` | 3 | 3 | 0 | 0 | E | 多数は E (記録用 HTTP サーバに届いた Authorization ヘッダ。)。E でない件は版選別の protocol/features・server/tools・auth/oauth の補助・transport/auth_hook など非公開シンボルを使う (not-e.tsv 参照)。 |  |  |
| `test_auth_oauth_basics.nim` | 79 | 0 | 2 | 77 | mixed | auth/oauth/* (pkce・challenge・urls・metadata・discovery・fetch・authcode・registration・jsonfield) を直接呼ぶ。mcp・auth/client・auth/resource_server の export 行に無い (auth/client は errors・tokens・FetchPolicy・defaultFetchPolicy のみ)。I は公開の口が届かない 2 件 (PKCE 固定ベクトル、304)、他は公開の口から確かめられるので S (movable)。 | PKCE の code_verifier は常にクライアントが選ぶ乱数なので、RFC 7636 付録 B の固定 verifier と固定 challenge の組を、公開の認可フローに与える口が外から届かない。pkce は mcp・auth/client のどちらからも export されない。 / 公開の OAuthClient は If-None-Match を付けた条件付き要求を送らないので、304 が返る状況を公開の口から作れない。fetch.httpExchange は非公開。 | 足場 77 件は呼び口を移せば E |
| `test_auth_resource_server.nim` | 23 | 17 | 0 | 6 | mixed | 多数は E (実 HttpServerTransport への素の HTTP の応答と公開の newResourceServerAuth。)。E でない件は版選別の protocol/features・server/tools・auth/oauth の補助・transport/auth_hook など非公開シンボルを使う (not-e.tsv 参照)。 |  | 足場 6 件は呼び口を移せば E |
| `test_auth_sha256.nim` | 6 | 0 | 6 | 0 | I | 公開の認可フローは verifier を 43 文字の乱数に固定するため既知ベクトルを与えられない。内部 sha256 を直接確かめる。 | PKCE の code_verifier は常にクライアントが選ぶ 43 文字なので、FIPS 180-4 / RFC 6234 の境界長 (55/56/64 バイト)・100 万文字のベクトルを公開の認可フローに与える口が外から届かない。sha256 は auth/oauth の内部部品で export されない。 |  |
| `test_base64_shape.nim` | 6 | 0 | 1 | 5 | mixed | 非公開の述語を直接呼ぶ。5 件は公開の cursor 経路から確かめられる S、20 万件の性質テスト 1 件は I。 | 20 万件のランダム入力で std/base64.decode の性質を確かめる。cursor を受ける公開経路 (server/pagination.nim:28、modern.nim:234、client/icons.nim:106) へ同量を流すと時間がかかりすぎる。base64_shape は非公開。 | 足場 5 件は呼び口を移せば E |
| `test_client_elicitation.nim` | 21 | 21 | 0 | 0 | E | loopback ピアの JSON-RPC と公開の setElicitationHandler など。 |  |  |
| `test_client_field_types.nim` | 6 | 6 | 0 | 0 | E | loopback ピアの不正応答に対する公開 API の McpProtocolError と、client/content (tools が export) の公開ヘルパ。 |  |  |
| `test_client_operations.nim` | 42 | 42 | 0 | 0 | E | loopback ピアの JSON-RPC と公開のクライアント操作。 |  |  |
| `test_client_requests.nim` | 42 | 41 | 1 | 0 | mixed | 多数は E (loopback ピアの JSON-RPC と公開の sendRequest/startRequest/callMethod、公開フィールド pendingRequests・lastTransportError。)。E でない件は版選別の protocol/features・server/tools・auth/oauth の補助・transport/auth_hook など非公開シンボルを使う (not-e.tsv 参照)。 | トークンが要求ごとに閉包を溜め込まないこと (リーク) は、トークンの内側を読む heldWaiters (doc: for tests) でしか見えない。テスト自身のコメントも I と書いている。 |  |
| `test_client_sampling_tools.nim` | 9 | 9 | 0 | 0 | E | loopback ピアの JSON-RPC と公開の setSamplingHandler。 |  |  |
| `test_client_server_requests.nim` | 25 | 25 | 0 | 0 | E | 多数は E (loopback ピアの応答・通知と公開のハンドラ API。)。E でない件は版選別の protocol/features・server/tools・auth/oauth の補助・transport/auth_hook など非公開シンボルを使う (not-e.tsv 参照)。 |  |  |
| `test_docs_version.nim` | 10 | 0 | 10 | 0 | mixed | gen_docs 道具の生成物・台帳の整合ゲート (I/gate) 6 件と、テンプレート構文を固定する S 4 件。 | SDK の振る舞いではなく、リポジトリの README・docs と機能表 (features / implementation_status) の整合を確かめる門。 / [リードが変更] SDK の振る舞いではなく、文書を生成する道具 (tools/gen_docs) の入出力を確かめる門。消すと README と docs の生成が確かめられなくなる |  |
| `test_elicitation_payload.nim` | 69 | 69 | 0 | 0 | E | 多数は E (server/elicit・client/elicitation が export する protocol/elicitation の純粋関数。)。E でない件は版選別の protocol/features・server/tools・auth/oauth の補助・transport/auth_hook など非公開シンボルを使う (not-e.tsv 参照)。 |  |  |
| `test_era_matrix.nim` | 34 | 34 | 0 | 0 | E | loopback に流れる JSON-RPC と公開の connect/negotiatedVersion/pendingRequests。 |  |  |
| `test_event_stream.nim` | 24 | 24 | 0 | 0 | E | mcp が export する transport/event_stream の公開手続き。 |  |  |
| `test_extensions.nim` | 40 | 40 | 0 | 0 | E | 多数は E (SessionedTransport/loopback の JSON-RPC と公開の拡張 API (server/extensions・client/extensions が protocol/extensions を export)。)。E でない件は版選別の protocol/features・server/tools・auth/oauth の補助・transport/auth_hook など非公開シンボルを使う (not-e.tsv 参照)。 |  |  |
| `test_features.nim` | 12 | 0 | 12 | 0 | I | 全件が機能表と上流の変更履歴の整合を確かめる門 (R5)。SDK の振る舞いは見ていない。 | SDK の振る舞いではなく、リポジトリの (機能表 src/protocol/features.nim と上流の変更履歴・仕様ページ名) の整合を確かめる門。protocol/features は入口から届かない。 |  |
| `test_first_of.nim` | 10 | 0 | 4 | 6 | mixed | transport/first_of は入口から届かない内部部品。6 件は公開の口 (McpCancelToken を共有した要求など) から確かめられる S、4 件は『何も起きない』ことの観測不能・受信ループの競合で I。 | 完了した待ちのあとで残りの future が失敗しても『何も起きない』ことは、通信にも公開の戻り値にも現れず、外から観測できない。 / 誰も待っていない間に future が終わる競合 (受信ループが別の仕事をしている間) は、外からは非決定的にしか作れない。 / 鳴ったベルを聞いたあとの次の待ちが再び待つ、という内部ループの待ち合わせの順序は、外から決定的に再現できない。 ほか 1 通り | 足場 6 件は呼び口を移せば E |
| `test_fuzz_regressions.nim` | 3 | 0 | 3 | 0 | I | 入口から届かない読み手を含め、任意のバイト列を各読み手へ直接流す。外から全ての読み手へ送る口が無いので I。最後の 1 件はコーパスと Entrances の名前の整合の門。 | 任意のバイト列を読む各読み手 (入口から届かない transport/address_policy・auth/oauth/urls・foundation/nim-bearer-challenge の `parseChallenges` (2026-10-15 に auth/oauth/challenge から移した)・protocol/diagnostic を含む) を、トランスポート越しに 1 件ずつ外から叩く口が無い。 / SDK の振る舞いではなく、リポジトリの (tests/fuzz/corpus の各ディレクトリと Entrances の名前) の整合を確かめる門。 |  |
| `test_http_client_streams.nim` | 70 | 70 | 0 | 0 | E | 生のソケットで書いたサーバに対し公開の StreamableHttpTransport を動かし、ワイヤ上のメッセージ・ヘッダ・接続の閉じ方を見る。全件 E。stderr の文字列断片を固定する 6 件に wording。 |  |  |
| `test_http_documents.nim` | 8 | 8 | 0 | 0 | E | HttpServerTransport.documents に置いた文書を実際の HTTP クライアントで叩き、状態・ヘッダ・本文だけを見る。全件 E (認可フックを差し込む 1 件は HttpServerAuth を使う)。 |  |  |
| `test_http_error_propagation.nim` | 4 | 4 | 0 | 0 | E | モックの HTTP サーバに対する公開のトランスポートの sendRequest/sendNotification が McpTransportError を上げるかだけを見る。全件 E (tests.map に行なし)。 |  |  |
| `test_http_sse_legacy.nim` | 55 | 55 | 0 | 0 | E | 平文の HTTP クライアントや手書きのサーバ越しに、公開の HttpServerTransport と README が入口として挙げる newSseLegacyTransport/newAutoHttpTransport を動かす。全件 E。stderr の断片を固定する 1 件に wording。 |  |  |
| `test_http_streams.nim` | 86 | 77 | 4 | 5 | mixed | 平文の HTTP クライアント越しに HttpServerTransport のワイヤ上の振る舞いを見る 77 件は E。末尾の内部モジュール sse_stream を直接叩く 9 件は E でない (外から確かめられない 4 件が I、公開の口から確かめられる 5 件が S)。 | 終了後の push は finish と並行する sendNotification の競合でしか起きず、外からは非決定的にしか作れない。 / keep-alive の既定は 15 秒 (DefaultKeepAliveMs) で HttpServerTransport から変えられず、外から確かめると 1 件 15 秒以上かかる。 / keep-alive の既定は 15 秒 (DefaultKeepAliveMs) で HttpServerTransport から変えられず、外から確かめると 2 周期で 30 秒以上かかる。 ほか 1 通り | 足場 5 件は呼び口を移せば E |
| `test_http_unresponsive.nim` | 2 | 2 | 0 | 0 | E | 何も返さない生のソケットに対し、公開の McpClient.connect/sendRequest が McpTimeoutError で終わるかを見る。 |  |  |
| `test_http_wire_internals.nim` | 2 | 0 | 2 | 0 | I | transport/http_wire を include して非公開の procs を呼ぶ。既定ポートが bind できず、閉じ済み応答の読み始めを競合なしに作れないので I。 | 既定ポート (80) は試験機で bind できず、ポート無しの URL の Host 行を通信の上で観測できない。include した非公開の requestText を直接呼ぶ。 / 閉じ済みの応答の読み始めを、ソケット越しでは競合なしに作れない。include した非公開の WireResponse/receive を直接呼ぶ。 |  |
| `test_icon_fetch.nim` | 19 | 5 | 10 | 4 | mixed | icon の取得 10 件は試験用の差し替え口 IconFetchOptions.get を通すので I (TLS サーバが無い)。data URI で補助がこの口を常に設定する 4 件は S、sniffIcon・origin 無しなど 5 件は E。 | https の icon を取るには TLS サーバが要り試験機に無い。試験用と doc に書かれた差し替え口 IconFetchOptions.get (と非公開の http_wire.request) でアドレスだけ http のローカルサーバに書き換えて確かめる。 | 足場 4 件は呼び口を移せば E |
| `test_icons.nim` | 14 | 13 | 0 | 1 | mixed | loopback/harness 越しの JSON と公開の toJson/parseIcons/safeIcons/listAll* を見る 13 件は E (うち 3 件は期待する版の選択に機能表を使うので features)。入口から届かない createToolInfo を使う 1 件は S。 |  | 足場 1 件は呼び口を移せば E |
| `test_implementation_info.nim` | 11 | 11 | 0 | 0 | E | loopback に流れる initialize/discover の JSON と公開のアクセサを見る。全 11 件が E (うち 2 件は期待する版の選択に機能表を使うので features)。 |  |  |
| `test_json_schema.nim` | 82 | 59 | 0 | 23 | mixed | 公開の validate/dialectOf/describe を見る 59 件は E (文面固定の 3 件に wording)。入口から届かない compileRegex/isMatch を直接呼ぶ 23 件は、validate の pattern から確かめられる S。 |  | 足場 23 件は呼び口を移せば E |
| `test_legacy_handshake.nim` | 25 | 25 | 0 | 0 | E | loopback に流れる initialize/initialized/ping と、公開の server/client の状態アクセサ、McpTasksCapability.toJson だけを見る。全件 E。 |  |  |
| `test_modern_protocol.nim` | 67 | 67 | 0 | 0 | E | mcp が export する protocol/modern の純関数を公開 API として呼び、戻り値だけを見る。全件 E (tests.map に行が無い 47 件は unmapped、全文一致の 2 件は wording)。 |  |  |
| `test_mrtr.nim` | 46 | 46 | 0 | 0 | E | server_harness のトランスポート上の JSON-RPC、client_peer の偽サーバーに流れるメッセージと公開の例外型、公開の protocol/mrtr・server/request_state (server/mrtr の doc が import を案内) だけを見る E。3 件が理由文字列・stderr の文言を固定 (wording)。 |  |  |
| `test_param_headers.nim` | 42 | 0 | 0 | 42 | S | protocol/param_headers (入口から届かない) を直接呼ぶ。同じ規則は tools/list と HTTP の POST・クライアント transport から確かめられるので S。ParamBinding の構造や理由文を比べる 6 件は movable ではない。 |  | 足場 36 件は呼び口を移せば E、足場 6 件は消してよい |
| `test_param_headers_http.nim` | 34 | 34 | 0 | 0 | E | 実ソケットの公開 transport (http_server・http・client) とスクリプトの偽サーバーに届くヘッダ・要求回数だけを見る E。2 件が stderr の文言を固定している (wording)。 |  |  |
| `test_request_hooks.nim` | 22 | 22 | 0 | 0 | E | 公開の addRequestInterceptor・addResponseFilter・onListScope・addToolListTransform・addListenFilterHook・notifyListChanged・subscriptionCount とハーネスのメッセージだけを見る E。10 件は tests.map に行が無い。 |  |  |
| `test_resource_links.nim` | 10 | 9 | 0 | 1 | mixed | ハーネスのメッセージと client_peer 越しの公開クライアント API を見る E。1 件だけ非公開の server/tools のビルダーの戻りを比べる S。 |  | 足場 1 件は消してよい |
| `test_sampling_tools_payload.nim` | 46 | 46 | 0 | 0 | E | server/server が export する protocol/sampling_tools の公開の純関数の戻りだけを見る E (1 件が問題文の語句を固定、1 件が tests.map に行無し)。 |  |  |
| `test_security_address.nim` | 39 | 1 | 0 | 38 | mixed | address_policy・guarded_wire・auth/oauth/{urls,fetch} (入口から届かない) を直接呼ぶ。拒否・許可は公開の handleChallenge・fetchIcon から確かめられるので S movable。E は公開の OAuth クライアント経由の 1 件。 |  | 足場 38 件は呼び口を移せば E |
| `test_security_auth.nim` | 4 | 4 | 0 | 0 | E | 公開の auth/client と実トランスポートを、偽の認可サーバー・リソースサーバーのソケット越しに見る E (宣言 4 件、3 件はバージョンごとに展開)。 |  |  |
| `test_security_auth_tokens.nim` | 18 | 4 | 0 | 14 | mixed | E は auth/client が export する tokens の公開関数・型。残り 14 件は入口から届かない authcode.parseTokenResponse を直接呼ぶ S movable (公開の handleChallenge と TokenStore から確かめられる)。 |  | 足場 14 件は呼び口を移せば E |
| `test_security_diagnostic.nim` | 13 | 3 | 0 | 10 | mixed | E の 3 件は loopback に注入したメッセージに対するサーバーの stderr。S の 10 件は非公開の protocol/diagnostic.peerText (9 件) と非公開定数 DefaultPeerTextLength (1 件) を使う movable。 |  | 足場 10 件は呼び口を移せば E |
| `test_security_diagnostic_auth.nim` | 1 | 0 | 0 | 1 | S | auth/oauth/fetch.httpExchange (入口から届かない) を直接呼ぶ S movable。 |  | 足場 1 件は呼び口を移せば E |
| `test_security_diagnostic_client.nim` | 10 | 10 | 0 | 0 | E | 公開クライアントと loopback/client_peer のメッセージ、stderr の行だけを見る E。7 件は Scenario が無く stderr の文言を固定 (wording, unmapped)。 |  |  |
| `test_security_expiry.nim` | 2 | 2 | 0 | 0 | E | 公開の TaskStore (protocol/tasks を server/tasks・client/tasks が export) の onExpire とストアの操作だけを見る E。 |  |  |
| `test_security_http.nim` | 35 | 35 | 0 | 0 | E | 実ソケットの公開 HttpServerTransport を素の HTTP クライアントで叩く E (sessionCount・pendingExchangeCount は公開アクセサ)。HttpServerAuth は transport.auth の型として公開と扱った。 |  |  |
| `test_security_icons.nim` | 5 | 3 | 0 | 2 | mixed | E の 3 件は公開の fetchIcon と resolver。S movable の 2 件は doc が「テスト用」と言う IconFetchOptions.get を差し替える。 |  | 足場 2 件は呼び口を移せば E |
| `test_security_pages.nim` | 4 | 4 | 0 | 0 | E | 公開の allPages (client/content を tools・resources・prompts が export) に偽の fetch を渡す E。1 件がエラー文を固定 (wording)。 |  |  |
| `test_security_poll.nim` | 5 | 5 | 0 | 0 | E | 公開の pollTask・MinPollIntervalMs (task_methods を server/tasks が export) に睡眠関数を差して待ち時間を見る E。 |  |  |
| `test_security_sampling.nim` | 3 | 3 | 0 | 0 | E | client/sampling が `*` で定義する parseSamplingRequest (公開) を呼ぶ E。 |  |  |
| `test_security_schema.nim` | 48 | 31 | 0 | 17 | mixed | E は json_schema の validate と SchemaLimits。S movable の 16 件は入口から届かない json_schema_regex を直接呼ぶ。S の 1 件は命令数 4 を写す。 |  | 足場 16 件は呼び口を移せば E、足場 1 件は消してよい |
| `test_security_tasks.nim` | 15 | 15 | 0 | 0 | E | 公開の TaskStore・parseTaskParam・McpTaskError と server_harness 越しの tasks/list・tools/call だけを見る E (1 件は tests.map に行無し)。 |  |  |
| `test_security_wire_headers.nim` | 47 | 0 | 6 | 41 | mixed | 入口から届かない transport/http_wire.request を直接呼ぶ。大半は公開の StreamableHttpTransport から確かめられる S movable。I の 6 件は応答オブジェクトの API や POST 以外の要求など公開の口に無いもの。 | 公開の transport は本文の無い POST を送らない (POST は常に JSON-RPC 本文を持つ) ので、Content-Length: 0 の規則に外から届く口が無い。 / 公開の transport は PUT を送らない (POST・GET・DELETE だけ) ので、この要求の組み立てに外から届く口が無い。 / 応答ヘッダの一覧そのもの (response.headers.len) は公開の transport から見えない。見えるのは Mcp-Session-Id などの特定のヘッダ値だけ。 ほか 3 通り | 足場 41 件は呼び口を移せば E |
| `test_security_wire_limits.nim` | 6 | 4 | 0 | 2 | mixed | E は公開の initSseParser と newStreamableHttpTransport。S movable の 2 件は入口から届かない http_wire.request を直接呼ぶ。 |  | 足場 2 件は呼び口を移せば E |
| `test_security_wire_tls.nim` | 8 | 0 | 7 | 1 | mixed | 入口から届かない http_wire.request に caFile・connectTo を渡す I (6 件、公開の transport に口が無い)。S は 2 件 (うち 1 件が movable、1 件は -d:ssl 無しで落とす足場)。 | [リードが変更] -d:ssl 無しのビルドでこのファイルのテストが黙って飛ばされるのを防ぐ門 / request の caFile (信頼する CA) と connectTo (接続先 IP の差し替え) を使う。公開の StreamableHttpTransport にはどちらの口も無く、自前の CA で作った証明書の検証は外から再現できない。 | 足場 1 件は呼び口を移せば E |
| `test_server_completion.nim` | 11 | 11 | 0 | 0 | E | completion/complete の応答と公開の parseCompletionRequest だけを見る (server/server が completion を export: src/server/server.nim:25)。機能表は版の選択だけに使う 3 件 (features)。 |  |  |
| `test_server_elicitation.nim` | 20 | 20 | 0 | 0 | E | elicitation/create のメッセージと公開の server.elicit / ctx.elicit・urlElicitationRequired の戻り値・例外だけを見ている。 |  |  |
| `test_server_errors.nim` | 16 | 16 | 0 | 0 | E | トランスポートに流れる JSON-RPC の error / result と、公開の setResourceHandlers 等の旧 API の応答を見る。機能表は版の選択だけに使う (features)。 |  |  |
| `test_server_logging.nim` | 19 | 19 | 0 | 0 | E | notifications/message と logging/setLevel の応答、公開の ctx.log / server.log を見る。機能表は版の選択だけに使う 8 件 (features)。 |  |  |
| `test_server_notifications.nim` | 16 | 16 | 0 | 0 | E | トランスポートに流れる notifications/* と公開の notify*・subscribersOf を見る。機能表は版の選択だけに使う 2 件 (features)。 |  |  |
| `test_server_pagination.nim` | 15 | 15 | 0 | 0 | E | wire 上の nextCursor と公開の pageOf / pagedList を見る (server/server が pagination を export: src/server/server.nim:25)。 |  |  |
| `test_server_progress_cancel.nim` | 25 | 25 | 0 | 0 | E | notifications/progress・cancelled と応答の有無、公開の cancelRequest・serveDetached・ctx.cancelled を見る。機能表は版の選択だけに使う (features)。 |  |  |
| `test_server_requests.nim` | 29 | 29 | 0 | 0 | E | server 起点の要求と応答をトランスポート越しに見る。holdForTask・sendHeld・TaskScope は server/server の公開フィールドで doc が内部用と言っていないので E (src/mcp.nim:12)。機能表は版の選択だけに使う (features)。 |  |  |
| `test_server_resources_prompts.nim` | 8 | 8 | 0 | 0 | E | resources/* と prompts/* の応答の形と能力未宣言時の -32601 だけを見ている。 |  |  |
| `test_server_sampling_tools.nim` | 9 | 9 | 0 | 0 | E | sampling/createMessage の送信内容・拒否・応答検査を、トランスポートと公開の createMessage・clientCapabilities で見ている。 |  |  |
| `test_silent_dead.nim` | 6 | 6 | 0 | 0 | E | 公開の processMessages と lastTransportError を、差したトランスポートで見ている。tests.map に行が無い (全件 unmapped)。 |  |  |
| `test_spec_coverage.nim` | 8 | 0 | 8 | 0 | I | SDK の振る舞いではなく、リポジトリの specs・tests.map・tests の整合を確かめる門 (R5)。 | SDK の振る舞いではなく、リポジトリの specs と tests.map と tests の整合を確かめる門。 |  |
| `test_stdio.nim` | 29 | 29 | 0 | 0 | E | 行区切り、子プロセスとの接続、子の環境変数と作業ディレクトリ、stderr の転送、終了の段階を、ストリームと実プロセス越しに見ている。文言固定が 1 件 (wording)。 |  |  |
| `test_streamable_http.nim` | 55 | 55 | 0 | 0 | E | 実ソケット上の HTTP の状態・ヘッダ・本文と、公開の HTTP トランスポートの口だけを見ている。tests.map に行が無い 11 件と文言固定 2 件に印。 |  |  |
| `test_structured_tool_output.nim` | 30 | 30 | 0 | 0 | E | tools/list・tools/call の応答、公開の McpClient.callTool、protocol/content の公開関数を見る。機能表は版の選択だけに使う 23 件 (features)。 |  |  |
| `test_subscriptions.nim` | 56 | 55 | 1 | 0 | mixed | 公開の Transport を流れる JSON-RPC と公開 API (listen / endSubscriptions / notify* / subscriptionCount、protocol/subscriptions は client/subscriptions.nim:29 の export) を見ている。43 件は版の選択に protocol/features を使うだけなので E (印 features)、heldWaiters の 1 件は I。 | token が保持する待ち手の数は外から見えない (アクセサ自体が for tests と明記)。版の選択にも protocol/features を使う (R6、これだけなら E のまま) |  |
| `test_tasks_client.nim` | 37 | 37 | 0 | 0 | E | 手書きの相手との間のメッセージと client の公開 API を見ている。stderr・エラー文を固定する 3 件は E のまま wording。 |  |  |
| `test_tasks_end_to_end.nim` | 9 | 9 | 0 | 0 | E | loopback で SDK の client と server を繋ぎ、公開 API だけを呼んでいる。 |  |  |
| `test_tasks_http.nim` | 4 | 2 | 2 | 0 | mixed | 実ソケットの SSE 本文だけを表明する。2 件は doc の無い store.resultStream を同期点に使うため I。 | tasks/result の応答ヘッダは最初のイベントと一緒にしか来ず、サーバが待ち始めたことをワイヤから知る口が無いので、doc の無い store.resultStream を同期点に使う (表明はワイヤ上のみ) / 同上: tasks/result の到着を待つ口がワイヤに無く、resultStream を同期点に使う |  |
| `test_tasks_principal.nim` | 4 | 4 | 0 | 0 | E | 実ソケットの HTTP と認可ヘッダ、ctx.principal だけを見ている。 |  |  |
| `test_tasks_server.nim` | 56 | 55 | 0 | 1 | mixed | トランスポートを流れるメッセージと公開 API を見ている。resultStream を読む 1 件は S、版の選択に features を使う 1 件は E (印 features)、stderr 文言を固定する 1 件は E (wording)。 |  | 足場 1 件は消してよい |
| `test_tasks_store.nim` | 63 | 62 | 0 | 1 | mixed | TaskStore の操作・純関数は server/tasks.nim:17 と client/tasks.nim:25 の export で公開 (task_methods も同じ)。全件 E。hook の 1 件のみ doc の無い resultStream を補助に読むため S (secondary)。4 件は wording。 |  | 足場 1 件は消してよい |
| `test_title_fields.nim` | 6 | 6 | 0 | 0 | E | server は応答、client は公開 API (list*, displayName) を見ている。server の 4 件は版の選択に features を使うだけで E (印 features)。 |  |  |
| `test_tool_annotations.nim` | 16 | 11 | 5 | 0 | mixed | annotations とクライアント側は公開 API。server/tools の builder を呼ぶ 5 件は mcp から届かないため I ([要判断])、版の選択に features を使う 2 件は E (印 features)。 | [要判断] server/tools の builder は src のどこからも呼ばれず mcp からも届かない。出力は builder を直接呼ぶ以外に観測する口が無い (README にも説明なし)。mcp から export すれば E になる |  |
| `test_tool_input_validation.nim` | 6 | 6 | 0 | 0 | E | トランスポート上の tools/call の応答だけを見ている。3 件は版の選択に features を使うだけで E (印 features)。 |  |  |
| `test_trace_context.nim` | 28 | 28 | 0 | 0 | E | 純関数 (protocol/trace_context は mcp.nim:39 の export) と _meta、ctx.traceContext を見ている。8 件は版の選択に features を使うだけで E (印 features)。 |  |  |
| `test_transport.nim` | 11 | 11 | 0 | 0 | E | 公開の McpTransport、isRequest 等、toJson、Scenario が約束する stderr 1 行だけを見ている。 |  |  |
| `test_version.nim` | 15 | 15 | 0 | 0 | E | protocol/version (types.nim:6 の export) の純関数だけを見ている。 |  |  |
| `test_version_build_config.nim` | 4 | 4 | 0 | 0 | E | nim check の終了コードと出力を見る。失敗 3 件は全文一致で wording。 |  |  |
| `test_version_floor.nim` | 17 | 17 | 0 | 0 | E | HTTP の状態・ヘッダ・本文と公開 API (protocol/version は types.nim:6 の export) を見ている。4 件は版の選択に features を使うだけで E (印 features)。 |  |  |

支援のファイル (テストを持たない。分類の対象外): `auth_fixtures.nim`、`client_peer.nim`、`loopback_transport.nim`、`server_harness.nim`、`sessioned_transport.nim`、`sse_reader.nim`、`stuck_transport.nim`。

## E テストが 1 本も結ばれていない仕様 ID (48 件)

`specs/tests.map` がその ID に結んでいるテストが、すべて I か足場に分類されたもの。「移せば E」は、結ばれたテストに、呼び口を公開側へ移せば E になる足場が含まれることを言う。

| 仕様 ID | 結ばれたテスト | 移せば E | テストのファイル |
|---|---|---|---|
| MCP-AUTH-1 | 足場 2 | はい | `test_auth_resource_server.nim` |
| MCP-AUTH-10 | 足場 9 | はい | `test_auth_oauth_basics.nim` |
| MCP-AUTH-21 | 足場 5 | はい | `test_auth_client_flow.nim`、`test_auth_oauth_basics.nim` |
| MCP-AUTH-22 | 足場 6 | はい | `test_auth_client_flow.nim` |
| MCP-AUTH-30 | 足場 7 | はい | `test_auth_oauth_basics.nim` |
| MCP-AUTH-34 | 足場 6 | はい | `test_auth_oauth_basics.nim` |
| MCP-AUTH-35 | 足場 11 | はい | `test_auth_oauth_basics.nim` |
| MCP-AUTH-36 | I 1、足場 4 | はい | `test_auth_oauth_basics.nim` |
| MCP-AUTH-37 | 足場 5 | はい | `test_auth_oauth_basics.nim` |
| MCP-AUTH-38 | 足場 2 | はい | `test_auth_oauth_basics.nim` |
| MCP-AUTH-39 | 足場 2 | はい | `test_auth_oauth_basics.nim` |
| MCP-AUTH-4 | 足場 1 | はい | `test_auth_resource_server.nim` |
| MCP-AUTH-40 | 足場 2 | はい | `test_auth_oauth_basics.nim` |
| MCP-AUTH-42 | 足場 5 | はい | `test_auth_oauth_basics.nim` |
| MCP-AUTH-8 | 足場 1 | はい | `test_auth_resource_server.nim` |
| MCP-CONTENT-FIELDS-8 | I 5 | はい | `test_tool_annotations.nim` |
| MCP-HTTP-13 | 足場 17 | はい | `test_param_headers.nim` |
| MCP-HTTP-24 | 足場 3 | はい | `test_param_headers.nim` |
| MCP-HTTP-25 | 足場 3 | はい | `test_param_headers.nim` |
| MCP-HTTPSTREAM-19 | I 1、足場 3 | はい | `test_http_streams.nim` |
| MCP-HTTPSTREAM-20 | I 3、足場 2 | はい | `test_http_streams.nim` |
| MCP-ICONS-8 | 足場 1 | はい | `test_icon_fetch.nim` |
| MCP-SEC-AUTH-5 | 足場 8 | はい | `test_security_auth_tokens.nim` |
| MCP-SEC-SCHEMA-1 | 足場 2 | はい | `test_security_schema.nim` |
| MCP-SEC-SCHEMA-11 | 足場 4 | はい | `test_json_schema.nim` |
| MCP-SEC-SCHEMA-12 | 足場 6 | はい | `test_json_schema.nim` |
| MCP-SEC-SCHEMA-13 | 足場 9 | はい | `test_json_schema.nim` |
| MCP-SEC-SCHEMA-14 | 足場 4 | はい | `test_security_schema.nim` |
| MCP-SEC-SCHEMA-2 | 足場 3 | はい | `test_security_schema.nim` |
| MCP-SEC-SCHEMA-3 | 足場 5 | はい | `test_security_schema.nim` |
| MCP-SEC-SWEEP-6 | I 3 | いいえ | `test_fuzz_regressions.nim` |
| MCP-SEC-WIRE-1 | I 4 | いいえ | `test_security_wire_tls.nim` |
| MCP-SEC-WIRE-10 | 足場 1 | はい | `test_security_icons.nim` |
| MCP-SEC-WIRE-11 | 足場 2 | はい | `test_security_address.nim` |
| MCP-SEC-WIRE-12 | 足場 12 | はい | `test_security_address.nim` |
| MCP-SEC-WIRE-13 | 足場 6 | はい | `test_security_address.nim` |
| MCP-SEC-WIRE-14 | 足場 2 | はい | `test_security_address.nim` |
| MCP-SEC-WIRE-15 | I 3、足場 9 | はい | `test_http_wire_internals.nim`、`test_security_wire_headers.nim` |
| MCP-SEC-WIRE-16 | I 2、足場 7 | はい | `test_security_wire_headers.nim` |
| MCP-SEC-WIRE-17 | 足場 4 | はい | `test_security_wire_headers.nim` |
| MCP-SEC-WIRE-18 | 足場 13 | はい | `test_security_wire_headers.nim` |
| MCP-SEC-WIRE-19 | I 3 | いいえ | `test_http_wire_internals.nim`、`test_security_wire_headers.nim` |
| MCP-SEC-WIRE-2 | 足場 7 | はい | `test_security_wire_headers.nim` |
| MCP-SEC-WIRE-20 | I 2、足場 1 | はい | `test_security_wire_headers.nim`、`test_security_wire_tls.nim` |
| MCP-SEC-WIRE-21 | 足場 3 | はい | `test_security_address.nim` |
| MCP-SEC-WIRE-4 | 足場 7 | はい | `test_security_address.nim` |
| MCP-SEC-WIRE-5 | 足場 5 | はい | `test_security_address.nim` |
| MCP-SEC-WIRE-7 | 足場 1 | はい | `test_security_icons.nim` |

## 2026-10-13: 呼び口を公開側へ移した

上の表と本文は、分類した時点の数である。そのあと、E テストが 1 本も無い仕様 ID に結ばれた「呼び口を移せば E になる」テスト 216 本について、実際に呼び口を公開の口へ書き換えた (本線のテストファイル 11 本。`src/` と `export` は変えていない。テストは消さず、名前も変えていない)。

| | 本数 |
|---|---:|
| 移した (E になった。TSV の印 `moved`) | 110 |
| 移せなかった (足場のまま。TSV の印 `not-movable`、理由は reason の欄) | 106 |

E テストが 1 本も結ばれていない仕様 ID は **17 件** になった (この系列の仕様 ID 469 件のうち): `MCP-AUTH-10`, `MCP-AUTH-34`, `MCP-AUTH-40`, `MCP-CONTENT-FIELDS-8`, `MCP-HTTP-24`, `MCP-HTTPSTREAM-20`, `MCP-SEC-SCHEMA-14`, `MCP-SEC-SWEEP-6`, `MCP-SEC-WIRE-1`, `MCP-SEC-WIRE-10`, `MCP-SEC-WIRE-11`, `MCP-SEC-WIRE-12`, `MCP-SEC-WIRE-13`, `MCP-SEC-WIRE-14`, `MCP-SEC-WIRE-19`, `MCP-SEC-WIRE-21`, `MCP-SEC-WIRE-7`。

1 本ごとの記録 (使っていた非公開の部品、通すようにした公開の口、移せない理由) は [test-entry-moves.tsv](test-entry-moves.tsv)。

決まりと確かめ方:

- 確かめる値 (入力と期待) を変えずに書けるものだけを移した。公開の口を通すと検証の一部が書けない・形が変わるテストは、テスト全体を移していない。
- 期待する例外の型が、内部の型から公開の口が返す型に替わったものがある (`RegexError` → `InvalidSchemaError`、`RegexLimitError` → `SchemaLimitError`)。
- 「宣言が不正」を「`tools/list` に載らない」で、「分類が loopback」を「拒否される」で見るように、公開の口での現れ方に置き換えたものがある (TSV の reason に書いた)。
- 外のアドレスへ接続を試みることになる書き換えは採らなかった (接続先の分類の「通る」側は、公開の口からは実際に接続しないと見えない)。
- **移したテストは、公開の口がそのビルドに無いと流れない。** もとのテストは部品を直接呼んでいたので、どの版を既定にしたビルドでも流れていた。移したあとは、既定版が `2026-07-28` より古いビルドで `test_param_headers.nim` の 13 本が、`2024-11-05`・`2025-03-26` のビルドで `test_security_auth_tokens.nim` の 8 本と `test_security_address.nim` の 3 本が、`test_auth_oauth_basics.nim` は `2024-11-05` で 24 本、`2025-03-26` で 19 本、`2025-06-18` で 10 本が skip になる (認可が無い、protected resource metadata が無い、など。条件は各テストの注釈)。古い版のタグでは、これらの規則を確かめるテストがそのぶん減った。
- 書き換えはワーカー (Claude Sonnet) 5 人。リードが 11 ファイルの差分をすべて読み、検証・入力が変わっていたもの、外のアドレスへ接続を試みるものなど 61 本を元に戻させた。移したテストの拒否が狙った理由で起きていることは、認可の 30 例ほどについて実際の文言を出して確かめた。各ファイルで、移したテストから数本を選び、期待値を誤らせると落ちることをワーカーが確かめた。
- **確かめていないこと**: 移したテストの本体のうち差分に出なかった行 (もとから公開の口だけだったはずの行) は読み直していない。移せなかったテストについて、ほかの公開の口が無いかの再検討はしていない。

移せなかった理由の型と、移すために export が要るもの (広げるかどうかは決めていない):

- 応答の「読み終えた」状態や本文の値が、公開のクライアントからは見えない (`transport/http_wire` の `WireResponse`、`request`)。
- 接続先の分類の結果、とくに「公開」「通る」側 (`transport/address_policy` の `classifyHost`・`classifyAddress`・`chooseDestination`・`parseHostLiteral`・`resolveHost`、`transport/guarded_wire` の `guardedRequest`、`auth/oauth/urls` の `checkFetchUrl`)。
- 挑戦ヘッダの `realm`・`error_description` や解析の構造、認可の部品の戻り値 (`parseChallenges`。2026-10-15 に `foundation/nim-bearer-challenge` へ移した。`auth/oauth/{authcode,discovery,metadata,registration,jsonfield}`)。
- 正規表現のプログラムの大きさと残りの歩数 (`jsonschema/json_schema_regex` の `Regex.size`、`isMatch` の予算)。
- `x-mcp-header` の束縛の個数 (`protocol/param_headers` の `declaredParamHeaders`)、イベントストリームの終わり方の値 (`transport/sse_stream`)。
- ツールの組み立ての手続き (`server/tools`。`src/` のどこからも呼ばれず、入口からも届かない)、アイコンの取得の差し替え口 (`IconFetchOptions.get`)。

## 2026-10-13: Scenario を読み直し、公開の口から見える観測で E テストを足した

呼び口を移したあとに残った 17 件について、Scenario が外から見える約束を言っているかを 1 件ずつ読み直した。
「同じ検証を、入口だけ替えて書く」ことはできなくても、**Then 節が言っていることを、公開の口から見える別の観測で確かめる**ことはできるものが 10 件あった。その 10 件に E テストを 53 行ぶん足した (あとで Scenario を書き直した `MCP-SEC-WIRE-14` の 3 行を加えて、11 件、56 行) (`specs/tests.map` の行の数。版ごとに展開されるテストは版の数だけ行がある)。`src/` と `export` は変えていない。もとのテストは消さず、書き換えてもいない。

E テストが 1 本も結ばれていない仕様 ID は **5 件** になった (469 件のうち)。

| 仕様 ID | 足した行 | 公開の口からの観測 |
|---|---:|---|
| `MCP-SEC-WIRE-12`、`-21` | 12、4 | 名前が「調べたいアドレス、どの方針でも通らないアドレス (169.254.0.1)」の順に解決されるようにし、公開だけを通す方針で `handleChallenge` に渡す。拒否の文言が分類を名指しする。1 つ目が通ったことは、文言が 2 つ目を名指しすることで分かる。どの場合も接続の前に拒否される |
| `MCP-SEC-WIRE-13` | 5 | URL のホストに書いた表記が、名前としてリゾルバに届くか、アドレスとして分類を名指しして拒否されるか |
| `MCP-SEC-WIRE-11` | 2 | 平文 http の metadata URL は、名前を解決する前に拒否される。302 の答えは報告され、転送先は要求されない (偽のサーバーが受けた要求の行で確かめる) |
| `MCP-SEC-SCHEMA-14` | 3 | `validate` に渡す上限 (`SchemaLimits.regex.maxProgramSize`、`maxRegexSteps`) をちょうどの値と 1 つ小さい値にして、通る・`SchemaLimitError` の境を見る |
| `MCP-HTTPSTREAM-20` | 2 | 生のソケットで、ストリームが終わるとサーバーが接続を閉じること、余分な 1 バイトのあとに閉じても `onRequestCancelled` が呼ばれること |
| `MCP-AUTH-10`、`-34` | 9、8 | クライアントがヘッダから読み取った `resource_metadata` は、リゾルバに届くホスト名で、`scope` は認可 URL で見える。リソースサーバーが組み立てるヘッダは、呼び手が渡せる scope に引用符・バックスラッシュ・改行を入れて、応答のヘッダで見る |
| `MCP-AUTH-40` | 3 | 認可応答を書き換えて返し、拒否の文言がその理由を言うことと、トークンのエンドポイントに要求が飛ばないこと |
| `MCP-HTTP-24` | 5 | 注釈のある property だけにヘッダが要ること、無効な宣言の理由はサーバーが stderr に書く行で見る |

Scenario のうち、公開の口からは見えず、足したテストが確かめていない部分:

- `MCP-SEC-WIRE-11` の「呼び手が求めたときだけ転送を追う」の、追う側 (アイコンの取得だけが使い、https のサーバーが要る)。
- `MCP-SEC-WIRE-13` の「数字がその基数での値を持つ」は、値が変わると分類が変わる表記でだけ見ている。公開のアドレスになる表記 (`0xAbCdEf01`、`1.2.65535`) は、公開の口では実際に接続しないと見えないので、もとの内部のテストだけが確かめる。角括弧が全体を囲まないホストも同じ。
- `MCP-AUTH-10`・`-34` の `realm`・`error_description` の値と、解析結果の形。クライアントはこれらを使わない。
- `MCP-HTTPSTREAM-20` の keep-alive の注釈行 (既定の 15 秒を公開の口から変えられない) と、どの接続も書いていないイベントの扱い。

足したテストについて、次のことは残る:

- アドレスの分類のテストは、分類の規則が壊れた SDK (変異検査の変異を含む) の上では、調べたいアドレスへ実際に接続を試みることがある (待ち時間は 200 ms にしてある)。正しい SDK の上ではどこにも接続しない。
- `MCP-SEC-SCHEMA-14` の歩数のテストは、`^a$` を `a` に当てるのに要る予算を 9 と固定している。数え方 (命令 4 つと、訪れる 5 回) は公開のフィールドの説明から導いたが、照合器の作りが変われば変わる数である。
- `resource_metadata` を challenge から読まない版 (`2024-11-05`、`2025-03-26`) を既定にしたビルドでは、アドレスと認可の足したテストは流れない。

残った 5 件:

| 仕様 ID | 結ばれているテスト | E が無い理由 |
|---|---|---|
| `MCP-SEC-SWEEP-6` | I 3 本 | ファジングで見つけた入力の再生。入口から届かない読み手を含み、1 件ずつ外から叩く口が無い |
| `MCP-SEC-WIRE-1` | I 4 本 | 自前の CA で作った証明書の検証。公開のトランスポートに、信頼する CA と接続先を差す口が無い |
| `MCP-SEC-WIRE-7`、`-10` | I 各 1 本 (足場から直した) | `fetchIcon` は https だけを受ける。接続が閉じられたことを外から見るには、公開の認証局が信頼する証明書を持つサーバーが要る |
| `MCP-SEC-WIRE-19` | I 3 本 | 読み待ちの途中で応答を閉じる口が、公開のトランスポートに無い |

Scenario の文言を直したもの (2026-10-13、利用者の指示。仕様 ID は変えていない):

| 仕様 ID | 直す前に言っていたこと | 直したあと |
|---|---|---|
| `MCP-SEC-SCHEMA-14` | 上限を 1 つ超えると `RegexLimitError` (入口から届かない型) | schema を検証すると `SchemaLimitError` |
| `MCP-SEC-WIRE-14` | 選ばれた接続先が loopback-only である (部品の内側の値)、システムの名前解決がアドレスをそのまま答える | loopback を表す名前への平文 http は、名前のアドレスがすべて loopback のときだけ出ていく。アドレスで書いたホストはそのアドレスとして判定され、リゾルバには尋ねない。E テスト 3 本を足した。もとの 2 本は I のまま結んである (接続先を選ぶ手続きの戻り値と、システムの名前解決を直接見る) |
| `MCP-AUTH-10` | クライアントが「その他の parameter」も見つける、「自分が組み立てる」ヘッダ | クライアントが見つけるのは `resource_metadata`・`scope`・`error`。ヘッダを書くのはリソースサーバーで、scope の中の引用符・バックスラッシュ・改行について言う |
| `MCP-SEC-WIRE-11` | 題が内部の部品 (guarded request) を名指ししていた | 「ネットワークから来た URL への要求」 |

`server/tools` を公開にした (2026-10-13、利用者の決定): `import mcp` が export する。`MCP-CONTENT-FIELDS-8` に結ばれた 5 本は、確かめ方は変えずに E になった。`import mcp` だけで組み立ての手続きに届くことを確かめるテスト 3 本 (`tests/test_tool_builders.nim`) を足した。README の「Features, at run time」に案内がある。上の「分け方」と「分類とは別に見つかったこと」が `server/tools` について言っていること (入口から届かない、決まっていない) は、分類した時点の話である。

確かめ方: 足したテストは、リードが書いたもの (アドレス、正規表現、ストリーム、30 行) と、ワーカー (Claude Sonnet) 1 人が書いたもの (認可、ヘッダ、25 行ぶん)。ワーカーの差分はリードが、既存の行を消していないこと、外のアドレスへ接続しないこと、例外を捨てていないことについて読み、3 ファイルを既定の版で流した。ワーカーのテスト本文を 1 行ずつ読み直してはいない (補助手続きと、認可応答・ヘッダの宣言のテストを読んだ)。期待値を誤らせると落ちることは、足したテストについては確かめていない。

## 2026-10-13: 分類を置き場に移した

この文書と [test-classification.tsv](test-classification.tsv) は、手で付けた分類の記録である。2026-10-13 に、分類を置き場に移した (ADR-KURA-0008 §3): 外部仕様テストは `tests/external/`、内部実装テストは `tests/internal/` にある。**これ以後、分類はこの文書ではなく置き場が言う。** この文書と TSV は更新しない。

- 混ざっていたファイル 21 本は、テストの塊ごとに 2 つに割った (`tests/external/test_X.nim` と `tests/internal/test_X_internal.nim`)。テストの本文は変えていない: 割る前のコミット (9453f398ae51) の 2,140 本と 1 本ずつ突き合わせ、文面が違うのは、流し方を案内する文のパスを直した 1 本だけである。
- 外部仕様テストは、入口 (`mcp`、`auth/client`、`auth/resource_server`、`transport/http_compat`、`server/request_state`) と、入口が丸ごと export するモジュールだけを import する。`nimble specCoverage` がそれを確かめ (nim-spec-coverage の `--external`・`--entry`)、外部仕様テストの無い仕様 ID と、入口の外を読む外部仕様テストがあれば失敗する。結果は `nimble specCoverage` の表 (g1-spec-coverage.md。2026-10-13 から追跡していない) の末尾の 2 つの節にある。
- 上の「分け方」で認めていた例外は無くなった。版と機能の表 (`protocol/features`) は入口が export する。テストの補助 (`sse_reader`、`auth_fixtures`) は、SDK の内側の部品を借りない形に書き直した。
- 割るときに、テストの本文が非公開の名前を使っていた 1 本を、外部から内部へ移した (`test_mrtr`)。
- 変異検査のジョブ (`tests/mutation/*.json`) は、外部仕様テストだけを走らせる。内部だけのテスト 10 件を、ジョブの `testCommand` から外した。
