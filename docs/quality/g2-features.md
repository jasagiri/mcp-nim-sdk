# G2 変異検出: features ジョブ

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
