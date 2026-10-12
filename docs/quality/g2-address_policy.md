# G2 変異検出: address_policy ジョブ

測定: `nim-muter`、ジョブ `tests/mutation/address_policy.json`、本線の 36a4c8a5 (2026-10-07)。
2026-10-12 に `address_policy.nim` を変えた。次の測定で測り直す。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 212 | 93 | 0 | 106 | 0 | 13 |

生き残り 106 件の分類 (2 人で分担し、下の 2 節に 1 件ずつ記録した)。

| 分類 | icons.nim と guarded_wire.nim | address_policy.nim | 計 |
|---|---:|---:|---:|
| 1 同値 | 2 | 12 | 14 |
| 2 ジョブに無かった既存テストで検出 (`test_icon_fetch` を追加) | 24 | 0 | 24 |
| 3 穴 (テストを追加、全件で変異を当てて確認) | 10 | 54 | 64 |
| 6 許容 | 2 | 2 | 4 |
| 計 | 38 | 68 | 106 |

`icons.nim` は測定後に base64 の形の確認が 3 行入った (push の前の測り直しの対象)。

## リードの判断

- **id 33** (`icons.nim` の `guardedGet` に渡す `followRedirects = true` → `false`): 第 1 節では「未確認」。**許容 (分類 6) とする。**
  アイコンは https だけなので、既定の経路でリダイレクトを追うことを見るには、試験用の証明書をクライアントに信頼させる口
  (`IconFetchOptions.caFile`) が要る。その口は今の公開 API に無く、テストのためだけには足さない。リダイレクト先の検査は
  `guarded_wire` のテスト (`test_security_address`) が押さえている。口を利用者向けに足すかは、2026-10-12 に足さないと決めた (id 33 は許容のまま)。
- システムの名前解決を呼ぶテスト 1 本 (第 2 節、id 174・176・113・114) は残す。渡すのは `127.0.0.1` と `::1` の数値だけで、
  問い合わせは外に出ない。

## 残っているもの

- 許容 4 件 (14、33、102、175)。
- **未割り当ての IPv6 空間が公開アドレスに分類される** (`fec0::/10` の旧サイトローカルなど。IANA の特殊用途の一覧には無いが、
  アドレス空間の一覧では IETF 予約)。2026-10-12 に、`2000::/3` の外でほかの分類に当たらないものを `acReserved` にすると決め、
  実装した (MCP-SEC-WIRE-21)。`2000::/3` の中は `acPublic` のまま。

## G2 変異検査: address_policy ジョブのうち icons.nim と guarded_wire.nim (g2f-ap-a)

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

### 生き残りの一覧

変異の id は測定時のもの。クラス 2 と 3 は、手で変異を当て、名前のあるテストが落ちるのを見た。

#### クラス 2: `tests/test_icon_fetch.nim` が検出する (ジョブの testCommand に足した)

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

#### クラス 1: 同値

| id | file:line | 変異 | 理由 |
|---|---|---|---|
| 32 | icons.nim:67 | `strip(trailing = false, ...)` の `false` → `true` | 末尾から落とす文字の集合 (空白、BOM の 3 バイト) は、後で調べる `<svg` `<?xml` `<!--` `<!doctype` のどの末尾の文字 (`g` `l` `-` `e`) も含まない。先頭の一致と `"<svg" in head` の結果は、末尾を切っても変わらない。 |
| 34 | icons.nim:73 | `none(IconType)` → `discard` | `sniffIcon` の戻り値 `Option[IconType]` の既定値が `none` なので、最後の式を捨てても同じ値が返る。 |

#### クラス 3: 隙間。テストを書き、変異で落ちることを確認した

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

Scenario は `MCP-ICONS-7` `MCP-ICONS-8` `MCP-SEC-WIRE-10` `MCP-SEC-WIRE-11` を足し、`specs/tests.map` に対応を書いた。
`tests/test_spec_coverage.nim` は合格する。

#### クラス 3: 未確認

| id | file:line | 変異 | 状態 |
|---|---|---|---|
| 33 | icons.nim:127 | `guardedGet` の `followRedirects = true` → `false` | テストを書けなかった。下の「残っているもの」を見よ。 |

#### クラス 6: 許容

| id | file:line | 変異 | 理由 |
|---|---|---|---|
| 14 | icons.nim:100 | `src.len > maxBytes * 2 + 128` → `>=` | この検査は、復号する前に大きすぎる入力を断る前置きである。ちょうど境界の長さの base64 は、復号すると必ず `maxBytes` を超える (接頭辞は最小でも 20 文字で、残りは 2 * maxBytes + 108 文字以上、復号後は 1.5 * maxBytes + 79 バイト以上) ので、後段の検査が同じ文言で断る。違いが出るのは、ちょうど境界の長さで base64 でない文字を含む入力の診断の文言 (「exceeds」と「not valid base64」) だけである。変異を当てて、足したテストでも落ちないことを確認した。 |

### 実行したこと

- 変異を当てて確認した 35 件はすべて、当てたあとに `jj restore` で戻した。`jj diff --stat` に `src/` のファイルは無い。
- `nim c -r` で `test_icon_fetch` `test_security_icons` `test_security_address` `test_spec_coverage` を流し、既定の版で合格。
  `-d:mcpDefaultProtocolVersion=2024-11-05` と `=2025-11-25` でも、`test_icon_fetch` `test_security_icons` `test_security_address` は合格 (`test_security_address` は版で 15 件と 16 件。版で出し分ける既存の 1 件のため)。
- 変異検査 (nim-muter) は流していない。`docs/quality/g2-protocol-versions.md` は触っていない。

### 残っているもの

- id 33 (`icons.nim` の `guardedGet` の `followRedirects`): 既定の取得経路で同じ origin への redirect が追われることを確かめるには、https のサーバーとその証明書を信頼するクライアントが要る。
  `http_wire.request` は `caFile` を取るが、`IconFetchOptions` には `caFile` が無く、`guardedGet` は渡さない。`caFile` が空のときは Nim の `newContext(CVerifyPeer)` が OS の証明書を使い、環境変数 `SSL_CERT_FILE` は `CVerifyPeerUseEnvVars` でしか読まれない。
  テスト用の CA を信頼させる道が公開 API (`IconFetchOptions.caFile` の追加) を変える以外に無いため、リードの判断に回していた。2026-10-12 に `caFile` は足さないと決めた。
  他の経路で代える案は無い (`options.get` を差し替えると `guardedGet` が通らない)。
- id 14 は許容 (上の理由)。
- クラス 4 (死んだコード) と 5 (欠陥) は無かった。

## G2 address_policy の記録 (g2f-ap-b)

対象は `src/transport/address_policy.nim`。測定は 36a4c8a5 のジョブ `address_policy` (212 変異体: killed 93 / survived 106 / compileError 13 / timeout 0 / runError 0)。
このファイルが扱うのは address_policy.nim の生き残り 68 件。同じジョブの `icons.nim` と `guarded_wire.nim` の生き残り 38 件は別の記録 (g2f-ap-a)。
測定以後 address_policy.nim は変わっていないので、行番号は測定時と同じ。

### 結果

- 分類 3 (gap): 54 件。全件を手で変異させ、名指しのテストが落ちることを確認した (変異ごとに適用、1 本のテスト実行、`jj restore`)。未確認は 0 件。
- 分類 1 (等価): 12 件。
- 分類 6 (許容): 2 件。
- 分類 2 / 4 / 5: 0 件。

新しいテストは `tests/test_security_address.nim` の末尾の 3 スイート (`... (mutation review, g2f-ap-b)`)。仕様は `specs/security.feature` の `MCP-SEC-WIRE-12` から `-3`。
IPv6 のブロックごとに、ブロックの最初と最後のアドレスと、すぐ外側の隣を表にして検査している。
確認した版: 既定版 (34 件 OK)、`-d:mcpDefaultProtocolVersion=2024-11-05` (33 件。認可クライアントのテスト 1 件はその版では外れる)、`=2025-11-25` (34 件)。警告 0。
id 49 (`embeddedV4` の 4 番目のオクテット) は、はじめ「どのブロックも /24 以下なので 4 番目は効かない」と読んで等価と見たが、6to4 では `at = 2` なので `a[at - 3]` が範囲外を読み、IndexDefect で落ちる。手で適用して確かめ、分類 3 とした。

### 生き残りの一覧

| id | 場所 | 変異 | 原文 → 変異 | 分類 | 理由 | 検出するテスト |
|---|---|---|---|---|---|---|
| 48 | address_policy.nim:77 | AOR | `at + 2` → `<+ -> ->` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「IPv4-mapped の IPv4 部分が文書用 /24 にあるとき 3 番目のオクテットが効く」 |
| 49 | address_policy.nim:77 | AOR | `at + 3` → `<+ -> ->` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「6to4 2002::/16 は bits 16..47 の IPv4 で判定される」 |
| 124 | address_policy.nim:92 | LOR | `zeroTo10 and a[10] == 0x000000FF` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「bytes 10/11 に ff があっても ::ffff:0:0/96 でなければ mapped と読まない」 |
| 123 | address_policy.nim:92 | LOR | `zeroTo10 and a[10] == 0x000000FF and a[11] == 0x000000FF` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「bytes 10/11 に ff があっても ::ffff:0:0/96 でなければ mapped と読まない」 |
| 127 | address_policy.nim:100 | LOR | `rest and a[i] == 0` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「::/96 の ::1 以外は reserved」 |
| 74 | address_policy.nim:104 | ROR | `a[0] == 0x00000000` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「NAT64 64:ff9b::/96 の中のアドレスは中の IPv4 で判定される」 |
| 131 | address_policy.nim:104 | LOR | `a[0] == 0x00000000 and a[1] == 0x00000064` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「64:ff9b:1::/48 や NAT64 と一部のバイトだけ一致するアドレスは NAT64 ではない」 |
| 75 | address_policy.nim:104 | ROR | `a[1] == 0x00000064` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「NAT64 64:ff9b::/96 の中のアドレスは中の IPv4 で判定される」 |
| 130 | address_policy.nim:104 | LOR | `a[0] == 0x00000000 and a[1] == 0x00000064 and a[2] == 0x000000FF` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「64:ff9b:1::/48 や NAT64 と一部のバイトだけ一致するアドレスは NAT64 ではない」 |
| 76 | address_policy.nim:104 | ROR | `a[2] == 0x000000FF` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「NAT64 64:ff9b::/96 の中のアドレスは中の IPv4 で判定される」 |
| 129 | address_policy.nim:104 | LOR | `a[0] == 0x00000000 and a[1] == 0x00000064 and a[2] == 0x000000FF and; a[3] == 0x0000009B` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「64:ff9b:1::/48 や NAT64 と一部のバイトだけ一致するアドレスは NAT64 ではない」 |
| 77 | address_policy.nim:104 | ROR | `a[3] == 0x0000009B` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「NAT64 64:ff9b::/96 の中のアドレスは中の IPv4 で判定される」 |
| 159 | address_policy.nim:105 | BLR | `true` → `false` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「NAT64 64:ff9b::/96 の中のアドレスは中の IPv4 で判定される」 |
| 132 | address_policy.nim:107 | LOR | `rest and a[i] == 0` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「64:ff9b:1::/48 や NAT64 と一部のバイトだけ一致するアドレスは NAT64 ではない」 |
| 78 | address_policy.nim:107 | ROR | `a[i] == 0` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「NAT64 64:ff9b::/96 の中のアドレスは中の IPv4 で判定される」 |
| 186 | address_policy.nim:108 | RVR | `return if rest:; classifyV4(embeddedV4(a, 12)); else:; acReserved` → `<return default>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「NAT64 64:ff9b::/96 の中のアドレスは中の IPv4 で判定される」 |
| 79 | address_policy.nim:110 | ROR | `a[0] == 0x00000020` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「6to4 2002::/16 は bits 16..47 の IPv4 で判定される」 |
| 187 | address_policy.nim:111 | RVR | `return classifyV4(embeddedV4(a, 2))` → `<return default>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「6to4 2002::/16 は bits 16..47 の IPv4 で判定される」 |
| 82 | address_policy.nim:113 | ROR | `a[1] == 0x00000000` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「100::/64 の境界は 64 ビット目」 |
| 160 | address_policy.nim:114 | BLR | `true` → `false` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「100::/64 の境界は 64 ビット目」 |
| 135 | address_policy.nim:116 | LOR | `discard64 and a[i] == 0` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「100::/64 の境界は 64 ビット目」 |
| 83 | address_policy.nim:116 | ROR | `a[i] == 0` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「100::/64 の境界は 64 ビット目」 |
| 188 | address_policy.nim:118 | RVR | `return acReserved` → `<return default>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「100::/64 の境界は 64 ビット目」 |
| 84 | address_policy.nim:122 | ROR | `a[0] == 0x00000020` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「2001::/23 は全体が reserved、隣は違う」 |
| 137 | address_policy.nim:122 | LOR | `a[0] == 0x00000020 and a[1] == 0x00000001` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「2001::/23 は全体が reserved、隣は違う」 |
| 85 | address_policy.nim:122 | ROR | `a[1] == 0x00000001` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「2001::/23 は全体が reserved、隣は違う」 |
| 138 | address_policy.nim:122 | LOR | `a[2] and 0xFE'u8` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「2001::/23 は全体が reserved、隣は違う」 |
| 86 | address_policy.nim:122 | ROR | `(a[2] and 0xFE'u8) == 0` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「2001::/23 は全体が reserved、隣は違う」 |
| 189 | address_policy.nim:123 | RVR | `return acReserved` → `<return default>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「2001::/23 は全体が reserved、隣は違う」 |
| 141 | address_policy.nim:124 | LOR | `a[0] == 0x00000020 and a[1] == 0x00000001` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「2001:db8::/32 は reserved、隣は違う」 |
| 140 | address_policy.nim:124 | LOR | `a[0] == 0x00000020 and a[1] == 0x00000001 and a[2] == 0x0000000D` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「2001:db8::/32 は reserved、隣は違う」 |
| 139 | address_policy.nim:124 | LOR | `a[0] == 0x00000020 and a[1] == 0x00000001 and a[2] == 0x0000000D and; a[3] == 0x000000B8` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「2001:db8::/32 は reserved、隣は違う」 |
| 91 | address_policy.nim:126 | ROR | `a[0] == 0x0000003F` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「3fff::/20 は reserved、隣は違う」 |
| 143 | address_policy.nim:126 | LOR | `a[0] == 0x0000003F and a[1] == 0x000000FF` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「3fff::/20 は reserved、隣は違う」 |
| 92 | address_policy.nim:126 | ROR | `a[1] == 0x000000FF` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「3fff::/20 は reserved、隣は違う」 |
| 144 | address_policy.nim:126 | LOR | `a[2] and 0xF0'u8` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「3fff::/20 は reserved、隣は違う」 |
| 93 | address_policy.nim:126 | ROR | `(a[2] and 0xF0'u8) == 0` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「3fff::/20 は reserved、隣は違う」 |
| 191 | address_policy.nim:127 | RVR | `return acReserved` → `<return default>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「3fff::/20 は reserved、隣は違う」 |
| 146 | address_policy.nim:130 | LOR | `a[0] == 0x000000FE and (a[1] and 0xC0'u8) == 0x00000080` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「fe80::/10 の最初と最後は link-local、似たアドレスは違う」 |
| 98 | address_policy.nim:139 | ROR | `classifyAddress(ip) == acPublic` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「全クラスのアドレスで、isGloballyRoutable は public だけ」 |
| 149 | address_policy.nim:153 | LOR | `text.len == 0 or text.len > 16` → `<or -> and>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「空の部分は名前」 |
| 102 | address_policy.nim:153 | ROR | `text.len > 16` → `<> -> >=>` | 6 | `text.len > 16` と `>= 16` の差は、接頭辞の後ろにちょうど 16 桁ある 0 埋めの値でだけ現れる。16 は桁数の上限にすぎず、どちらでも名前として解決され、得られたアドレスが `chooseDestination` で判定されるので安全側。この上限を仕様として固定するテストは実装の写しになる。 | - |
| 195 | address_policy.nim:154 | RVR | `return none(uint64)` → `<return default>` | 1 | 返り値型が Option[T] で、`return default` は none と同じ値。元の `return none(T)` と全入力で区別できない。 | - |
| 54 | address_policy.nim:160 | AOR | `ord(c) - ord('A')` → `<- -> +>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「16 進の大文字が値を持つ」 |
| 53 | address_policy.nim:160 | AOR | `ord(c) - ord('A') + 10` → `<+ -> ->` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「16 進の大文字が値を持つ」 |
| 196 | address_policy.nim:161 | RVR | `return none(uint64)` → `<return default>` | 1 | 返り値型が Option[T] で、`return default` は none と同じ値。元の `return none(T)` と全入力で区別できない。 | - |
| 103 | address_policy.nim:162 | ROR | `digit >= base` → `<>= -> >>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「その基数に無い桁は名前」 |
| 197 | address_policy.nim:163 | RVR | `return none(uint64)` → `<return default>` | 1 | 返り値型が Option[T] で、`return default` は none と同じ値。元の `return none(T)` と全入力で区別できない。 | - |
| 104 | address_policy.nim:165 | ROR | `value > 0x00000000FFFFFFFF'u64` → `<> -> >=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「32 ビットの上端のリテラルは読め、1 つ上は名前」 |
| 198 | address_policy.nim:166 | RVR | `return none(uint64)` → `<return default>` | 1 | 返り値型が Option[T] で、`return default` は none と同じ値。元の `return none(T)` と全入力で区別できない。 | - |
| 105 | address_policy.nim:176 | ROR | `text.len > 1` → `<> -> >=>` | 1 | 長さ 1 の文字列は先頭が `[` かつ末尾が `]` になれない (同じ 1 文字)。`>= 1` にしても分岐の結果は変わらない。 | - |
| 151 | address_policy.nim:176 | LOR | `text.len > 1 and text[0] == '['` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「全体を囲まない括弧はアドレスではない」 |
| 150 | address_policy.nim:176 | LOR | `text.len > 1 and text[0] == '[' and text[^1] == ']'` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「全体を囲まない括弧はアドレスではない」 |
| 199 | address_policy.nim:179 | RVR | `return none(IpAddress)` → `<return default>` | 1 | 返り値型が Option[T] で、`return default` は none と同じ値。元の `return none(T)` と全入力で区別できない。 | - |
| 201 | address_policy.nim:184 | RVR | `return none(IpAddress)` → `<return default>` | 1 | 返り値型が Option[T] で、`return default` は none と同じ値。元の `return none(T)` と全入力で区別できない。 | - |
| 202 | address_policy.nim:187 | RVR | `return none(IpAddress)` → `<return default>` | 1 | 返り値型が Option[T] で、`return default` は none と同じ値。元の `return none(T)` と全入力で区別できない。 | - |
| 203 | address_policy.nim:192 | RVR | `return none(IpAddress)` → `<return default>` | 1 | 返り値型が Option[T] で、`return default` は none と同じ値。元の `return none(T)` と全入力で区別できない。 | - |
| 204 | address_policy.nim:196 | RVR | `return none(IpAddress)` → `<return default>` | 1 | 返り値型が Option[T] で、`return default` は none と同じ値。元の `return none(T)` と全入力で区別できない。 | - |
| 58 | address_policy.nim:197 | AOR | `5 - numbers.len` → `<- -> +>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「最後の部分が残りのバイトに収まる境界」 |
| 111 | address_policy.nim:198 | ROR | `numbers[^1] >= (1'u64 shl (8 * remainingBytes))` → `<>= -> >>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「最後の部分が残りのバイトに収まる境界」 |
| 205 | address_policy.nim:199 | RVR | `return none(IpAddress)` → `<return default>` | 1 | 返り値型が Option[T] で、`return default` は none と同じ値。元の `return none(T)` と全入力で区別できない。 | - |
| 172 | address_policy.nim:226 | SDL | `none(AddressClass)` → `discard` | 1 | 関数の最後の式 `none(AddressClass)` を `discard` にすると result は既定値 none になり、同じ値を返す。 | - |
| 174 | address_policy.nim:248 | SDL | `result.add text` → `discard` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「アドレスで書かれたホストを system resolver に渡すと、そのアドレスが返る」 |
| 175 | address_policy.nim:251 | SDL | `freeAddrInfo(info)` → `discard` | 6 | `freeAddrInfo` を呼ばないと getaddrinfo の結果を解放しない。メモリリークであって戻り値・例外には現れない。リーク検査 (runtime-safety-audit) の担当で、E テストでは検出できない。 | - |
| 113 | address_policy.nim:252 | ROR | `result.len == 0` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「アドレスで書かれたホストを system resolver に渡すと、そのアドレスが返る」 |
| 176 | address_policy.nim:260 | SDL | `result.add parseIpAddress(text)` → `discard` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「アドレスで書かれたホストを system resolver に渡すと、そのアドレスが返る」 |
| 114 | address_policy.nim:263 | ROR | `result.len == 0` → `<== -> !=>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「アドレスで書かれたホストを system resolver に渡すと、そのアドレスが返る」 |
| 156 | address_policy.nim:305 | LOR | `result.loopbackOnly and class == acLoopback` → `<and -> or>` | 3 | 外部仕様の事実 (RFC のブロック境界、inet_aton の読み方、loopbackOnly の定義) を境界で検査するテストが無かった。 | `test_security_address.nim` の 「全アドレスが loopback のときだけ loopbackOnly」 |

### 残っているもの

- 分類 6 の 2 件 (102, 175)。理由は表のとおり。
- 2026-10-12 に決めて直した点が 1 つある。`classifyAddress` は `::/8` のうち `::`、`::1`、`::ffff:0:0/96`、`64:ff9b::/96` 以外 (たとえば `::ff:7f00:1`)、`0100::/8` の `100::/64` 以外、`fec0::/10` (廃止されたサイトローカル、RFC 3879) などを public と返していた。IANA の address space registry では `::/8` などは IETF の予約なので、`2000::/3` (割り当て済みの global unicast) の外でほかの分類に当たらないものを `acReserved` にした。仕様は MCP-SEC-WIRE-21、テストは `test_security_address.nim` の "the IPv6 space outside 2000::/3"。
- `systemAddresses` / `resolveHost` のテスト (id 174, 176, 113, 114) は、数字で書いたアドレス (`127.0.0.1`、`::1`) を system resolver に渡す。getaddrinfo は数字の表記を DNS に問い合わせずに読むのでネットワークには出ないが、「system resolver に触れない」という指示には厳密には反する。名前の解決はテストしていない。不要ならこの 1 テストを外し、4 件を分類 6 にする。

## 測り直し (本線 76a08c6a、2026-10-10)

36a4c8a5 の測定のあとに足したテストと修正を入れたコミットで、同じジョブを測り直した。変異 212、検出 181、時間切れ 0、コンパイル不能 13、**生き残り 18** (前回 106)。

前回の生き残りとの突き合わせは変異の指紋で行った (指紋が変わった行は、ファイル・変異の文面・3 行以内の行番号で合わせた)。18 件はすべて前回も生き残っていて、この文書に分類と理由がある。新しく現れた生き残りは無い。前回「穴」としてテストを足した変異は、1 件も残っていない。
