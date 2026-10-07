# G2 変異検出: server ジョブ、server.nim 以外のファイル

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5 (2026-10-07)。担当は `resources.nim`、`prompts.nim`、`pagination.nim`、`completion.nim`、`log_level.nim`。`server.nim` は別の記録 (リードが `g2-server.md` にまとめる)。

| ファイル | survived | killed | compileError |
|---|---:|---:|---:|
| `src/server/resources.nim` | 56 | 0 | 0 |
| `src/server/prompts.nim` | 4 | 0 | 0 |
| `src/server/pagination.nim` | 6 | 8 | 3 |
| `src/server/completion.nim` | 3 | 14 | 0 |
| `src/protocol/log_level.nim` | 1 | 2 | 0 |

runError はない。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 6 |
| 2 ジョブに無い既存のテストが検出 | 0 |
| 3 穴 (テストを追加) | 4 |
| 4 到達しない・冗長なコード | 60 |
| 5 欠陥 | 0 |
| 6 許容 | 0 |

分類 3 の 4 件は、変異を手で当てて、追加したテストだけが落ちる (または異常終了する) ことを確かめた。分類 1 は式から読んだ。

## resources.nim と prompts.nim: 1 件も検出されなかった理由

どちらのモジュールも、SDK のどこからも import されていない。`src/`、`examples/`、`tests/`、`docs/`、`templates/`、下流の `build/ws/ds-*/src`、`products/*/src` を、エクスポートされた全 proc 名 (`createResourceInfo`、`detectMimeType`、`readFileAsResource`、`createPromptInfo`、`createTextContent` ほか) で検索して、定義以外の出現は 0 件だった。`src/mcp.nim` が import するのは `client/resources` と `client/prompts` で、サーバー側の同名ファイルではない。サーバーの resources / prompts は `server.nim` のハンドラ経由で動いていて、これらのヘルパーを使わない。

変異したコードはどのテストのコンパイルにも入らないので、テストが何であっても変異は検出されない。さらに `resources.nim` は**コンパイルできない**: 173 行の `pattern \!= "*"` に余計なバックスラッシュがあり、`Error: undeclared identifier: '\!='` になる (単独でコンパイルして確認した)。`prompts.nim` は通るが、未使用 import の警告が 3 件 (`asyncdispatch`、`options`、`sequtils`) 出る。使われていないので表に出なかった。

テストは書かない (死んだコードのテストは何も守らない)。リードの判断を待つ。提案は、2 ファイルを削除し、`tests/mutation/server.json` の `sources` から外すこと。

## 分類 4: resources.nim と prompts.nim の 60 件

理由はすべて同じ (上の節): どこからも import されず、`resources.nim` はコンパイルもできない。

| id | file:line | mutator | 変異 |
|---|---|---|---|
| 4 | `server/prompts.nim:11` | ROR | `arguments.len > 0` → `<> -> >=>` |
| 7 | `server/prompts.nim:14` | BLR | `false` → `true` |
| 5 | `server/prompts.nim:20` | ROR | `description.len > 0` → `<> -> >=>` |
| 6 | `server/prompts.nim:28` | ROR | `description.len > 0` → `<> -> >=>` |
| 447 | `server/resources.nim:11` | ROR | `description.len > 0` → `<> -> >=>` |
| 448 | `server/resources.nim:14` | ROR | `mimeType.len > 0` → `<> -> >=>` |
| 449 | `server/resources.nim:17` | ROR | `size >= 0` → `<>= -> >>` |
| 450 | `server/resources.nim:40` | ROR | `description.len > 0` → `<> -> >=>` |
| 451 | `server/resources.nim:43` | ROR | `mimeType.len > 0` → `<> -> >=>` |
| 452 | `server/resources.nim:46` | ROR | `arguments.len > 0` → `<> -> >=>` |
| 461 | `server/resources.nim:49` | BLR | `false` → `true` |
| 453 | `server/resources.nim:55` | ROR | `description.len > 0` → `<> -> >=>` |
| 464 | `server/resources.nim:63` | RVR | `return "text/plain"` → `<return default>` |
| 465 | `server/resources.nim:65` | RVR | `return "text/markdown"` → `<return default>` |
| 466 | `server/resources.nim:67` | RVR | `return "text/html"` → `<return default>` |
| 467 | `server/resources.nim:69` | RVR | `return "text/css"` → `<return default>` |
| 468 | `server/resources.nim:71` | RVR | `return "application/javascript"` → `<return default>` |
| 469 | `server/resources.nim:73` | RVR | `return "application/json"` → `<return default>` |
| 470 | `server/resources.nim:75` | RVR | `return "application/xml"` → `<return default>` |
| 471 | `server/resources.nim:77` | RVR | `return "application/pdf"` → `<return default>` |
| 472 | `server/resources.nim:79` | RVR | `return "image/png"` → `<return default>` |
| 473 | `server/resources.nim:81` | RVR | `return "image/jpeg"` → `<return default>` |
| 474 | `server/resources.nim:83` | RVR | `return "image/gif"` → `<return default>` |
| 475 | `server/resources.nim:85` | RVR | `return "image/svg+xml"` → `<return default>` |
| 476 | `server/resources.nim:87` | RVR | `return "audio/mpeg"` → `<return default>` |
| 477 | `server/resources.nim:89` | RVR | `return "audio/wav"` → `<return default>` |
| 478 | `server/resources.nim:91` | RVR | `return "video/mp4"` → `<return default>` |
| 479 | `server/resources.nim:93` | RVR | `return "video/webm"` → `<return default>` |
| 480 | `server/resources.nim:95` | RVR | `return "application/zip"` → `<return default>` |
| 481 | `server/resources.nim:97` | RVR | `return "application/x-tar"` → `<return default>` |
| 482 | `server/resources.nim:99` | RVR | `return "application/gzip"` → `<return default>` |
| 483 | `server/resources.nim:101` | RVR | `return "text/x-nim"` → `<return default>` |
| 484 | `server/resources.nim:103` | RVR | `return "text/x-python"` → `<return default>` |
| 485 | `server/resources.nim:105` | RVR | `return "text/x-c"` → `<return default>` |
| 486 | `server/resources.nim:107` | RVR | `return "text/x-c++"` → `<return default>` |
| 487 | `server/resources.nim:109` | RVR | `return "text/x-c-header"` → `<return default>` |
| 488 | `server/resources.nim:111` | RVR | `return "text/x-rust"` → `<return default>` |
| 489 | `server/resources.nim:113` | RVR | `return "text/x-go"` → `<return default>` |
| 490 | `server/resources.nim:115` | RVR | `return "text/x-java"` → `<return default>` |
| 491 | `server/resources.nim:117` | RVR | `return "text/x-csharp"` → `<return default>` |
| 492 | `server/resources.nim:119` | RVR | `return "text/x-typescript"` → `<return default>` |
| 493 | `server/resources.nim:121` | RVR | `return "text/x-ruby"` → `<return default>` |
| 494 | `server/resources.nim:123` | RVR | `return "text/x-php"` → `<return default>` |
| 495 | `server/resources.nim:125` | RVR | `return "text/x-shellscript"` → `<return default>` |
| 496 | `server/resources.nim:127` | RVR | `return "text/x-bat"` → `<return default>` |
| 497 | `server/resources.nim:129` | RVR | `return "text/x-powershell"` → `<return default>` |
| 498 | `server/resources.nim:131` | RVR | `return "text/x-sql"` → `<return default>` |
| 499 | `server/resources.nim:133` | RVR | `return "application/octet-stream"` → `<return default>` |
| 500 | `server/resources.nim:136` | RVR | `return mimeType.startsWith("text/") or mimeType == "applicat` → `<return default>` |
| 459 | `server/resources.nim:136` | LOR | `mimeType.startsWith("text/") or mimeType == "application/jso` → `<or -> and>` |
| 454 | `server/resources.nim:137` | ROR | `mimeType == "application/json"` → `<== -> !=>` |
| 458 | `server/resources.nim:137` | LOR | `mimeType.startsWith("text/") or mimeType == "application/jso` → `<or -> and>` |
| 455 | `server/resources.nim:138` | ROR | `mimeType == "application/javascript"` → `<== -> !=>` |
| 457 | `server/resources.nim:138` | LOR | `mimeType.startsWith("text/") or mimeType == "application/jso` → `<or -> and>` |
| 456 | `server/resources.nim:139` | ROR | `mimeType == "application/xml"` → `<== -> !=>` |
| 501 | `server/resources.nim:152` | RVR | `return createTextResourceContent(uri, text, mimeType)` → `<return default>` |
| 502 | `server/resources.nim:157` | RVR | `return createBinaryResourceContent(uri, encoded, mimeType)` → `<return default>` |
| 460 | `server/resources.nim:173` | LOR | `"*" and not name.match(pattern)` → `<and -> or>` |
| 462 | `server/resources.nim:182` | SDL | `result.add(createResourceInfo(uri, name, "", mimeType, size.` → `discard` |
| 463 | `server/resources.nim:184` | SDL | `result.add(createResourceInfo(uri, name, "Directory", "inode` → `discard` |

## pagination.nim、completion.nim、log_level.nim の 10 件

| id | file:line | mutator | 変異 | 分類 | 理由 | 検出するテスト |
|---|---|---|---|---|---|---|
| 23 | `pagination.nim:31` | RVR | `return none(int)` → `return default` | 1 | `default(Option[int])` は `none(int)` と同じ値 (`has` が false) | |
| 24 | `pagination.nim:33` | RVR | 同上 | 1 | 同上 | |
| 25 | `pagination.nim:38` | RVR | 同上 | 1 | 同上 | |
| 26 | `pagination.nim:40` | RVR | 同上 | 1 | 同上 | |
| 12 | `pagination.nim:39` | ROR | `offset < 1` → `offset <= 1` | 3 | ページサイズ 1 の 2 ページ目のカーソルは `offset:1`。変異するとこのカーソルが無効になる。既存のテストはページサイズ 2 だけで、オフセットは 2 と 4 しか使わなかった | `test_server_pagination.nim` "Given a page size of 1, when the pages are followed, ..." |
| 13 | `pagination.nim:39` | ROR | `offset >= itemCount` → `offset > itemCount` | 3 | 末尾そのもの (`offset:5`、5 件) は発行されないカーソルで、無効でなければならない。既存のテストは 50 だけ試していた | `test_server_pagination.nim` "Given a cursor nobody issued, ..." に `b2Zmc2V0OjU=` を追加 |
| 439 | `completion.nim:24` | LOR | `node.isNil or node.kind != JObject` → `and` | 1 | `requiredString` の呼び出しは `reference` と `argument` だけで、どちらも直前に非 nil の JObject と確かめてある。しかも `node{key}` は nil と非オブジェクトに nil を返す (std/json) ので、ガード自体が冗長 (分類 4 としても読める。削除はしない) | |
| 441 | `completion.nim:33` | LOR | `params.isNil or params.kind != JObject` → `and` | 3 | `params` が nil のとき変異は nil の `kind` を読んで SIGSEGV。非オブジェクトの params では結果が同じ (`{}` が nil を返す) | `test_server_completion.nim` "Given a request without params, ..." |
| 438 | `completion.nim:71` | ROR | `values.len > MaxCompletionValues` → `>=` | 3 | ちょうど 100 件のとき、変異は `hasMore: true` を足す。仕様の上限は 100 件で、100 件に収まるなら続きがあるとは言えない | `test_server_completion.nim` "Given exactly 100 values, ..." |
| 2 | `log_level.nim:24` | SDL | `none(McpLogLevel)` → `discard` | 1 | 関数の最後の式。`discard` にすると `result` が既定値になり、`default(Option[McpLogLevel])` は `none` と同じ | |

## 追記したもの (リードが統合する)

- `tests/mutation/server.json`: なし (追加したテストは `test_server_pagination.nim` と `test_server_completion.nim` で、どちらも既に testCommand に入っている)。
- `specs/tests.map`: `MCP-PAGINATION-1`、`MCP-COMPLETION-1`、`MCP-COMPLETION-4` に各 1 行。

## 残っているもの

- `resources.nim` と `prompts.nim` (分類 4、60 件): リードの判断待ち。削除と `sources` からの除外を提案する。
- 分類 1 の 6 件は式から読んだだけで、実行していない。439 は冗長なガードで、削除するかどうかはリードが決める。
