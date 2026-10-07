# G2 変異検出: auth_resource_server ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/auth_resource_server.json` (`src/auth/resource_server.nim`、`src/transport/auth_hook.nim`)、本線の 36a4c8a5 (2026-10-07)。
行番号は 36a4c8a5 のもの (`resource_server.nim` はその後変わっていない)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 42 | 28 | 0 | 12 | 0 | 2 |

生き残り 12 件: 同値 (1) 4 件、穴 (3) 8 件。ほかの分類は 0 件。
認可のサーバー側は安全に関わるコードなので、チャレンジの文面、トークンの長さの上限、検証器の失敗の扱いを変える変異は、1 件も許容に回していない。
分類 3 の 8 件は、変異を 1 件ずつ手で当てて、追加したテストが落ちることを確かめた。
同値の 4 件は、4 件をまとめて当てても `test_auth_resource_server.nim` が全部通ることを確かめた。
テストはすべて `tests/test_auth_resource_server.nim` にあり (ジョブの `testCommand` に既に入っている。ジョブの変更は無い)、
認可のある 4 つの版 (2025-03-26 / 2025-06-18 / 2025-11-25 / 2026-07-28) それぞれで通る。`-d:mcpDefaultProtocolVersion=2024-11-05` でもコンパイルでき、通る。
Scenario は仮の id `MCP-AUTH-g2e-auth-diag-1` と `-2` (リードが付け替える)。

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 / 検出するテスト |
|---:|---|---|---|---|---|
| 1 | resource_server.nim:93 | ROR | `config.scopesSupported.len > 0` → `>= 0` | 3 穴 | scope を設定しなければ、メタデータ文書に `scopes_supported` は載らない (変異後は空配列が載る)。`Given a configuration that lists no scopes, when the metadata document is made, then it has no scopes_supported` |
| 2 | resource_server.nim:99 | ROR | `error.len > 0` → `>= 0` | 3 穴 | トークンの無い要求への 401 は、資格情報を咎めないので `error` を持たない (RFC 6750 3.1。変異後は `error=""`)。`Given a request without a token ..., then the challenge names no error: there was no credential to fault` |
| 3 | resource_server.nim:101 | ROR | `description.len > 0` → `>= 0` | 3 穴 | `insufficient_scope` の 403 は説明を持たない (変異後は `error_description=""`)。`Given a token that lacks scope ..., then the challenge carries no empty description` (トークン無しの 401 のテストも落ちる) |
| 24 | resource_server.nim:102 | SDL | `params.add ("error_description", description)` → `discard` | 3 穴 | 拒んだトークンの 401 `invalid_token` は説明を持つ。`Given a token the verifier rejects ..., then the challenge explains the refusal` |
| 32 | resource_server.nim:113 | RVR | `return none(string)` → `return default` | 1 同値 | `Option[string]` の既定値が `none`。 |
| 33 | resource_server.nim:116 | RVR | 同上 | 1 同値 | 同上。 |
| 34 | resource_server.nim:119 | RVR | 同上 | 1 同値 | 同上。 |
| 5 | resource_server.nim:115 | ROR | `value.len <= 7` → `< 7` | 1 同値 | 長さがちょうど 7 (`"Bearer "`) の値は、変異後は次の検査へ進み、`value[7 .. ^1]` が空文字列になって、118 行の `token.len == 0` で `none` になる。長さ 7 未満は変異後も 115 行が止める。`"Bearer "` は既存テストの入力にも入っている。 |
| 9 | resource_server.nim:118 | ROR | `token.len > MaxTokenLength` → `>=` | 3 穴 | 上限は「これより長い」トークンを断る。8192 文字ちょうどは検証器に届き、8193 文字は届かない。`Given a token of 8192 characters and one of 8193 ..., then only the longer is refused before the verifier` (上限の値 `MaxTokenLength` は公開していないので、テストは 8192 を直に書く) |
| 30 | resource_server.nim:165 | SDL | 検証器が失敗したときの `stderr.writeLine` → `discard` | 3 穴 | 失敗は例外の型名だけを stderr に書き、トークンも例外の文面も書かない。`Given a verifier that fails ..., when a token arrives, then stderr names the failure and not the token` |
| 31 | resource_server.nim:183 | SDL | 書けない scope のときの `stderr.writeLine` → `discard` | 3 穴 | 検証器が返した scope がヘッダに書けない (制御文字) ときは、stderr に理由を書く。`Given a verifier that names a scope that cannot go in a header ..., then the answer is 500 without a challenge and stderr says why` |
| 41 | resource_server.nim:184 | RVR | `return answered(HttpServerAuthResponse(code: 500))` → `return default` | 3 穴 | 同じテスト。答えは 500 で、`WWW-Authenticate` を持たない (変異後は code が 0)。 |

## 残っているもの

何も残っていない。同値の 4 件 (id 32、33、34、5) は変異を当てても振る舞いが変わらないことを確かめた。
