# G2 変異検出: version ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/version.json`、本線の 36a4c8a5 (2026-10-07)。対象は `src/protocol/version.nim`。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 23 | 14 | 0 | 5 | 0 | 4 |

ジョブは既定版 2024-11-05 / 2025-03-26 / 2025-06-18 / 2025-11-25 と `-d:mcpOldestProtocolVersion=2026-07-28` でテストを流す。
生き残りは、どの版の組み合わせでも落ちない (下の表の理由) ものだけで、別の既定版・下限版でだけ検出される変異は無かった。

追加したテスト: `tests/test_version_build_config.nim` (仕様 ID `MCP-VERSION-10`、リードが採番し直す)。
一行のプログラムを `nim check` で検査し、未公開の版や、下限が既定より新しい組み合わせでビルドが止まり、どの設定が誤りかを名指すことを確かめる。ジョブの `testCommand` に追記した。

| id | file:line | 変異 | 元 → 変異後 | 分類 | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 16 | version.nim:34 | SDL | `parseProtocolVersion` の末尾の `none(McpProtocolVersion)` を `discard` に | 1 同値 | `result` は `Option` の既定値で、それは `none`。 |
| 17 | :39 | SDL | 既定版の `doAssert parsed.isSome, …` を `discard` に | 3 穴 | 消しても次の `parsed.get` がコンパイル時に `UnpackDefect` で止まるので、ビルドが止まること自体は同じ。違うのは、どの設定が誤りかを名指す文面。`tests/test_version_build_config.nim` の `Given a default version that was never released, …` が文面を確かめる。 |
| 18 | :46 | SDL | 下限版の同じ `doAssert` を `discard` に | 3 穴 | 同じ。`Given an oldest version that was never released, …` |
| 19 | :49 | SDL | `doAssert parsed.get <= DefaultProtocolVersion, …` を `discard` に | 3 穴 | 消すと、下限が既定より新しい (話す版が 1 つも無い) ビルドがコンパイルできてしまう。`Given an oldest version newer than the default, …` |
| 9 | :83 | ROR | `latestLegacyVersion` の `v > result.get` → `>=` | 1 同値 | 差が出るのは `v` が今の `result` と等しいときだけで、そのとき `result = some(v)` は同じ値の再代入。`supported` に重複があっても結果は変わらない。 |

compileError の 4 件は、型が合わず測定の対象にならない変異。

## 残っているもの

なし。
