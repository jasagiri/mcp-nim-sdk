# 公式の適合性テストの結果: 2026-10-06

対象のコミット: `feat(protocol): one table of which version has which feature` (5feb96d) の上に、
`tests/interop/` の適合性テスト用プログラムを足したもの。
道具: `@modelcontextprotocol/conformance` 0.2.0-alpha.12 (2026-07-28 のシナリオを含む)。
流し方は `tests/interop/README.md` の「公式の適合性テスト」。結果の生データは `peers/run_conformance.py` が
`build/interop-nim/conformance.{md,jsonl}` に書く。

## 読み方

- サーバー検査の対象は `tests/interop/nim_conformance_server.nim`。公式の「everything server」と同じ名前のツール・
  リソース・プロンプトのうち、**今の SDK の公開ハンドラで実現できるものだけ**を持つ (ツール 7、リソース 3 と
  テンプレート 1、プロンプト 4)。実現できないものは偽物を置かずに省いてあり、そのシナリオは落ちる。
- 「原因」の分類: **SDK** = SDK に機能が無い、**検査用** = 検査用サーバー/クライアントに名前や動作が無い (SDK の機能が
  無いために置けない場合は SDK も併記)、**不具合** = SDK の誤り、**設計** = 解釈が分かれる点。
- 「担当」は共通ブリーフの担当名。第 2 波になりそうなものは「第 2 波」と書いた。
- シナリオの状態は、その中の検査の最悪のもの。`warn` は SHOULD 違反など、`skipped` は一部の検査が実行されなかったもの。

## 結果の要約

| ビルド (仕様の版) | サーバー検査 合格 / 警告 / 不合格 (計) | クライアント検査 合格 / 未対応 / 一部未実行 (計) |
|---|---|---|
| 2026-07-28 (2026-07-28) | 20 / 3 / 16 (39) | 1 / 31 / 1 (33) |
| 2026-07-28 (2025-11-25) | 21 / 0 / 10 (31) | 1 (+`initialize` は情報のみ) / 17 / 0 (19) |
| 2025-11-25 | 21 / 0 / 10 (31) | 同上 |
| 2025-06-18 | 19 / 0 / 8 (27) | 1 (+`initialize`) / 3 / 0 (5) |
| 2025-03-26 | 1 / 0 / 0 (1) | 0 / 2 / 0 (2) |
| 2024-11-05 | 検査なし (この版のシナリオも HTTP+SSE の検査も無い) | 検査なし |

合格したサーバー検査 (2026-07-28 のビルド): tools-list、tools-call の simple-text / image / audio / embedded-resource /
mixed-content / error、json-schema-2020-12、resources-list / read-text / read-binary / templates-read、prompts-list と
get の 4 種、dns-rebinding-protection、input-required-result の unsupported-methods と validate-input。
2025-11-25 以前のビルドでは、これに ping、server-initialize、server-session-lifecycle が加わる
(2025-03-26 のビルドは server-session-lifecycle のみが対象)。

## サーバー検査の不合格と原因

下の表の「版」は、そのシナリオが落ちたビルド。同じ原因で複数の版に出るものは 1 行にまとめた。

| シナリオ | 版 | 症状 | 原因 | 担当 |
|---|---|---|---|---|
| completion-complete | 2025-06-18 以降すべて | `completion/complete` が Method not found | **SDK**: 補完の要求を振り分けていない。`completions` 能力の型も無い | server-core |
| logging-set-level | 2025-06-18, 2025-11-25 | `logging/setLevel` が Method not found | **SDK**: 振り分けが無い。`logging` 能力の型はあるが、`logging/setLevel` を処理しないので検査用サーバーは宣言していない | server-core |
| tools-call-with-logging | 2025-06-18, 2025-11-25 | 同上 (ツール呼び出しの前に `logging/setLevel` を送る) | **SDK**: 上と同じ。加えて、ツールのハンドラが通知を送る手段 (呼び出しの文脈) を受け取れない | server-core |
| tools-call-with-progress | 全版 | ツール `test_tool_with_progress` が無い | **SDK + 検査用**: ハンドラ `(name, arguments)` は要求の `_meta.progressToken` を見られず、進捗通知を送れないので、検査用サーバーにツールを置けない | server-core |
| resources-subscribe | 2025-06-18, 2025-11-25 | `resources/subscribe` が Method not found | **SDK**: `McpResourceHandlers` に `subscribeHandler` / `unsubscribeHandler` の欄はあるが、`handleStandardRequest` が振り分けていない (欄だけで動かない) | server-core |
| resources-unsubscribe | 同上 | 同上 (前提として subscribe を呼ぶ) | 同上 | server-core |
| tools-call-sampling | 2025-06-18, 2025-11-25 | ツール `test_sampling` が無い | **SDK + 検査用**: サーバー発の `sampling/createMessage` を送る API が無い | server-core (クライアント側の応答は client-core) |
| tools-call-elicitation | 同上 | ツール `test_elicitation` が無い | **SDK + 検査用**: サーバー発の `elicitation/create` を送る API が無い (2025-06-18 で導入) | server-core |
| elicitation-sep1034-defaults | 2025-11-25 | ツール `test_elicitation_sep1034_defaults` が無い | **SDK + 検査用**: 上と同じ。2025-11-25 の elicitation の拡張も未実装 | server-core |
| elicitation-sep1330-enums | 2025-11-25 | ツール `test_elicitation_sep1330_enums` が無い | 同上 | server-core |
| caching (1 検査) | 2026-07-28 | `resources/templates/list` が Method not found | **不具合**: `listTemplatesHandler` を登録しても振り分けていない。他 6 検査 (tools / prompts / resources の list、read、ttl、scope) は合格 | server-core |
| server-stateless (2 検査) | 2026-07-28 | `_meta` が無い要求と、`_meta` に protocolVersion が無い要求に `-32600` を返す。仕様 (basic/index.mdx) は `-32602` で、HTTP は 400 | **不具合/設計**: HTTP 400 は合っているが、コードが違う。要求に `_meta` が無いと HTTP サーバーが旧版の要求とみなし、`Mcp-Session-Id header is required` (`-32600`) で拒否する (curl で再現: `Mcp-Method` と `MCP-Protocol-Version: 2026-07-28` のヘッダ付きの `tools/list`)。時代を `_meta` の有無で決めており、`MCP-Protocol-Version` ヘッダが 2026-07-28 を指していても使っていない。ヘッダが 2026-07-28 なら `modern.nim` の検証 (`-32602`) に回すのが素直 | http-legacy (`http_server.nim`) と server-core |
| server-stateless (さらに 4 検査 `not testable`) | 2026-07-28 | `test_missing_capability` / `test_streaming_elicitation` / `test_logging_tool` を検査用サーバーが一覧に出していない | **SDK + 検査用**: 未宣言の client capability を要する処理の拒否 (`-32021`)、応答の stream に独立した要求を載せない規則、`logLevel` を無視する規則を試す診断ツール。SDK にこれらの機能が無く置けない | server-core |
| server-stateless (5 検査 `skipped`) | 2026-07-28 | `subscriptions/listen` 系 (確認応答、id の付与、通知の絞り込み、list_changed) が実行されない | **SDK**: `subscriptions/listen` が未実装 | 第 2 波 (server-core) |
| http-header-validation (1 検査) | 2026-07-28 | `Mcp-Name: "  test_simple_text  "` (前後の空白) を 400 `-32020` で拒否。仕様の検査は「HTTP は前後の空白 (OWS) を除くので受理すること」 | **不具合**: `decodeHeaderValue` が前後の空白を「不正」としている。ただし `tests/test_modern_protocol.nim:263` が ` padded` は `isNone` と固定しているので、**意図した挙動と検査の解釈が衝突**している。送信側の符号化 (空白で始まる値は base64) は正しいので、直すなら受け取る側 (`http_server.nim`) で OWS を除いてから復号する。1〜2 行ではなく、既存テストの意味を変えるので直していない | http-legacy (`http_server.nim`) と、`modern.nim` の持ち主 |
| http-custom-header-server-validation (5 検査) | 2026-07-28 | `x-mcp-header` を持つツールが無く「検査不能」 | **SDK**: `x-mcp-header` と `Mcp-Param-*` が未実装 (`src/transport/http.nim` に TODO)。`features.nim` の `ftParameterHeaders` はある | 第 2 波 (http-legacy / server-core) |
| input-required-result-* (basic-elicitation / basic-sampling / basic-list-roots / request-state / multiple-input-requests / multi-round / non-tool-request / result-type / tampered-state / capability-check の 10 本が不合格、missing-input-response と ignore-extra-params が警告) | 2026-07-28 | 診断ツール `test_input_required_result_*` が無い | **SDK**: SEP-2322 の InputRequiredResult (複数ラウンドの要求) が未実装。ハンドラの返り値の型に載せる方法も無い | 第 2 波 (server-core) |
| sep-2164-resource-not-found (警告) | 2026-07-28 | 存在しない URI の `resources/read` の誤りに `data.uri` が無い (SHOULD) | **SDK**: `-32602` は合格。`data: {uri}` を付けていない | server-core |

合格を妨げていない補足: `server-sse-multiple-streams` は情報のみ (複数の stream を張るシナリオ。SDK は 1 要求 1 応答で動く)。

## クライアント検査

`nim_conformance_client` が実行するのは `initialize`、`tools_call`、`request-metadata` の 3 つで、残りは
「この SDK のクライアントに機能が無い」と stderr に出して終了コード 2 で断る (偽の成功を作らない)。
結果は `unsupported`。

| シナリオ | 版 | 結果 | 備考 |
|---|---|---|---|
| tools_call | 2025-06-18 以降 | 合格 | 接続して `add_numbers` を呼ぶ |
| initialize | 2025-06-18, 2025-11-25 | 合格 (検査は情報のみ) | |
| request-metadata | 2026-07-28 | 一部未実行 | 5 検査合格。roots / sampling / elicitation の capability を宣言する 3 検査は、クライアントがそれらの機能を持たないので実行されない (client-core) |
| auth/* (basic-cimd、metadata-default・var1〜3、scope-*、token-endpoint-auth-*、pre-registration、resource-mismatch、offline-access-*、authorization-server-migration、iss-*、metadata-issuer-mismatch) | 2025-03-26 以降の版ごとに 2〜25 本 | 未対応 | OAuth のクライアントが無い | auth |
| http-standard-headers、http-custom-headers、http-invalid-tool-headers | 2026-07-28 | 未対応 | `x-mcp-header` と `Mcp-Param-*` が未実装。`http-invalid-tool-headers` は「呼んではならない」検査 11 が、何もしないので合格に見えるが、`tools/list` を要求する 2 検査は落ちる | 第 2 波 (client-core / http-legacy) |
| json-schema-ref-no-deref、json-schema-2020-12-preservation | 2025-11-25 以降 | 未対応 | クライアントが `tools/list` のスキーマを扱う検査用の動作が無い。SDK 側の保持は未確認 | client-core |
| sep-2322-client-request-state | 2026-07-28 | 未対応 | InputRequiredResult の requestState をクライアントが返す機能が無い | 第 2 波 (client-core) |
| elicitation-sep1034-client-defaults | 2025-11-25 | 未対応 | クライアントに elicitation の応答機能が無い | client-core |
| sse-retry | 2025-11-25 | 未対応 | SSE の `retry` と Last-Event-ID での再接続 | http-legacy / client-core |

## 相互接続の確認で見つけた、SDK の不具合の疑い (`src/` は直していない)

1. **旧版の Python SDK のサーバー (1.8.1) に対し、`server/discover` の探りで接続できない。** 相手は未知のリクエストで
   終了する (公式の Python 2.x のクライアント `auto` も同じく `Connection closed` で失敗する) ので、相手側の都合。ただし
   Nim のクライアントは、相手が終了したあとの失敗を `ValueError: No handles or timers registered in dispatcher.` と
   報告する (直接実行で再現)。中継 (`tee_stdio.py`) を挟むと、45 秒待ってから時間切れになる。原因の説明になる文言に
   するか、transport の終了を `initialize` の待ち受けに伝えるべき。再現: `build/interop-nim/2026-07-28/nim_client stdio
   <env>/old/py-1.8.1/.venv/bin/python <env>/py/py1_server.py stdio`。担当: client-core。
2. **debug ビルドでは、サーバーが返すエラー文に async のトレース (ローカルの絶対パス) が入る。** 例:
   `Failed to call tool: Unknown tool: x Async traceback: /Users/.../src/...`。`-d:release` では出ない (確認済み)。
   `e.msg` をそのまま応答に入れていることが原因。クライアントに見える文言にパスが混ざるのは情報の漏れなので、
   `e.msg` の整形か、トレースを切り落とす処理が要る。担当: server-core。
3. **自動判定のクライアントが、起動の遅い両対応のサーバー相手に、探りの応答を待たずに `initialize` を送ることがある。**
   負荷の高いマシンで 1 回だけ発生した (Python 2.3.0 のサーバー、stdio): `server/discover` のあと応答が来る前に
   `initialize` を送り、サーバーが探りに答えたあと `initialize` を `-32022` で拒否して失敗した。探りの時間切れが短い
   疑いがあるが、再現できていない (再実行では常に成立) ので**未確認**。担当: client-core。
4. 未確認の観察: ポートの衝突で上流が応答しない状態の中継に、HTTP の Nim クライアントが `server/discover` を 45 秒で約 6000 回
   再送した (ログ上)。単純な「接続を閉じるサーバー」では再現せず、すぐ失敗する。再送の上限や間隔があるか確認が要る。
   担当: http-legacy / client-core。

`src/` は変更していない。共通ブリーフの「1〜2 行で直る明白な誤り」に当たるものは見つからなかった
(上の `decodeHeaderValue` は既存のテストと衝突するので直していない)。

## 確かめていないこと

- 2024-11-05 の HTTP+SSE の適合性 (検査が無い)。
- 適合性テストの `--requirements 2026-07-28` (OAuth の資源サーバーとクライアントの必須セット)。auth の仕事が入ってから流す。
- 拡張のシナリオ (tasks、skills、auth の extension): この SDK の対象外。
- 認可サーバー側のシナリオ: 対象外 (SDK は認可サーバーではない)。
