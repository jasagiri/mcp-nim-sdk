#!/bin/bash

# 構造化されたカバレッジレポート生成スクリプト
set -e

echo "構造化されたカバレッジレポートを生成中..."

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# タイムスタンプを生成
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
COVERAGE_ROOT="${PROJECT_ROOT}/build/coverage_reports/${TIMESTAMP}"

# ディレクトリ構造を作成
mkdir -p "${COVERAGE_ROOT}/data"
mkdir -p "${COVERAGE_ROOT}/html"
mkdir -p "${COVERAGE_ROOT}/lcov"
mkdir -p "${COVERAGE_ROOT}/logs"
mkdir -p "${COVERAGE_ROOT}/test_results"

# gcovディレクトリを準備
GCOV_DIR="${PROJECT_ROOT}/build/coverage/gcov"
mkdir -p "${GCOV_DIR}"

echo "カバレッジディレクトリ: ${COVERAGE_ROOT}"

# 環境情報を記録
cat > "${COVERAGE_ROOT}/environment.txt" << EOF
Coverage Report Generation
Generated: $(date)
Nim Version: $(nim --version | head -n 1)
GCC Version: $(gcc --version | head -n 1)
Host: $(hostname)
User: $(whoami)
EOF

# テストファイルを取得
TEST_FILES=$(find tests -maxdepth 1 -name "test_*.nim" -type f | sort)

# 各テストごとに個別のカバレッジデータを生成
for TEST_FILE in $TEST_FILES; do
    TEST_NAME=$(basename $TEST_FILE .nim)
    echo "テスト実行中: $TEST_NAME"
    
    # テスト用の一時ディレクトリを作成
    TEST_CACHE="${COVERAGE_ROOT}/data/${TEST_NAME}"
    mkdir -p "$TEST_CACHE"
    
    # テストをカバレッジ付きでコンパイル・実行 (100%カバレッジを目指す設定)
    if nim c -r \
        --passC:-fprofile-arcs \
        --passC:-ftest-coverage \
        --passL:-lgcov \
        --debugger:native \
        --lineDir:on \
        --debuginfo \
        --nimcache:"$TEST_CACHE" \
        "$TEST_FILE" > "${COVERAGE_ROOT}/test_results/${TEST_NAME}.log" 2>&1; then
        echo "  ✓ 成功: $TEST_NAME"
    else
        echo "  ✗ 失敗: $TEST_NAME"
        # テスト失敗の詳細をログに表示
        echo "テスト失敗の詳細:" >> "${COVERAGE_ROOT}/logs/error_${TEST_NAME}.log"
        cat "${COVERAGE_ROOT}/test_results/${TEST_NAME}.log" >> "${COVERAGE_ROOT}/logs/error_${TEST_NAME}.log"
        continue
    fi
    
    # gcovデータを生成
    (cd "$TEST_CACHE" && gcov *.c -o "${GCOV_DIR}" > /dev/null 2>&1) || true
    echo "gcov処理完了: ${TEST_NAME}" > "${COVERAGE_ROOT}/logs/gcov_${TEST_NAME}.log"
    
    # lcovで個別のカバレッジデータを作成（詳細な設定で100%カバレッジを目指す）
    LCOV_PATH=$(which lcov)
    echo "Using lcov from: ${LCOV_PATH}"
    ${LCOV_PATH} --capture --directory "$TEST_CACHE" \
         --output-file "${COVERAGE_ROOT}/lcov/${TEST_NAME}.info" \
         --rc lcov_branch_coverage=1 \
         --rc genhtml_branch_coverage=1 \
         --rc lcov_function_coverage=1 \
         --rc genhtml_function_coverage=1 \
         --ignore-errors gcov,mismatch,unmapped \
         --exclude '/usr/*' --exclude '*/choosenim/*' --exclude '*/nimble/*' \
         --include "*/mcp-nim-sdk/src/*" \
         > "${COVERAGE_ROOT}/logs/lcov_${TEST_NAME}.log" 2>&1 || true
         
    # ゼロカバレッジ行をチェック
    echo "ゼロカバレッジ行のチェック: ${TEST_NAME}" > "${COVERAGE_ROOT}/logs/zero_coverage_${TEST_NAME}.log"
    ${LCOV_PATH} --zerocounters --directory "$TEST_CACHE" >> "${COVERAGE_ROOT}/logs/zero_coverage_${TEST_NAME}.log" 2>&1 || true
done

# 全てのカバレッジデータを統合
echo "カバレッジデータを統合中..."
LCOV_FILES=$(find "${COVERAGE_ROOT}/lcov" -name "*.info" -type f)

if [ -n "$LCOV_FILES" ]; then
    # 最初のファイルをベースにする
    FIRST_FILE=$(echo $LCOV_FILES | cut -d' ' -f1)
    cp "$FIRST_FILE" "${COVERAGE_ROOT}/lcov/combined.info"
    
    # 残りのファイルをマージ
    for INFO_FILE in $LCOV_FILES; do
        if [ "$INFO_FILE" != "$FIRST_FILE" ]; then
            ${LCOV_PATH} --add-tracefile "${COVERAGE_ROOT}/lcov/combined.info" \
                 --add-tracefile "$INFO_FILE" \
                 --output-file "${COVERAGE_ROOT}/lcov/combined_temp.info" \
                 > "${COVERAGE_ROOT}/logs/lcov_merge.log" 2>&1 || true
            mv "${COVERAGE_ROOT}/lcov/combined_temp.info" "${COVERAGE_ROOT}/lcov/combined.info"
        fi
    done
    
    # HTMLレポートを生成（100%カバレッジレポートの詳細設定）
    echo "HTMLレポートを生成中..."
    
    # Source filesのみにフィルタリングして詳細なカバレッジレポートを作成
    ${LCOV_PATH} --extract "${COVERAGE_ROOT}/lcov/combined.info" "*/mcp-nim-sdk/src/*" \
         --output-file "${COVERAGE_ROOT}/lcov/filtered.info" \
         --rc lcov_branch_coverage=1 \
         > "${COVERAGE_ROOT}/logs/lcov_filter.log" 2>&1 || true
         
    # Uncovered linesがあれば列挙
    ${LCOV_PATH} --list-full-path \
         --rc lcov_branch_coverage=1 \
         "${COVERAGE_ROOT}/lcov/filtered.info" \
         > "${COVERAGE_ROOT}/logs/uncovered_lines.log" 2>&1 || true
    
    # 事前処理: フィルタリングや修正を行う
    echo "カバレッジデータの前処理を実行中..."
    
    # 修正されたinfoファイルを作成
    cat "${COVERAGE_ROOT}/lcov/filtered.info" | grep -v "/lib/pure/options.nim:382" | grep -v "/lib/pure/options.nim:383" > "${COVERAGE_ROOT}/lcov/filtered_fixed.info"
    
    # genhtml のパスを取得
    GENHTML_PATH=$(which genhtml)
    echo "Using genhtml from: ${GENHTML_PATH}"

    # HTMLレポート生成（最大限のエラー回避オプション付き）
    ${GENHTML_PATH} "${COVERAGE_ROOT}/lcov/filtered_fixed.info" \
            --output-directory "${COVERAGE_ROOT}/html" \
            --ignore-errors all \
            --rc genhtml_branch_coverage=1 \
            --rc genhtml_function_coverage=1 \
            --rc genhtml_hi_limit=90 \
            --rc genhtml_med_limit=75 \
            --rc genhtml_line_field_width=12 \
            --rc genhtml_overview_width=120 \
            --rc genhtml_no_prefix=1 \
            --rc geninfo_adjust_src_path="/home/user/_src/mcp-nim-sdk=>." \
            --synthesize-missing \
            --show-details \
            --title "MCP Nim SDK Coverage Report (Target: 100%)" \
            --legend \
            --demangle-cpp \
            --function-coverage \
            --branch-coverage \
            > "${COVERAGE_ROOT}/logs/genhtml.log" 2>&1
            
    # HTMLレポート生成に失敗した場合のフォールバック
    if [ $? -ne 0 ]; then
        echo "⚠️ genhtml failed with standard options, trying alternatives..."
        # よりシンプルな設定で再試行
        ${GENHTML_PATH} "${COVERAGE_ROOT}/lcov/filtered_fixed.info" \
                --output-directory "${COVERAGE_ROOT}/html" \
                --ignore-errors all \
                --rc lcov_excl_line=DEBUG \
                > "${COVERAGE_ROOT}/logs/genhtml_fallback.log" 2>&1 || true
    fi
            
    # カバレッジサマリーを作成
    echo "カバレッジサマリーの作成中..."
    ${LCOV_PATH} --summary "${COVERAGE_ROOT}/lcov/filtered.info" \
         --rc lcov_branch_coverage=1 \
         > "${COVERAGE_ROOT}/logs/coverage_summary.log" 2>&1 || true
         
    # カバレッジサマリーをローカルファイルに保存
    cat "${COVERAGE_ROOT}/logs/coverage_summary.log" > "${COVERAGE_ROOT}/coverage_summary.txt"
            
    # 必ず詳細なindex.htmlを作成する
    echo "詳細なindex.htmlを作成中..."
    cat > "${COVERAGE_ROOT}/html/index.html" << EOF
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
  <title>MCP Nim SDK Coverage Report</title>
  <link rel="stylesheet" type="text/css" href="gcov.css">
  <style>
    body {
      font-family: sans-serif;
      margin: 20px;
      line-height: 1.6;
    }
    h1, h2 {
      color: #333;
    }
    .container {
      max-width: 1200px;
      margin: 0 auto;
      padding: 20px;
      background-color: #f8f9fa;
      border-radius: 5px;
      box-shadow: 0 2px 5px rgba(0,0,0,0.1);
    }
    .section {
      margin-bottom: 30px;
      border-bottom: 1px solid #ddd;
      padding-bottom: 20px;
    }
    .file-list {
      margin-left: 20px;
    }
    a {
      text-decoration: none;
      color: #0366d6;
    }
    a:hover {
      text-decoration: underline;
    }
    .time {
      color: #666;
      font-style: italic;
      font-size: 0.9em;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      margin: 20px 0;
    }
    th, td {
      border: 1px solid #ddd;
      padding: 8px;
      text-align: left;
    }
    th {
      background-color: #f1f1f1;
    }
    tr:nth-child(even) {
      background-color: #f9f9f9;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="section">
      <h1>MCP Nim SDK Coverage Report (Target: 100%)</h1>
      <p class="time">Generated: $(date)</p>
    </div>
    
    <div class="section">
      <h2>Coverage Summary</h2>
      <div id="coverage-summary">
        <pre>$(cat "${COVERAGE_ROOT}/logs/coverage_summary.log" 2>/dev/null || echo "Coverage summary not available")</pre>
      </div>
    </div>

    <div class="section">
      <h2>Uncovered Lines</h2>
      <div id="uncovered-lines">
        <pre>$(grep -A 10 "lines......:" "${COVERAGE_ROOT}/logs/uncovered_lines.log" 2>/dev/null || echo "No uncovered lines information available")</pre>
      </div>
    </div>
      
    <div class="section">
      <h2>Source Files</h2>
      
      <h3>MCP Core Files</h3>
      <ul class="file-list">
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/client.nim.gcov.html">client.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/logger.nim.gcov.html">logger.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/prompts.nim.gcov.html">prompts.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/protocol.nim.gcov.html">protocol.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/resources.nim.gcov.html">resources.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/roots.nim.gcov.html">roots.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/sampling.nim.gcov.html">sampling.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/server.nim.gcov.html">server.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/tools.nim.gcov.html">tools.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/types.nim.gcov.html">types.nim</a></li>
      </ul>
      
      <h3>Transport Layer</h3>
      <ul class="file-list">
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/transport/base.nim.gcov.html">transport/base.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/transport/http.nim.gcov.html">transport/http.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/transport/inmemory.nim.gcov.html">transport/inmemory.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/transport/sse.nim.gcov.html">transport/sse.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/src/mcp/transport/stdio.nim.gcov.html">transport/stdio.nim</a></li>
      </ul>
      
      <h3>Test Files</h3>
      <ul class="file-list">
        <li><a href="home/user/_src/mcp-nim-sdk/tests/test_client.nim.gcov.html">test_client.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/tests/test_helpers.nim.gcov.html">test_helpers.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/tests/test_logger.nim.gcov.html">test_logger.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/tests/test_protocol.nim.gcov.html">test_protocol.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/tests/test_resources.nim.gcov.html">test_resources.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/tests/test_roots.nim.gcov.html">test_roots.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/tests/test_sampling.nim.gcov.html">test_sampling.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/tests/test_simple_client.nim.gcov.html">test_simple_client.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/tests/test_tools.nim.gcov.html">test_tools.nim</a></li>
        <li><a href="home/user/_src/mcp-nim-sdk/tests/test_types.nim.gcov.html">test_types.nim</a></li>
      </ul>
    </div>

    <div class="section">
      <h2>Standard Library</h2>
      <p>Explore the coverage of Standard Library modules:</p>
      <ul class="file-list">
        <li><a href="lib/core/index.html">Core Library</a></li>
        <li><a href="lib/pure/index.html">Pure Library</a></li>
        <li><a href="lib/std/index.html">Standard Library</a></li>
        <li><a href="lib/system/index.html">System Library</a></li>
      </ul>
    </div>

    <div class="section">
      <h2>Coverage Statistics</h2>
      <p>This coverage report shows the code execution paths tested during the test suite run. Files with higher coverage percentages have more of their code paths exercised by tests.</p>
      <p>The target for this report is <strong>100% coverage</strong> across all source files.</p>
      <p>Coverage is measured in three ways:</p>
      <ul>
        <li><strong>Line coverage</strong>: Percentage of executable lines that were executed</li>
        <li><strong>Function coverage</strong>: Percentage of functions that were called</li>
        <li><strong>Branch coverage</strong>: Percentage of branches that were taken (if/else, match statements, etc.)</li>
      </ul>
      <p>Files with low coverage should have more tests added to cover all code paths.</p>
    </div>
    
    <div class="section">
      <h2>Suggested Next Steps</h2>
      <p>To improve coverage:</p>
      <ol>
        <li>Review the "Uncovered Lines" section above</li>
        <li>Add tests for any uncovered functions</li>
        <li>Add tests for error conditions and edge cases</li>
        <li>Ensure all branches (if/else, pattern matches) are tested</li>
      </ol>
    </div>
  </div>
</body>
</html>
EOF
fi

# サマリーレポートを作成
cat > "${COVERAGE_ROOT}/summary.txt" << EOF
カバレッジレポートサマリー (目標: 100%)
=================================
生成日時: $(date)
ディレクトリ: ${COVERAGE_ROOT}

テスト結果:
EOF

# 各テストの結果をサマリーに追加
for LOG_FILE in ${COVERAGE_ROOT}/test_results/*.log; do
    TEST_NAME=$(basename $LOG_FILE .log)
    if grep -q "SUCCESS" "$LOG_FILE" 2>/dev/null || grep -q "\[OK\]" "$LOG_FILE" 2>/dev/null; then
        echo "  ✓ $TEST_NAME: 成功" >> "${COVERAGE_ROOT}/summary.txt"
    else
        echo "  ✗ $TEST_NAME: 失敗" >> "${COVERAGE_ROOT}/summary.txt"
    fi
done

# カバレッジ統計を追加
echo "" >> "${COVERAGE_ROOT}/summary.txt"
echo "カバレッジ統計:" >> "${COVERAGE_ROOT}/summary.txt"
echo "=============" >> "${COVERAGE_ROOT}/summary.txt"
if [ -f "${COVERAGE_ROOT}/logs/coverage_summary.log" ]; then
    cat "${COVERAGE_ROOT}/logs/coverage_summary.log" >> "${COVERAGE_ROOT}/summary.txt"
else
    echo "カバレッジ統計が利用できません" >> "${COVERAGE_ROOT}/summary.txt"
fi

# カバレッジしていないファイルの情報
echo "" >> "${COVERAGE_ROOT}/summary.txt"
echo "カバレッジが不十分な行:" >> "${COVERAGE_ROOT}/summary.txt"
echo "====================" >> "${COVERAGE_ROOT}/summary.txt"
if [ -f "${COVERAGE_ROOT}/logs/uncovered_lines.log" ]; then
    grep -A 10 "lines......:" "${COVERAGE_ROOT}/logs/uncovered_lines.log" >> "${COVERAGE_ROOT}/summary.txt" 2>/dev/null || echo "未カバーの行がありません" >> "${COVERAGE_ROOT}/summary.txt"
else
    echo "未カバーの行の情報が利用できません" >> "${COVERAGE_ROOT}/summary.txt"
fi

# 最新のレポートへのシンボリックリンクを作成
mkdir -p "${PROJECT_ROOT}/build/coverage_reports"
ln -sfn "$TIMESTAMP" "${PROJECT_ROOT}/build/coverage_reports/latest"

echo ""
echo "カバレッジレポートが生成されました:"
echo "  場所: ${COVERAGE_ROOT}"
echo "  HTMLレポート: ${COVERAGE_ROOT}/html/index.html"
echo "  サマリー: ${COVERAGE_ROOT}/summary.txt"
echo ""
echo "最新のレポートは以下でも参照できます:"
echo "  build/coverage_reports/latest/html/index.html"

# fallbackインデックスを作成（エラーがあった場合の保険）
if [ ! -f "${COVERAGE_ROOT}/html/index.html" ]; then
    echo "⚠️ Warning: index.html not found, creating fallback..."
    mkdir -p "${COVERAGE_ROOT}/html"
    cat > "${COVERAGE_ROOT}/html/index.html" << FALLBACK_HTML
<!DOCTYPE HTML>
<html>
<head>
  <title>MCP Coverage Report</title>
  <style>
    body { font-family: sans-serif; margin: 20px; }
    h1 { color: #333; }
    pre { background: #f5f5f5; padding: 10px; border-radius: 5px; }
  </style>
</head>
<body>
  <h1>MCP Nim SDK Coverage Report</h1>
  <p>Generated: $(date)</p>
  
  <h2>Raw Coverage Data</h2>
  <p>See raw coverage data in: ${COVERAGE_ROOT}/lcov/</p>
  
  <h2>Summary</h2>
  <pre>$(cat "${COVERAGE_ROOT}/logs/coverage_summary.log" 2>/dev/null || echo "Coverage summary not available")</pre>
</body>
</html>
FALLBACK_HTML
fi