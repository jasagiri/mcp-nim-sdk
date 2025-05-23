#!/bin/bash

# 簡易的なカバレッジレポート生成スクリプト
set -e

# エラーの場合にindex.htmlを保証
function ensure_index_html() {
  if [ ! -f "${OUTPUT_DIR}/html/index.html" ]; then
    echo "⚠️ Failed to generate index.html, creating a fallback..."
    mkdir -p "${OUTPUT_DIR}/html"
    cat > "${OUTPUT_DIR}/html/index.html" << FALLBACK
<!DOCTYPE HTML>
<html>
<head><title>Simple Coverage Report</title></head>
<body>
<h1>MCP Nim SDK Simple Coverage Report</h1>
<p>Generated: $(date)</p>
<p>Simple coverage report is available. For a full report, run: <code>nimble coverage_structured</code></p>
</body>
</html>
FALLBACK
  fi
}

# エラー発生時の処理
trap ensure_index_html EXIT

echo "簡易的なカバレッジレポートを生成中..."

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# 出力ディレクトリ
OUTPUT_DIR="${PROJECT_ROOT}/build/coverage_simple"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/*" 2>/dev/null || true

# gcovディレクトリを準備
GCOV_DIR="${PROJECT_ROOT}/build/coverage/gcov"
mkdir -p "${GCOV_DIR}"

# nimcacheディレクトリを準備
NIMCACHE_DIR="${OUTPUT_DIR}/nimcache"
mkdir -p "${NIMCACHE_DIR}"

# コアテストを実行
echo "コアテストを実行中..."

CORE_TESTS=(
  "tests/test_protocol.nim"
  "tests/test_client.nim"
  "tests/test_server.nim"
  "tests/test_resources.nim"
  "tests/test_tools.nim"
)

for TEST in "${CORE_TESTS[@]}"; do
  echo "テスト実行中: $TEST"
  nim c -r --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-lgcov \
      --nimcache:"${NIMCACHE_DIR}" \
      "${TEST}" >> "${OUTPUT_DIR}/test_output.log" 2>&1 || echo "テスト $TEST が失敗しました"
done

# gcovデータを生成
(cd "${NIMCACHE_DIR}" && gcov *.c -o "${GCOV_DIR}" > /dev/null 2>&1) || true

# lcovでカバレッジデータを作成
echo "カバレッジデータ生成中..."
LCOV_PATH=$(which lcov)
echo "Using lcov from: ${LCOV_PATH}"
${LCOV_PATH} --capture --directory "${NIMCACHE_DIR}" \
     --output-file "${OUTPUT_DIR}/coverage.info" \
     --rc lcov_branch_coverage=1 \
     --ignore-errors gcov,mismatch,unmapped \
     --include "*/mcp-nim-sdk/src/*" \
     > "${OUTPUT_DIR}/lcov.log" 2>&1 || true

# HTMLレポートを生成
echo "HTMLレポート生成中..."

# 修正されたinfoファイルを作成
cat "${OUTPUT_DIR}/coverage.info" | grep -v "/lib/pure/options.nim:382" | grep -v "/lib/pure/options.nim:383" > "${OUTPUT_DIR}/coverage_fixed.info"

# genhtml のパスを取得
GENHTML_PATH=$(which genhtml)
echo "Using genhtml from: ${GENHTML_PATH}"

# よりロバストな設定でHTMLレポート生成
${GENHTML_PATH} "${OUTPUT_DIR}/coverage_fixed.info" \
        --output-directory "${OUTPUT_DIR}/html" \
        --ignore-errors all \
        --rc genhtml_branch_coverage=1 \
        --rc genhtml_no_prefix=1 \
        --synthesize-missing \
        --title "MCP Nim SDK Simple Coverage Report" \
        --legend \
        --function-coverage \
        > "${OUTPUT_DIR}/genhtml.log" 2>&1

# 失敗した場合はフォールバック
if [ $? -ne 0 ]; then
    echo "⚠️ genhtml failed with standard options, trying simplified version..."
    ${GENHTML_PATH} "${OUTPUT_DIR}/coverage_fixed.info" \
            --output-directory "${OUTPUT_DIR}/html" \
            --ignore-errors all \
            > "${OUTPUT_DIR}/genhtml_fallback.log" 2>&1 || true
fi

# カバレッジサマリーを作成
echo "カバレッジサマリー作成中..."
${LCOV_PATH} --summary "${OUTPUT_DIR}/coverage.info" \
     --rc lcov_branch_coverage=1 \
     > "${OUTPUT_DIR}/summary.log" 2>&1 || true

# サマリーをファイルに保存
echo "カバレッジレポートサマリー" > "${OUTPUT_DIR}/summary.txt"
echo "=======================" >> "${OUTPUT_DIR}/summary.txt"
echo "生成日時: $(date)" >> "${OUTPUT_DIR}/summary.txt"
echo "" >> "${OUTPUT_DIR}/summary.txt"
cat "${OUTPUT_DIR}/summary.log" >> "${OUTPUT_DIR}/summary.txt"

# シンプルなindex.htmlを作成
cat > "${OUTPUT_DIR}/html/index.html" << EOF
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
  <title>MCP Nim SDK Simple Coverage Report</title>
  <style>
    body { font-family: sans-serif; margin: 20px; }
    h1, h2 { color: #333; }
    pre { background: #f5f5f5; padding: 10px; border-radius: 5px; }
  </style>
</head>
<body>
  <h1>MCP Nim SDK Simple Coverage Report</h1>
  <p>Generated: $(date)</p>
  
  <h2>Summary</h2>
  <pre>$(cat "${OUTPUT_DIR}/summary.log" 2>/dev/null || echo "No summary available")</pre>
  
  <h2>Core MCP Files</h2>
  <ul>
    <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/client.nim.gcov.html">client.nim</a></li>
    <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/logger.nim.gcov.html">logger.nim</a></li>
    <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/prompts.nim.gcov.html">prompts.nim</a></li>
    <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/protocol.nim.gcov.html">protocol.nim</a></li>
    <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/resources.nim.gcov.html">resources.nim</a></li>
    <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/roots.nim.gcov.html">roots.nim</a></li>
    <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/server.nim.gcov.html">server.nim</a></li>
    <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/tools.nim.gcov.html">tools.nim</a></li>
  </ul>
  
  <p>Note: This is a simplified coverage report. For a more detailed report, run: <code>nimble coverage_structured</code></p>
</body>
</html>
EOF

echo ""
echo "カバレッジレポートが生成されました:"
echo "  場所: ${OUTPUT_DIR}"
echo "  HTMLレポート: ${OUTPUT_DIR}/html/index.html"
echo "  サマリー: ${OUTPUT_DIR}/summary.txt"
echo ""
echo "より詳細なレポートを生成するには次のコマンドを実行してください:"
echo "  nimble coverage_structured"