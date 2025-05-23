#\!/bin/bash
# ===========================================================================
# 環境変数設定ファイル for power_assert_nim
# 
# このファイルはスクリプト間で共有される設定値を定義します。
# すべてのスクリプトはこのファイルを読み込んで環境設定を行います。
# ===========================================================================

# 基本パス設定
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SRC_DIR="${PROJECT_ROOT}/src"
export TESTS_DIR="${PROJECT_ROOT}/tests"
export DOCS_DIR="${PROJECT_ROOT}/docs"

# ビルド関連ディレクトリ
export BUILD_DIR="${PROJECT_ROOT}/build"
export BUILD_BIN="${BUILD_DIR}/bin"
export BUILD_LIB="${BUILD_DIR}/lib"
export BUILD_TESTS="${BUILD_DIR}/tests"
export BUILD_DOCS="${BUILD_DIR}/doc"
export BUILD_BENCHMARKS="${BUILD_DIR}/benchmarks"
export BUILD_COVERAGE="${BUILD_DIR}/coverage"
export BUILD_NIMCACHE="${BUILD_DIR}/nimcache"

# ビルド設定
export NIM_COMPILER="nim"
export NIMBLE="nimble"
export NIMBLE_FLAGS=""
export NIM_RELEASE_FLAGS="-d:release"
export NIM_DEBUG_FLAGS="-d:debug"
export NIM_LIB_FLAGS="--app:lib"
export NIMBLE_DIR="${PROJECT_ROOT}/.nimble"

# ファイル名パターン
export MAIN_MODULE="power_assert"
export TEST_FILES="test_power_assert.nim test_operators.nim test_custom_types.nim test_basic.nim"
export BENCHMARK_FILES="bench_power_assert.nim"

# ツール設定
export COVERAGE_ENABLED=${COVERAGE_ENABLED:-false}
export GENERATE_DOCS=${GENERATE_DOCS:-false}
export VERBOSE=${VERBOSE:-false}
export COLOR_OUTPUT=${COLOR_OUTPUT:-true}

# プラットフォーム検出
export IS_WINDOWS=false
export IS_MACOS=false
export IS_LINUX=false

case "$(uname -s)" in
  Darwin*)  
    export IS_MACOS=true
    export OS_NAME="macOS"
    ;;
  Linux*)   
    export IS_LINUX=true 
    export OS_NAME="Linux"
    ;;
  CYGWIN*|MINGW*|MSYS*) 
    export IS_WINDOWS=true
    export OS_NAME="Windows" 
    ;;
  *)
    export OS_NAME="Unknown"
    ;;
esac

# カラー設定 (非Windows環境のみ)
if [[ "${COLOR_OUTPUT}" == "true" && "${IS_WINDOWS}" == "false" ]]; then
  export COLOR_RESET="\033[0m"
  export COLOR_RED="\033[0;31m"
  export COLOR_GREEN="\033[0;32m"
  export COLOR_YELLOW="\033[0;33m"
  export COLOR_BLUE="\033[0;34m"
  export COLOR_PURPLE="\033[0;35m"
  export COLOR_CYAN="\033[0;36m"
  export COLOR_WHITE="\033[0;37m"
  export COLOR_BOLD="\033[1m"
  export COLOR_DIM="\033[2m"
  export COLOR_UNDERLINE="\033[4m"
else
  export COLOR_RESET=""
  export COLOR_RED=""
  export COLOR_GREEN=""
  export COLOR_YELLOW=""
  export COLOR_BLUE=""
  export COLOR_PURPLE=""
  export COLOR_CYAN=""
  export COLOR_WHITE=""
  export COLOR_BOLD=""
  export COLOR_DIM=""
  export COLOR_UNDERLINE=""
fi

# ユーザー定義の環境設定をロード (存在する場合)
if [[ -f "${PROJECT_ROOT}/.env.local" ]]; then
  source "${PROJECT_ROOT}/.env.local"
fi

# 設定内容の表示（VERBOSEが有効な場合）
if [[ "${VERBOSE}" == "true" ]]; then
  echo "Project configuration:"
  echo "  PROJECT_ROOT: ${PROJECT_ROOT}"
  echo "  BUILD_DIR: ${BUILD_DIR}"
  echo "  OS: ${OS_NAME}"
  echo "  Nim compiler: ${NIM_COMPILER}"
  echo "  Main module: ${MAIN_MODULE}"
fi
