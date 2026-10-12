# G1 仕様網羅

測定: 2026-10-12、Nim 2.2.12。

## nim-spec-coverage では確かめていない

`../nim-spec-coverage/bin/spec_coverage . --tests tests` は終了コード 2 で止まる:

```
no ADR found under <root>/docs/adr
```

この道具が読むのは `docs/adr/*.md` の `- **ABC-01** …` の宣言と、テストの `# SPEC: ABC-01` の
タグだけである。このリポジトリは仕様を `specs/*.feature` の Scenario に `@spec:MCP-…` で宣言し、
テストとの対応を `specs/tests.map` (`ID | テストのファイル | テストの名前`) に持つ
(`specs/README.md`)。`docs/adr/` は無く、`# SPEC:` のタグを持つテストのファイルは 0 本である。

形を道具に合わせて揃えるか、道具に Scenario の形を読ませるかは決まっていない。決まるまで、
**nim-spec-coverage による仕様網羅は確かめていない**。

## リポジトリ自身の対応表で数えたもの

`specs/*.feature` の `@spec:` と `specs/tests.map` の 1 列目を突き合わせた。
同じ突き合わせを `tests/test_spec_coverage.nim` が `nimble test` のたびに行い、加えて
`tests.map` の名前のテストがそのファイルにあることを確かめる (3 先端とも通過)。

| 先端 | コミット | `.feature` | 宣言された ID | 対応するテストのある ID | 無い ID | `tests.map` の行 | 対応表に出るテストのファイル |
|---|---|---:|---:|---:|---:|---:|---:|
| 本線 (`2026-07-28`) | d6be71894897 | 27 | 467 | 467 | 0 | 1812 | 81 / 88 |
| 拡張 (`mcp-2026-07-28-ext`) | 1fc2f4e8e43f | 31 | 541 | 541 | 0 | 2323 | 102 / 109 |
| 下書き (`mcp-draft`) | 287974bf660f | 37 | 667 | 661 | 6 | 2939 | 124 / 131 |

- ID の重複、ID の無い Scenario、宣言の無い ID を指す行は、どの先端にも無い。
- ファイルの数は `tests/test_*.nim` (直下)。`tests/` の下の `.nim` は下書きの先端で 148 本ある
  (補助、変異検査の設定の相手役などを含む)。

### テストの無い ID (下書きの先端だけ)

6 件とも `specs/draft_events.feature` で `@unimplemented` を付けた Scenario で、実装が無い。

| ID | Scenario |
|---|---|
| MCP-DRAFT-EVENTS-38 | events/poll can wait for events (waitMs) |
| MCP-DRAFT-EVENTS-39 | Deliveries can carry a server identity signature (v1a) |
| MCP-DRAFT-EVENTS-40 | A callback can be verified by a receiver-published well-known document |
| MCP-DRAFT-EVENTS-41 | An event type can be backed by a durable upstream through a check function |
| MCP-DRAFT-EVENTS-42 | A webhook subscription can be granted no expiry and kept across restarts |
| MCP-DRAFT-EVENTS-43 | A server announces capabilities.events to clients of older versions |

### 対応表に出ないテストのファイル (3 先端で同じ 7 本)

`test_auth_sha256.nim`、`test_docs_version.nim`、`test_features.nim`、`test_first_of.nim`、
`test_http_error_propagation.nim`、`test_silent_dead.nim`、`test_spec_coverage.nim`。
どの仕様 ID にも結ばれていない。E / I / 足場のどれに当たるかは分けていない。

## この数字が言っていないこと

- **「E テストのある ID」ではない。** テストを E / I / 足場に分ける作業はまだで、`tests.map` が
  指すテストが外部仕様テストかどうかは確かめていない。上の表は「対応表に行があり、その名前の
  テストが存在する ID」の数である。
- 対応表の行が、その Scenario の言う振る舞いを実際に確かめているかは、この突き合わせでは
  分からない (行と名前の存在だけを見る)。
