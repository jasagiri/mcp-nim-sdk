#!/bin/sh
# Build the directory the interop checks run in: the peer scripts next to
# pinned releases of the official Python and TypeScript SDKs.
#
#   tests/interop/peers/setup.sh [DIR]      (default: build/interop)
#
# Needs uv, node and npm. Nothing is installed outside DIR.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dir=${1:-build/interop}
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)

cp -R "$here/py" "$dir/"
cp "$here/run_versions.py" "$dir/"

# Python SDK: 2.x speaks every version; each 1.x release below is the last
# whose newest protocol version is the one named.
py_env() {  # py_env SUBDIR MCP_VERSION
  mkdir -p "$dir/$1"
  uv venv --quiet --python 3.13 "$dir/$1/.venv"
  uv pip install --quiet --python "$dir/$1/.venv/bin/python" "mcp==$2"
}
py_env py2 2.3.0
py_env py1 1.30.0            # 2025-11-25
py_env old/py-1.22.0 1.22.0  # 2025-06-18
py_env old/py-1.9.4 1.9.4    # 2025-03-26
py_env old/py-1.8.1 1.8.1    # 2024-11-05

# TypeScript SDK: 2.x is published as separate packages.
mkdir -p "$dir/ts"
cp "$here"/ts/*.mjs "$dir/ts/"
(cd "$dir/ts" && npm init -y >/dev/null && npm install --silent --save-exact \
  @modelcontextprotocol/client@2.3.1 @modelcontextprotocol/server@2.3.1 \
  @modelcontextprotocol/node@2.1.1 @modelcontextprotocol/sdk@1.32.1 zod)

ts_env() {  # ts_env SDK_VERSION
  mkdir -p "$dir/old/ts-$1"
  cp "$here/ts/ts1_client.mjs" "$here/ts/ts1_server.mjs" "$dir/old/ts-$1/"
  (cd "$dir/old/ts-$1" && npm init -y >/dev/null && \
    npm install --silent --save-exact "@modelcontextprotocol/sdk@$1" zod)
}
ts_env 1.23.1  # 2025-06-18
ts_env 1.12.3  # 2025-03-26
ts_env 1.10.2  # 2024-11-05

# The official conformance suite; the alpha has the 2026-07-28 scenarios.
mkdir -p "$dir/conformance"
(cd "$dir/conformance" && npm init -y >/dev/null && \
  npm install --silent --save-exact @modelcontextprotocol/conformance@0.2.0-alpha.12)

echo "interop peers ready in $dir"
