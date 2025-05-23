@echo off
REM Unified cleanup script for power_assert_nim project
REM This script provides a thorough cleanup of all build artifacts

REM Load environment settings
CALL "%~dp0..\..\scripts\env\env.bat"

echo === Power Assert Nim Cleanup ===

REM クリーンアップをスキップする特別なディレクトリ
SET "SKIP_DIRS=doc"
IF DEFINED SKIP_CLEAN_DIRS SET "SKIP_DIRS=%SKIP_CLEAN_DIRS%"

REM ビルドディレクトリのクリーンアップ
if exist "%BUILD_DIR%" (
  echo Cleaning build directory contents...
  
  REM サブディレクトリのクリーンアップ（スキップディレクトリを除く）
  
  REM bin ディレクトリ
  CALL :CLEAN_DIR "bin"
  
  REM tests ディレクトリ
  CALL :CLEAN_DIR "tests"
  
  REM lib ディレクトリ
  CALL :CLEAN_DIR "lib"
  
  REM coverage ディレクトリ
  CALL :CLEAN_DIR "coverage"
  
  REM benchmarks ディレクトリ
  CALL :CLEAN_DIR "benchmarks"
  
  REM nimcache ディレクトリ
  CALL :CLEAN_DIR "nimcache"
  
  echo Build directory cleaned
) else (
  mkdir "%BUILD_DIR%"
  echo Build directory created
)

REM 標準ビルドディレクトリ構造を作成
if not exist "%BUILD_BIN%" mkdir "%BUILD_BIN%"
if not exist "%BUILD_TESTS%" mkdir "%BUILD_TESTS%"
if not exist "%BUILD_LIB%" mkdir "%BUILD_LIB%"
if not exist "%BUILD_DOCS%" mkdir "%BUILD_DOCS%"
if not exist "%BUILD_COVERAGE%" mkdir "%BUILD_COVERAGE%"
if not exist "%BUILD_BENCHMARKS%" mkdir "%BUILD_BENCHMARKS%"
if not exist "%BUILD_NIMCACHE%" mkdir "%BUILD_NIMCACHE%"

REM テストディレクトリからバイナリを削除
echo Removing binary files from tests directory...
SET "TEST_BINS=test_power_assert test_operators test_custom_types test_basic test_ast"
FOR %%F IN (%TEST_BINS%) DO (
  if exist "%TESTS_DIR%\%%F.exe" del "%TESTS_DIR%\%%F.exe" >nul 2>&1
  if exist "%TESTS_DIR%\%%F" del "%TESTS_DIR%\%%F" >nul 2>&1
)
echo Test binaries removed

REM ソースディレクトリからバイナリを削除
echo Removing binary from src directory...
if exist "%SRC_DIR%\%MAIN_MODULE%.exe" del "%SRC_DIR%\%MAIN_MODULE%.exe" >nul 2>&1
if exist "%SRC_DIR%\%MAIN_MODULE%" del "%SRC_DIR%\%MAIN_MODULE%" >nul 2>&1
echo Source binaries removed

REM オブジェクトファイルと一時ファイルを削除
echo Cleaning object files and temporary artifacts...
for /r "%PROJECT_ROOT%" %%G in (*.o *.obj *.tmp *.pdb *.ilk) do del "%%G" >nul 2>&1

REM nimcacheディレクトリ（プロジェクトルート）をクリーンアップ
if exist "%PROJECT_ROOT%\nimcache" rmdir /s /q "%PROJECT_ROOT%\nimcache" >nul 2>&1

echo All artifacts cleaned
echo === Cleanup complete! ===
exit /b 0

REM ディレクトリクリーンアップ用のサブルーチン
:CLEAN_DIR
SET "DIR_TO_CLEAN=%~1"
SET "SKIP=false"

REM スキップリストとチェック
FOR %%D IN (%SKIP_DIRS%) DO (
  IF "%DIR_TO_CLEAN%"=="%%D" SET "SKIP=true"
)

IF "%SKIP%"=="true" (
  echo Skipping %DIR_TO_CLEAN% directory ^(preserved^)
  exit /b 0
)

REM ディレクトリを空にする
SET "FULL_DIR_PATH=%BUILD_DIR%\%DIR_TO_CLEAN%"
IF EXIST "%FULL_DIR_PATH%" (
  del /s /q "%FULL_DIR_PATH%\*.*" >nul 2>&1
)
exit /b 0