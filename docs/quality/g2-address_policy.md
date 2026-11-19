# G2 変異検出: address_policy ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

状態: 測定済み (仕分けは読んで行った。変異は当てていない。テストも実装も足していない)。

測定: 変異検査の道具 0.2.15、ジョブ `tests/mutation/address_policy.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 215 | 163 | 0 | 39 | 0 | 13 |

仕分けの件数: test_owed 11、spec_question 4、equivalent 18、unreached 6、accepted 0、undecided 0。

仕分けの前提 (読んで確かめたこと):

- 公開の入口から `address_policy` に届くホストは、すべて `std/uri` の `parseUri(...).hostname` を通る (`auth/oauth/urls.nim` の `checkFetchUrl`・`narrowedTo`、`auth/oauth/authcode.nim` の `checkRedirectUri`、`auth/client.nim` の `obtainCredentials`、`transport/guarded_wire.nim` の `guardedRequest`、`client/icons.nim` の `guardedGet`)。`parseUri` は権限部の `[` と `]` を hostname に入れない (`urls.nim` の `originOf` が `[` `]` を付け直しているのはそのため。この測定でも、`[::1]` を URL で渡す既存の E テストが 182:31 の変異を検出していない)。空の hostname は、どの経路でも先に断られる (`checkFetchUrl` の `uri.hostname.len == 0`、`narrowedTo` の `host.len > 0`、`checkRedirectUri` の `uri.hostname.len == 0`、`isSafeIconUri` の `url.hostname.len == 0`)。`std/uri` の実装そのものは手元で開けなかったので、この 1 点は司会の側で確かめてほしい。
- `guardedRequest`・`chooseDestination`・`classifyHost`・`parseHostLiteral`・`isGloballyRoutable`・`systemAddresses`・`resolveHost` は、公開の入口のどれからも export されていない (`guarded_wire` は `AddressNotAllowed` だけ、`auth/client` と `client/icons` は `HostResolver` だけ)。
- 前の記録の「許容」4 件 (id 14・33・102・175) は、仕分けの担当とリードの判断で、代表が受け入れた記録は無い。今回は `accepted` を使わず、下の表で分類し直した。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/client/icons.nim:BLR:06f2836fc29ba2c6:0` | icons.nim:73 | `strip(trailing = false, …)` の `false` → `true` | equivalent | 末尾から落とす文字 (空白、タブ、改行、BOM の 3 バイト) は、後で調べる `<svg`・`<?xml`・`<!--`・`<!doctype` のどの文字でもない。末尾を落としても `startsWith` と `"<svg" in head` の結果は変わらない (前の記録 id 32 と同じ)。 | - |
| `src/client/icons.nim:SDL:52241519363d708c:0` | icons.nim:79 | 末尾の `none(IconType)` → `discard` | equivalent | `sniffIcon` の戻り値は `Option[IconType]` で、`result` の既定値が none。末尾の式を捨てても同じ値が返る。 | - |
| `src/client/icons.nim:ROR:0a9e8b7201a2946a:0` | icons.nim:106 | `src.len > maxBytes * 2 + 128` → `>=` | spec_question | 文面だけの違いではない。`isSafeIconUri` はヘッダ (`image/…;base64`) の長さを限らないので、ヘッダを長くすれば「全体がちょうど 2N+128 文字で、復号後が N バイト以下」の data URI を作れる。元は読み、変異は「exceeds」で断る。前の記録 (id 14) は接頭辞が最小の場合だけを見て許容としていた。全体の長さの上限 2N+128 はどの仕様 ID にも無く、MCP-ICONS-8 は「復号後が N バイトなら読む」としか言わない。 | 問い: data URI 全体の長さの上限 (2N+128 文字。ヘッダが長いと、復号後が N バイト以下でも断る) を MCP-ICONS-8 に足して仕様にするか、この前置きの検査を消して復号後のバイト数だけで決めるか。仕様にする場合の E テスト: `tests/external/test_icon_fetch.nim` で `maxBytes: 64`、`data:image/png;x=<詰め物>;base64,<Png の base64>` を全体 256 文字にして読めること、257 文字で断ること。 |
| `src/client/icons.nim:BLR:7a096473f5c56e36:0` | icons.nim:136 | `guardedGet` の `followRedirects = true` → `false` | test_owed | 既定の取得の経路で、同じ origin への redirect を追わなくなる (302 がそのまま返り「the icon was answered with 302」で失敗する)。検出していたテスト (「Given a redirect inside the origin…」) は `tests/internal/test_icon_fetch_internal.nim` に移っていて、しかも `options.get` を差し替えるので `guardedGet` を通らない。前の記録 (id 33) の許容の理由「`IconFetchOptions` に `caFile` が無い」は、`caFile` が足された今は成り立たない。 | MCP-ICONS-6 (redirect は origin の中で追う)。`tests/external/test_security_trusted_ca.nim` に足す。既存の `startTlsServer(cert, key, answerFor)` で、`GET /hop` には `302` と `Location: /icon.png`、ほかには PNG を返す。`fetchIcon(McpIcon(src: origin & "/hop"), origin, IconFetchOptions(caFile: caFile))` の `bytes == Png` と `server.requests == 2` を見る。変異だと McpIconError になる。 |
| `src/client/icons.nim:SDL:6f3fb3ba120cea62:0` | icons.nim:168 | `asked.addCallback(…)` → `discard` | test_owed | 時間切れの後に届いた応答の接続を閉じなくなる。既存の E テスト (`test_security_trusted_ca.nim` の「Given an answer that comes after the timeout…」) が検出しないのは、`guardedGet` が `headerTimeoutMs = timeoutMs` を渡していて、400 ms 後の応答より先に `http_wire` 自身のヘッダの時間切れが接続を閉じるから。この callback が働くのは、応答の頭が「取得の時間切れ (最初から timeoutMs)」より後、「ヘッダの時間切れ (接続が済んでから timeoutMs)」より前に届くときだけ (幅は接続と TLS の握手にかかった時間)。内部のテスト (`tests/internal/test_security_icons_internal.nim`) は `options.get` に `wire.request` を渡して検出していたが、`WireResponse` を公開の入口から作れないので E テストでは使えない。 | MCP-SEC-WIRE-7。`tests/external/test_security_trusted_ca.nim` に足す。`startTlsServer` に握手の前の待ち (例: 最初の `recv` の前に 200 ms) を足し、`timeoutMs: 300`、応答は要求の頭から 200 ms 後 (届くのは約 400 ms、ヘッダの時間切れは約 500 ms)。`"no answer within"` の後に `waitUntil` で `server.peerClosed` を見る。変異だと応答は届くが誰も閉じず、`peerClosed` が false のまま。時刻に頼るテストになるので、安定して窓に入れられないと分かったら「この callback を残すか、ヘッダの時間切れに任せて消すか」の問いに回す。 |
| `src/client/icons.nim:SDL:b8da7b0f36fbff3c:0` | icons.nim:172 | callback の中の `asked.read().close()` → `discard` | test_owed | 上の行と同じ箇所の成功の側。時間切れの後に届いた応答を閉じなくなる。 | MCP-SEC-WIRE-7。上の行と同じ 1 本で検出できる。 |
| `src/client/icons.nim:LOR:d0758cf5bf3869b1:0` | icons.nim:193 | `normalizedMime(declared).isGeneric and icon.mimeType.isSome` → `or` | test_owed | サーバーの型が汎用で icon に `mimeType` が無いと `icon.mimeType.get` が UnpackDefect で落ちる。サーバーの型が具体的で icon に `mimeType` があると、サーバーの型ではなく icon の型で照合する。検出していたテスト (「Given a generic Content-Type…」) は `tests/internal/test_icon_fetch_internal.nim` に移っている。 | MCP-ICONS-6 (Scenario の文面は「サーバーの型が無い・汎用のときだけ icon の型を使う」とまでは言っていない。足すなら文面も 1 行足すとよい)。`tests/external/test_security_trusted_ca.nim` に足す。(1) `Content-Type: application/octet-stream` で PNG を返し、`mimeType` の無い icon を `caFile` つきで取ると届く (変異は Defect)。(2) `Content-Type: image/png` で PNG を返し、icon の `mimeType` が `image/jpeg` でも届く (変異は「says it is image/jpeg」で断る)。 |
| `src/transport/address_policy.nim:ROR:6963caab8a732d3a:0` | address_policy.nim:114 | `a[1] == 0x00` → `!=` (100::/64 の 2 バイト目) | equivalent | MCP-SEC-WIRE-12 の 100::/64 の端。端の内側は `100::1`、外側は `101::1`。どちらも元から reserved: `a[0] == 0x01` のアドレスは、この分岐に入っても入らなくても、後ろのどの分岐にも当たらず、最後の `(a[0] and 0xe0) != 0x20` (MCP-SEC-WIRE-21、2000::/3 の外) で reserved になる。2026-10-12 に WIRE-21 を足してから、100::/64 の分岐は結果を変えなくなった。 | - (下の「気づいたこと」1) |
| `src/transport/address_policy.nim:BLR:25fb981ada75a013:0` | address_policy.nim:115 | `var discard64 = true` → `false` | equivalent | 同じ端 (MCP-SEC-WIRE-12 の 100::/64)。内側 `100::ffff:ffff:ffff:ffff`、外側 `100:0:0:1::`。変異はこの分岐で返らなくなるだけで、どちらも最後の検査 (WIRE-21) で reserved。 | - |
| `src/transport/address_policy.nim:LOR:599810830dd74984:0` | address_policy.nim:117 | `discard64 and a[i] == 0` → `or` | equivalent | 同じ端。内側 `100::ffff:ffff:ffff:ffff`、外側 `100:0:0:1::`。変異は外側もこの分岐で reserved を返すが、外側は元でも WIRE-21 で reserved。 | - |
| `src/transport/address_policy.nim:ROR:d3eeb18120899816:0` | address_policy.nim:117 | `a[i] == 0` → `!=` | equivalent | 同じ端。内側 `100::1`、外側 `100:0:0:1::`。分岐に入るか落ちるかが入れ替わるだけで、どちらの道も reserved。 | - |
| `src/transport/address_policy.nim:ROR:807614c9afd6bc95:0` | address_policy.nim:145 | `classifyAddress(ip) == acPublic` → `!=` | unreached | `isGloballyRoutable` を呼ぶコードが `src/` に無く、公開の入口のどれも export していない (`rg isGloballyRoutable` で当たるのは定義と `tests/internal/test_security_address_internal.nim` だけ)。公開の入口からこの行を通る入力は作れない。 | - (下の「気づいたこと」2) |
| `src/transport/address_policy.nim:ROR:6085680557716233:0` | address_policy.nim:159 | `text.len > 16` → `>=` | spec_question | 接頭辞を除いてちょうど 16 桁の部分 (例: `0x000000007f000001`) が、元はアドレス (127.0.0.1、loopback)、変異は名前になる。E テストの `seenHost` で「loopback」と「name」の違いとして見える。桁数の上限 16 はどの仕様 ID にも無い (MCP-SEC-WIRE-13 は「inet_aton の読み方で読む」で、inet_aton は 0 を詰めた 17 桁以上も読む。元のコードは 17 桁以上を名前にする)。前の記録 (id 102) は「どちらでも名前として解決され、得たアドレスが判定されるので安全側」として許容にしていた。 | 問い: IPv4 リテラルの 1 部分の桁数の上限 (16 桁までは読み、17 桁からは名前) を MCP-SEC-WIRE-13 に足して仕様にするか、上限を消して値の上限 (32 ビット) だけにするか。仕様にする場合の E テスト: `tests/external/test_security_address.nim` で `seenHost("0x000000007f000001") == "loopback"`、`seenHost("0x0000000007f000001") == "name"`。 |
| `src/transport/address_policy.nim:RVR:189e39fef5ff9821:0` | address_policy.nim:160 | `return none(uint64)` → `<return default>` | equivalent | 戻り値は `Option[uint64]`。`default` は none で、`none(uint64)` と同じ値。 | - |
| `src/transport/address_policy.nim:AOR:712096cfdabf46b5:0` | address_policy.nim:165 | `ord(c) - ord('a')` → `+` (16 進の小文字) | test_owed | 小文字の `a`〜`f` が 16 以上の値になり、その部分が読めず、ホストが名前になる。既存の E テストで小文字の 16 進を含むのは `0x7f.1` などを「断られること」だけ見る 1 本 (名前になっても OS の解決の結果で断られるので落ちない) で、`seenHost` で見ているのは大文字だけ。検出していた `classifyHost` のテストは `tests/internal/test_security_address_internal.nim` に移っている。 | MCP-SEC-WIRE-13 (hex in either case)。`tests/external/test_security_address.nim` の「the notations of an IPv4 literal…」に足す。既存の `seenHost` で `seenHost("0x7f.1") == "loopback"`、`seenHost("0xa9fea9fe") == "link-local"`、`seenHost("0x7f.0xbc.0xd.1") == "loopback"` (a〜f を全部通す。public になるリテラルは実際に接続しに行くので使わない)。変異だと "name"。 |
| `src/transport/address_policy.nim:AOR:a39c4a8f03967ecf:0` | address_policy.nim:165 | `ord(c) - ord('a') + 10` → `- 10` | test_owed | 小文字の `a`〜`f` が負の数になり、`uint64` への変換で巨大な値になって基数以上として断られ、ホストが名前になる。 | MCP-SEC-WIRE-13。上の行と同じ 1 本で検出できる。 |
| `src/transport/address_policy.nim:RVR:837f93a5a6a3cef7:0` | address_policy.nim:167 | `else: return none(uint64)` → `<return default>` | equivalent | `Option[uint64]` の既定値は none。 | - |
| `src/transport/address_policy.nim:RVR:189e39fef5ff9821:1` | address_policy.nim:169 | `return none(uint64)` → `<return default>` | equivalent | 同上。 | - |
| `src/transport/address_policy.nim:RVR:189e39fef5ff9821:2` | address_policy.nim:172 | `return none(uint64)` → `<return default>` | equivalent | 同上。 | - |
| `src/transport/address_policy.nim:ROR:5c144123e0d1c803:0` | address_policy.nim:182 | `text.len > 1` → `>=` | equivalent | 長さ 1 の文字列は、先頭が `[` で末尾が `]` にはなれない (同じ 1 文字)。`>= 1` でも条件の結果は変わらない。 | - |
| `src/transport/address_policy.nim:LOR:0ec7ea83d23e569b:0` | address_policy.nim:182 | `text.len > 1 and text[0] == '['` → `or` | unreached | 違いが出るのは、空のホスト (変異は `text[0]` で IndexDefect) と、`[` で始まらず `]` で終わるホストだけ。公開の入口から届くホストは `parseUri` の hostname で `[` `]` を含まず、空のホストは `checkFetchUrl`・`narrowedTo`・`checkRedirectUri`・`isSafeIconUri` が先に断る (上の前提)。 | - (下の「気づいたこと」3) |
| `src/transport/address_policy.nim:ROR:39d08468294bbef9:0` | address_policy.nim:182 | `text[0] == '['` → `!=` | unreached | 違いが出るのは `[` で始まるホストか `]` で終わるホストだけ。`parseUri` の hostname は `[` `]` を含まない (上の前提)。検出していたテスト (「Given brackets that do not enclose the whole host…」) は `parseHostLiteral` を直接呼ぶもので、`tests/internal/` に移っている。 | - |
| `src/transport/address_policy.nim:LOR:8a87907c3adf061b:0` | address_policy.nim:182 | `… and text[^1] == ']'` → `or` | unreached | 違いが出るのは、空のホスト (変異は `text[^1]` で IndexDefect) と `]` で終わるホストだけ。どちらも公開の入口からは届かない (上の前提)。 | - |
| `src/transport/address_policy.nim:ROR:8675285f10785e89:0` | address_policy.nim:182 | `text[^1] == ']'` → `!=` | unreached | 違いが出るのは `[` で始まるホストだけ。`parseUri` の hostname は `[` で始まらない (上の前提)。 | - |
| `src/transport/address_policy.nim:RVR:cd25a55c955dff67:0` | address_policy.nim:185 | `return none(IpAddress)` → `<return default>` | equivalent | 戻り値は `Option[IpAddress]`。`default` は none で同じ値。 | - |
| `src/transport/address_policy.nim:RVR:cd25a55c955dff67:1` | address_policy.nim:190 | `return none(IpAddress)` → `<return default>` | equivalent | 同上。 | - |
| `src/transport/address_policy.nim:RVR:cd25a55c955dff67:2` | address_policy.nim:193 | `return none(IpAddress)` → `<return default>` | equivalent | 同上。 | - |
| `src/transport/address_policy.nim:RVR:cd25a55c955dff67:3` | address_policy.nim:198 | `return none(IpAddress)` → `<return default>` | equivalent | 同上。 | - |
| `src/transport/address_policy.nim:ROR:5f70ca975cb2f940:0` | address_policy.nim:201 | `numbers[i] > 255` → `>=` (最後でない部分) | test_owed | 最後でない部分がちょうど 255 のリテラル (例: `10.255.0.1`) が、元はアドレス (private)、変異は名前になる。既存の E テストは、最後の部分の端 (`10.2.3.255` と `10.2.3.256`) しか見ていない。 | MCP-SEC-WIRE-13 (最後でない部分は 1 バイト)。端の内側 `10.255.0.1`、外側 `10.256.0.1`。`tests/external/test_security_address.nim` の「the notations of an IPv4 literal…」に、既存の `seenHost` で `seenHost("10.255.0.1") == "private"`、`seenHost("10.256.0.1") == "name"` を足す。変異だと 1 つ目が "name"。 |
| `src/transport/address_policy.nim:RVR:cd25a55c955dff67:4` | address_policy.nim:202 | `return none(IpAddress)` → `<return default>` | equivalent | `Option[IpAddress]` の既定値は none。 | - |
| `src/transport/address_policy.nim:RVR:cd25a55c955dff67:5` | address_policy.nim:205 | `return none(IpAddress)` → `<return default>` | equivalent | 同上。 | - |
| `src/transport/address_policy.nim:RVR:7d1eedc761f25d37:0` | address_policy.nim:231 | `classifyHost` の `return some(acReserved)` → `<return default>` (none) | spec_question | `:` を含むが IPv6 として読めないホスト (例: `https://[::zz]/authorize`) が、reserved ではなく「名前」になる。取りに行く URL では、`chooseDestination` が同じホストを「malformed」で断るので、違いは文面だけ (どちらも OAuthSecurityError)。しかし取りに行かない URL (`metadata.nim` が `checkFetchUrl` で確かめる `authorization_endpoint`、`client.nim` の client metadata document URL) では、元は断り、変異は通して利用者をその URL に送る。「読めないアドレスは reserved として断る」はどの仕様 ID にも無い (MCP-SEC-WIRE-4 は読めるアドレスの表記、MCP-AUTH-38 は plain http だけ)。 | 問い: `:` を含むが IPv6 として読めないホストの URL を、取りに行かないエンドポイントでも断ることを仕様 (MCP-SEC-WIRE-4 か MCP-AUTH-38 に 1 行) にするか。仕様にする場合の E テスト: `tests/external/test_auth_oauth_basics.nim` の「Given metadata with a plain http authorization or registration endpoint…」と同じ形 (`startFakeAs`・`startFakeRs`・`clientOf(…).unchallenged()`) で、`authServer.metadata["authorization_endpoint"] = %"https://[::zz]/authorize"` に OAuthSecurityError を期待する。このファイルは今の testCommand に無いので、足すときは testCommand にも入れる。 |
| `src/transport/address_policy.nim:SDL:ad636063358436a8:0` | address_policy.nim:232 | 末尾の `none(AddressClass)` → `discard` | equivalent | `classifyHost` の `result` の既定値が none。末尾の式を捨てても同じ値が返る。 | - |
| `src/transport/address_policy.nim:SDL:1d7d0c7158c7c7b0:0` | address_policy.nim:254 | `systemAddresses` の `result.add text` → `discard` | test_owed | resolver を渡さないとき (`FetchPolicy.resolver`・`IconFetchOptions.resolver` が nil) に、OS の解決の答えが空になり、名前のホストがすべて「cannot resolve」で断られる。E テストは名前のホストに必ず resolver を渡していて、OS の解決を通るものが無い (リテラルは解決に回らない)。検出していたテスト (「Given a host written as an address, when the system resolver is asked…」) は `systemAddresses`・`resolveHost` を直接呼ぶもので、`tests/internal/` に移っている。 | MCP-SEC-WIRE-5 (名前は解決した先で判定し、その先へ接続する)。`tests/external/test_security_address.nim` に足す。既存の redirect のテストと同じ 127.0.0.1 の待ち受けを立て、サーバーは `http://127.0.0.1:<port>/mcp`、既定の方針 (resolver なし) で、challenge の metadata URL を `http://localhost:<port>/x` にする。`requested == @["GET /x HTTP/1.1"]` を見る。変異だと解決できずに断られ、要求が届かない。注意: `localhost` を OS のリゾルバに渡す (外には出ないが、前のリードの判断は「渡すのは数値だけ」だった)。これを E テストで許すかは司会が決めてほしい。許さないなら、この 4 件は公開の入口から決定的に確かめる道が無い。 |
| `src/transport/address_policy.nim:SDL:587af74a67c0104c:0` | address_policy.nim:257 | `finally: freeAddrInfo(info)` → `discard` | spec_question | `getaddrinfo` の結果を解放しなくなる。戻り値・例外・通信は変わらず、変わるのはプロセスのメモリ (名前を解決するたびに漏れる) だけ。E テストでは見えず、どの仕様 ID にも当たらない。文面の違いではないので、代表の決定 (2026-10-23) の許容には当たらない。前の記録 (id 175) は「リーク検査の担当」として許容にしていたが、代表が受け入れた記録は無い。 | 問い: 資源の漏れだけが変わる変異 (解放を消すもの) を、G2 では「E テストの対象外。リーク検査で守る」として受け入れると決めるか。 |
| `src/transport/address_policy.nim:ROR:22cf8d6f11883448:0` | address_policy.nim:258 | `systemAddresses` の `result.len == 0` → `!=` | test_owed | OS の解決が答えを返したときに OSError になり、名前のホストがすべて「cannot resolve」で断られる。 | MCP-SEC-WIRE-5。254 行と同じ 1 本で検出できる。 |
| `src/transport/address_policy.nim:SDL:a49b63d6c5610a7a:0` | address_policy.nim:266 | `resolveHost` の `result.add parseIpAddress(text)` → `discard` | test_owed | OS の解決の答えを 1 つも受け取らず、名前のホストがすべて「cannot resolve」で断られる。 | MCP-SEC-WIRE-5。254 行と同じ 1 本で検出できる。 |
| `src/transport/address_policy.nim:ROR:22cf8d6f11883448:1` | address_policy.nim:269 | `resolveHost` の `result.len == 0` → `!=` | test_owed | OS の解決が答えを返したときに OSError になる。 | MCP-SEC-WIRE-5。254 行と同じ 1 本で検出できる。 |
| `src/transport/guarded_wire.nim:BLR:6129904a4ce5d728:0` | guarded_wire.nim:16 | 引数の既定値 `followRedirects = false` → `true` | unreached | `guardedRequest` を呼ぶのは `auth/oauth/fetch.nim` の `exchange` (`followRedirects = false` を明示) と `client/icons.nim` の `guardedGet` (`true` を明示) の 2 か所だけで、どちらも既定値を使わない。`guardedRequest` は公開の入口から export されていない。検出していたテスト (「Given an answer that redirects, when no one asked for redirects to be followed…」) は `guardedRequest` を直接呼ぶもので、`tests/internal/` に移っている。E テストの「Given a metadata URL that answers with a redirect…」は `fetch.nim` の明示の `false` を確かめている。 | - (MCP-SEC-WIRE-11 の「unless asked」は、公開の入口からは `fetch.nim` の経路でだけ確かめられる) |

### 気づいたこと (分類は上のとおり。決めるのは代表)

1. `classifyAddress` の 100::/64 の分岐 (address_policy.nim:113-119) は、MCP-SEC-WIRE-21 (2000::/3 の外は reserved) を足してから結果を変えない。MCP-SEC-WIRE-12 の文面には 100::/64 が残っている。分岐を消すか、説明のために残すかは決まっていない。
2. `isGloballyRoutable` は公開の印 (`*`) が付いているが、呼ぶコードも export する入口も無い。docstring は「webhook の宛先の既定の検査」と言うが、その webhook のコードはこのブランチに無い。
3. `parseHostLiteral` の「`[` `]` で囲んだ IPv6 を受ける」(address_policy.nim:182-183) は、公開の入口から届くホストが `parseUri` の hostname だけなので、今は通らない。MCP-SEC-WIRE-13 の表 (`specs/tests.map`) でこれを確かめているのは内部のテストだけ。

測定: 変異検査の道具、ジョブ `tests/mutation/address_policy.json`、本線の 36a4c8a5 (2026-10-07)。
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
- 変異検査 (変異検査の道具) は流していない。`docs/quality/g2-protocol-versions.md` は触っていない。

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

司会の追記 (2026-11-11): 254・258・266・269 行の 4 件 (案 C) は、台帳では spec_question にした。検出するには E テストが `localhost` を OS のリゾルバに渡す必要があり、このジョブの前の判断 (渡すのは数値だけ) を変えることになるため、代表に問う。182 行の 4 件の unreached は、Nim 2.2.12 で `parseUri("https://[::1]:8080/x").hostname` が `::1` を返すことを流して確かめた。
