# G1 仕様網羅: 表の読み方

[g1-spec-coverage.md](g1-spec-coverage.md) は `nimble specCoverage` の出力である (手で書き換えない)。
道具は `../nim-spec-coverage` で、`specs/*.feature` の `@spec:ID` を宣言として読み、`specs/tests.map`
(`ID | テストのファイル | テストの名前`) の行でテストと結ぶ (`--scenarios specs`、ADR-SPC-0001 の SCN-01〜06)。
系列ごとに仕様の数が違うので、表は系列 (本線、拡張、下書き) ごとに生成し直す。

## この表が言っていないこと

- **「外部仕様テスト (E) のある ID」ではない。** テストを E / I / 足場に分ける作業はまだで、`tests.map` が
  指すテストが外部仕様テストかどうかは確かめていない。表は「対応表に行があり、そのファイルが存在する ID」である。
- 行の名前のテストがそのファイルに実在するかは、道具ではなく `tests/test_spec_coverage.nim` が
  `nimble test` のたびに確かめる。
- 行のテストが、その Scenario の言う振る舞いを実際に確かめているかは、どちらでも分からない。

## 下書きの系列

`@unimplemented` の Scenario (実装が無く、テストを載せない決まりの宣言) も、道具はテストの無い宣言として数える。
下書きの系列では `MCP-DRAFT-EVENTS-38`〜`43` の 6 件がこれに当たり、`nimble specCoverage` は終了コード 1 で終わる。
未実装の宣言を分母から外すかどうかは決まっていない。

## どの仕様 ID にも結ばれていないテストのファイル

`test_auth_sha256.nim`、`test_docs_version.nim`、`test_features.nim`、`test_first_of.nim`、
`test_http_error_propagation.nim`、`test_silent_dead.nim`、`test_spec_coverage.nim` (2026-10-12、3 系列で同じ)。
E / I / 足場のどれに当たるかは分けていない。
