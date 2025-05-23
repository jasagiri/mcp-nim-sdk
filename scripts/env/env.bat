@echo off
REM ===========================================================================
REM 環境変数設定ファイル for power_assert_nim (Windows版)
REM 
REM このファイルはスクリプト間で共有される設定値を定義します。
REM すべてのスクリプトはこのファイルを読み込んで環境設定を行います。
REM ===========================================================================

REM 基本パス設定
SET "PROJECT_ROOT=%~dp0..\..\"
SET "SRC_DIR=%PROJECT_ROOT%src"
SET "TESTS_DIR=%PROJECT_ROOT%tests"
SET "DOCS_DIR=%PROJECT_ROOT%docs"

REM ビルド関連ディレクトリ
SET "BUILD_DIR=%PROJECT_ROOT%build"
SET "BUILD_BIN=%BUILD_DIR%\bin"
SET "BUILD_LIB=%BUILD_DIR%\lib"
SET "BUILD_TESTS=%BUILD_DIR%\tests"
SET "BUILD_DOCS=%BUILD_DIR%\doc"
SET "BUILD_BENCHMARKS=%BUILD_DIR%\benchmarks"
SET "BUILD_COVERAGE=%BUILD_DIR%\coverage"
SET "BUILD_NIMCACHE=%BUILD_DIR%\nimcache"

REM ビルド設定
SET "NIM_COMPILER=nim"
SET "NIMBLE=nimble"
SET "NIMBLE_FLAGS="
SET "NIM_RELEASE_FLAGS=-d:release"
SET "NIM_DEBUG_FLAGS=-d:debug"
SET "NIM_LIB_FLAGS=--app:lib"
SET "NIMBLE_DIR=%PROJECT_ROOT%.nimble"

REM ファイル名パターン
SET "MAIN_MODULE=power_assert"
SET "TEST_FILES=test_power_assert.nim test_operators.nim test_custom_types.nim test_basic.nim"
SET "BENCHMARK_FILES=bench_power_assert.nim"

REM ツール設定
IF NOT DEFINED COVERAGE_ENABLED SET "COVERAGE_ENABLED=false"
IF NOT DEFINED GENERATE_DOCS SET "GENERATE_DOCS=false"
IF NOT DEFINED VERBOSE SET "VERBOSE=false"
IF NOT DEFINED COLOR_OUTPUT SET "COLOR_OUTPUT=false"

REM プラットフォーム検出 (Windows固定)
SET "IS_WINDOWS=true"
SET "IS_MACOS=false"
SET "IS_LINUX=false"
SET "OS_NAME=Windows"

REM ユーザー定義の環境設定をロード (存在する場合)
IF EXIST "%PROJECT_ROOT%.env.local.bat" (
  CALL "%PROJECT_ROOT%.env.local.bat"
)

REM 設定内容の表示（VERBOSEが有効な場合）
IF "%VERBOSE%"=="true" (
  echo Project configuration:
  echo   PROJECT_ROOT: %PROJECT_ROOT%
  echo   BUILD_DIR: %BUILD_DIR%
  echo   OS: %OS_NAME%
  echo   Nim compiler: %NIM_COMPILER%
  echo   Main module: %MAIN_MODULE%
)