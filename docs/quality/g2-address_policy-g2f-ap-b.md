# G2 address_policy の記録 (g2f-ap-b)

対象は `src/transport/address_policy.nim`。測定は 36a4c8a5 のジョブ `address_policy` (212 変異体: killed 93 / survived 106 / compileError 13 / timeout 0 / runError 0)。
このファイルが扱うのは address_policy.nim の生き残り 68 件。同じジョブの `icons.nim` と `guarded_wire.nim` の生き残り 38 件は別の記録 (g2f-ap-a)。
測定以後 address_policy.nim は変わっていないので、行番号は測定時と同じ。

## 結果

- 分類 3 (gap): 54 件。全件を手で変異させ、名指しのテストが落ちることを確認した (変異ごとに適用、1 本のテスト実行、`jj restore`)。未確認は 0 件。
- 分類 1 (等価): 12 件。
- 分類 6 (許容): 2 件。
- 分類 2 / 4 / 5: 0 件。

新しいテストは `tests/test_security_address.nim` の末尾の 3 スイート (`... (mutation review, g2f-ap-b)`)。仕様は `specs/security.feature` の `MCP-SEC-WIRE-g2f-ap-b-1` から `-3`。
IPv6 のブロックごとに、ブロックの最初と最後のアドレスと、すぐ外側の隣を表にして検査している。
確認した版: 既定版 (34 件 OK)、`-d:mcpDefaultProtocolVersion=2024-11-05` (33 件。認可クライアントのテスト 1 件はその版では外れる)、`=2025-11-25` (34 件)。警告 0。
id 49 (`embeddedV4` の 4 番目のオクテット) は、はじめ「どのブロックも /24 以下なので 4 番目は効かない」と読んで等価と見たが、6to4 では `at = 2` なので `a[at - 3]` が範囲外を読み、IndexDefect で落ちる。手で適用して確かめ、分類 3 とした。

## 生き残りの一覧

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

## 残っているもの

- 分類 6 の 2 件 (102, 175)。理由は表のとおり。
- リードの判断を待つ点が 1 つある。`classifyAddress` は `::/8` のうち `::`、`::1`、`::ffff:0:0/96`、`64:ff9b::/96` 以外 (たとえば `::ff:7f00:1`)、`0100::/8` の `100::/64` 以外、`fec0::/10` (廃止されたサイトローカル、RFC 3879) などを public と返す。IANA の special-purpose registry に載っていないので、`acReserved` の文書 (registry が取り分けたもの) とは矛盾しない。ただし IANA の address space registry では `::/8` などは IETF の予約。厳しくするなら範囲の定義を決める必要があり、仕様にまだ無いので変えず、テストにも固定していない。
- `systemAddresses` / `resolveHost` のテスト (id 174, 176, 113, 114) は、数字で書いたアドレス (`127.0.0.1`、`::1`) を system resolver に渡す。getaddrinfo は数字の表記を DNS に問い合わせずに読むのでネットワークには出ないが、「system resolver に触れない」という指示には厳密には反する。名前の解決はテストしていない。不要ならこの 1 テストを外し、4 件を分類 6 にする。
