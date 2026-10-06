# 公式の適合性テストの結果: 2026-10-06

対象は本線 `5dad2e1` (`test(mutation): the jobs run the security tests ...`) の上に、この作業のコミット (下の「見つけた SDK の不具合」の 4 件と、
`tests/interop/` の検査用プログラムの更新) を重ねたもの。
道具: `@modelcontextprotocol/conformance` 0.2.0-alpha.12 (2026-07-28 のシナリオを含む)。
流し方は `tests/interop/README.md` の「公式の適合性テスト」。結果の生データは `peers/run_conformance.py` が
`build/interop-nim/conformance.{md,jsonl}` に書く。

この文書の前の版は、検査用プログラムが一部の機能しか登録しない状態の結果で、不合格を「SDK に機能が無い」と分類していた。
検査用のサーバーとクライアントがその時点の SDK の機能を使うように更新したところ、その分類の大半が検査用の欠落だったことが分かった。
下は更新後の測定で、更新前の数字は「結果の要約」に並べてある。

## 読み方

- サーバー検査の対象は `tests/interop/nim_conformance_server.nim`。公式の「everything server」と同じ名前のツール・リソース・
  プロンプトに加え、シナリオが探す診断用のツールを持つ (ツール 27、リソース 3 とテンプレート 1、プロンプト 5)。登録する機能は
  ログ (`ctx.log`、`logging/setLevel`)、進捗 (`ctx.reportProgress`)、補完 (`onComplete`)、リソースの購読、sampling と elicitation
  (2025-11-25 まではサーバー発の要求 `ctx.createMessage` / `ctx.elicit`、2026-07-28 は `ctx.requireInput`)、複数ラウンドの要求
  (署名した `requestState`)、`x-mcp-header` の引数、`listChanged` 通知。
- クライアント検査の対象は `tests/interop/nim_conformance_client.nim`。roots・sampling・elicitation と OAuth のフックを有効にして接続し、
  サーバーが一覧に出したツールを 1 つずつ呼び、リソースを読み、プロンプトを取る。シナリオごとの特別な動作は、シナリオが文脈で渡す
  ツール呼び出し (`http-custom-headers`)、JSON Schema の往復 (`json-schema-2020-12-preservation`)、フォームの既定値 (elicitation)、
  認可の同意 (認可 URL を開いてリダイレクトの引数を返す) の 4 つだけ。
- 「分類」: **不具合** = SDK の誤り (外部仕様テストを先に書いて `src/` を直した)、**検査用** = 検査用プログラムに足りなかったもの、
  **検査側** = 検査の側の動作で SDK が正しいもの。
- シナリオの状態は、その中の判定される検査の最悪のもの。INFO の検査 (検査側が通信を記録するだけのもの) は数えない。INFO しか無い
  シナリオは「記録のみ」。`skipped` は一部の検査が実行されなかったもの。

## 結果の要約

更新前は検査用プログラムの更新前 (本線 `5dad2e1` のまま) の測定、更新後は最後の 1 回の測定。更新前の表は `build/keep/conformance-before-fixture-update.md` にある。

| ビルド (仕様の版) | サーバー検査 合格 / 警告 / 不合格 (計) 更新前 → 更新後 | クライアント検査 合格 / 未対応 / 一部未実行 (計) 更新前 → 更新後 |
|---|---|---|
| 2026-07-28 (2026-07-28) | 22 / 3 / 14 → **40 / 0 / 0** (40) | 1 / 31 / 1 → **32** / 0 / 1 (33) |
| 2026-07-28 (2025-11-25) | 21 / 0 / 10 → **32 / 0 / 0** + 記録のみ 1 (33) | 1 / 17 / 0 → **19** / 0 / 0 (19) |
| 2025-11-25 | 21 / 0 / 10 → **32 / 0 / 0** + 記録のみ 1 (33) | 1 / 17 / 0 → **19** / 0 / 0 (19) |
| 2025-06-18 | 19 / 0 / 8 → **27 / 0 / 0** (27) | 1 / 3 / 0 → **5** / 0 / 0 (5) |
| 2025-03-26 | 1 / 0 / 0 → 1 / 0 / 0 (1) | 0 / 2 / 0 → **2** / 0 / 0 (2) |
| 2024-11-05 | 検査なし (この版のシナリオも HTTP+SSE の検査も無い) | 検査なし |

更新前の「合格」の数え方は、INFO の検査を 1 つでも持つシナリオを「記録のみ」にしていた。更新後は INFO を数えないので、`initialize` と
`server-sse-multiple-streams` は合格に数えられる (検査の中身は変わっていない)。

## 更新前のサーバー検査の不合格

| シナリオ | 版 | 更新前の症状 | 分類 | 対処 |
|---|---|---|---|---|
| completion-complete | 2025-06-18 以降 | `Method not supported` | 検査用 | `completions` を宣言し `onComplete` を登録 |
| logging-set-level、tools-call-with-logging | 2025-06-18、2025-11-25 | `Method not supported` | 検査用 | `logging` を宣言し、ツール `test_tool_with_logging` で `ctx.log` を 3 回呼ぶ |
| tools-call-with-progress | 全版 | `Internal error` (ツールが無い) | 検査用 + **不具合** | ツール `test_tool_with_progress` を足すと、2026-07-28 だけ「結果が返らない」(次の節の 1)。他の版は合格 |
| resources-subscribe / unsubscribe | 2025-06-18、2025-11-25 | `Method not supported` | 検査用 | `resources: {subscribe: true}` を宣言 (ハンドラは登録不要) |
| tools-call-sampling、tools-call-elicitation、elicitation-sep1034-defaults、elicitation-sep1330-enums | 2025-06-18、2025-11-25 | `Internal error` (ツールが無い) | 検査用 | `ctx.createMessage` / `ctx.elicit` を使うツールを足した。SEP-1034 の既定値と SEP-1330 の 5 種の enum はそのままの schema で通る |
| input-required-result-* (10 本が不合格、2 本が警告) | 2026-07-28 | 診断ツールが無い | 検査用 | `ctx.requireInput` / `requireInputs`、署名した `requestState` (`sealRequestState` / `openRequestState`) で 8 つのツールとプロンプト 1 つを足した |
| sep-2164-resource-not-found (警告) | 2026-07-28 | 誤りが `-32603`、`data.uri` 無し | 検査用 | 検査用が `ValueError` を投げていた。`newResourceNotFound(uri)` に直すと `-32602` と `data.uri` が付く |
| http-custom-header-server-validation | 2026-07-28 | `x-mcp-header` のツールが無く検査不能 | 検査用 + **不具合** | 引数に `x-mcp-header` を持つツール `test_custom_headers` を足すと、パディングの無い Base64 を受理してしまう (次の節の 2) |
| server-stateless | 2026-07-28 | 診断ツール 3 つが無く検査不能 (4 検査)、listChanged が宣言されず 2 検査が skipped | 検査用 | `test_missing_capability` (`requireInput` の sampling で `-32021`)、`test_streaming_elicitation`、`test_logging_tool`、`test_trigger_tool_change`、`test_trigger_prompt_change` を足し、`tools` と `prompts` の `listChanged` を宣言 |

## 見つけた SDK の不具合 (4 件、すべて直した)

各件は、失敗する外部仕様テストを先に書き、`src/` を直し、同じコミットに入れてある。

1. **SSE の応答が、最後のイベントを 15 秒遅れて返す** (`tools-call-with-progress`、2026-07-28)。`serveStream` は、書き込みの間に積まれた
   イベントの通知を取り逃がし、次の keep-alive (15 秒) まで待っていた。最後の進捗通知のすぐあとに結果を返すツールの結果が、
   検査側の 10 秒の時間切れより遅れて届く。待つ前に変更の通知を控えるようにして直した。
   テスト: `tests/test_http_streams.nim` の "Given a response that is ready while the last notification is being written ..." (2 つ)。
2. **パディングの無い Base64 の `Mcp-Param-*` を受理していた** (`http-custom-header-server-validation`)。SEP-2243 の表は
   `=?base64?SGVsbG8?=` (パディングの誤り) を `=?base64?SGVs!!!bG8=?=` (文字の誤り) と並べて「サーバーは拒否しなければならない」とする。
   `decodeHeaderValue` が標準ライブラリの復号に任せ、足りないパディングを許していた。4 文字ずつの組と末尾 2 つまでの `=` を要求するようにした。
   テスト: `tests/test_modern_protocol.nim`、`tests/test_param_headers_http.nim`。
3. **ルートの well-known URI の保護リソースのメタデータを拒否していた** (クライアント、`auth/metadata-var2`)。RFC 9728 3.3 はメタデータの
   `resource` を、well-known URL を作った元の識別子と一致させる。ルートの URL では、それはオリジンである。クライアントは MCP の URL
   (`.../mcp`) との完全一致を求めて文書を捨て、最初に試した経路の 404 だけを報告していた。ルートの URL から得た文書は、オリジンも MCP の URL も
   名乗ってよいことにした。他の `resource`、他の URL から得た文書は引き続き拒否する (テストあり)。
   テスト: `tests/test_auth_client_flow.nim`。
4. **認可と token の要求の `resource` を、公表された識別子と違う値で送っていた** (クライアント、`auth/metadata-var2` の
   `resource-parameter-matches-prm`)。MCP は、メタデータの `resource` をサーバーの正規の URI とし、クライアントはそれをそのまま送る。
   常に MCP の URL を送っていた。発見で読んだ識別子を、認可の要求、コードの交換、更新に使うようにした。token の保管の鍵は MCP の URL のまま。
   テスト: `tests/test_auth_client_flow.nim`。

## 更新後に残る、合格でないもの

| シナリオ | 版 | 状態 | 分類 | 理由 |
|---|---|---|---|---|
| server-sse-polling | 2025-11-25 (2 つのビルド) | 記録のみ (判定される検査が無い) | 検査用の欠落 (閉じていない) | シナリオは、呼び出しの途中で SSE の stream を閉じるツール `test_reconnection` を呼び、`text/event-stream` でなければ「priming event の検査は適用外」と INFO を出す (警告も不合格も無い)。SDK のサーバーは 2025-11-25 で priming event を送るが、ハンドラから要求の stream を閉じる公開 API が無いので、このツールを置けない。仕様では stream を閉じるのは「してよい」(MAY) で、SDK の誤りではない。クライアント側の再接続は `sse-retry` で合格 |
| http-standard-headers | 2026-07-28 | 一部未実行 (2 検査) | 検査側 | 検査が `Mcp-Method` を確かめる方法の一覧に `initialize` と `notifications/initialized` を含み、クライアントが送らなければ `Client did not send a initialize request; Mcp-Method header was not exercised for this method.` と SKIPPED にする。2026-07-28 は `initialize` の握手を持たない (検査側 README: 2026 は「要求ごとの `_meta`」の無状態の生涯) ので、クライアントが送らないのが仕様どおり。他の 9 検査 (`tools/list`、`tools/call` の `Mcp-Name`、`resources/read`、`prompts/get` など) は合格 |

不合格と警告は 0 件。

## クライアント検査

更新前は `initialize`、`tools_call`、`request-metadata` の 3 つ以外を「この SDK のクライアントに機能が無い」と断っていた。SDK のクライアントには
OAuth、`Mcp-Param-*` と `x-mcp-header` の検査、複数ラウンドの再試行、elicitation、SSE の再開があり、断る理由は無かった。
`nim_conformance_client` はそれらを使うようになり、`--suite all` のシナリオは 1 つも断っていない (断る場合は理由を stderr に書き、終了コード 2)。

| シナリオ | 版 | 結果 | 備考 |
|---|---|---|---|
| tools_call、initialize、request-metadata | 該当する版 | 合格 | `request-metadata` は roots / sampling / elicitation の宣言の 3 検査も実行される |
| auth/* (basic-cimd、metadata-default・var1〜3、scope-*、token-endpoint-auth-*、pre-registration、offline-access-*、authorization-server-migration、iss-*、2025-03-26 の 2 本) | 版ごとに 2〜25 本 | 合格 | `metadata-var2` は SDK の不具合 3 と 4 を直して合格 |
| auth/resource-mismatch、iss-wrong-issuer、iss-supported-missing、iss-unexpected、metadata-issuer-mismatch | 2026-07-28 | 合格 | クライアントは SDK の拒否 (`OAuthSecurityError`) を報告して終了コード 1。シナリオは拒否したことを確かめる |
| http-custom-headers、http-invalid-tool-headers | 2026-07-28 | 合格 | `x-mcp-header` が不正なツールは SDK が一覧から外す。有効なツールは呼べる |
| json-schema-2020-12-preservation、json-schema-ref-no-deref | 2025-11-25 以降 | 合格 | スキーマの往復は欠けなし。ネットワークの `$ref` は取りに行かない |
| sep-2322-client-request-state | 2026-07-28 | 合格 | `requestState` を変えずに返す、状態が無ければ付けない、id を変える |
| elicitation-sep1034-client-defaults | 2025-11-25 | 合格 | 検査用の同意の処理が既定値でフォームを埋める (SDK は埋めない: アプリケーションの役割) |
| sse-retry | 2025-11-25 | 合格 | |
| http-standard-headers | 2026-07-28 | 一部未実行 | 上の表 |

## SDK の不具合の疑い (`src/` は直していない)

今回の測定で見つけた 1 は、再現を添えて報告するだけにした (例外の型を足すので公開 API が変わる)。2〜5 は前回の記録で、この作業では確認も修正もしていない。

1. **認可が恒久的に失敗したことが、旧版のサーバーへの切り替えに隠れる。** 2026-07-28 のクライアントは、探り (`server/discover`) の送信が
   `McpTransportError` で失敗すると「旧版のサーバーが本体の無い応答で断った」とみなして `initialize` に切り替える (`src/client/client.nim` の
   `discover`)。認可のフックが恒久的な失敗を報告した場合も同じ型 (`authorization for URL failed: ...`、`src/transport/http.nim` の `post`) なので、
   切り替わり、利用者に見えるエラーは `initialize` の失敗になる。`auth/scope-retry-limit` (2026-07-28) で測定: 試行の上限を超えた探りのあと
   クライアントは `initialize` を送り (検査側は `MCP-Protocol-Version` が無いと 400)、最後のエラーは `ValueError: Initialization failed: Missing
   MCP-Protocol-Version header` で、本当の原因 (認可を繰り返しても 403 `insufficient_scope`) は出ない。検査自体は合格 (上限を超えて認可を
   試みない)。他の拒否のシナリオ (`resource-mismatch`、`iss-*`、`metadata-issuer-mismatch`) では、最後のエラーは本当の原因 (メタデータの不一致、`iss` の不一致など) を指していた (切り替えのあとの `initialize` も同じ理由で失敗するため、と推測するが、確認していない)。直すなら認可の失敗に専用の `McpTransportError` の派生型を与え、`discover` が再送出する。
   再現: `nim_conformance_client` を `MCP_CONFORMANCE_SCENARIO=auth/scope-retry-limit` で公式の検査に起動させる
   (`peers/run_conformance.py --builds 2026-07-28 --roles client`)。

2. **旧版の Python SDK のサーバー (1.8.1) に対し、`server/discover` の探りで接続できない。** 相手は未知のリクエストで
   終了する (公式の Python 2.x のクライアント `auto` も同じく `Connection closed` で失敗する) ので、相手側の都合。ただし
   Nim のクライアントは、相手が終了したあとの失敗を `ValueError: No handles or timers registered in dispatcher.` と
   報告する (直接実行で再現)。中継 (`tee_stdio.py`) を挟むと、45 秒待ってから時間切れになる。担当: client-core。
3. **debug ビルドでは、サーバーが返すエラー文に async のトレース (ローカルの絶対パス) が入る。** 例:
   `Failed to call tool: Unknown tool: x Async traceback: /Users/.../src/...`。`-d:release` では出ない (前回確認)。
   `e.msg` をそのまま応答に入れていることが原因。担当: server-core。
4. **自動判定のクライアントが、起動の遅い両対応のサーバー相手に、探りの応答を待たずに `initialize` を送ることがある。**
   負荷の高いマシンで 1 回だけ発生した (Python 2.3.0 のサーバー、stdio)。再現できていないので**未確認**。担当: client-core。
5. 未確認の観察: ポートの衝突で上流が応答しない状態の中継に、HTTP の Nim クライアントが `server/discover` を 45 秒で約 6000 回
   再送した (ログ上)。単純な「接続を閉じるサーバー」では再現せず、すぐ失敗する。再送の上限や間隔があるか確認が要る。

## 確かめていないこと

- 2024-11-05 の HTTP+SSE の適合性 (検査が無い)。相互接続は `interop-matrix-2026-10-06.md` で、25 行とも合格。
- 適合性テストの `--requirements 2026-07-28` (OAuth の資源サーバーとクライアントの必須セット)。
- 拡張のシナリオ (`list` が `extension` と表示する `auth/client-credentials-*`、`auth/dpop*`、`auth/wif-jwt-bearer`、`sep-2640-*` など): `--suite all` に入らず、この SDK のコアの外。tasks の拡張も同じ。
- 認可サーバー側のシナリオ: 対象外 (SDK は認可サーバーではない)。
- 変更したモジュールの変異検査: 実行していない。`docs/quality/g2-protocol-versions.md` の「未測定」に足した。
