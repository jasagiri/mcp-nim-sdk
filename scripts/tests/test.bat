@echo off
REM Test script for power_assert_nim

REM Get the project root directory
SET "PROJECT_ROOT=%~dp0..\..\"
SET "TESTS_DIR=%PROJECT_ROOT%tests"
SET "BUILD_DIR=%PROJECT_ROOT%build\tests"

REM Create build directory if it doesn't exist
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

REM Check if a specific test file is specified
if defined TEST_FILE (
  REM Run a specific test
  SET "TEST_PATH=%TESTS_DIR%\%TEST_FILE%"
  
  if not exist "%TEST_PATH%" (
    echo Error: Test file %TEST_PATH% not found.
    exit /b 1
  )
  
  echo Running test: %TEST_FILE%
  nim c -r -o:"%BUILD_DIR%\%TEST_FILE:.nim=%" "%TEST_PATH%"
) else (
  REM Run all tests
  echo Running all tests...
  
  nim c -r -o:"%BUILD_DIR%\test_power_assert" "%TESTS_DIR%\test_power_assert.nim"
  nim c -r -o:"%BUILD_DIR%\test_operators" "%TESTS_DIR%\test_operators.nim"
  nim c -r -o:"%BUILD_DIR%\test_custom_types" "%TESTS_DIR%\test_custom_types.nim"
  
  echo All tests completed.
)