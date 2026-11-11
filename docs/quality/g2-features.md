# G2 変異検出: features ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/features.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。状態: 測定済み。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 8 | 0 | 0 | 8 | 0 | 0 |

ジョブの testCommand (`test_version`・`test_legacy_handshake`・`test_era_matrix` を 5 つの既定の版で) は、版の交渉だけを確かめ、機能の表 (`has`) の答えで分かれる振る舞いをほとんど通らない。`test_era_matrix` が 2026-07-28 で `ping`・`logging/setLevel`・`resources/subscribe` を断ることを見ているが、そのサーバーは logging も subscribe も宣言しておらず、`has` の答えに関わらず断られる。

`tests/external/` の多くのテストは、期待する側を `versionsWith(ft…)`・`versionsWithout(ft…)` (`server_harness.nim`) や `v.has(ft…)` で作っている。これらは変異した `has` を期待の側でも使うので、表の変異とは食い違わず、検出しない。検出するのは、版を定数 (`mpv20251125` など) で書いて結果を決め打ちしているテストだけである。下の案はその条件で選んだ。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/protocol/features.nim:BLR:fd541d232acef4ff:0` | features.nim:104 | `forever()` の `present: false` → `true` | test_owed | `until` が「在る、版は既定値の 2024-11-05」になり、`version < 2024-11-05` はどの版でも偽なので、終わりの無い機能 (`ftTools`・`ftSamplingTools`・`ftElicitation` など) がすべての版で「無い」になる。例: `ftSamplingTools` が 2025-11-25 と 2026-07-28 で無くなる。 | MCP-SAMPLING-TOOLS-1。既存の `tests/external/test_sampling_tools_payload.nim` の `Given tools and a tool choice, when the request is checked in 2025-11-25 and later, then there is nothing to report` が検出するはず (変異だと `tools` が問題として報告され `len == 0` が落ちる)。testCommand に足す。 |
| `src/protocol/features.nim:BLR:c7f595570f3a2986:0` | features.nim:107 | `before(v)` の `present: true` → `false` | test_owed | 終わりのある機能が終わらなくなる。例: `ftTasks` が 2026-07-28 で、`ftJsonRpcBatch`・`ftAuthDefaultEndpoints` が 2025-06-18 以降で、`ftHttpSessions`・`ftPing` が 2026-07-28 で「在る」になる。 | MCP-TASKS-2。既存の `tests/external/test_tasks_server.nim` の `Given a 2026-07-28 request, when the server describes itself, then tasks are not declared` が検出するはず (変異だと `server/discover` の capabilities に `tasks` が残る)。同じ suite の `…when it calls tasks/get, tasks/result, tasks/list or tasks/cancel, then the method is unknown` も落ちるはず。既定の版が 2026-07-28 のビルドでだけ走る suite。testCommand に足す。 |
| `src/protocol/features.nim:ROR:12ca2a82fc644ed8:0` | features.nim:158 | `version >= s.since` → `>` | test_owed | 機能が始まった版ちょうどで「無い」になる。例: `ftSamplingTools` と `ftTasks` が 2025-11-25 で、`ftElicitation` が 2025-06-18 で、`ftAuthorization` が 2025-03-26 で無くなる。 | MCP-SAMPLING-TOOLS-1。既存の `tests/external/test_sampling_tools_payload.nim` の `Given tools and a tool choice, when the request is checked in 2025-11-25 and later, then there is nothing to report` が検出するはず (`WithTools` は始まった版ちょうどの `mpv20251125` を定数で含む)。MCP-TASKS-1 の `test_tasks_server.nim` の `Given tasks enabled, when a 2025-11-25 client handshakes, then the server declares list, cancel and tools/call` も落ちるはず。testCommand に足す。 |
| `src/protocol/features.nim:LOR:56840ae9a1303474:0` | features.nim:158 | `version >= s.since and (…)` → `or` | test_owed | 終わりの無い機能は、始まる前の版でも「在る」になる (右辺が常に真)。終わりのある機能は、始まる前の版と終わった後の版で「在る」になる。例: `ftSamplingTools` が 2025-06-18 以前で、`ftTasks` が 2025-06-18 以前と 2026-07-28 で在ることになる。 | MCP-SAMPLING-TOOLS-2。既存の `tests/external/test_sampling_tools_payload.nim` の `Given tools or a tool choice, when checked in 2025-06-18, then the field is reported` が検出するはず (変異だと 2025-06-18 で `tools` が報告されない)。MCP-TASKS-2 の `test_tasks_server.nim` の `Given a client of an older version, when it calls tasks/get, then the method is unknown` (2025-06-18 を定数で使う) も落ちるはず。testCommand に足す。 |
| `src/protocol/features.nim:LOR:6c550e70d3915cd6:0` | features.nim:158 | `not s.until.present or version < s.until.version` → `and` | test_owed | 終わりのある機能は `not present` が偽で、終わりの無い機能は `version < 2024-11-05` (既定値) が偽なので、`has` がどの機能・どの版でも偽を返す。例: `ftSamplingTools` が 2025-11-25 で、`ftTasks` が 2025-11-25 で無くなる。 | MCP-SAMPLING-TOOLS-1。既存の `tests/external/test_sampling_tools_payload.nim` の `Given tools and a tool choice, when the request is checked in 2025-11-25 and later, then there is nothing to report` が検出するはず。testCommand に足す。 |
| `src/protocol/features.nim:ROR:818cc11b5bfbb09f:0` | features.nim:158 | `version < s.until.version` → `<=` | test_owed | 機能が終わった版ちょうどで「在る」になる。例: `ftTasks`・`ftHttpSessions`・`ftPing`・`ftResourceSubscribe` が 2026-07-28 で、`ftJsonRpcBatch`・`ftAuthDefaultEndpoints` が 2025-06-18 で在ることになる。 | MCP-TASKS-2。既存の `tests/external/test_tasks_server.nim` の `Given a 2026-07-28 request, when the server describes itself, then tasks are not declared` が検出するはず (`ftTasks` が終わる版ちょうどの `mpv20260728` を定数で使う)。既定の版が 2026-07-28 のビルドでだけ走る。testCommand に足す。 |
| `src/protocol/features.nim:SDL:ec5c33aa9b5418dc:0` | features.nim:163 | `result.add feature` → `discard` | spec_question | `featuresOf` が常に空の列を返す。`mcp` が `features` を丸ごと export するので公開の入口から違いは見えるが、`src/` の中に呼び手は無く、使うのは `tools/gen_docs.nim` (文書の生成) と `tests/internal/test_features.nim` だけ。`specs/*.feature` にこの関数の振る舞いを定める仕様 ID は無い。 | 代表への問い: `featuresOf` を公開 API の仕様にして仕様 ID と E テストを足しますか、それとも文書を作る道具の部品として `tools/` の側へ移し (2026-10-13 に `implementation_status.nim` を対象から外したのと同じ扱い)、ジョブの対象から外しますか。 |
| `src/protocol/features.nim:ROR:b4abacca4aebefdf:0` | features.nim:237 | `specPage` の `version >= mpv20260728` → `>` | spec_question | 2026-07-28 が最新の版なので `modern` が常に偽になり、`specPage(ftStdio, mpv20260728)` が `basic/transports/stdio` ではなく `basic/transports` を返すなど、2026-07-28 のページが旧版のページになる。公開の入口から違いは見えるが、`src/` の中に呼び手は無く、使うのは `tools/gen_docs.nim` と `tests/internal/test_features.nim` だけ。仕様 ID は無い。 | 代表への問い: `specPage` (仕様書のページの対応) を公開 API の仕様にして仕様 ID と E テストを足しますか、それとも `featuresOf` と一緒に文書を作る道具の側へ移してジョブの対象から外しますか。 |

### testCommand に足すファイルの案

- `tests/external/test_sampling_tools_payload.nim` (純粋な関数のテストで、通信も待ちも無い。既定の版 1 回で足りる): 104 行の BLR、158 行の `>=` → `>`、`and` → `or`、`or` → `and` の 4 件。
- `tests/external/test_tasks_server.nim` (既定の版が 2026-07-28 のビルドで 1 回): 107 行の BLR と 158 行の `<` → `<=` の 2 件。上の 4 件のうち 104 行の BLR を除く 3 件も、このファイルで重ねて検出するはず。
- 境界の 2 件は、どちらも 1 つの機能でしか確かめられない (始まりちょうどは `ftSamplingTools`・`ftTasks` の 2025-11-25、終わりちょうどは `ftTasks` の 2026-07-28)。式は全機能で共通なので変異の検出には足りるが、表の各行 (`span` の `case`) の正しさを確かめるものではない。
- どちらのファイルも、変異したコードで実際に流してはいない (仕分けは読んで行う)。検出は次の測定で確かめる。

測定: `nim-muter`、ジョブ `tests/mutation/features.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/protocol/features.nim` と `src/protocol/implementation_status.nim`。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 58 | 8 | 0 | 1 | 0 | 49 |

compileError の 49 件は、機能表 (`McpFeature` の列挙、`span`・`displayName`・`specPage` と `implementation_status.nim` の `case`) の変異で、
`case` が網羅的でなくなる、または型が合わなくなるためコンパイルできない。変異として成立しないので測定の対象にならない。

| id | file:line | 変異 | 元 → 変異後 | 分類 | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 4 | features.nim:264 | ROR | `specPage(ftHttpSse, …)` の `version == mpv20241105` → `!=` | 3 穴 | 差が出るのは 2026-07-28 だけ。元は `elif modern` の枝で `basic/transports/streamable-http`、変異後は最初の枝で `basic/transports`。他の版は、どちらの式でも `basic/transports`。`tests/test_features.nim` の `Given HTTP+SSE, when the page of each version is asked, …` が全版のページを確かめる。 |

## 残っているもの

- 分類 4 (リードの判断、2026-10-07): `ftHttpSse` の `specPage` の最初の枝 (`if version == mpv20241105: "basic/transports"`) は最後の `else` と同じ値を返す冗長な枝だったので削除した。
  旧版の分岐をそのまま残したのか、2025-03-26 以降で別のページを想定していたのかは、コードからは分からないので消していない。
  消すなら `if modern: … else: "basic/transports"` になり、この枝の変異は次の測定から無くなる。

## 2026-10-13: ジョブを外部仕様テストで組み直した (未測定)

テストを置き場で分けた結果、このジョブが走らせていた `test_features` と `test_spec_coverage` は内部実装テスト (文書と表の整合を見る門) になった。変異検査は外部仕様テストだけで測る (ADR-MUTER-0004 §3.1) ので、ジョブを、版の交渉を確かめる外部仕様テスト (`test_version`、`test_legacy_handshake`、`test_era_matrix`) を 5 つの版の既定で流す形に組み直した。対象から `src/protocol/implementation_status.nim` を外した: 文書を作る道具の表で、利用者から見える振る舞いが無く、外部仕様テストでは測れない。

**この組み直しのあとは未測定。** 上の記録は、組み直す前のジョブでの測定である。機能の表 (`features.nim`) の 1 行を誤らせる変異を、版の交渉のテストがどこまで捕まえるかは、測ってみないと分からない。

## 文書用の関数を分けた (2026-11-11)

`featuresOf`・`displayName`・`specPage` は `src/protocol/feature_docs.nim` に移し、`mcp` の公開から外した (代表の方針 2026-11-11「公開APIはできるだけ絞ったほうが良い」「役割が明確になるように適切に分割」)。使うのは `tools/gen_docs.nim` と内部テスト (`tests/internal/test_features.nim`・`tests/internal/test_docs_version.nim`) だけで、プロトコルを話すプログラムは `version.has(feature)` を使う。このジョブの対象 `src/protocol/features.nim` からこの 3 つが無くなるので、spec_question の 2 件 (`featuresOf` の SDL、`specPage` の ROR) は測り直しで消える。`feature_docs.nim` は公開の仕様を持たないので G2 のジョブには入れず、内部テストで守る。
