# 版ごとの相互接続の総当たり: 2026-10-06

`tests/interop/peers/run_nim.py` の結果。Nim を 5 つの版 (`-d:mcpDefaultProtocolVersion=V`) でビルドし、公式の
Python SDK (`mcp` 1.30.0 / 2.3.0、およびその版が最新だった時期の 1.22.0 / 1.9.4 / 1.8.1) と TypeScript SDK
(`@modelcontextprotocol/sdk` 1.32.1 / 1.23.1 / 1.12.3 / 1.10.2、`client` / `server` 2.3.1) の組と、stdio と
Streamable HTTP でつないだ。ツールは `echo` だけで、確認するのは「接続の成立、版の確定、`tools/list`、`tools/call`」。

判定は、クライアントが出力した版と、中継 (`tee_stdio.py` / `tee_http.py`) が記録した `VER` 行の両方が期待の版を
指すこと (`run_versions.py` と同じ方式)。手順と期待の種類は `tests/interop/README.md`。

## 結果

312 行: **合格 312、不合格 0**。所要時間は、HTTP+SSE の行を流すようにしたあとの再実行 (ビルド済み、`--jobs 3`) で 64 秒。
最初の実行は 764 秒 (5 回のビルドを含み、同じマシンで他の作業が走る中) で、そのときは HTTP+SSE の 25 行が未実装として流されず、287 合格 / 25 未実装だった。
全行は `build/interop-nim/nim_versions.md` と `.jsonl` に出る (再現するには `nimble interop`)。

| transport | Nim のビルド | 公式 → Nim | Nim → 公式 |
|---|---|---|---|
| stdio | 2024-11-05、2025-03-26、2025-06-18、2025-11-25、2026-07-28 (各) | 20 合格 | 15 合格 |
| Streamable HTTP | 2025-03-26、2025-06-18、2025-11-25、2026-07-28 (各) | 16 合格 | 12 合格 |
| HTTP+SSE | 5 ビルド (各) | 3 合格 (Python 2.x を 2024-11-05 に固定、Python 1.8.1、TypeScript 1.10.2) | 2 合格 (TypeScript 1.10.2、Python 1.8.1) |

2024-11-05 のビルドの Streamable HTTP の行は無い (その版の HTTP は HTTP+SSE。ビルドは 2024-11-05 より新しい版を話さない)。

### 合格の内訳 (期待の種類)

- 版を指定して成立 (`ok:V`): 255 行 (HTTP+SSE の 25 行はすべてこれ。TypeScript 2.x に HTTP+SSE の transport は無く、1.x の公式サーバーだけが相手)。公式のクライアントを V に固定、あるいは自動判定させて、Nim のビルドの上限 (自動判定) または
  V (固定) で成立。公式のサーバーの上限が V のとき、Nim のクライアントは min(ビルドの版, V) で成立。
- 成立してはならない (`reject`): 21 行。
  - 2026-07-28 に固定した公式のクライアント (Python 2.x、TypeScript 2.x) → 2025-11-25 以前のビルド。
    TypeScript は `Version negotiation failed`、Python は stdio で `ListToolsResult` の検証失敗 (旧版のサーバーは
    `cacheScope` を返さない)、HTTP で `Mcp-Session-Id header is required`。
  - 2026-07-28 だけを話す公式のサーバー (TypeScript 2.x `--legacy=reject`) ← 2025-11-25 以前のビルドの Nim のクライアント。
    `Unsupported protocol version`。
- 上限より新しい版で成立してはならない (`reject-or-downgrade`): 36 行。相手の SDK によって、拒否 (TypeScript 2.x は
  サーバーが返した古い版を拒否する) か、ビルドの版に下げて成立する (Python、TypeScript 1.x) かが分かれる。どちらも期待どおり。
  新しすぎる版で成立した行は 0。

## 途中で見つけたこと (この表の外)

- 旧い TypeScript SDK 1.10.2 / 1.12.3 のサーバーが `tools/call` で `keyValidator._parse is not a function` を返した。zod 4 を
  入れていたのが原因で、`setup.sh` が旧い SDK の環境に入れる zod を `zod@3` に直した (相手側の環境の問題で、SDK の不具合ではない)。
- Python 1.8.1 のサーバーは未知のリクエストで終了するため、Nim のクライアントの自動判定 (`server/discover` で探る) が使えない。
  この行だけ、Nim のクライアントの上限を 2024-11-05 に固定した (行の `fixed_by` に記録)。公式の Python 2.x の自動判定も同じ相手に失敗する。
- ポートを固定の範囲 (18000 番台) にすると、同じマシンの他の作業と衝突し、中継が他人のサーバーに転送して誤った結果が出た。
  初回の実行の不合格 9 行のうち 8 行は、この衝突か、サーバーの起動待ち (8 秒) の短さが原因だった。OS に空きを選ばせ、起動待ちを
  30 秒にして再実行すると 0 行になった (残りの 1 行は次の項)。
- クライアントが探りの応答を待たずに `initialize` を送った例が 1 回あった (負荷の高いときの Python 2.3.0 のサーバー、stdio)。
  初回の実行の不合格 1 行がこれで、再実行では再現せず、未確認。`docs/quality/conformance-2026-10-06.md` の「不具合の疑い」に書いた。

## 確かめていないこと

- HTTP+SSE の期待は `ok:2024-11-05` だけ。ビルドの版が新しくても、HTTP+SSE は 2024-11-05 の transport なので、版を上げる交渉の行は無い。
- Claude Code: 課金が発生するので流していない (手順は README)。旧版のサーバーに対して `initialize` に切り替えるかも未確認。
- Nim ⇔ Nim (異なる版のビルド同士): この総当たりには入れていない。手で 6 組 (サーバー 2025-11-25 / 2025-03-26 / 2026-07-28 ×
  クライアント 2026-07-28 / 2025-06-18) を HTTP で流し、すべて成立した (版は min(双方の上限))。表には出していない。
- 2024-11-05 を要求する公式のクライアントを Streamable HTTP で Nim につなぐ行: 仕様上その組み合わせが無いので出していない。
- ツール以外 (リソース、プロンプト、通知、sampling など) の相互接続。適合性テストの側で見る (`conformance-2026-10-06.md`)。
