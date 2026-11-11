# G2 変異検出: rate_limit ジョブ

## 測り直し (拡張ブランチの b04fcb9c、2026-11-11)

測定: `nim-muter` 0.2.15、ジョブ `tests/mutation/rate_limit.json`。テストは 2026-10-13 に外部と内部に分け直した後のもの。状態: 測定済み。

| 全体 | killed | timeout | survived | runError | compileError |
|---|---|---|---|---|---|
| 30 | 16 | 1 | 12 | 0 | 1 |

対象は `src/server/rate_limit.nim`。このモジュールはどの公開の入口からも export されておらず、外から届く道は `src/server/server.nim` の `rateLimited` が呼ぶ `take` の 1 本だけ。`rateLimited` は `perSecond <= 0` なら `take` を呼ばずに返り、`maxSenders` には `max(1, server.maxRateLimitedSenders)` を渡し、`now` は渡さない (既定の `getMonoTime()`)。下の仕分けはこの呼び方を前提にしている。

### 生き残りの仕分け

| 指紋 | file:line | 変異 | class | 理由 | 仕様 ID / 足すテストの案 |
|---|---|---|---|---|---|
| `src/server/rate_limit.nim:ROR:0ca230dd385f2a04:0` | rate_limit.nim:48 | `bucket.filled(now, perSecond) >= perSecond.float` → `>` | spec_question | `filled` は `min(perSecond.float, …)` なので `>` は決して成り立たず、`makeRoom` の 1 段目 (満杯に戻った送り手を忘れる) が丸ごと働かなくなる。満杯の送り手を忘れること自体は外から見えない (新しいバケツも満杯で始まる) が、代わりに 2 段目が最も古い印の送り手を忘れるので、「満杯の送り手が居るのに、まだ使い切ったままの最古の送り手が忘れられて満額に戻る」という違いが外に出る。MCP-RATE-3 の Scenario は「満杯に戻った送り手が居ないとき」しか述べておらず、居るときにどうなるかはどの仕様 ID にも無い。 | 問い: 「満杯に戻った送り手が居る間は、使い切った送り手を忘れない (満額に戻さない)」を MCP-RATE-3 に足して仕様にしますか、それとも 1 段目 (46〜51 行) を消して「常に最も長く静かな送り手を忘れる」だけにしますか。仕様にするなら案: 毎秒 2・送り手 2 で、alice が 2 回 (使い切り)、bob が 1 回、bob が満杯に戻る 500 ms 過ぎ・alice が満杯に戻る前に carol が話し、直後の alice の 2 回のうち 2 回目が断られること (変異だと alice が忘れられて 2 回とも通る)。時間に依るので `quickRun` と同じく所要時間を測って繰り返す形が要る |
| `src/server/rate_limit.nim:SDL:9e5c2f527dddabee:0` | rate_limit.nim:49 | `quiet.add key` → `discard` | spec_question | `quiet` が常に空になり、1 段目が働かない。外から見える違いは上の行 (48 行) と同じ。 | 上の行と同じ問い・同じテストの案 |
| `src/server/rate_limit.nim:SDL:36c078446e02eae4:0` | rate_limit.nim:51 | `limiter.buckets.del(key)` → `discard` | spec_question | 満杯の送り手を集めても消さないので、1 段目が働かない。外から見える違いは 48 行の行と同じ (表の大きさは 2 段目が保つので `maxSenders` は越えない)。 | 48 行の行と同じ問い・同じテストの案 |
| `src/server/rate_limit.nim:LOR:ab81a607d669deb3:0` | rate_limit.nim:56 | `oldest.len == 0 or bucket.stamp < oldestStamp` → `and` | test_owed | 変異後は、表を回る順で最初に出会った「印が今より前」の送り手を選び、そこで止まる (2 件目からは `oldest.len == 0` が偽)。最も長く静かな送り手ではなく、ハッシュ表の並びで先に来る送り手が忘れられる。今のテストは alice が最古で、かつ表の並びでも alice が先に来るので通ってしまう (生き残ったことからの推論)。 | MCP-RATE-3。案: 既存の `Given a limit of 2 senders, when a third sender speaks, …` と同じ形で、alice と bob の役を入れ替えた 1 本を足す (毎秒 1・送り手 2。bob が 2 回で 2 回目は断られ、次に alice が 1 回、carol が 1 回、そのあと bob がもう一度通ること。併せて、忘れられていない alice の 2 回目が断られることも見る)。表の並びは鍵で決まり話した順に依らないので、変異だと 2 本のどちらかで「最古でない方」が忘れられ、最古の送り手が断られたままになって落ちる |
| `src/server/rate_limit.nim:ROR:4df609b56b2ba6c1:0` | rate_limit.nim:56 | `bucket.stamp < oldestStamp` → `<=` | unreached | 差が出るのは、2 つの送り手の印 (`MonoTime`、ナノ秒) がちょうど等しいときだけ (そのとき忘れる相手が、表の並びで先の方から後の方に変わる)。印は `take` の既定の引数 `getMonoTime()` で付き、`server.nim` の `rateLimited` は `now` を渡さないので、公開の入口から 2 つの要求に同じ印を付ける入力を作れない。なお、同じだけ静かな 2 者のどちらを忘れるかは MCP-RATE-3 も定めていない。 | なし |
| `src/server/rate_limit.nim:SDL:57e7ddd2e965b6f0:0` | rate_limit.nim:66 | `doAssert perSecond > 0 and maxSenders > 0, …` → `discard` | unreached | この表明が落ちる入力は公開の入口から作れない。`server.nim` の `rateLimited` が `if perSecond <= 0: return none(…)` で先に返り (MCP-RATE-4 の「0 は制限なし」)、`maxSenders` には `max(1, server.maxRateLimitedSenders)` を渡す。`take` の呼び手はここだけで、`rate_limit` は export されていない。 | なし |
| `src/server/rate_limit.nim:ROR:81e6fa10bdd566a6:0` | rate_limit.nim:66 | `perSecond > 0` → `>= 0` | unreached | 差が出るのは `perSecond == 0` のときだけ。`rateLimited` の `if perSecond <= 0: return` が先に返すので、`take` に 0 は届かない。 | なし |
| `src/server/rate_limit.nim:LOR:3bd431dcd2ec0d8c:0` | rate_limit.nim:66 | `perSecond > 0 and maxSenders > 0` → `or` | unreached | 差が出るのは片方だけが 0 以下のときだけ。`rateLimited` は `perSecond <= 0` で先に返り、`maxSenders` は `max(1, …)` で 1 以上にしてから渡すので、どちらも起きない。 | なし |
| `src/server/rate_limit.nim:ROR:6b406dff25c263b4:0` | rate_limit.nim:66 | `maxSenders > 0` → `>= 0` | unreached | 差が出るのは `maxSenders == 0` のときだけ。`rateLimited` が `max(1, server.maxRateLimitedSenders)` を渡すので、`take` に 0 は届かない。 | なし |
| `src/server/rate_limit.nim:AOR:7c64e14a3577099a:0` | rate_limit.nim:86 | `(1.0 - bucket.tokens) / perSecond.float` → `*` | test_owed | `retryAfterMs` が「不足分 ÷ 毎秒の数」ではなく「不足分 × 毎秒の数」になる。毎秒 1 では同じ値で、今のテスト (`Given a refused request, then the error says how long to wait`) は毎秒 1 でしか見ていないので通る。毎秒 2 以上では待ち時間が毎秒の数の 2 乗倍になる (毎秒 4 で最大 251 ms のはずが最大 4001 ms)。 | MCP-RATE-1 (`data.retryAfterMs`)。案: 毎秒 4 で 5 回続けて送り、断られた 5 回目の `retryAfterMs` が 1 以上 251 以下 (1 回分が戻る時間 1000 ÷ 4 に切り上げの 1) であること。変異だと 1000 を超えて落ちる |
| `src/server/rate_limit.nim:AOR:53d668ef4efecbc3:0` | rate_limit.nim:86 | `… * 1000.0` → `/ 1000.0` | test_owed | 秒からミリ秒への換算が逆になり、`int(…)` が 0 になって `retryAfterMs` が常に 1 になる。今のテストは 0 より大きく 1000 以下としか見ていないので通る。言われたとおり 1 ms 待っても、まだ断られる。 | MCP-RATE-1 (`data.retryAfterMs`)、MCP-RATE-2 (待てばまた答えが来る)。案: 毎秒 1 で 2 回続けて送り、断られた 2 回目の `retryAfterMs` が「1000 − 2 回を送るのにかかった ms」以上であること (かかった時間は外で測るので、中の経過時間より長く、下限として安全)。変異だと 1 で落ちる。振る舞いで見るなら、`retryAfterMs` だけ待って送ると通ること |
| `src/server/rate_limit.nim:AOR:0066a8bb1ed0649e:0` | rate_limit.nim:86 | `int(…) + 1` → `- 1` | test_owed | 切り上げの 1 が引き算になり、待ち時間が 2 ms 短くなる。不足分が 2 ms 未満のときは `retryAfterMs` が 0 か −1 になる。今のテストは毎秒 1 (待ち時間が 1000 ms 近く) で `wait > 0` を見るだけなので通る。 | MCP-RATE-1 (`data.retryAfterMs`。既存のテストが「0 ms より大きい」を見ている)。案: 既定の毎秒 100 で 300 回を間を置かずに送り、断られた応答すべての `retryAfterMs` が 1 以上であること。毎秒 100 では不足分が 0〜10 ms に散らばり、変異だと不足分が 2 ms 未満の断り (およそ 5 回に 1 回) で 0 以下になって落ちる。要求が 2 ms に 1 回より遅い実行では何も分からないので、既存の `quickRun` と同じく所要時間を測り、遅い実行は繰り返す。上の 2 行の案と合わせ、「上限 (1000 ÷ 毎秒 + 1)・下限 (残り時間以上)・常に 1 以上」を 1 本にまとめてもよい |

### 時間切れ

| 指紋 | file:line | 変異 | 無限ループか | 理由 |
|---|---|---|---|---|
| `src/server/rate_limit.nim:SDL:322e013d963ce2cc:0` | rate_limit.nim:59 | `limiter.buckets.del(oldest)` → `discard` | 無限ループ (本物の時間切れ。測り直しは要らない) | 52 行目の `while limiter.buckets.len >= maxSenders` の中で表を減らすのはこの 1 文だけなので、消すとループに入ったら終わらない。既存の `Given a limit of 2 senders, when a third sender speaks, …` (MCP-RATE-3) は、満杯の送り手が居ないまま 3 人目が話すので必ずこのループに入る。負荷による偽の時間切れではない。 |

補足: 56 行目の LOR の変異 (`or` → `and`) も、表のどの送り手の印も今より前でないときは `oldest` が空のままになり、同じループが終わらなくなる。今回は生き残りとして数えられているので、その経路はテストで通っていない。上の MCP-RATE-3 の案を足せば、どちらの形でも検出される。
