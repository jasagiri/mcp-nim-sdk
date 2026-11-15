# G2 変異検出: server ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: nim-muter 0.2.15、全 517 変異。killed 414、survived 71、timeout 3、compileError 29。
生き残りは 2 人で分担して仕分けた (server.nim の 1119 行より前と、それ以降およびほかのファイル)。

### server.nim の 1118 行までの生き残り

状態: 測定済み。32 件を仕分けた (test_owed 7、spec_question 11、equivalent 8、unreached 1、accepted 5、undecided 0)。行番号は測定時 (b04fcb9c) のもの。変異を当てて走らせてはいない (式と呼び出し元を読んだ)。

| 指紋 | 場所 | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/server/server.nim:SDL:a83049649b1ae0f4:0` | server.nim:549 | `doAssert negotiated.isSome, …` → `discard` | unreached | `negotiateLegacyVersion` が none を返すのは、サーバーが旧版を 1 つも話さないときだけ。そのサーバーでは `isModernPath` が真になり (`not server.speaksLegacy`)、`initialize` は `handleModernRequest` の先頭の検査が断るので `handleInitialize` に来ない。表明を偽にする入力を公開の入口から作れない | |
| `src/server/server.nim:SDL:932eac12f9b57944:0` | server.nim:580 | `stderr.writeLine("… initialized notification in state … ignored")` → `discard` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。通知を無視することは保たれ (直後の `return`)、消えるのは stderr の診断の 1 行だけ。この行を定める仕様 ID は無く、プログラムも読まない | |
| `src/server/server.nim:SDL:a0221c45aefc8214:0` | server.nim:596 | `stderr.writeLine("… notifications/cancelled without a usable requestId ignored")` → `discard` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。不正な取り消しを無視することは保たれ (MCP-CANCEL-9 が確かめる)、消えるのは stderr の診断の 1 行だけ | |
| `src/server/server.nim:ROR:99ececf14e11d202:0` | server.nim:603 | `reason.len > 0` → `>=` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。理由の無い取り消しの診断の行の末尾に `: ` が付くだけ。MCP-CANCEL-8 が定めるのは理由つきの取り消しの行で、そちらは変わらない | |
| `src/server/server.nim:RVR:55560fa5ef49175d:0` | server.nim:691 | `return none(JsonRpcError)` → `<return default>` | equivalent | `default(Option[JsonRpcError])` は none。返る値が同じ | |
| `src/server/server.nim:SDL:ac1cdc5394dff63c:0` | server.nim:702 | 末尾の `none(JsonRpcError)` → `discard` | equivalent | 手続きの最後の式。`discard` にすると `result` の既定値が返り、それは none | |
| `src/server/server.nim:ROR:049ce7071c2450f3:0` | server.nim:742 | `perSecond > 0` → `>=` | equivalent | 違いが出るのは `maxProgressPerSecond == 0` のときだけ (0 で割る)。`progressIntervalMs` を呼ぶのは `progressWanted` と `scheduleProgressFlush` で、どちらも `reportProgress` の `perSecond > 0` (798 行) が真のときにしか呼ばれない。負の値は前後とも偽 | |
| `src/server/server.nim:LOR:df64d69160ddee26:0` | server.nim:746 | `progressSentAt == default(MonoTime) or elapsed >= interval` → `and` | spec_question | 最初の 1 通は前後とも送る (既定の時刻からの経過は巨大)。2 通目以降は、変異だと間隔が明けていても必ず抑えてタイマー (1 ms 後) か要求の終わりに送る。届く値と数は同じで、変わるのは「`reportProgress` が戻った時点で送り終えているか」と、ほかの通知との順序だけ。MCP-PROGRESS-10 はそこを言っていない | 問い 1 (下)。仕様にするなら: 上限 2/秒、1 を報告、600 ms 待って 2 を報告し、`reportProgress` が戻った直後に通信路が 2 を持つことを見る (変異だとまだ無い) |
| `src/server/server.nim:ROR:b614b41f99a310c4:0` | server.nim:747 | `elapsed >= interval` → `>` | spec_question | 上限が 1000 以下なら、違いは経過がちょうど間隔と同じ ms のときだけで、時計を差し替えられないので作れない。上限が 1000 を超えると間隔が 0 ms に丸まり、元は無制限に送り、変異は同じ ms の報告を抑える。1000 を超える上限の意味は、どの仕様 ID も言っていない | 問い 2 (下) |
| `src/server/server.nim:BLR:d2d47480390fbf49:0` | server.nim:765 | `ctx.progressFlushScheduled = false` → `true` | spec_question | 変異だと、1 度タイマーが走った後は 2 度とタイマーを掛けない。抑えた値は次の報告か要求の終わりまで出ない。MCP-PROGRESS-10 が言う「最後の値は応答の前に届く」は 1631 行の `flushProgress` が満たすので、どのテストも落ちない。「ハンドラが走っている間に間隔が明けたら送る」は仕様 ID に無い | 問い 1。仕様にするなら: 上限 2/秒、1・2 を続けて報告、700 ms 待つ、3・4 を続けて報告、700 ms 待つ。ハンドラが戻る前に 4 が届いていること (変異だと届かない) |
| `src/server/server.nim:SDL:76a93fa5ca3cf1c2:0` | server.nim:767 | `await ctx.flushProgress()` → `discard` | spec_question | タイマーが何も送らなくなる。抑えた値は次の報告か要求の終わりに出る。765 行と同じく、間隔が明けた時点で送ることを言う仕様 ID が無い | 問い 1。仕様にするなら: 上限 2/秒、1・2 を続けて報告して 1.5 秒待つ。待っている間に 2 が届いていること |
| `src/server/server.nim:SDL:fc6dc7040ef9eae0:0` | server.nim:769 | `stderr.writeLine("… could not send held progress: …")` → `discard` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。変わるのは stderr の 1 行だけで、応答も状態も変わらない。この行を定める仕様 ID は無い | |
| `src/server/server.nim:BLR:d3d9dea44044874b:0` | server.nim:775 | `ctx.progressFlushScheduled = true` → `false` | spec_question | 変異だと、抑えるたびにタイマーが増える。どのタイマーも「最後に送った時刻 + 間隔」を狙い、最初の 1 本が抑えた値を空にするので、残りは何もしない。違いが出るのは、2 本のタイマーの発火の間 (1 ms 未満) に新しい報告が挟まったときだけで、テストから作れない。タイマーの仕組みそのものが仕様かどうかに従う | 問い 1。タイマーを仕様にしても、この 1 件は時刻の競合でしか違いが出ないので、そのときは理由を書き直す |
| `src/server/server.nim:SDL:960dc7cba28a5fd4:0` | server.nim:777 | `asyncCheck ctx.flushProgressLater(…)` → `discard` | spec_question | タイマーを掛けない (旗は立ったまま)。767 行と同じ | 問い 1。767 行と同じテスト |
| `src/server/server.nim:AOR:6c8a3b9884d8c722:0` | server.nim:777 | `ctx.progressIntervalMs - sinceMs` → `+` | spec_question | タイマーが遅れる (最大で間隔の 2 倍)。届く値は同じで、変わるのは届く時刻だけ | 問い 1。仕様にするなら: 上限 2/秒、1 を報告、400 ms 待って 2 を報告、さらに 500 ms 後 (元は 100 ms 後に届く。変異は 900 ms 後) に 2 が届いていること |
| `src/server/server.nim:ROR:e470916accc3a50e:0` | server.nim:798 | `perSecond > 0` → `>=` | equivalent | 違いが出るのは 0 のときだけ。そのとき `progressWanted` が呼ばれるが、`progressIntervalMs` は 0 を返し (742 行)、経過 >= 0 は常に真なので抑えない。前後とも 10 通すべて送る | |
| `src/server/server.nim:SDL:b67c640ef3e799a4:0` | server.nim:803 | `ctx.scheduleProgressFlush()` → `discard` | spec_question | タイマーを掛けない。767 行と同じ | 問い 1。767 行と同じテスト |
| `src/server/server.nim:SDL:1dfce068d3c256ff:0` | server.nim:882 | `stderr.writeLine("… could not cancel timed out …")` → `discard` | accepted | 失敗の文面は契約ではない (代表の決定 2026-10-23)。時間切れは直後の `McpRequestTimeout` で呼び手に伝わる。消えるのは、取り消しの通知を送れなかったことの stderr の 1 行だけ | |
| `src/server/server.nim:ROR:e21ca2205ff1179f:0` | server.nim:939 | `version < mpv20251125` → `<=` | test_owed | 2025-11-25 のクライアントが sampling.context を宣言していなくても、thisServer を断らずに送る | MCP-SAMPLING-TOOLS-16。既存の `tests/external/test_sampling_asks_fix.nim` の「Given a client that declared sampling without context, when the server asks with includeContext thisServer or allServers, then it raises and sends nothing」が検出するはず。testCommand に足す |
| `src/server/server.nim:LOR:1ba5c18cfd67e07a:0` | server.nim:939 | `version < mpv20251125 or params.isNil` → `and` | test_owed | 2025-11-25 より前の版のクライアント (sampling.context という capability が無い) に thisServer を尋ねると、変異は断る。元は送る。既存のテストはどれも 2025-11-25 以降だけを回す | MCP-SAMPLING-TOOLS-16 (Scenario に「2025-11-25 より前の版には、宣言が無くても送る」の 1 行が要る)。案: sampling を宣言した 2025-06-18 のクライアントに `server.createMessage` で includeContext thisServer を尋ね、要求が 1 通送られること (変異だと失敗して何も送らない) |
| `src/server/server.nim:LOR:30db418c2ad7dda5:0` | server.nim:939 | `… or params.isNil or params.kind != JObject` → `and` | test_owed | params が nil のとき、変異は nil の `kind` を読んで落ちる (SIGSEGV)。元は none を返し、次の `createMessageParamsProblems` が断る。nil でない params では前後で同じ | MCP-SAMPLING-TOOLS-9。案: 2025-11-25 以降のクライアントに `server.createMessage(session, nil)` を呼び、future が失敗で終わり、何も送られないこと (変異だとテストのプロセスが落ちる) |
| `src/server/server.nim:ROR:215d7c788bb4b647:0` | server.nim:939 | `params.kind != JObject` → `==` | test_owed | オブジェクトの params で常に none を返し、thisServer を断らない | MCP-SAMPLING-TOOLS-16。既存の `tests/external/test_sampling_asks_fix.nim` の同じテスト (… then it raises and sends nothing) が検出するはず。testCommand に足す |
| `src/server/server.nim:LOR:fedbc6ac5ee3bcb9:0` | server.nim:939 | `… or params.kind != JObject or capability.context` → `and` | test_owed | sampling.context を宣言したクライアントにも thisServer を断る | MCP-SAMPLING-TOOLS-16。既存の `tests/external/test_sampling_asks_fix.nim` の「Given a client that declared sampling.context, when the server asks with includeContext thisServer or allServers, then the request is sent」が検出するはず。testCommand に足す |
| `src/server/server.nim:RVR:0c511227513989c7:0` | server.nim:940 | `return none(string)` → `<return default>` | equivalent | `default(Option[string])` は none。返る値が同じ | |
| `src/server/server.nim:RVR:e76d06edc181a757:0` | server.nim:942 | `return some("the client did not declare the sampling.context capability")` → `<return default>` | test_owed | none が返り、`createMessage` が断らずに送る。文面だけの変異ではない (断ること自体が消える) | MCP-SAMPLING-TOOLS-16。既存の `tests/external/test_sampling_asks_fix.nim` の「… then it raises and sends nothing」が検出するはず。testCommand に足す |
| `src/server/server.nim:SDL:2413a04126052c00:0` | server.nim:943 | 末尾の `none(string)` → `discard` | equivalent | 手続きの最後の式。`result` の既定値は none | |
| `src/server/server.nim:SDL:a03926d31f0f6ba8:0` | server.nim:962 | `raiseIfAny("sampling/createMessage", samplingToolResultProblems(params))` → `discard` | test_owed | outputSchema に合わない structuredContent を持つ tool_result を、断らずに送る | MCP-SAMPLING-TOOLS-17。既存の `tests/external/test_sampling_asks_fix.nim` の「Given a tool_result whose structuredContent breaks the outputSchema of its tool, when the server asks, then it is refused and nothing is sent」が検出するはず (`{"temp": "hot"}` はこの検査だけが断る)。testCommand に足す |
| `src/server/server.nim:LOR:da079c31597359f5:0` | server.nim:1061 | `tools.isNil or tools.kind != JArray` → `and` | equivalent | 呼び出し元は tools/list の 1341 行だけで、渡るのは `listPage` が作った応答。`listPage` は必ず `payload["tools"] = newJArray()` を置くので、`tools` は nil でない配列。前後とも偽で、先へ進む。この早期 return (1058〜1062 行) は届かない防御で、消せばこの変異も無くなる | |
| `src/server/server.nim:SDL:36bdbcdcc4bd7dce:0` | server.nim:1067 | `stderr.writeLine("… not listing tool '…': …")` → `discard` | spec_question | 一覧から外すことは保たれる (MCP-HTTP-11 が確かめる)。消えるのは、ハンドラの誤りを知らせる stderr の 1 行。docstring は「The handler's mistake is logged, not hidden」と言うが、仕様 ID が無い。クライアントには何も伝わらないので、この行が誤りの唯一の出口 | 問い 3 (下)。仕様にするなら: x-mcp-header が不正な tool を 1 つ返すサーバーに 2026-07-28 で tools/list を呼び、stderr に tool の名前を含む 1 行が出ること |
| `src/server/server.nim:SDL:8f8eca04c2e996e4:0` | server.nim:1079 | `stderr.writeLine("[mcp-server] " & peerText(methodName) & ": " & why)` → `discard` (`logDefect` の本体) | spec_question | ハンドラの欠陥は、クライアントには「Internal error」とだけ返し、原因は stderr に書く。変異だと原因がどこにも残らない。行の文言ではなく、行があることの問い。同じ形の行を仕様にした例がある (MCP-TRANSPORT-3、MCP-SEC-HTTP-8) が、この行には仕様 ID が無い | 問い 3。仕様にするなら: blob が base64 でない resources/read の結果を返すハンドラを呼び、応答が -32603 で、stderr にメソッド名を含む 1 行が出ること |
| `src/server/server.nim:SDL:88577c9e13b7fdfc:0` | server.nim:1083 | `logDefect(methodName, why)` → `discard` (`handlerDefect`) | spec_question | 1079 行と同じ。`handlerDefect` を通る 3 か所 (resources/read・tools/list・prompts/get) で原因が残らなくなる | 問い 3。1079 行と同じテスト |
| `src/server/server.nim:RVR:3ac2bd94b4efe6f7:0` | server.nim:1111 | `return none(JsonNode)` → `<return default>` | equivalent | `default(Option[JsonNode])` は none。返る値が同じ | |

代表への問い:

- 問い 1 (746・765・767・775・777 の 2 件・803 行、計 7 件): 抑えた進捗を、ハンドラがまだ走っている間に、間隔が明けた時点で送ること (タイマー) を仕様にするか。
  - 案 A (推奨): 仕様にする。MCP-PROGRESS-10 に足すか MCP-PROGRESS-11 を作り、「抑えた値は、次の報告が無くても間隔が明けたら届く」「間隔が明けた後の報告は、その場で送る」を書いて、表の案のテストを足す。理由: まとめて報告した後に長く黙って働くハンドラでは、タイマーが無いとクライアントが古い進捗を応答まで見続ける。
  - 案 B: 仕様にしない。`flushProgressLater`・`scheduleProgressFlush`・`progressFlushScheduled` を消し、抑えた値は次の報告か要求の終わりに送るだけにする。7 件は無くなる。
- 問い 2 (747 行): `maxProgressPerSecond` が 1000 を超えるとき、どう振る舞うか。今は `1000 div perSecond` が 0 になり、制限が掛からない (欠陥の疑い)。
  - 案 A (推奨): 間隔を 1 ms 以上にする (1000 を超える上限は 1000 と同じ) と決め、MCP-PROGRESS-10 に書く。境界 (ちょうど同じ ms) の違いは時計を差し替えられないので残り、そのときに理由を書く。
  - 案 B: 「1000 を超える値は制限なし」を仕様にし、上限 2000 で 10 通すべて届くテストを足す (変異は同じ ms の報告を抑えるので落ちる)。
- 問い 3 (1067・1079・1083 行): ハンドラの誤りでサーバーが内部エラーを返す・tool を一覧から外すとき、原因を stderr に 1 行書くことを仕様にするか。
  - 案 A (推奨): 仕様にする (MCP-SEC-HTTP-8 と同じ形: 相手には内部の詳細を渡さず、こちら側に 1 行残す)。文言は確かめず、行があることとメソッド名・tool の名前を含むことだけを確かめる。理由: クライアントには原因が伝わらないので、この行が消えるとハンドラを書いた人が原因を知る手段が無い。
  - 案 B: 「失敗の文面は契約ではない (代表の決定 2026-10-23)」に含めて accepted にする。行の有無まで文面とみなすことになる。

timeout の 3 件 (どれも「ただ遅い」ではなく、来ない合図を待ち続けて止まる。無限ループではない):

- `src/server/server.nim:SDL:c54b6bb249cbda80:0` (server.nim:1216、`server.subscriptions.add subscription` → `discard`): 購読が表に載らないので、通知の配信も `endSubscriptions` もこの購読を見つけない。listen の応答が返らず、それを待つテストが終わらない。
- `src/server/server.nim:SDL:cba6c56101be01b8:0` (server.nim:1221、`subscription.closed.completesWith(ended)` → `discard`): 購読を終えても `ended` が完了せず、`await ended` が戻らない。listen の応答を待つテストが終わらない。
- `src/server/server.nim:SDL:9963156d79866778:0` (server.nim:1906、`subscription.closed.complete()` → `discard`): 同じく `ended` が完了しない。サーバーが購読を終えた後の listen の応答を待つテストが終わらない。

### server.nim の 1119 行以降と pagination.nim・completion.nim・log_level.nim の生き残り

状態: 測定済み。39 件 (server.nim 32、pagination.nim 5、completion.nim 1、log_level.nim 1)。
equivalent 20、test_owed 5、spec_question 9、accepted 5、unreached 0、undecided 0。行番号は測定時 (b04fcb9c) のもの。

spec_question は 2 つの問いにまとまる。

- 問い A (8 件、表の「問い A」): 失敗の原因が stderr の 1 行にしか出ない箇所 (相手には "Internal error" だけを返す、または失敗を捕まえて続ける) で、
  その行が在ることを仕様にするか。選択肢: (1) 仕様にする。MCP-ERRORS-1 の「a handler that fails ... is told to the peer as "Internal error"」に
  「原因は stderr の 1 行に出る」を足すか、MCP-TRANSPORT-3・MCP-SEC-HTTP-9 と同じ形の Scenario を 1 つ足し、E テストは SDK の文言ではなく
  ハンドラ自身のメッセージ・ツール名が stderr に出ることを見る。(2) 「失敗の文面は契約ではない (代表の決定 2026-10-23)」に含めて accepted とする。
  推奨は (1): 行を消すと失敗が黙って消え、「エラーを握り潰さない」の規則を守っているのがこの行だけだから。行の文言は (2) のまま契約にしない。
  2026-10-07 の「分類 6 許容」はリードの判断で、代表の決定の記録が無いので根拠にしていない。
- 問い B (1 件): 終わった要求を処理中の表から消すこと (消さないと表が要求の数だけ育つ) を仕様にするか。選択肢: (1) 外から見える数
  (`sessionCount`・`subscriptionCount` と同じ形の件数) を足して仕様と E テストにする。(2) 外から見えない資源の後始末として equivalent とする。
  推奨は (2)。応答も取り消しの結果も変わらず、このためだけに公開 API を足すのは「公開 API を絞る」に反する。メモリの伸びは変異検査ではなく長時間の実測で見る。

| 指紋 | 場所 | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/protocol/log_level.nim:SDL:a664419c0a0c689c:0` | log_level.nim:24 | 末尾の `none(McpLogLevel)` → `discard` | equivalent | `result` の既定値が `Option` の none で、末尾の式を消しても同じ値を返す。 | |
| `src/server/completion.nim:LOR:d6c43bcc123b2459:0` | completion.nim:24 | `node.isNil or node.kind != JObject` → `and` | equivalent | `requiredString` は非公開で、呼び出し元 (`parseCompletionRequest` の `reference`・`argument`) は直前で nil でない JObject だと確かめてから渡す。どちらの式も常に偽。この検査自体が要らない (`node{key}` だけで足りる)。 | |
| `src/server/pagination.nim:RVR:534e648d390a1b6f:0` | pagination.nim:29 | `return none(int)` → `return default` | equivalent | `default(Option[int])` は none。`pageOf` は `isNone` で断るので同じ。 | |
| `src/server/pagination.nim:RVR:534e648d390a1b6f:1` | pagination.nim:34 | `return none(int)` → `return default` | equivalent | 同上。 | |
| `src/server/pagination.nim:RVR:534e648d390a1b6f:2` | pagination.nim:36 | `return none(int)` → `return default` | equivalent | 同上。 | |
| `src/server/pagination.nim:RVR:534e648d390a1b6f:3` | pagination.nim:41 | `return none(int)` → `return default` | equivalent | 同上。 | |
| `src/server/pagination.nim:RVR:534e648d390a1b6f:4` | pagination.nim:43 | `return none(int)` → `return default` | equivalent | 同上。 | |
| `src/server/server.nim:RVR:3ac2bd94b4efe6f7:1` | server.nim:1119 `listedEntry` | `return none(JsonNode)` → `return default` | equivalent | `default(Option[JsonNode])` は none。 | |
| `src/server/server.nim:SDL:d1c044ccecdaa480:0` | server.nim:1121 `listedEntry` | 1000 ページを超えた一覧の stderr の行 → `discard` | spec_question | 問い A。行を消すと、止まらないカーソルを出すハンドラのツールが「一覧に無い」のと区別なく扱われ、原因がどこにも出ない。 | 仕様にするなら: 1001 ページ目もカーソルを返す `toolsList` に `tools/call` し、stderr にメソッド名とツール名が出ることを見る。 |
| `src/server/server.nim:SDL:f85418f42f56ae88:0` | server.nim:1123 `listedEntry` | 末尾の `none(JsonNode)` → `discard` | equivalent | `result` の既定値が none。 | |
| `src/server/server.nim:RVR:0c511227513989c7:1` | server.nim:1134 `missingPromptArgument` | `return none(string)` → `return default` | equivalent | `default(Option[string])` は none。 | |
| `src/server/server.nim:SDL:2413a04126052c00:1` | server.nim:1139 `missingPromptArgument` | 末尾の `none(string)` → `discard` | equivalent | `result` の既定値が none。 | |
| `src/server/server.nim:RVR:55560fa5ef49175d:1` | server.nim:1163 `paramHeaderMismatch` | `return none(JsonRpcError)` → `return default` | equivalent | `default(Option[JsonRpcError])` は none。 | |
| `src/server/server.nim:RVR:55560fa5ef49175d:2` | server.nim:1166 `paramHeaderMismatch` | `return none(JsonRpcError)` → `return default` | equivalent | 同上。 | |
| `src/server/server.nim:RVR:87aa8baa528c4cef:0` | server.nim:1175 `inputProblems` | `return ""` → `return default` | equivalent | 文字列のリテラルの置き換え先は `""` で、元と同じ値。 | |
| `src/server/server.nim:SDL:54751f1833f11faf:0` | server.nim:1179 `inputProblems` | 確かめられない inputSchema の stderr の行 → `discard` | spec_question | 問い A。相手には "Internal error" だけが返り、どのツールのスキーマがなぜ使えないかはこの行にしか出ない。 | 仕様にするなら: inputSchema が使えないツールへの `tools/call` で、-32603 に加えて stderr にツール名が出ることを見る (tools の入力検査の Scenario に足す)。 |
| `src/server/server.nim:ROR:7e4dba6fe46fb9ea:0` | server.nim:1205 `listen` | `maxListenStreamsPerSession > 0` → `>=` | test_owed | 上限 0 (制限なし) のとき、変異ではどの `subscriptions/listen` も "Too many listen streams" で断られる。既存のテストは名前に「0 means no limit」とあるが、既定値しか見ていない。 | MCP-SEC-SWEEP-7 (0: no limit)。`tests/external/test_security_subscription_limits.nim` に足す: `maxListenStreamsPerSession = 0` で 1 つの session が既定の 16 を超える (たとえば 17 本の) listen を開き、どれも断られず `subscriptionCount` が本数になる。 |
| `src/server/server.nim:ROR:7dcb1e3bc7bd7f72:0` | server.nim:1308 `resources/subscribe` | `maxSubscriptionsPerSession > 0` → `>=` | test_owed | 上限 0 のとき、変異では最初の `resources/subscribe` から "Too many subscriptions" になる。 | MCP-SEC-SWEEP-7 (0: no limit)。同じテストで `maxSubscriptionsPerSession = 0` とし、`resources/subscribe` がエラーにならないことを見る (1 件で足りる)。 |
| `src/server/server.nim:SDL:4a51256852b1bc32:0` | server.nim:1457 `inputRequiredResponse` | `defect` の stderr の行 → `discard` | spec_question | 問い A。input_required を出せないハンドラの誤りは、相手には "Internal error" だけで、理由はこの行にしか出ない。 | 仕様にするなら: input_required を許さない版・メソッドで `McpInputRequired` を投げるハンドラを呼び、stderr にメソッド名と理由が出ることを見る。 |
| `src/server/server.nim:ROR:eed3e77b3bbe9689:0` | server.nim:1467 `inputRequiredResponse` | `payloadProblems.len == 0` → `!=` | test_owed | 変異では、形の正しい inputRequests の tool_result を outputSchema と照らさず、input_required を返してしまう。 | MCP-SAMPLING-TOOLS-17。既存の `tests/external/test_sampling_asks_fix.nim` の「Given a 2026-07-28 handler that asks with a tool_result that breaks the schema, when the request is served, then the answer is an error and not input_required」が検出するはず。testCommand に足す (新しいテストは要らない)。 |
| `src/server/server.nim:ROR:2bc73289de46c34c:0` | server.nim:1469 `inputRequiredResponse` | `entry{"method"}.getStr() == SamplingMethod` → `!=` | test_owed | 変異では sampling の項目だけが照合から外れる。 | MCP-SAMPLING-TOOLS-17。同上の既存のテスト。 |
| `src/server/server.nim:SDL:4e20a99a93ab2350:0` | server.nim:1471 `inputRequiredResponse` | `payloadProblems.add …` → `discard` | test_owed | 変異では見つけた問題を捨て、input_required を返す。 | MCP-SAMPLING-TOOLS-17。同上の既存のテスト。 |
| `src/server/server.nim:RVR:9bd38dfae0fced9f:0` | server.nim:1519 `unusableResultType` | `return none(JsonRpcResponse)` → `return default` | equivalent | `default(Option[JsonRpcResponse])` は none。 | |
| `src/server/server.nim:RVR:9bd38dfae0fced9f:1` | server.nim:1525 `unusableResultType` | `return none(JsonRpcResponse)` → `return default` | equivalent | 同上。 | |
| `src/server/server.nim:SDL:9167956a112233e6:1` | server.nim:1536 `unusableResultType` | 末尾の `none(JsonRpcResponse)` → `discard` | equivalent | `result` の既定値が none。 | |
| `src/server/server.nim:SDL:d1b755fb0b7df450:0` | server.nim:1581 `handleModernRequest` | `logDefect(method, hintProblem.get)` → `discard` | spec_question | 問い A。使えない cache hint は相手には "Internal error" だけで、何が誤りかはこの行にしか出ない。1118 行までの `logDefect` の中の行 (1079・1083) と同じ扱いにそろえる。 | 仕様にするなら: 使えない cache hint を返すハンドラを 2026-07-28 で呼び、stderr にメソッド名と理由が出ることを見る。 |
| `src/server/server.nim:RVR:9bd38dfae0fced9f:2` | server.nim:1598 `rateLimited` | `return none(JsonRpcResponse)` → `return default` | equivalent | `default(Option[JsonRpcResponse])` は none。 | |
| `src/server/server.nim:ROR:ac38735bd85e189f:0` | server.nim:1602 `rateLimited` | `request.peer.len > 0` → `>=` | accepted | 送り手の鍵が `"c:"` から `"a:"` に変わるだけで、空でない peer の鍵 (`"a:" & peer`) とは重ならず、数え方も断り方も同じ。変わるのは最初の断りの stderr の語 (connection → address) だけ。失敗の文面は契約ではない (代表の決定 2026-10-23)。 | |
| `src/server/server.nim:RVR:9bd38dfae0fced9f:3` | server.nim:1607 `rateLimited` | `return none(JsonRpcResponse)` → `return default` | equivalent | `default(Option[JsonRpcResponse])` は none。 | |
| `src/server/server.nim:SDL:147247bc28948ef8:0` | server.nim:1674 `processRequest` | 取り消された要求のハンドラへの `addCallback` (後から失敗したら stderr に書く) → `discard` | spec_question | 問い A。取り消した後のハンドラの失敗は、応答を送らないので、この callback の行にしか出ない。callback はほかに何もしない。 | 仕様にするなら: 取り消しの後で例外を投げるハンドラを `processMessages` 経由で走らせ、stderr にハンドラのメッセージが出ることを見る。 |
| `src/server/server.nim:SDL:4ce645a09adf342a:0` | server.nim:1676 `processRequest` | 上の callback の中の stderr の行 → `discard` | spec_question | 問い A。上と同じ行。 | 上と同じテスト。 |
| `src/server/server.nim:SDL:217b4855ba87df7f:0` | server.nim:1678 `processRequest` | 「cancelled; no response sent」の stderr の行 → `discard` | accepted | 取り消しは保たれ (応答を送らず、通信路に `requestDropped` で伝える)、失敗を隠す行でもない (取り消しは相手か通信路が起こしたもので、原因はそちらにある)。消えるのは経過の診断だけ。失敗の文面は契約ではない (代表の決定 2026-10-23)。 | |
| `src/server/server.nim:SDL:018856cae0ec4679:0` | server.nim:1684 `processRequest` | ハンドラの失敗の stderr の行 → `discard` | spec_question | 問い A。MCP-ERRORS-1 は相手に "Internal error" だけを伝えると決めており、例外の名前とメッセージはこの行にしか出ない。 | 仕様にするなら: 自前のメッセージで失敗するハンドラを `processMessages` 経由で呼び、相手への応答にそのメッセージが無く、stderr に在ることを見る (MCP-ERRORS-1 に足す)。 |
| `src/server/server.nim:SDL:0eec084d1ec55604:0` | server.nim:1691 `processRequest` | `server.inFlight.del(key)` → `discard` | spec_question | 問い B。残った項目は `finished` なので `cancelRequest` は偽を返し、同じ id の次の要求は上書きする。応答も取り消しも変わらず、変わるのは表の大きさ (要求の数だけ育つ) だけで、公開の入口から見えない。2026-10-07 の「残した」はリードの判断。 | 仕様にするなら: 処理中の要求の件数を返す入口を足し、応答の後に 0 に戻ることを見る。 |
| `src/server/server.nim:SDL:393bb8d0d0b11c7e:0` | server.nim:1732 `processMessages` | 閉じた通信路の枝の `server.failPending(none(string), e)` → `discard` | equivalent | 直前の `cancelSession` が `server.sessions` の全部の鍵について `failPending(some(session), …)` を呼ぶ。待ちを作る `request` は operational な session にしか作らず、session を表から消すのは `endSession` だけで、それも先に待ちを失敗させる。だからこの行に来たとき待ちは残っていない。この 1 行は消せる。 | |
| `src/server/server.nim:SDL:56d3852372d11e8a:0` | server.nim:1736 `processMessages` | 「transport loop ended with」の stderr の行 → `discard` | accepted | 失敗は `lastTransportError` に残り、待っている要求にも同じ例外で伝わる (MCP-SERVERREQ-6)。消えるのは重ねて書く診断だけ。失敗の文面は契約ではない (代表の決定 2026-10-23)。 | |
| `src/server/server.nim:SDL:f3ee4f544648e438:0` | server.nim:1774 `deliverEach` | 「could not send … to session」の stderr の行 → `discard` | accepted | 最初の失敗は全部を試した後に呼び手へ raise される。消えるのは重ねて書く診断だけ。失敗の文面は契約ではない (代表の決定 2026-10-23)。 | |
| `src/server/server.nim:SDL:e0eb1207a5ec6a6b:0` | server.nim:1794 `deliverToSubscribers` | 「could not send … to subscription」の stderr の行 → `discard` | accepted | 同上 (最初の失敗は呼び手へ raise される)。失敗の文面は契約ではない (代表の決定 2026-10-23)。 | |
| `src/server/server.nim:SDL:c148c02d2dfcb737:0` | server.nim:1904 `endSubscriptions` | 「could not cancel subscription」の stderr の行 → `discard` | spec_question | 問い A。stdio で `notifications/cancelled` を送れなかった失敗は捕まえて続けるので、この行を消すと黙って消える。 | 仕様にするなら: 通知の送信が失敗する stdio の通信路で `endSubscriptions` を呼び、listen は結果で終わり、stderr に失敗が出ることを見る。 |

timeout の 3 件 (どれも待ちが終わらなくなる変異で、ただ遅いのではない。測り直しは要らない):

- `src/server/server.nim:SDL:c54b6bb249cbda80:0` (1216、`server.subscriptions.add subscription` を消す): listen が表に載らず、`endSubscriptions` も件数の待ちも届かないので、listen の応答を待つテストが終わらない。
- `src/server/server.nim:SDL:cba6c56101be01b8:0` (1221、`subscription.closed.completesWith(ended)` を消す): サーバーが購読を終えても `ended` が完了せず、listen の応答が出ない。
- `src/server/server.nim:SDL:9963156d79866778:0` (1906、`subscription.closed.complete()` を消す): `endSubscriptions` が購読を終わらせず、listen の応答が出ない。

## 最初の測定 (本線の 36a4c8a5、2026-10-07)

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5 (2026-10-07)。

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 502 | 236 | 2 | 237 | 0 | 27 |

生き残り 237 件の分類 (4 人で分担し、下の 4 節に 1 件ずつ記録した)。

| 分類 | 338〜899 行 | 901〜1291 行 | 1302 行以降 | server.nim 以外 | 計 |
|---|---:|---:|---:|---:|---:|
| 1 同値 | 4 | 6 | 4 | 6 | 20 |
| 2 ジョブに無い既存のテストが検出 (ジョブに追記) | 4 | 25 | 24 | 0 | 53 |
| 3 穴 (テストを追加) | 41 | 21 | 19 | 4 | 85 |
| 4 到達しない・使われない・観測できないコード | 2 | 1 | 1 | 60 | 64 |
| 5 欠陥 | 0 | 0 | 0 | 0 | 0 |
| 6 許容 (標準エラーの診断の文面) | 5 | 3 | 9 | 0 | 17 |

分類 2 と 3 は、変異を 1 件ずつ手で当てて、テストが落ちる (または止まる) ことを確かめた。分類 1 は式と不変条件から読んだ。

## 分類 4 の扱い (リードの判断、2026-10-07)

- `src/server/resources.nim` (56 件) と `src/server/prompts.nim` (4 件): 削除した。SDK、examples、テスト、文書、下流のどこからも import されておらず
  (`import mcp` が取り込むのは `client/` の同名のモジュール)、`resources.nim` は単独ではコンパイルもできなかった。ジョブの `sources` からも外した。
- id 197・335 (`server.nim` の `handleInitialize`、合意できる旧版が無い場合の枝): 削除し、`doAssert` に替えた。握手の無い版しか話さないサーバーは、
  ここに来る前に `initialize` を断っている (`tests/test_version_floor.nim` の 2026-07-28 専用ビルドで確認)。
- id 127 (`server.nim:956`、`withoutInvalidParamHeaders` の早期 return): 残した。呼び出し元は `listPage` の結果だけなので今は届かないが、
  「結果が無い、または `tools` が配列でないなら触らない」という防御で、消すと後の変更で nil を踏む。届かないので次の測定でも生き残る。
- id 290 (`server.nim:1493`、`server.inFlight.del(key)`): 残した。消さなくても応答は変わらず、処理中の要求の表が大きくなるだけで、外からは見えない。
  件数を返す公開 API をこのためだけに足すことはしない。次の測定でも生き残る。
- id 439 (`completion.nim:24`、`requiredString` の nil と種類の検査): 残した。今の呼び出し元は nil でない JObject しか渡さないので同値。

## 仕様 ID の振り直し

3 人が別々に同じ番号を振っていたので、取り込み時に振り直した: 「フィルタは 2026-07-28 の結果をオブジェクト以外にできない」は MCP-HOOKS-3、
「request interceptor は要求に答えるか、サーバーに任せる」は MCP-HOOKS-4、「同じ要求への 2 度目の答えは無視される」は MCP-SERVERREQ-12。
下の各節の本文に残る MCP-HOOKS-2 / MCP-SERVERREQ-10 の表記のうち、これらの Scenario を指すものは、この番号に読み替える。

## 気づいた点 (未対応)

- 成功の応答で `result` も `error` も無いもの (ハンドラが既定値を返した場合) を、通信路の符号化が `"result": {}` として送っていた。
  ハンドラの誤りが空の成功に見える。2026-10-12 に、符号化を内部エラー (-32603、"Internal error") にし、stderr に 1 行出すと決めて直した
  (MCP-TRANSPORT-3、`transport.nim`)。本線の応答を作る経路 (`newJsonRpcResponse`、`newJsonRpcErrorResponse`) はすべて `result` か `error` を明示するので、
  この枝に入るのは既定値の `JsonRpcResponse` を返したハンドラだけ。下の id 172 付近の「外から見える違い」の記述は、この変更の前のもの。

測定の後に `src/server/server.nim` を変えた (上の `doAssert`)。push の前に、このジョブを測り直す。

## src/server/server.nim の 338〜899 行

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5 (2026-10-07)。ジョブ全体の数字 (7 ファイル):

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 502 | 236 | 2 | 237 | 0 | 27 |

この節は `src/server/server.nim` の 338〜899 行の生き残り 56 件 (id 順ではなく行順)。ほかの範囲は別の節 (別の担当) が記録する。

| 分類 | 件数 |
|---|---:|
| 1 同値 | 4 |
| 2 ジョブに無い既存のテストが検出 (ジョブに追記) | 4 |
| 3 穴 (テストを追加) | 41 |
| 4 到達しない・冗長なコード | 2 |
| 5 欠陥 | 0 |
| 6 許容 | 5 |

分類 2 と 3 は、変異を 1 件ずつ手で当て、テストが落ちる (または止まる) ことを確かめた。そのあと `jj restore` で戻した。
分類 1 は式から読んだ。1 件も runError は無い。

ジョブの `testCommand` に足したテスト: `test_request_hooks`、`test_trace_context`、`test_server_sampling_tools` (後ろの 2 つは分類 2)。

| id | 場所 | 変異子 | 変異 | 分類 | 理由 | 検出するテスト |
|---:|---|---|---|---:|---|---|
| 328 | `server.nim:338` | RVR | `return false` → `<return default>` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された。 |  |
| 162 | `server.nim:338` | BLR | `false` → `true` | 3 | 未知の要求の取り消しが `true` を返さないこと (docstring の第 1 句) を直接呼んで確かめる。 | test_server_progress_cancel `cancelRequest called directly` |
| 87 | `server.nim:340` | LOR | `ctx.cancelled or ctx.finished` → `<or -> and>` | 3 | 同じ要求を 2 度取り消すと 2 度目は `false`。変異では `cancelSignal.complete()` を 2 度呼び FutureError になる。 | test_server_progress_cancel `cancelRequest called directly` |
| 329 | `server.nim:341` | RVR | `return false` → `<return default>` | 2 | **訂正 (2026-10-10)**: 同値ではない。nim-muter の RVR はリテラルの戻り値を反対の値にする (`return false` → `return true`。報告の表示だけが `<return default>`)。76a08c6a の測り直しで検出された。 |  |
| 163 | `server.nim:341` | BLR | `false` → `true` | 3 | 既に取り消した要求・initialize の取り消しが `false` であること。 | test_server_progress_cancel `cancelRequest called directly` |
| 165 | `server.nim:345` | BLR | `true` → `false` | 3 | 生きている要求の取り消しが `true` を返すこと。 | test_server_progress_cancel `cancelRequest called directly` |
| 191 | `server.nim:373` | SDL | `server.listenFilterHooks.add hook` → `discard` | 3 | 4 つの拡張口のうち listen hook・interceptor・transform は、どのテストにも登録されていなかった。登録順に効くことを確かめる。 | test_request_hooks `hooks run in the order they were added` の listen filter hooks |
| 192 | `server.nim:378` | SDL | `server.interceptors.add interceptor` → `discard` | 3 | 同上 (interceptor)。 | test_request_hooks `hooks run in the order they were added` の request interceptors |
| 193 | `server.nim:383` | SDL | `server.responseFilters.add filter` → `discard` | 2 | response filter は test_request_hooks が検出する (job に追記)。 | test_request_hooks `response filters` |
| 194 | `server.nim:394` | SDL | `server.toolListTransforms.add transform` → `discard` | 3 | 同上 (tool list transform)。 | test_request_hooks `hooks run in the order they were added` の tool list transforms |
| 195 | `server.nim:460` | SDL | `await subscribe(uri)` → `discard` | 3 | 旧 API の subscribe ハンドラが呼ばれるテストが無かった。 | test_server_errors `the earlier API` の subscribe and unsubscribe handlers |
| 196 | `server.nim:464` | SDL | `await unsubscribe(uri)` → `discard` | 3 | 同上 (unsubscribe)。 | test_server_errors `the earlier API` の subscribe and unsubscribe handlers |
| 332 | `server.nim:477` | RVR | `return await get(name, arguments)` → `<return default>` | 3 | 旧 API の prompt get ハンドラの戻り値が prompts/get の結果になること。 | test_server_errors `the earlier API` の get handler |
| 333 | `server.nim:483` | RVR | `return newJsonRpcErrorResponse(request.id, -32600, "Server a` → `<return default>` | 3 | 2 度目の initialize が invalid request で、最初の握手が残ること。 | test_legacy_handshake `sends initialize again` |
| 90 | `server.nim:490` | LOR | `params.isNil or params.kind != JObject` → `<or -> and>` | 3 | params が無い・object でない initialize が invalid params であること (変異では nil を参照して落ちる)。 | test_legacy_handshake `no params or params that are no object` |
| 197 | `server.nim:505` | SDL | `supportedJson.add %($v)` → `discard` | 4 | 下の「残っているもの」を参照。 |  |
| 335 | `server.nim:506` | RVR | `return newJsonRpcErrorResponse(request.id, -32022,; "Unsuppo` → `<return default>` | 4 | 同上。 |  |
| 336 | `server.nim:523` | RVR | `return newJsonRpcErrorResponse(request.id, ErrInvalidParams,` → `<return default>` | 3 | clientInfo が Implementation でない initialize が invalid params で、握手が始まらないこと。 | test_legacy_handshake `a clientInfo that is no Implementation` |
| 200 | `server.nim:542` | SDL | `stderr.writeLine("[mcp-server] initialized notification in s` → `discard` | 6 | 診断の文言だけを書く行 (stderr)。 |  |
| 205 | `server.nim:558` | SDL | `stderr.writeLine("[mcp-server] notifications/cancelled witho` → `discard` | 6 | 同上。 |  |
| 36 | `server.nim:561` | ROR | `reasonNode.kind != JString` → `<!= -> ==>` | 3 | 取り消しの reason が ctx.cancelReason に届き、無い・文字列でないときは空であること。 | test_server_progress_cancel `a cancellation with a reason` |
| 207 | `server.nim:563` | SDL | `stderr.writeLine("[mcp-server] request " & peerText(requestI` → `discard` | 6 | 同上。 |  |
| 37 | `server.nim:565` | ROR | `reason.len > 0` → `<> -> >=>` | 6 | 診断の文言の末尾 (`: reason`) を付けるかどうかだけが変わる。 |  |
| 40 | `server.nim:580` | ROR | `samplingJson["tools"].kind == JObject` → `<== -> !=>` | 3 | sampling.tools が object のとき宣言とみなし、object でないとき宣言なしとみなすこと。 | test_legacy_handshake `declares capabilities as objects` / `that are no objects` |
| 41 | `server.nim:581` | ROR | `samplingJson["context"].kind == JObject` → `<== -> !=>` | 3 | 同上 (sampling.context)。 |  |
| 42 | `server.nim:584` | ROR | `elicitationJson.kind == JObject` → `<== -> !=>` | 3 | 同上 (elicitation)。 |  |
| 43 | `server.nim:590` | ROR | `experimentalJson.kind == JObject` → `<== -> !=>` | 3 | 同上 (experimental)。 |  |
| 44 | `server.nim:594` | ROR | `extensionsJson.kind == JObject` → `<== -> !=>` | 3 | 同上 (extensions)。 |  |
| 338 | `server.nim:653` | RVR | `return none(JsonRpcError)` → `<return default>` | 1 | `Option[T]` の既定値は `none`。`return none(JsonRpcError)` と `return default` は同じ。 |  |
| 341 | `server.nim:663` | RVR | `return rejectInvalidTraceContext(request.params)` → `<return default>` | 2 | 不正な traceparent を invalid params で断るテストが test_trace_context にある (job に追記)。 | test_trace_context `a malformed traceparent, when the request arrives` |
| 211 | `server.nim:664` | SDL | `none(JsonRpcError)` → `discard` | 1 | 手続きの最後の式 `none(JsonRpcError)` を `discard` にしても、`result` の既定値が `none`。 |  |
| 52 | `server.nim:723` | ROR | `logger.len > 0` → `<> -> >=>` | 3 | logger を渡さない log に logger キーが付かないこと。 | test_server_logging `without a logger` |
| 114 | `server.nim:736` | LOR | `ctx.finished or ctx.cancelled` → `<or -> and>` | 3 | 答えた後・取り消した後の log は何も送らないこと。 | test_server_logging `has been answered, when its context logs` / `cancelled, when its handler logs` |
| 56 | `server.nim:779` | ROR | `relatedTask.len > 0` → `<> -> >=>` | 3 | task を持たない要求は hold hook に尋ねず、すぐ送る。 | test_server_requests `names no task` |
| 120 | `server.nim:779` | LOR | `relatedTask.len > 0 and relatedRequestId.len == 0` → `<and -> or>` | 3 | task と元の要求の両方を持つ要求は、hold hook に尋ねず元の要求に載せて送る。 | test_server_requests `a task and a request of the client` |
| 57 | `server.nim:779` | ROR | `relatedRequestId.len == 0` → `<== -> !=>` | 3 | 同上。 |  |
| 119 | `server.nim:779` | LOR | `relatedTask.len > 0 and relatedRequestId.len == 0 and; not s` → `<and -> or>` | 3 | hook が無いか断る要求は、すぐ送る。 | test_server_requests `no hold hook` / `hook that declines` |
| 220 | `server.nim:784` | SDL | `server.pending.del(key)` → `discard` | 3 | hook が例外で断った要求は待ちの表から消え、後の sendHeld は何も送らない。 | test_server_requests `a hold hook that refuses` |
| 58 | `server.nim:786` | ROR | `timeoutMs > 0` → `<> -> >=>` | 3 | timeoutMs = 0 は無制限 (docstring)。変異では即座に timeout になる。 | test_server_requests `no time limit` |
| 221 | `server.nim:787` | SDL | `server.pending.del(key)` → `discard` | 3 | 保留中に時間切れになった要求は、後の sendHeld で送られない。 | test_server_requests `a held request whose time ran out` |
| 223 | `server.nim:794` | SDL | `stderr.writeLine("[mcp-server] could not cancel timed out " ` → `discard` | 6 | 診断の文言だけを書く行 (stderr)。 |  |
| 224 | `server.nim:808` | SDL | `await server.transport.sendRequest(outgoing)` → `discard` | 3 | sendHeld が保留した要求を tasks/result の stream に載せて送ること。 | test_server_requests `waits until sendHeld puts it on the stream` |
| 124 | `server.nim:841` | LOR | `roots.isNil or roots.kind != JArray` → `<or -> and>` | 3 | roots/list の答えに roots 配列が無ければ remote error。変異では nil を参照して落ちる。 | test_server_requests `answers roots/list without a roots array` |
| 228 | `server.nim:857` | SDL | `raiseIfAny("sampling/createMessage",; createMessageParamsPro` → `discard` | 2 | sampling/createMessage の引数検査は test_server_sampling_tools が検出する (job に追記)。 | test_server_sampling_tools `break the pairing of tool uses and results` |
| 229 | `server.nim:863` | SDL | `raiseIfAny("sampling/createMessage result",; createMessageRe` → `discard` | 2 | 結果の検査も同様。 | test_server_sampling_tools `an answer that stops for tool use without a tool_use block` ほか |
| 230 | `server.nim:876` | SDL | `inc scope.inputsOpen` → `discard` | 3 | task に属する要求が入力待ちを数えること。 | test_server_requests `told it needs input at the first request` |
| 60 | `server.nim:877` | ROR | `scope.inputsOpen == 1` → `<== -> !=>` | 3 | 同上。 |  |
| 231 | `server.nim:878` | SDL | `scope.awaitingInput(true)` → `discard` | 3 | 最初の要求で task に「入力待ち」を知らせること。 |  |
| 167 | `server.nim:878` | BLR | `true` → `false` | 3 | 同上 (引数が true)。 |  |
| 232 | `server.nim:885` | SDL | `dec scope.inputsOpen` → `discard` | 3 | 最後の答えで数を減らすこと。 |  |
| 61 | `server.nim:886` | ROR | `scope.inputsOpen == 0` → `<== -> !=>` | 3 | 同上。 |  |
| 233 | `server.nim:887` | SDL | `scope.awaitingInput(false)` → `discard` | 3 | 最後の答えで task に「入力待ちでない」を知らせること。 |  |
| 168 | `server.nim:887` | BLR | `false` → `true` | 3 | 同上 (引数が false)。 |  |
| 234 | `server.nim:892` | SDL | `await ctx.server.ping(ctx.session, input.relatedRequestId, i` → `discard` | 3 | ctx.ping が client に ping を送ること。 | test_server_requests `as no task` ほか |
| 235 | `server.nim:894` | SDL | `ctx.endInput()` → `discard` | 3 | ctx.ping の終わりに endInput が呼ばれること。 |  |
| 346 | `server.nim:899` | RVR | `return await ctx.server.listRoots(ctx.session, input.related` → `<return default>` | 3 | ctx.listRoots が client の roots を返すこと。 |  |

### 診断の行 (分類 6) の理由

id 200、205、207、223 は stderr に診断を 1 行書くだけの文、id 37 はその行の末尾 (`: reason`) を付けるかどうかの条件である。
診断は人が読むためで、プロトコルの結果にも状態にも効かない。`tests/test_security_diagnostic.nim` が検査するのは、ピアの文字列を `peerText` で無害にすること
(MCP-SEC-HTTP-7) で、この 5 行は対象に含まれない。行の有無や文言を検査するテストは、実装の文字列を写すだけになり、実装と独立な情報を持たない。

### 残っているもの

- id 197 と 335 (`server.nim:502-511`、`handleInitialize` の `negotiated.isNone` の枝): 到達しない (分類 4)。`handleInitialize` に来るのは
  `isModernPath` が偽の要求だけで、それは「サーバーの版が旧版」か「サーバーが旧版を話す」のどちらかのとき。どちらも
  `spokenVersionsUpTo(server.protocolVersion)` に旧版を 1 つ以上含み、`negotiateLegacyVersion` は旧版が 1 つでもあれば `none` を返さない。
  旧版を話さないサーバーへの旧版の initialize は `handleModernRequest` (`server.nim:1383-1387`) が -32022 で断る。枝は 10 行で、
  削除は未実施 (リードの判断を待つ)。残すなら、届かないと分かる `raiseAssert` に替える (client の id 307 と同じ扱い)。
- 分類 6 の 5 件 (上)。

## src/server/server.nim の 901〜1291 行

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5 (2026-10-07)。ジョブ全体の数字 (4 人で分担):

| 全変異 | killed | timeout | survived | runError | compileError |
|---:|---:|---:|---:|---:|---:|
| 502 | 236 | 2 | 237 | 0 | 27 |

この節の担当は `src/server/server.nim` の 901〜1291 行で、生き残りは 56 件。この範囲の server.nim はレポートの時点から変わっていない
(`jj diff -r owwryuxn::mwslvmvr -- src/server` は空)。分類:

| 分類 | 件数 |
|---|---:|
| 1 同値 | 6 |
| 2 ジョブに無い既存のテストが検出 (ジョブに追記) | 25 |
| 3 穴 (テストを追加) | 21 |
| 4 到達しない・冗長なコード | 1 |
| 5 欠陥 | 0 |
| 6 許容 | 3 |

分類 2 と 3 は、変異を 1 件ずつ手で当てて、その 1 本のテストプログラムが落ちる (または止まる) ことを確かめた。分類 1 は式から読み、
`Option[T]` と `string` の既定値だけは nim で確かめた。

### 測り方についての注記

- `return <式>` を `return default` に替える RVR の変異は、応答を返す箇所では `JsonRpcResponse` の既定値になる。通信路の符号化
  (`transport.nim` の `toJson`) は result も error も無い応答を `"result": {}` にするので、**外から見える違いは `jsonrpc` が "2.0" でなくなること**
  だけになる箇所がある (成功の応答)。そこで `tests/server_harness.nim` の `responseTo` が、読んだ応答の `jsonrpc` が "2.0" であることを検査する
  ようにした (JSON-RPC 2.0 の規則)。分類 2 のうち RVR の行 (359, 362, 364, 365, 378, 379, 404) の検出は、この検査が入った状態で確かめた。
- 分類 3 の「穴」のうち 377 と 403 は、この harness の検査だけが検出する。

### 生き残り 56 件

| id | 場所 | 変異 | 元 → 変異後 | 分類 | 理由 | いま検出するテスト |
|---:|---|---|---|---|---|---|
| 64 | server.nim:956 | ROR | `tools.kind != JArray` → `<!= -> ==>` | 2 | `!=` を `==` にすると、配列の一覧では何も外さずに返る。 | test_param_headers_http: Given a tool whose x-mcp-header is invalid, when tools are listed, then the server does not publish it |
| 67 | server.nim:1115 | ROR | `registered.extensionId.len > 0` → `<> -> >=>` | 3 | `registerOpenMethod` にテストが無く、空の拡張 id でも宣言を求める変異が通った。 | test_extensions: Given a method of a specification that asks nothing of the client, when a client that declared nothing calls it, then the server serves it (MCP-EXT-16) |
| 71 | server.nim:1238 | ROR | `faults.len > 0` → `<> -> >=>` | 2 | `faults.len >= 0` では、適合する結果にも内部エラーを返す。 | test_structured_tool_output: Given structuredContent and no content, when the result is answered, then the serialized JSON is added as text ほか |
| 127 | server.nim:956 | LOR | `tools.isNil or tools.kind != JArray` → `<or -> and>` | 4 | `withoutInvalidParamHeaders` の呼び出し元は `listPage` の結果だけで、`result` は常に `tools` 配列を持つ。`tools.isNil` は決して真にならないので `or` を `and` にしても結果は同じ。この 2 行の早期 return (953-957 行) は防御で届かない。リードの判断を仰ぐ。 |  |
| 130 | server.nim:1056 | LOR | `capabilities.tools.isSome and capabiliti` → `<and -> or>` | 2 | `and` を `or` にすると、listChanged を宣言していない (または capability 自体が無い) 型を確認応答に含めてしまう。 | test_subscriptions: Given a type the server does not support, when it acknowledges, then that type is omitted |
| 131 | server.nim:1058 | LOR | `capabilities.prompts.isSome and capabili` → `<and -> or>` | 2 | `and` を `or` にすると、listChanged を宣言していない (または capability 自体が無い) 型を確認応答に含めてしまう。 | test_subscriptions: Given a type the server does not support, when it acknowledges, then that type is omitted |
| 132 | server.nim:1101 | LOR | `known.clientCapabilities.isSome and; kno` → `<and -> or>` | 2 | `declaredCapabilities` の 3 つの枝 (リクエスト自身の宣言、initialize の extensions、`and` の短絡)。 | test_extensions: Given a handler that uses ctx.requireClientExtension ... / Given a legacy client that declared an extension in initialize ... |
| 133 | server.nim:1115 | LOR | `registered.extensionId.len > 0 and not r` → `<and -> or>` | 2 | `and` を `or` にすると、宣言した client への呼び出しや servedUndeclared の拡張が missing-capability になる。 | test_extensions: Given an extension the server alone declares, when a client that declared nothing calls its method, then the server serves it and the client sends it ほか |
| 134 | server.nim:1115 | LOR | `registered.extensionId.len > 0 and not r` → `<and -> or>` | 2 | `and` を `or` にすると、宣言した client への呼び出しや servedUndeclared の拡張が missing-capability になる。 | test_extensions: Given an extension the server alone declares, when a client that declared nothing calls its method, then the server serves it and the client sends it ほか |
| 135 | server.nim:1136 | LOR | `caps.resources.isNone or server.resource` → `<or -> and>` | 3 | capability の宣言と handler の登録の両方が要る。既存のテストは両方とも無いサーバーしか使わず、`or` が `and` でも通った。残りの 2 通りを検査する。 | test_server_resources_prompts / test_server_errors: Given handlers for resources and prompts but no capability declared ... / Given the capabilities declared but no handlers ... / Given tool handlers but no tools capability ... (MCP-RESOURCES-13, MCP-TOOLS-6) |
| 136 | server.nim:1151 | LOR | `caps.resources.isNone or server.resource` → `<or -> and>` | 3 | capability の宣言と handler の登録の両方が要る。既存のテストは両方とも無いサーバーしか使わず、`or` が `and` でも通った。残りの 2 通りを検査する。 | test_server_resources_prompts / test_server_errors: Given handlers for resources and prompts but no capability declared ... / Given the capabilities declared but no handlers ... / Given tool handlers but no tools capability ... (MCP-RESOURCES-13, MCP-TOOLS-6) |
| 140 | server.nim:1201 | LOR | `caps.tools.isNone or server.toolCall.isN` → `<or -> and>` | 3 | capability の宣言と handler の登録の両方が要る。既存のテストは両方とも無いサーバーしか使わず、`or` が `and` でも通った。残りの 2 通りを検査する。 | test_server_resources_prompts / test_server_errors: Given handlers for resources and prompts but no capability declared ... / Given the capabilities declared but no handlers ... / Given tool handlers but no tools capability ... (MCP-RESOURCES-13, MCP-TOOLS-6) |
| 143 | server.nim:1245 | LOR | `caps.prompts.isNone or server.promptsLis` → `<or -> and>` | 3 | capability の宣言と handler の登録の両方が要る。既存のテストは両方とも無いサーバーしか使わず、`or` が `and` でも通った。残りの 2 通りを検査する。 | test_server_resources_prompts / test_server_errors: Given handlers for resources and prompts but no capability declared ... / Given the capabilities declared but no handlers ... / Given tool handlers but no tools capability ... (MCP-RESOURCES-13, MCP-TOOLS-6) |
| 144 | server.nim:1251 | LOR | `caps.prompts.isNone or server.promptGet.` → `<or -> and>` | 3 | capability の宣言と handler の登録の両方が要る。既存のテストは両方とも無いサーバーしか使わず、`or` が `and` でも通った。残りの 2 通りを検査する。 | test_server_resources_prompts / test_server_errors: Given handlers for resources and prompts but no capability declared ... / Given the capabilities declared but no handlers ... / Given tool handlers but no tools capability ... (MCP-RESOURCES-13, MCP-TOOLS-6) |
| 236 | server.nim:901 | SDL | `ctx.endInput()` → `discard` | 3 | ctx.listRoots / ctx.createMessage が入力の範囲を閉じないと、答えたあともタスクが input_required のまま (Tasks: 答えが届くまで input_required、そのあと working)。 | test_tasks_end_to_end: Given a tool that asks the client for sampling or roots inside a task, when the client has answered, then the task is working again while the tool goes on |
| 237 | server.nim:908 | SDL | `ctx.endInput()` → `discard` | 3 | ctx.listRoots / ctx.createMessage が入力の範囲を閉じないと、答えたあともタスクが input_required のまま (Tasks: 答えが届くまで input_required、そのあと working)。 | test_tasks_end_to_end: Given a tool that asks the client for sampling or roots inside a task, when the client has answered, then the task is working again while the tool goes on |
| 238 | server.nim:916 | SDL | `server.pending.del(key)` → `discard` | 3 | 答え済みの id への 2 度目の答えは、表に残った待ちを完了済みの future に再度 complete させる。表から消すことが「2 度目は無視」を成り立たせる。 | test_server_requests: Given an answer that arrives twice, when the second arrives, then it is ignored and the first answer stands |
| 248 | server.nim:962 | SDL | `stderr.writeLine("[mcp-server] not listi` → `discard` | 6 | 標準エラーへ出す診断行の文面だけの差 (tests/test_security_diagnostic.nim が検査するのは peerText を通ること。この 3 行は検査しない)。クライアントに返る答えは変わらない。同じ理由で 3 件まとめて許容。 |  |
| 252 | server.nim:1006 | SDL | `stderr.writeLine("[mcp-server] tools/lis` → `discard` | 6 | 標準エラーへ出す診断行の文面だけの差 (tests/test_security_diagnostic.nim が検査するのは peerText を通ること。この 3 行は検査しない)。クライアントに返る答えは変わらない。同じ理由で 3 件まとめて許容。 |  |
| 253 | server.nim:1008 | SDL | `none(JsonNode)` → `discard` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 256 | server.nim:1036 | SDL | `checkParamHeaders(declared.bindings, arg` → `discard` | 2 | `checkParamHeaders` を呼ばないと、Mcp-Param-* ヘッダと引数の食い違いが見逃される。 | test_param_headers_http: Given a Base64 header without its padding, when posted, then the answer is 400 header mismatch ほか |
| 257 | server.nim:1048 | SDL | `stderr.writeLine("[mcp-server] tools/cal` → `discard` | 6 | 標準エラーへ出す診断行の文面だけの差 (tests/test_security_diagnostic.nim が検査するのは peerText を通ること。この 3 行は検査しない)。クライアントに返る答えは変わらない。同じ理由で 3 件まとめて許容。 |  |
| 258 | server.nim:1082 | SDL | `server.subscriptions.add subscription` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 259 | server.nim:1077 | SDL | `hook(ctx, requested, honored)` → `discard` | 3 | `addListenFilterHook` に外部から見えるテストが無く、フックの呼び出しを消しても全部通った。 | test_subscriptions: Given listen filter hooks, when a client listens, then each runs in the order added and the acknowledgment carries what they leave in the filter (MCP-SUBSCRIBE-13) |
| 260 | server.nim:1084 | SDL | `await server.transport.sendNotification(` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 261 | server.nim:1087 | SDL | `subscription.closed.completesWith(ended)` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 262 | server.nim:1088 | SDL | `ctx.cancelSignal.completesWith(ended)` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 263 | server.nim:1089 | SDL | `await ended` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 264 | server.nim:1091 | SDL | `server.subscriptions.remove subscription` → `discard` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 265 | server.nim:1103 | SDL | `newJNull()` → `discard` | 3 | `declaredCapabilities` の公開 API は「何も分からなければ JSON null」と文書化しているのに、nil を返しても通った。 | test_extensions: Given a legacy client, when a handler reads what the client declared, then only the extensions are carried over and nothing known is JSON null (MCP-EXT-12) |
| 350 | server.nim:996 | RVR | `return none(JsonNode)` → `<return default>` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 352 | server.nim:1004 | RVR | `return none(JsonNode)` → `<return default>` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 353 | server.nim:1018 | RVR | `return content.outputProblems(version, s` → `<return default>` | 2 | `outputProblems` が空の列を返すと、outputSchema に合わない結果がそのまま通る。 | test_structured_tool_output: Given a version before 2026-07-28, when structuredContent is not an object, then the server answers with an internal error; 2026-07-28 accepts any JSON ほか |
| 354 | server.nim:1032 | RVR | `return none(JsonRpcError)` → `<return default>` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 355 | server.nim:1035 | RVR | `return none(JsonRpcError)` → `<return default>` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 356 | server.nim:1044 | RVR | `return ""` → `<return default>` | 1 | `return none(...)` を `return default` に (253 は式を `discard` に) 替えても、`Option[T]` の既定値は none、`string` の既定値は "" で同じ。nim r で `default(Option[string]).isNone` と `default(string) == ""` が真であることを確認した。 |  |
| 358 | server.nim:1073 | RVR | `return newJsonRpcErrorResponse(request.i` → `<return default>` | 2 | 不正な filter のときの invalid params が既定の応答になる。 | test_subscriptions: Given a request without a usable notifications filter, when it arrives, then it is invalid params |
| 359 | server.nim:1092 | RVR | `return newJsonRpcResponse(request.id, li` → `<return default>` | 2 | 購読の登録・確認応答・終了の合図・待機・解除・最後の応答のどれを消しても、listen のテストが落ちる (止まる)。 | test_subscriptions (該当するテストは複数) |
| 360 | server.nim:1099 | RVR | `return ctx.clientCapabilities` → `<return default>` | 2 | `declaredCapabilities` の 3 つの枝 (リクエスト自身の宣言、initialize の extensions、`and` の短絡)。 | test_extensions: Given a handler that uses ctx.requireClientExtension ... / Given a legacy client that declared an extension in initialize ... |
| 361 | server.nim:1102 | RVR | `return %*{"extensions": known.clientCapa` → `<return default>` | 2 | `declaredCapabilities` の 3 つの枝 (リクエスト自身の宣言、initialize の extensions、`and` の短絡)。 | test_extensions: Given a handler that uses ctx.requireClientExtension ... / Given a legacy client that declared an extension in initialize ... |
| 362 | server.nim:1120 | RVR | `return newJsonRpcErrorResponse(request.i` → `<return default>` | 2 | 拡張メソッドの missing-capability の答え、成功の答え、dispatchExtension への経路。 | test_extensions: Given a client that does not declare the extension, when it calls an extension method, then it gets the missing-capability error naming the extension ほか |
| 363 | server.nim:1124 | RVR | `return malformed.get` → `<return default>` | 3 | 拡張メソッドの handler がオブジェクトでない値を返したときの内部エラーにテストが無かった。 | test_extensions: Given an extension method whose handler returns something that is not an object, when it answers, then it is an internal error (MCP-EXT-17) |
| 364 | server.nim:1125 | RVR | `return newJsonRpcResponse(request.id, an` → `<return default>` | 2 | 拡張メソッドの missing-capability の答え、成功の答え、dispatchExtension への経路。 | test_extensions: Given a client that does not declare the extension, when it calls an extension method, then it gets the missing-capability error naming the extension ほか |
| 365 | server.nim:1133 | RVR | `return answer.get` → `<return default>` | 3 | `addRequestInterceptor` の契約 (順序、最初の答えで終わる、none なら続行) が Tasks 拡張越しにしか検査されていなかった。 | test_request_hooks: Given interceptors, when a request is served, then they run in the order added, the first answer ends the matter and none lets the server carry on (MCP-HOOKS-2) |
| 372 | server.nim:1155 | RVR | `return missingParam(request, "uri")` → `<return default>` | 3 | 必須の文字列パラメーター (uri / name) が無い・文字列でないときの invalid params にテストが無かった。 | test_server_resources_prompts / test_server_errors: Given a read or a get whose required string parameter is missing or not a string ... / Given a call whose name is missing or not a string ... (MCP-RESOURCES-14) |
| 377 | server.nim:1178 | RVR | `return newJsonRpcResponse(request.id, ne` → `<return default>` | 3 | 成功の応答 (空の result) を既定の応答に替えても、通信路の符号化が空の result を補うので、どのテストも気付かなかった。応答は jsonrpc "2.0" を持つ、という JSON-RPC の規則を harness の responseTo で検査するようにした。 | tests/server_harness.nim の responseTo (test_server_notifications、test_server_logging が落ちる) |
| 378 | server.nim:1182 | RVR | `return notSupported(request)` → `<return default>` | 2 | `subscriptions/listen` の旧版での method not found と、modern での listen の応答。 | test_subscriptions: Given a version without subscriptions/listen, when it is requested, then it is method not found ほか |
| 379 | server.nim:1183 | RVR | `return await server.listen(request, ctx)` → `<return default>` | 2 | `subscriptions/listen` の旧版での method not found と、modern での listen の応答。 | test_subscriptions: Given a version without subscriptions/listen, when it is requested, then it is method not found ほか |
| 380 | server.nim:1187 | RVR | `return notSupported(request)` → `<return default>` | 3 | capability を宣言していない・handler が無いときの method not found の答え。 | test_server_errors: Given the tools capability but no call handler, when a tool is called, then the method is not found |
| 383 | server.nim:1202 | RVR | `return notSupported(request)` → `<return default>` | 3 | capability を宣言していない・handler が無いときの method not found の答え。 | test_server_errors: Given the tools capability but no call handler, when a tool is called, then the method is not found |
| 384 | server.nim:1205 | RVR | `return missingParam(request, "name")` → `<return default>` | 3 | 必須の文字列パラメーター (uri / name) が無い・文字列でないときの invalid params にテストが無かった。 | test_server_resources_prompts / test_server_errors: Given a read or a get whose required string parameter is missing or not a string ... / Given a call whose name is missing or not a string ... (MCP-RESOURCES-14) |
| 386 | server.nim:1215 | RVR | `return newJsonRpcErrorResponse(request.i` → `<return default>` | 2 | 食い違いの答えが既定の応答になると、400 の header mismatch にならない。 | test_param_headers_http: Given a Base64 header without its padding, when posted, then the answer is 400 header mismatch ほか |
| 394 | server.nim:1255 | RVR | `return missingParam(request, "name")` → `<return default>` | 3 | 必須の文字列パラメーター (uri / name) が無い・文字列でないときの invalid params にテストが無かった。 | test_server_resources_prompts / test_server_errors: Given a read or a get whose required string parameter is missing or not a string ... / Given a call whose name is missing or not a string ... (MCP-RESOURCES-14) |
| 395 | server.nim:1261 | RVR | `return malformed.get` → `<return default>` | 3 | prompts/get の handler がオブジェクトでない値を返したときの内部エラーにテストが無かった (tools/call には既にあった)。 | test_server_errors: Given a prompt handler whose result is not an object, when the prompt is requested, then the answer is an internal error (MCP-PROMPTS-5) |
| 403 | server.nim:1287 | RVR | `return newJsonRpcResponse(request.id, ne` → `<return default>` | 3 | 成功の応答 (空の result) を既定の応答に替えても、通信路の符号化が空の result を補うので、どのテストも気付かなかった。応答は jsonrpc "2.0" を持つ、という JSON-RPC の規則を harness の responseTo で検査するようにした。 | tests/server_harness.nim の responseTo (test_server_notifications、test_server_logging が落ちる) |
| 404 | server.nim:1291 | RVR | `return await server.dispatchExtension(re` → `<return default>` | 2 | 拡張メソッドの missing-capability の答え、成功の答え、dispatchExtension への経路。 | test_extensions: Given a client that does not declare the extension, when it calls an extension method, then it gets the missing-capability error naming the extension ほか |

### ジョブへの追記

`tests/mutation/server.json` の testCommand の末尾に追記した (この順): `test_subscriptions`、`test_extensions`、`test_request_hooks`、
`test_param_headers_http`、`test_structured_tool_output`、`test_tasks_end_to_end`。どれも、上の表の変異のどれかを 1 本で検出することを確かめてある。
`specs/tests.map` と `specs/*.feature` には、追加したテストに対応する行 (MCP-SUBSCRIBE-13、MCP-EXT-12 の追加行・MCP-EXT-16・17、MCP-HOOKS-2、
MCP-RESOURCES-13・14、MCP-TOOLS-6、MCP-PROMPTS-5、MCP-TASKS-14 の追加行、MCP-SERVERREQ-10) を足した。

### 残っているもの

- 分類 6 (許容) の 3 件 (id 248, 252, 257): 標準エラーへ出す診断行の文面。
- 分類 4 の 1 件 (id 127): `withoutInvalidParamHeaders` の 953〜957 行の早期 return は、呼び出し元が `listPage` の結果だけなので届かない。
  削除するかどうかはリードの判断に任せる (削除すると 64 の変異の意味も変わる)。
- 上のほかは、テストを足したか、ジョブに既存のテストを足して検出を確かめた。

## src/server/server.nim の 1302 行以降

測定: `nim-muter`、ジョブ `tests/mutation/server.json`、本線の 36a4c8a5。担当は `src/server/server.nim` の 1302 行から末尾の生き残りと、server.nim の timeout 2 件 (id 239 と 296)。
総数はリードが g2-server.md にまとめる。ここでは担当分の 55 件 + timeout 2 件を 1 件ずつ記録する。

分類の件数 (timeout 2 件を含む 57 行):

| 分類 | 件数 |
|---|---:|
| 1 | 4 |
| 2 | 24 |
| 3 | 19 |
| 4 | 1 |
| 6 | 9 |

分類 2 と 3 は、変異を 1 件ずつ手で当ててテストが落ちる (または止まる) ことを確かめた (id 239 の行は 917 行目)。分類 1 は式と不変条件から読んだ。

| id | file:line | mutator | 原文 → 変異 | 分類 | 理由 | 検出するテスト |
|---:|---|---|---|---|---|---|
| 274 | server.nim:1302 | SDL | `stderr.writeLine(...)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 275 | server.nim:1303 | SDL | `newJsonRpcErrorResponse(...)` → discard | 2 | `input_required` を返せない場合の内部エラー応答が空になる | test_mrtr: handler asks for nothing など |
| 406 | server.nim:1305 | RVR | `return defect(...)` → 既定値 | 2 | 版が複数往復を持たないときの内部エラー | test_mrtr: version without multi round-trips |
| 407 | server.nim:1307 | RVR | `return defect(...)` → 既定値 | 2 | 許されないメソッドの内部エラー | test_mrtr: request that does not support input_required |
| 408 | server.nim:1310 | RVR | `return defect(problem.get)` → 既定値 | 2 | 何も尋ねない handler の内部エラー | test_mrtr: handler that asks for nothing |
| 72 | server.nim:1312 | ROR | `payloadProblems.len > 0` → `>= 0` | 2 | 常に真になり正常な尋ね返しが内部エラーになる | test_mrtr: tool that needs input |
| 409 | server.nim:1313 | RVR | `return defect(payloadProblems.join)` → 既定値 | 2 | 規則違反の input request の内部エラー | test_mrtr: input request breaks the rules |
| 73 | server.nim:1315 | ROR | `missing.len > 0` → `>= 0` | 2 | 常に真になり正常な尋ね返しが capability 欠落になる | test_mrtr: tool that needs input |
| 410 | server.nim:1318 | RVR | `return newJsonRpcErrorResponse(...)` → 既定値 | 2 | capability 欠落エラー | test_mrtr: client that did not declare |
| 273 | server.nim:1325 | SDL | `newJsonRpcResponse(...)` → discard | 2 | input_required の応答そのもの | test_mrtr: tool that needs input |
| 413 | server.nim:1342 | RVR | `return inputRequiredResponse(...)` → 既定値 | 2 | `McpInputRequired` の応答 | test_mrtr: tool that needs input |
| 416 | server.nim:1359 | RVR | `return none(...)` → 既定値 | 1 | `Option[JsonRpcResponse]` の既定値は none で、同じ値を返す |  |
| 417 | server.nim:1361 | RVR | `return some(error)` → 既定値 | 3 | resultType が文字列でないときの内部エラーを確かめるテストが無かった | test_extensions: Given a tool whose result has a resultType that is not a string |
| 418 | server.nim:1365 | RVR | `return none(...)` → 既定値 | 1 | 同上 (既定値が none) |  |
| 419 | server.nim:1370 | RVR | `return some(internal error)` → 既定値 | 2 | どの拡張も定義しない resultType の内部エラー | test_extensions: handler that returns a resultType no extension defines |
| 420 | server.nim:1375 | RVR | `return some(missing capability)` → 既定値 | 3 | 宣言していない拡張の resultType への -32021 が未検査だった | test_extensions: Given a tool whose result carries an extension's resultType ... |
| 276 | server.nim:1376 | SDL | 末尾の `none(...)` → discard | 1 | `result` の既定値が none で、同じ値を返す |  |
| 425 | server.nim:1401 | RVR | `return newJsonRpcErrorResponse(...)` → 既定値 | 2 | inputResponses / requestState の型違いは invalid params | test_mrtr: inputResponses or requestState of the wrong type |
| 150 | server.nim:1413 | LOR | `isNil or kind != JObject` → `and` | 3 | handler の結果が object でない (nil / 配列) とき 2026-07-28 は内部エラー。標準の handler は途中で検査済みで、この守りに届くのはフィルターなどが差し替えた結果だけだった | test_request_hooks: Given a filter that turns a 2026-07-28 result into something that is not an object |
| 426 | server.nim:1414 | RVR | `return newJsonRpcErrorResponse(...)` → 既定値 | 3 | 同上 | 同上 |
| 427 | server.nim:1418 | RVR | `return unusable.get` → 既定値 | 2 | 使えない resultType の応答を返す | test_extensions: handler that returns a resultType no extension defines |
| 281 | server.nim:1454 | SDL | `handling.addCallback(finished = true)` → 削除 | 3 | 応答済みの detached 要求に cancel しても ctx が cancelled にならない、が未検査だった | test_server_progress_cancel: Given a detached request that has been answered, when it is cancelled ... |
| 170 | server.nim:1454 | BLR | `finished = true` → false | 3 | 同上 | 同上 |
| 151 | server.nim:1457 | LOR | `not finished and not cancelled` → `or` | 3 | 2 回目の cancel と応答後の cancel が何も変えないことが未検査だった | test_server_progress_cancel: detached request ... cancelled twice / answered |
| 171 | server.nim:1458 | BLR | `ctx.cancelled = true` → false | 2 | tasks/cancel で tool が停止を知らされる | test_tasks_server: Given a working task, when cancelled, then ... the tool is told |
| 282 | server.nim:1460 | SDL | `ctx.cancelSignal.complete()` → discard | 2 | 同上 | test_tasks_server: Given a working task, when cancelled ... |
| 284 | server.nim:1471 | SDL | `cancelSignal.completesWith(settled)` → 削除 | 3 | 取り消された要求の待ちが、止められない handler の終了まで続く。transport への通知が handler の終了後になる | test_server_progress_cancel: Given a request in flight, when the client cancels it, then the transport is told at once ... |
| 286 | server.nim:1476 | SDL | 放棄した handler の `addCallback` → discard | 6 | コールバックの効果は中の診断行だけ。診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 288 | server.nim:1478 | SDL | `stderr.writeLine(cancelled ... ended with)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 287 | server.nim:1480 | SDL | `stderr.writeLine(... cancelled; no response sent)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 289 | server.nim:1486 | SDL | `stderr.writeLine(... failed with)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 79 | server.nim:1492 | ROR | `getOrDefault(key) == ctx` → `!=` | 3 | 同じ id が再利用されたとき、先の要求の終了が後の要求の登録を消してしまう | test_server_progress_cancel: Given a request id used again while the first request runs ... |
| 290 | server.nim:1493 | SDL | `server.inFlight.del(key)` → discard | 4 | 消さない効果は private な表 `inFlight` の肥大だけ。完了済みの項目は `cancelRequest` が finished で拒むので公開 API からは見えない。観測用の公開手続き (`subscriptionCount` の類) が無いと検査できない。リードに報告 (公開 API の追加になるため触れない) |  |
| 291 | server.nim:1495 | SDL | `transport.requestDropped(...)` → discard | 3 | 取り消した要求を transport が知らされることが未検査だった (SessionedTransport に記録を追加) | test_server_progress_cancel: transport is told at once |
| 296 | server.nim:1526 | SDL | `server.resolveResponse(...)` → discard (timeout) | 2 | timeout: 応答がサーバーの待ちに届かず、サーバー発の要求を待つテストが終わらない | test_server_requests など (timeout として検出済み) |
| 239 | server.nim:917 | SDL | `waiting.complete(response)` → discard (timeout) | 2 | timeout: 同上。待ちの future が完了しないので、答えを待つテストが終わらない | 同上 |
| 299 | server.nim:1532 | SDL | `server.cancelSession(session)` → discard | 3 | transport が閉じたとき処理中の要求が cancelled になることが未検査だった (待ちの失敗は `failPending(none)` が代行するので隠れていた) | test_server_progress_cancel: Given a transport that closes, when a request is in flight, then it is cancelled |
| 298 | server.nim:1533 | SDL | `failPending(none, e)` (McpTransportClosedError 節) → discard | 1 | 直前のループで `cancelSession` が全セッションの `failPending(some(session))` を済ませる。待ちの表の鍵のセッションは必ず `server.sessions` にある (`request` は operational なセッションにしか出さず、`endSession` は cancelSession の後で消す) ので、ここは常に空振り |  |
| 300 | server.nim:1536 | SDL | `failPending(none, e)` (CatchableError 節) → discard | 3 | transport が close 以外の失敗をしたとき、サーバーの待ちが失敗することが未検査だった (SessionedTransport に `breakDown` を追加) | test_server_requests: Given a transport that fails while the server waits ... |
| 301 | server.nim:1537 | SDL | `stderr.writeLine(transport loop ended with)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 304 | server.nim:1550 | SDL | `server.endSession(session)` → discard | 3 | transport がセッションを終えたとき、要求の cancel とクライアントの忘却が未検査だった | test_server_progress_cancel: Given a transport that ends a session ... |
| 307 | server.nim:1575 | SDL | `stderr.writeLine(could not send ... session)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 308 | server.nim:1593 | SDL | `await transport.sendNotification(notification)` → discard | 2 | 購読ストリームへの配信 | test_subscriptions: tool list changes ... tagged with its id |
| 309 | server.nim:1595 | SDL | `stderr.writeLine(could not send ... subscription)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 310 | server.nim:1606 | SDL | `deliverToSubscribers(...)` → discard (`notifySubscribers`) | 3 | 拡張が購読者に通知する公開手続きを呼ぶテストが無かった。変異すると nil の future を返し、テストは SIGSEGV で落ちる | test_subscriptions: Given an open subscription, when an extension notifies the subscribers ... |
| 312 | server.nim:1619 | SDL | `await deliverToSubscribers(...)` (deliverAll) → discard | 2 | list_changed が購読ストリームにも届く | test_subscriptions: tool list changes ... |
| 154 | server.nim:1642 | LOR | `resources.isSome and ...subscribe` → `or` | 3 | resources を宣言しないサーバーで notifyResourceUpdated が何も送らず、投げないことが未検査だった | test_request_hooks: Given a server that declared no tools, prompts or resources ... |
| 155 | server.nim:1660 | LOR | tools `isSome and listChanged` → `or` | 2 | listChanged 無しの tools では送らない | test_request_hooks: Given a list the server did not declare listChanged for ... |
| 156 | server.nim:1662 | LOR | prompts `and` → `or` | 3 | prompts / resources の同じ守りは tools でしか検査されていなかった | test_request_hooks: Given prompts and resources declared without listChanged ... |
| 157 | server.nim:1664 | LOR | resources `and` → `or` | 3 | 同上 | 同上 |
| 316 | server.nim:1668 | SDL | `deliverAll(...)` (notifyListChanged) → discard | 2 | params 付きの list_changed | test_request_hooks: notifyListChanged carries params |
| 174 | server.nim:1697 | BLR | `tornDown = true` → false | 3 | endSubscriptions を続けて 2 回呼んでも、取り消しと応答は 1 回だけであることが未検査だった | test_subscriptions: Given a stdio server that ends its subscriptions twice in a row ... |
| 82 | server.nim:1698 | ROR | `kind == mtkStdio` → `!=` | 2 | stdio だけが notifications/cancelled を送る | test_subscriptions: stdio ... notifications/cancelled |
| 321 | server.nim:1703 | SDL | `await sendNotification(cancelled)` → discard | 2 | 同上 | test_subscriptions: Given a stdio server, when it ends a subscription ... |
| 322 | server.nim:1705 | SDL | `stderr.writeLine(could not cancel subscription)` → discard | 6 | 診断行の文面だけが変わる。stderr の文面は、`test_security_diagnostic` が検査する行 (制御文字の無害化) 以外は検査しない。 |  |
| 320 | server.nim:1707 | SDL | `subscription.closed.complete()` → discard | 2 | listen の応答が返らず、テストが終わらない (止まる = 検出) | test_subscriptions: ends a subscription (止まる) |
| 84 | server.nim:1721 | ROR | `level >= known.logLevel.get` → `>` | 3 | クライアントが設定した水準そのものの配信が未検査だった | test_server_logging: Given a client whose level is error, when the server logs at error ... |

### ジョブへの追記 (tests/mutation/server.json の testCommand)

`test_mrtr` / `test_extensions` / `test_request_hooks` / `test_tasks_server` / `test_subscriptions` を末尾に追記した。

### 他の共有ファイルへの追記

- `tests/sessioned_transport.nim`: `dropped` と `requestDropped`、`breakDown` を追加。
- `specs/tests.map` と `specs/*.feature`: MCP-EXT-5、MCP-HOOKS-2 (新)、MCP-CANCEL-1/3/7 (7 は新)、MCP-SERVERREQ-6、MCP-LISTCHANGED-1、MCP-SUBSCRIBE-3/6、MCP-LOGGING-2 に行を追加。

### 残っているもの

- id 290 (`server.nim:1493`、分類 4): `inFlight` の肥大は公開 API から観測できない。`inFlight` の件数を返す公開手続きを足せば検査できる。2026-10-12 に、足さないと決めた。
- id 296 と 239 (917 行) は timeout として検出済み。
- 診断行 (分類 6) の 9 件は文面だけの差で、許容した。

## server.nim 以外 (pagination / completion / log_level、および削除した resources / prompts)

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

### resources.nim と prompts.nim: 1 件も検出されなかった理由

どちらのモジュールも、SDK のどこからも import されていない。`src/`、`examples/`、`tests/`、`docs/`、`templates/`、下流の `build/ws/ds-*/src`、`products/*/src` を、エクスポートされた全 proc 名 (`createResourceInfo`、`detectMimeType`、`readFileAsResource`、`createPromptInfo`、`createTextContent` ほか) で検索して、定義以外の出現は 0 件だった。`src/mcp.nim` が import するのは `client/resources` と `client/prompts` で、サーバー側の同名ファイルではない。サーバーの resources / prompts は `server.nim` のハンドラ経由で動いていて、これらのヘルパーを使わない。

変異したコードはどのテストのコンパイルにも入らないので、テストが何であっても変異は検出されない。さらに `resources.nim` は**コンパイルできない**: 173 行の `pattern \!= "*"` に余計なバックスラッシュがあり、`Error: undeclared identifier: '\!='` になる (単独でコンパイルして確認した)。`prompts.nim` は通るが、未使用 import の警告が 3 件 (`asyncdispatch`、`options`、`sequtils`) 出る。使われていないので表に出なかった。

テストは書かない (死んだコードのテストは何も守らない)。リードの判断を待つ。提案は、2 ファイルを削除し、`tests/mutation/server.json` の `sources` から外すこと。

### 分類 4: resources.nim と prompts.nim の 60 件

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

### pagination.nim、completion.nim、log_level.nim の 10 件

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

### 追記したもの (リードが統合する)

- `tests/mutation/server.json`: なし (追加したテストは `test_server_pagination.nim` と `test_server_completion.nim` で、どちらも既に testCommand に入っている)。
- `specs/tests.map`: `MCP-PAGINATION-1`、`MCP-COMPLETION-1`、`MCP-COMPLETION-4` に各 1 行。

### 残っているもの

- `resources.nim` と `prompts.nim` (分類 4、60 件): 解消済み。どこからも import されていなかったので、`refactor(server): remove two modules nothing imported and a branch initialize cannot reach` で削除した。
- 分類 1 の 6 件は式から読んだだけで、実行していない。439 は冗長なガードで、削除するかどうかはリードが決める。

## 測り直し (本線 76a08c6a、2026-10-10)

36a4c8a5 の測定のあとに足したテストと修正を入れたコミットで、同じジョブを測り直した。変異 442、検出 371、時間切れ 5、コンパイル不能 27、**生き残り 39** (前回 237)。

前回の生き残りとの突き合わせは変異の指紋で行った。39 件のうち 37 件は前回も生き残っていて、この文書に分類と理由がある (行番号は 2〜7 行ずれている)。前回「穴」(分類 3) としてテストを足した変異は、1 件も残っていない。

| 分類 | 件数 | 内訳 |
|---|---|---|
| 1 同値 | 19 | `return none(T)` → `return default` と、末尾の `none(T)` → `discard` (どちらも `Option` の既定値は none)。`log_level.nim:24`、`completion.nim:24`、`pagination.nim` の 5 件、`server.nim` の 12 件 |
| 4 到達しない・冗長 | 3 | id 127 (`withoutInvalidParamHeaders` の早期 return)、id 290 (`inFlight.del`)、下の新規 1 件 |
| 6 許容 | 17 | stderr への診断の出力と、その文言 (`reason.len > 0`) |

新しく現れた 2 件 (どちらも測定のあとに足した行):

| 場所 | 変異 | 分類 | 理由 |
|---|---|---|---|
| `pagination.nim:43` | RVR `return none(int)` → `return default` | 1 | `default(Option[int])` は `none(int)`。同じ手続きのほかの 4 件と同じ |
| `server.nim:504` | SDL `doAssert negotiated.isSome, …` → `discard` | 4 | 握手を持つ版を 1 つも話さないサーバーは、ここに来る前に `initialize` へエラーを返している。表明は、その前提が崩れたときに止めるためのもので、テストから真にできない |

2026-10-12 に、id 290 (`inFlight` の件数を外から見えるようにするか) は、公開 API を足さないと決めた。次の測定でも生き残る。

## 2 回目の測定 (拡張ブランチの 654cb11a、2026-11-15)

518 件のうち 444 件を検出、生き残り 35 件、時間切れ 2 件。1 回目に「テストが要る」とした 33 件のうち 31 件は検出されるようになった。

| 場所 | 変異 | 分類 | 理由 |
|---|---|---|---|
| `server.nim:743` | ROR `perSecond > 0` → `>= 0` | 1 | 新規。`progressIntervalMs` を呼ぶのは `reportProgress` の `perSecond > 0 and …` の内側だけで、0 以下ではここに来ない。else の枝は冗長な守り |
| `server.nim:748` | ROR 間隔の比較 `>=` → `>` | 未決 | 間隔ちょうどの 1 ms だけ結果が変わる。時計を差し替えられないと E テストで固定できない |
| `server.nim:776` | BLR `progressFlushScheduled = true` → `false` | 未決 | 同じ間隔の中で 2 回目に保留されたときに遅延の送信が 2 つ予約される。保留は送る前に空にするので送られるのは 1 回で、外から見える差は 1 ms 未満の競合だけ |
