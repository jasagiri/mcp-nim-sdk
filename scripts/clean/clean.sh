#!/bin/bash
# Unified cleanup script for power_assert_nim project
# This script provides a thorough cleanup of all build artifacts

# 共通環境設定と関数をロード
SCRIPT_DIR="$(dirname "$0")"
source "${SCRIPT_DIR}/../../scripts/env/env.sh"
source "${SCRIPT_DIR}/../../scripts/common/common.sh"

log_info "Power Assert Nim Cleanup"

# クリーンアップをスキップする特別なディレクトリ
SKIP_DIRS="${SKIP_CLEAN_DIRS:-doc}"

# ビルドディレクトリのクリーンアップ
if [ -d "${BUILD_DIR}" ]; then
  log_info "Cleaning build directory contents..."
  
  # ビルドサブディレクトリをクリーンアップ
  for dir in bin tests lib coverage benchmarks nimcache; do
    # スキップするディレクトリをチェック
    skip=false
    for skip_dir in ${SKIP_DIRS}; do
      if [ "$dir" = "$skip_dir" ]; then
        skip=true
        break
      fi
    done
    
    if [ "${skip}" = "true" ]; then
      log_warning "Skipping $dir directory (preserved)"
      continue
    fi
    
    # ディレクトリをクリーンアップ
    if [ -d "${BUILD_DIR}/${dir}" ]; then
      rm -rf "${BUILD_DIR}/${dir}"/* 2>/dev/null || true
    fi
  done
  
  # nimcacheディレクトリの詳細クリーンアップ
  if [ -d "${BUILD_NIMCACHE}" ]; then
    find "${BUILD_NIMCACHE}" -type f -name "*.o" -delete 2>/dev/null || true
    find "${BUILD_NIMCACHE}" -type f -name "*.c" -delete 2>/dev/null || true
    find "${BUILD_NIMCACHE}" -type f -name "*.json" -delete 2>/dev/null || true
  fi
  
  # ビルドディレクトリ直下の一時ファイルを削除
  find "${BUILD_DIR}" -maxdepth 1 -type f -delete 2>/dev/null || true
  
  log_success "Build directory cleaned"
else
  mkdir -p "${BUILD_DIR}"
  log_success "Build directory created"
fi

# 標準ビルドディレクトリ構造を作成
for dir in bin tests lib doc coverage benchmarks nimcache; do
  mkdir -p "${BUILD_DIR}/${dir}"
done

# テストディレクトリからバイナリを削除
log_info "Removing binary files from tests directory..."
for test_bin in test_power_assert test_operators test_custom_types test_basic test_ast; do
  rm -f "${TESTS_DIR}/${test_bin}" 2>/dev/null || true
done
log_success "Test binaries removed"

# ソースディレクトリからバイナリを削除
log_info "Removing binary from src directory..."
rm -f "${SRC_DIR}/${MAIN_MODULE}" 2>/dev/null || true
log_success "Source binaries removed"

# オブジェクトファイル、一時ファイルを削除
log_info "Cleaning object files and temporary artifacts..."
find "${PROJECT_ROOT}" -type f -name "*.o" -delete 2>/dev/null || true
find "${PROJECT_ROOT}" -type f -name "*.tmp" -delete 2>/dev/null || true
find "${PROJECT_ROOT}" -type f -name "*.pdb" -delete 2>/dev/null || true
find "${PROJECT_ROOT}" -type f -name "*.ilk" -delete 2>/dev/null || true

# macOS固有のファイルを削除
if [ "${IS_MACOS}" = "true" ]; then
  find "${PROJECT_ROOT}" -name ".DS_Store" -type f -delete 2>/dev/null || true
fi

# nimcacheディレクトリをクリーンアップ
rm -rf "${PROJECT_ROOT}/nimcache" 2>/dev/null || true

log_success "All artifacts cleaned"
log_info "Cleanup complete!"