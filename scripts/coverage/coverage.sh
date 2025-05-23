#!/bin/bash
# カバレッジレポート生成のメインスクリプト

set -e

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS_DIR="${PROJECT_ROOT}/scripts/coverage"

# ヘルプメッセージを表示
function show_help() {
  echo "MCP Nim SDK Coverage Tool"
  echo "========================="
  echo ""
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -s, --simple       Run simple coverage (fast)"
  echo "  -f, --full         Run full structured coverage (comprehensive)"
  echo "  -t, --test FILE    Run coverage for a specific test file"
  echo "  -o, --open         Open the report in browser after generation"
  echo "  -h, --help         Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --simple                  # Run simple coverage"
  echo "  $0 --full                    # Run full structured coverage"
  echo "  $0 --test test_client.nim    # Test specific file"
  echo "  $0 --simple --open           # Run simple coverage and open in browser"
}

# 引数を解析
SIMPLE_MODE=false
FULL_MODE=false
OPEN_REPORT=false
TEST_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--simple)
      SIMPLE_MODE=true
      shift
      ;;
    -f|--full)
      FULL_MODE=true
      shift
      ;;
    -t|--test)
      TEST_FILE="$2"
      shift 2
      ;;
    -o|--open)
      OPEN_REPORT=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Error: Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# デフォルトはシンプルモード
if [ "$SIMPLE_MODE" = "false" ] && [ "$FULL_MODE" = "false" ] && [ -z "$TEST_FILE" ]; then
  SIMPLE_MODE=true
fi

# 特定のテストファイルが指定された場合
if [ -n "$TEST_FILE" ]; then
  echo "Running coverage for specific test: $TEST_FILE"
  export TEST_FILE="$TEST_FILE"
  "$SCRIPTS_DIR/coverage_simple.sh"
  
# シンプルモード
elif [ "$SIMPLE_MODE" = "true" ]; then
  echo "Running simple coverage report..."
  "$SCRIPTS_DIR/coverage_simple.sh"
  
# 完全な構造化カバレッジ
elif [ "$FULL_MODE" = "true" ]; then
  echo "Running full structured coverage report..."
  "$SCRIPTS_DIR/coverage_structured.sh"
fi

# ブラウザでレポートを開く
if [ "$OPEN_REPORT" = "true" ]; then
  echo "Opening coverage report in browser..."
  
  # レポートのパスを決定
  if [ "$FULL_MODE" = "true" ]; then
    REPORT_PATH="${PROJECT_ROOT}/build/coverage_reports/latest/html/index.html"
  else
    REPORT_PATH="${PROJECT_ROOT}/build/coverage/html/index.html"
  fi
  
  # OSに応じてブラウザで開く
  if [ "$(uname)" = "Darwin" ]; then
    # macOS
    open "$REPORT_PATH"
  elif [ "$(uname)" = "Linux" ]; then
    # Linux
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$REPORT_PATH"
    else
      echo "Warning: xdg-open not found. Please open report manually at: $REPORT_PATH"
    fi
  else
    # Windows or other OS
    echo "Please open the coverage report manually at: $REPORT_PATH"
  fi
fi

echo "Coverage reporting completed successfully."