@echo off
REM Test coverage script for power_assert_nim
REM Note: Windows coverage would typically use OpenCppCoverage, but
REM this script is a placeholder for compatibility

REM Get the project root directory
SET "PROJECT_ROOT=%~dp0..\..\"
SET "TESTS_DIR=%PROJECT_ROOT%tests"
SET "BUILD_DIR=%PROJECT_ROOT%build\tests"
SET "COVERAGE_DIR=%PROJECT_ROOT%coverage"

REM Create directories if they don't exist
if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
if not exist "%COVERAGE_DIR%" mkdir "%COVERAGE_DIR%"

echo Running tests, but coverage generation on Windows requires OpenCppCoverage...
echo This script is provided for compatibility with the standardized project structure.

REM Run the tests normally since coverage generation is OS-specific
call "%PROJECT_ROOT%scripts\tests\test.bat"

echo For actual coverage on Windows, please install and configure OpenCppCoverage.