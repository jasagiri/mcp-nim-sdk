# G2 変異検出: utf8 ジョブ

測定: nim-muter 0.2.15、ジョブ `tests/mutation/utf8.json`、拡張ブランチの 654cb11a (2026-11-14)。
対象は `src/compat/utf8.nim`。UTF-8 の検査が `src/transport/transport.nim` から移ったあと、どのジョブも対象にしていなかったので足した。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 17 | 12 | 1 | 4 | 0 | 0 |

## 生き残り (司会が読んで仕分けた)

| 指紋 | 場所 | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/compat/utf8.nim:ROR:b273926411ebde1d:0` | utf8.nim:16 | `at >= text.len` → `>` | unreached | 差が出るのは `at == text.len` で呼ばれたときだけ。呼び手は `isUtf8` と `diagnostic.nim` の 2 つで、どちらも `i < text.len` の輪の中から呼ぶ。モジュールは SDK の内部で、公開の入口から `at` を選べない | — |
| `src/compat/utf8.nim:RVR:7018026ff64ed67b:0` | utf8.nim:17 | `return 0` → `return default` | equivalent | `int` の既定値は 0 | — |
| `src/compat/utf8.nim:AOR:da3355fa56ef9180:0` | utf8.nim:33 | `at + width` → `at - width` | test_owed | 輪が空になり、3 バイト目・4 バイト目が継続バイトかを確かめなくなる。既存の入力は 2 バイト目までで断られるものだけだった | MCP-STDIO-9・MCP-HTTP-43。`NotUtf8` に 3 バイト目・4 バイト目が継続バイトでない並びを足した (変異を手で当てて、テストが落ちることを確かめた) |
| `src/compat/utf8.nim:RVR:7018026ff64ed67b:2` | utf8.nim:35 | `return 0` → `return default` | equivalent | `int` の既定値は 0 | — |
