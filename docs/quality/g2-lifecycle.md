# G2 変異検出: `src/protocol/lifecycle.nim`

測定: `nim-muter`、ジョブ `tests/mutation/lifecycle.json` (対象は `lifecycle.nim` と `types.nim`、この記録は `lifecycle.nim` の分)、mainline の 36a4c8a5 (2026-10-07)。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 31 | 18 | 0 | 10 | 0 | 3 |

## survived 10 件

分類は、1 = 同値、3 = 穴 (新しい外部仕様テストを足した)。
クラス 3 の行は、変異を手で当てて `tests/test_legacy_handshake.nim` が落ちることを確かめた (変異 1 件ごとにテスト 1 回、当てたあとファイルは戻した)。
戻り値を既定値にする変異のうち、`JsonRpcNotification` は `params` が nil になり、テストが nil 参照で異常終了する (これも検出として数える)。

| id | file:line | mutator | 変異 | class | 理由 / 検出するテスト |
|---|---|---|---|---|---|
| 2 | lifecycle.nim:29 | ROR | `requests.len > 0` → `>= 0` | 3 | 要求の種類を何も支えない tasks capability に、空の `requests` が付く。`Given a tasks capability that supports list only, when written, then it declares no requests` |
| 24 | lifecycle.nim:36 | RVR | `return none(McpTasksCapability)` → 既定値 | 1 | `Option` の既定値は none で、元の戻り値と同じ。 |
| 25 | lifecycle.nim:109 | RVR | `return none(JsonNode)` → 既定値 | 1 | 同上。 |
| 27 | lifecycle.nim:175 | RVR | `createInitializedNotification` の戻り値 → 既定値 | 4 | 呼び出し元の無い補助関数だった。関数ごと削除した (下記)。 |
| 28 | lifecycle.nim:178 | RVR | `isPingRequest` → 既定値 (false) | 4 | 呼び出し元の無い補助関数だった。関数ごと削除した (下記)。 |
| 10 | lifecycle.nim:178 | ROR | `== "ping"` → `!= "ping"` | 4 | 呼び出し元の無い補助関数だった。関数ごと削除した (下記)。 |
| 11 | lifecycle.nim:188 | ROR | `reason.len > 0` → `>= 0` | 4 | 呼び出し元の無い補助関数だった。関数ごと削除した (下記)。 |
| 30 | lifecycle.nim:191 | RVR | `createCancelledNotification` の戻り値 → 既定値 | 4 | 呼び出し元の無い補助関数だった。関数ごと削除した (下記)。 |
| 12 | lifecycle.nim:202 | ROR | `message.len > 0` → `>= 0` | 4 | 呼び出し元の無い補助関数だった。関数ごと削除した (下記)。 |
| 31 | lifecycle.nim:205 | RVR | `createProgressNotification` の戻り値 → 既定値 | 4 | 呼び出し元の無い補助関数だった。関数ごと削除した (下記)。 |

## 追加したテストと仕様

- `tests/test_legacy_handshake.nim` に suite `lifecycle messages: wire forms` を追加 (8 件)。`specs/tests.map` の MCP-TASKS-1、MCP-LIFECYCLE-3、MCP-LIFECYCLE-4、MCP-CANCEL-4、MCP-PROGRESS-1 の行に足した。
- `tests/mutation/lifecycle.json` の `testCommand` は変更なし (`test_legacy_handshake` を全版で既に含む)。
- 新しいテストは版に依存しない。デフォルト版 2024-11-05 でも通ることを確かめた。

## 残っているもの

- 同値 (id 24, 25) は上表の理由のとおり。
- クラス 4: `createInitializedNotification`、`isPingRequest`、`createCancelledNotification`、`createProgressNotification` は公開されていたが、SDK、examples、相互接続の道具、下流のどこからも呼ばれていなかった (client と server は通知を自分で組み立てる)。使われないコードをテストで支えるのをやめ、関数と、そのためだけに足したテスト 6 件を削除した (id 27, 28, 10, 11, 30, 12, 31)。
- 他に未決のものはない。
