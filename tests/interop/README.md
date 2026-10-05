# 他実装との相互接続の確認

この SDK で作ったサーバーとクライアントを、公式の Python SDK・TypeScript SDK、
Claude Code とつないで確かめるための道具。

## 構成

| ファイル | 役割 |
|---|---|
| `nim_stdio_server.nim` | stdio のサーバー。ツール `echo` を 1 つ持つ |
| `nim_http_server.nim` | Streamable HTTP のサーバー。`nim_http_server PORT` で `http://127.0.0.1:PORT/mcp` |
| `nim_client.nim` | クライアント。`nim_client stdio CMD [ARGS...]` または `nim_client http URL` |
| `peers/py/py1_*.py`, `py2_*.py` | Python SDK 1.x / 2.x の相手役 (サーバーとクライアント) |
| `peers/ts/ts1_*.mjs`, `ts2_*.mjs` | TypeScript SDK 1.x / 2.x の相手役 |
| `peers/py/tee_stdio.py`, `tee_http.py` | 通信を中継して記録する。流れた版を `VER ...` 行で書き出す |
| `peers/run_versions.py` | Python ⇔ TypeScript を版ごとに総当たりする |
| `peers/run_nim.py` | Nim を 5 つの版でビルドし、公式 SDK との総当たりを判定付きで流す (下の「版ごとの総当たり」) |
| `peers/run_conformance.py` | 公式の適合性テストを Nim のサーバー・クライアントに対して流す |
| `nim_conformance_server.nim` | 適合性テストの対象のサーバー (HTTP のみ)。決まった名前のツール・リソース・プロンプトを持つ |
| `nim_conformance_client.nim` | 適合性テストが起動するクライアント。対応しないシナリオは終了コード 2 で断る |
| `peers/setup.sh` | 相手役の実行環境を作る |

Nim 側の 3 本は、ビルドのデフォルト版とそれ以前の版を話す。話す版の上限はビルドごとに決まる
(`-d:mcpDefaultProtocolVersion=2025-06-18` など)。`nim_client` は環境変数 `MCP_VERSION` で
上限をさらに下げられる。

クライアントはどれも、成功すると次の形の JSON を 1 行出力して終了コード 0 で終わる。

```json
{"ok":true,"impl":"mcp-nim-sdk","requested":"auto","protocolVersion":"2026-07-28","tools":["echo"],"result":"hello"}
```

## 準備

`uv`、`node`、`npm` が要る。

```sh
tests/interop/peers/setup.sh            # build/interop に環境を作る
nim c --path:src -o:build/interop/nim_stdio_server tests/interop/nim_stdio_server.nim
nim c --path:src -o:build/interop/nim_http_server tests/interop/nim_http_server.nim
nim c --path:src -o:build/interop/nim_client tests/interop/nim_client.nim
```

## 実行例

```sh
cd build/interop

# 公式クライアント → Nim のサーバー (stdio)。MCP_VERSION で要求する版を固定する
MCP_VERSION=2025-06-18 py2/.venv/bin/python py/py2_client.py stdio ./nim_stdio_server
MCP_VERSION=auto node ts/ts2_client.mjs stdio ./nim_stdio_server

# Nim のクライアント → 公式サーバー (stdio)
./nim_client stdio py2/.venv/bin/python py/py2_server.py stdio
./nim_client stdio node ts/ts2_server.mjs stdio --max=2025-03-26

# HTTP
./nim_http_server 18110 &
MCP_VERSION=2025-11-25 node ts/ts1_client.mjs http http://127.0.0.1:18110/mcp
py2/.venv/bin/python py/py2_server.py http 18101 &
./nim_client http http://127.0.0.1:18101/mcp
```

相手役が要求する版・話す版の上限の決め方は、各スクリプト冒頭のコメントに書いてある。
公開 API で版を固定できない SDK は、その版が最新だった時期のリリースを使う
(`setup.sh` が `old/` 以下に入れる)。

## Claude Code から呼ぶ

ユーザーの設定は変えず、一時的な設定ファイルを指定して 1 回だけ実行する。

```sh
cat > /tmp/mcp-nim.json <<JSON
{"mcpServers":{"interop":{"type":"stdio","command":"$PWD/build/interop/nim_stdio_server"}}}
JSON
claude -p 'Call the echo tool of the "interop" MCP server with text "nim-interop-ok" and reply with exactly the text it returned, nothing else.' \
  --mcp-config /tmp/mcp-nim.json --strict-mcp-config \
  --allowedTools mcp__interop__echo --output-format json \
  --no-session-persistence --max-budget-usd 0.50 --model haiku < /dev/null
```

## 版ごとの総当たり (`peers/run_nim.py`)

```sh
tests/interop/peers/setup.sh build/interop        # 初回だけ (nimble interop は無ければ自動で作る)
python3 tests/interop/peers/run_nim.py            # または: nimble interop
python3 tests/interop/peers/run_nim.py --builds 2025-06-18 --transports stdio     # 絞る
python3 tests/interop/peers/run_nim.py --versions 2026-07-28 --directions to-nim   # 相手の版・向きで絞る
python3 tests/interop/peers/run_nim.py --list     # 行の一覧だけ (実行しない)
```

Nim のビルドを 5 つ (`-d:mcpDefaultProtocolVersion=V`、`build/interop-nim/V/` に置く) 作り、ビルドごと・transport ごとに次を流す。

- 公式のクライアント (版 V に固定、または探る `auto`) → Nim のサーバー
- Nim のクライアント → 公式のサーバー (その版が上限)

判定は `run_versions.py` と同じで、クライアントの出力した版と、中継 (`tee_stdio.py` / `tee_http.py`) が
記録した `VER` 行の**両方**が期待の版を指すときだけ合格にする。各行は期待を 3 種のどれかで持つ。

| 期待 | 意味 |
|---|---|
| `ok:V` | ちょうど V で成立しなければならない |
| `reject` | 成立してはならない (例: 2025-06-18 までのビルドに 2026-07-28 固定のクライアント) |
| `reject-or-downgrade` | ビルドの上限より新しい版で成立してはならない。失敗も、ビルド自身の版に下げて成立するのも正しい (相手の SDK による) |

制限と例外:

- Streamable HTTP の行は 2025-03-26 以降だけ (2024-11-05 の HTTP は HTTP+SSE)。2024-11-05 だけを話すビルドには HTTP の行が無い。
- HTTP+SSE (`sse`) の行は用意してあるが、Nim 側に実装が無いので「未実装」と表示して流さない。実装後は `--try-unimplemented` で流す
  (その際 `nim_http_server` が `sse` を受け付けるようにする必要がある。今は何もしない)。
- 公式の Python 1.8.1 のサーバーは未知のリクエストで終了するため、2026-07-28 の探り (`server/discover`) で死ぬ。
  その行だけ Nim のクライアントの上限を 2024-11-05 に固定して流す (行の `fixed_by` に書いてある)。
- ポートは OS が空きを選ぶ。固定の範囲にすると他の作業と衝突し、中継が他人のサーバーに転送してしまう。

出力は `build/interop-nim/` の `nim_versions.md` (Markdown の表) と `nim_versions.jsonl` (1 行 1 JSON)、`logs/` (行ごとの通信記録)。
不合格の行があれば終了コードは 1。所要時間は 2026-10-06 に、同じマシンで他のビルドが走る中、`--jobs 3` で
5 回のビルドを含め **312 行 (うち 25 行が未実装) で約 13 分 (764 秒)**。

## 公式の適合性テスト (`peers/run_conformance.py`)

```sh
python3 tests/interop/peers/run_conformance.py          # または: nimble conformance (ビルド込みで約 7 分、ビルド済みなら約 3 分)
python3 tests/interop/peers/run_conformance.py --builds 2026-07-28 --roles server
```

`@modelcontextprotocol/conformance` (0.2.0-alpha.12) を、サーバーとクライアントの両方の向きで流す。
サーバー検査は `nim_conformance_server` を HTTP で、クライアント検査は `nim_conformance_client` を
`conformance client --command ...` で起動させる。ビルドの版ごとに、その版の仕様のシナリオだけを選ぶ
(2026-07-28 のビルドは 2025-11-25 の組も流す)。結果は `build/interop-nim/conformance.md` と `conformance.jsonl`。
**不合格は SDK にまだ無い機能の一覧なので、終了コード 1 が通常の状態**。内訳と原因は `docs/quality/conformance-2026-10-06.md`。

## Claude Code での確認

課金が発生するので自動化していない。上の「Claude Code から呼ぶ」の手順を手で流す。確認する点:
`server/discover` を送ること、`tools/list` と `tools/call` が 2026-07-28 の形式であること、結果が `nim-interop-ok` であること。
旧版のサーバーに対して `initialize` に切り替えるかは未確認。

## まだ無いもの

- TODO: 2024-11-05 の HTTP+SSE での確認 (この SDK に HTTP+SSE の実装がまだ無い。行は `run_nim.py` に用意済み)。
- TODO: 適合性テストのクライアント検査のうち、認可・HTTP ヘッダ・request state などは、SDK のクライアントに機能が無いので
  `nim_conformance_client` が断っている。機能が入ったら対応するシナリオを足す。
