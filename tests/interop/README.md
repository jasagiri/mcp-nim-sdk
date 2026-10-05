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

## まだ無いもの

- TODO: `run_versions.py` に Nim のバイナリを組み込む。現状は Python ⇔ TypeScript だけを総当たりする。
  Nim との組み合わせは、上の実行例のコマンドを個別に流して確かめている。
- TODO: 公式の適合性テスト (`@modelcontextprotocol/conformance`) の対象になるサーバー。
  決まった名前のツール・リソース・プロンプト (`test_simple_text` ほか) を持つ必要がある。
- TODO: 2024-11-05 の HTTP+SSE での確認 (この SDK に HTTP+SSE の実装がまだ無い)。
