# G2 変異検査: address_policy ジョブのうち icons.nim と guarded_wire.nim (g2f-ap-a)

担当範囲は `src/client/icons.nim` の生き残り 36 件と `src/transport/guarded_wire.nim` の 2 件。
`src/transport/address_policy.nim` は別の担当 (g2f-ap-b) が持つ。

測定は 36a4c8a5 (change `owwryuxn`) で行ったもので、ジョブ全体の数字は 212 件中 killed 93 / survived 106 / compileError 13 / timeout 0 / runError 0。
`icons.nim` はその後に import と base64 の形の検査が足されたため、現在の行は測定時より 1 行から 3 行後ろにある。変異を手で当てるときは、行ではなく文面で探した。

本線の先端 (`kvonwtpk`) に対する作業の結果を次に示す。

| 区分 | 件数 |
|---|---|
| 1 同値 | 2 |
| 2 別のテストが検出 (ジョブに足した) | 24 |
| 3 隙間 (テストを書き、変異で落ちることを確認した) | 10 |
| 3 隙間 (未確認。下記) | 1 |
| 6 許容 | 1 |
| 4 / 5 | 0 |

## 生き残りの一覧

変異の id は測定時のもの。クラス 2 と 3 は、手で変異を当て、名前のあるテストが落ちるのを見た。

### クラス 2: `tests/test_icon_fetch.nim` が検出する (ジョブの testCommand に足した)

`tests/test_icon_fetch.nim` は `tests/mutation/base64_shape.json` のジョブにはあったが、address_policy のジョブには無かった。
`tests/mutation/address_policy.json` の `testCommand` の末尾に足した (`.github/workflows/g2.yml` は json を呼ぶだけで、コマンドを繰り返していない)。
すべての id について変異を手で当てて確認した。

| id | file:line | 変異 | 検出したテスト |
|---|---|---|---|
| 21 | icons.nim:61 | `and` → `or` (PNG の長さ検査) | `Given bytes of no allowed image type ...` (5 バイトの `hello` で IndexDefect) |
| 22 | icons.nim:63 | `and` → `or` (JPEG) | `Given an icon of an allowed type ...`, `Given an SVG ...` (WebP と SVG が JPEG になる) |
| 24 | icons.nim:65 | 最初の `and` → `or` (WebP) | `Given an SVG ...` (SVG が WebP になる) |
| 23 | icons.nim:65 | 2 つ目の `and` → `or` (WebP) | `Given bytes of no allowed image type ...` (IndexDefect) |
| 5 | icons.nim:61 | `==` → `!=` (PNG 署名) | `Given an icon of an allowed type ...` ほか 4 件 |
| 7 | icons.nim:63 | `==` → `!=` (JPEG 署名) | `Given an icon of an allowed type ...` ほか 2 件 |
| 9 | icons.nim:65 | `==` → `!=` (`RIFF`) | `Given an icon of an allowed type ...` |
| 10 | icons.nim:65 | `==` → `!=` (`WEBP`) | `Given an icon of an allowed type ...` |
| 40 | icons.nim:62 | `return some(itPng)` → 既定値 | `Given an icon of an allowed type ...` ほか |
| 41 | icons.nim:64 | `return some(itJpeg)` → 既定値 | `Given an icon of an allowed type ...` ほか |
| 42 | icons.nim:66 | `return some(itWebp)` → 既定値 | `Given an icon of an allowed type ...` |
| 43 | icons.nim:72 | `return some(itSvg)` → 既定値 | `Given an SVG ...` |
| 25 | icons.nim:69 | `<svg` の `or` → `and` | `Given an SVG ...` (`<?xml` で始まる SVG) |
| 28 | icons.nim:70 | `<?xml` と `<!--` の `or` → `and` | `Given an SVG ...` |
| 11 | icons.nim:77 | `base == "image/jpg"` → `!=` | `Given an icon of an allowed type ...` ほか 4 件 |
| 12 | icons.nim:85 | `bytes.len == 0` → `!=` | `Given an icon of an allowed type ...` ほか 4 件 |
| 29 | icons.nim:93 | `and` → `or` (宣言と中身の食い違い) | `Given an icon of an allowed type ...` ほか 3 件 |
| 13 | icons.nim:93 | `said != $found.get` → `==` | `Given an icon of an allowed type ...` ほか 4 件 |
| 15 | icons.nim:103 | `parts.len != 2` → `==` | `Given a data URI, when fetched ...` |
| 35 | icons.nim:112 | `accepted(...)` を `discard` | `Given a data URI, when fetched ...` (別の型の中身が通ってしまう) |
| 44 | icons.nim:141 | `return iconFromDataUri(...)` → 既定値 | `Given a data URI ...` と `Given a data URI whose data is not base64 ...` |
| 20 | icons.nim:171 | `response.code != Http200` → `==` | `Given an icon of an allowed type ...` ほか |
| 31 | icons.nim:184 | `and` → `or` (サーバーの型が無い場合のみ icon の型を使う) | `Given a generic Content-Type, ...` (`mimeType` が none の `Option.get`) |
| 45 | icons.nim:186 | `return accepted(...)` → 既定値 | `Given an icon of an allowed type ...` ほか |

### クラス 1: 同値

| id | file:line | 変異 | 理由 |
|---|---|---|---|
| 32 | icons.nim:67 | `strip(trailing = false, ...)` の `false` → `true` | 末尾から落とす文字の集合 (空白、BOM の 3 バイト) は、後で調べる `<svg` `<?xml` `<!--` `<!doctype` のどの末尾の文字 (`g` `l` `-` `e`) も含まない。先頭の一致と `"<svg" in head` の結果は、末尾を切っても変わらない。 |
| 34 | icons.nim:73 | `none(IconType)` → `discard` | `sniffIcon` の戻り値 `Option[IconType]` の既定値が `none` なので、最後の式を捨てても同じ値が返る。 |

### クラス 3: 隙間。テストを書き、変異で落ちることを確認した

新しいテストは、既存のファイルの末尾に `(mutation review, g2f-ap-a)` の suite として足した。

| id | file:line | 変異 | 検出するテスト |
|---|---|---|---|
| 4 | icons.nim:61 | `bytes.len >= 8` → `>` | `Given nothing but the signature of an image type, ...` (`test_icon_fetch.nim`) |
| 6 | icons.nim:63 | `bytes.len >= 3` → `>` | 同上 |
| 8 | icons.nim:65 | `bytes.len >= 12` → `>` | 同上 |
| 27 | icons.nim:70 | `<!--` と `<!doctype` の `or` → `and` | `Given markup that opens with a comment or a doctype, ...` |
| 26 | icons.nim:70 | `(...) and "<svg" in head` → `or` | `Given markup that holds no svg element at its start, ...` |
| 2 | icons.nim:100 | `maxBytes * 2 + 128` → `- 128` | `Given a data URI icon of exactly the allowed size, ...` (`maxBytes` が小さいとすべて拒まれる) |
| 16 | icons.nim:110 | `bytes.len > maxBytes` → `>=` | 同上 |
| 39 | icons.nim:170 | `defer: response.close()` を `discard` | `Given an answer that is not 200, when the fetch is refused, then the connection is closed` (`test_security_icons.nim`) |
| 209 | guarded_wire.nim:27 | `scheme == "http"` → `!=` | `Given a name that resolves to a private address, when plain http is asked for, ...` (`test_security_address.nim`) |
| 211 | guarded_wire.nim:16 | `followRedirects = false` の既定値 → `true` | `Given an answer that redirects, when no one asked for redirects to be followed, ...` |

39 について: 成功の経路ではこの `close` を消しても接続が閉じる (`readAll` が本文を読み切ったときに閉じる) ので、成功の経路のテストでは落ちなかった。
落ちるのは、本文を読まずに拒む経路 (200 以外の応答) である。

Scenario は `MCP-ICONS-g2f-ap-a-1` `MCP-ICONS-g2f-ap-a-2` `MCP-SEC-WIRE-g2f-ap-a-1` `MCP-SEC-WIRE-g2f-ap-a-2` を足し、`specs/tests.map` に対応を書いた。
`tests/test_spec_coverage.nim` は合格する。

### クラス 3: 未確認

| id | file:line | 変異 | 状態 |
|---|---|---|---|
| 33 | icons.nim:127 | `guardedGet` の `followRedirects = true` → `false` | テストを書けなかった。下の「残っているもの」を見よ。 |

### クラス 6: 許容

| id | file:line | 変異 | 理由 |
|---|---|---|---|
| 14 | icons.nim:100 | `src.len > maxBytes * 2 + 128` → `>=` | この検査は、復号する前に大きすぎる入力を断る前置きである。ちょうど境界の長さの base64 は、復号すると必ず `maxBytes` を超える (接頭辞は最小でも 20 文字で、残りは 2 * maxBytes + 108 文字以上、復号後は 1.5 * maxBytes + 79 バイト以上) ので、後段の検査が同じ文言で断る。違いが出るのは、ちょうど境界の長さで base64 でない文字を含む入力の診断の文言 (「exceeds」と「not valid base64」) だけである。変異を当てて、足したテストでも落ちないことを確認した。 |

## 実行したこと

- 変異を当てて確認した 35 件はすべて、当てたあとに `jj restore` で戻した。`jj diff --stat` に `src/` のファイルは無い。
- `nim c -r` で `test_icon_fetch` `test_security_icons` `test_security_address` `test_spec_coverage` を流し、既定の版で合格。
  `-d:mcpDefaultProtocolVersion=2024-11-05` と `=2025-11-25` でも、`test_icon_fetch` `test_security_icons` `test_security_address` は合格 (`test_security_address` は版で 15 件と 16 件。版で出し分ける既存の 1 件のため)。
- 変異検査 (nim-muter) は流していない。`docs/quality/g2-protocol-versions.md` は触っていない。

## 残っているもの

- id 33 (`icons.nim` の `guardedGet` の `followRedirects`): 既定の取得経路で同じ origin への redirect が追われることを確かめるには、https のサーバーとその証明書を信頼するクライアントが要る。
  `http_wire.request` は `caFile` を取るが、`IconFetchOptions` には `caFile` が無く、`guardedGet` は渡さない。`caFile` が空のときは Nim の `newContext(CVerifyPeer)` が OS の証明書を使い、環境変数 `SSL_CERT_FILE` は `CVerifyPeerUseEnvVars` でしか読まれない。
  テスト用の CA を信頼させる道が公開 API (`IconFetchOptions.caFile` の追加) を変える以外に無いため、リードの判断に回す。
  他の経路で代える案は無い (`options.get` を差し替えると `guardedGet` が通らない)。
- id 14 は許容 (上の理由)。
- クラス 4 (死んだコード) と 5 (欠陥) は無かった。
