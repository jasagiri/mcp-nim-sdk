@echo off
REM Build script for power_assert_nim

REM Load common environment settings and functions
SETLOCAL EnableDelayedExpansion
SET "SCRIPT_DIR=%~dp0"
CALL "%SCRIPT_DIR%..\..\scripts\env\env.bat"
CALL "%SCRIPT_DIR%..\..\scripts\common\common.bat"

CALL :log_info "Building power_assert_nim"

REM Create build directory if it doesn't exist
CALL :ensure_dir "%BUILD_BIN%"

REM Set build mode based on environment variable or default to release
IF NOT DEFINED BUILD_MODE SET "BUILD_MODE=release"

IF /I "%BUILD_MODE%"=="release" (
  SET "BUILD_FLAGS=%NIM_RELEASE_FLAGS%"
  CALL :log_info "Building in RELEASE mode"
) ELSE IF /I "%BUILD_MODE%"=="debug" (
  SET "BUILD_FLAGS=%NIM_DEBUG_FLAGS%"
  CALL :log_info "Building in DEBUG mode"
) ELSE (
  CALL :log_warning "Unknown build mode: %BUILD_MODE%. Using release mode."
  SET "BUILD_FLAGS=%NIM_RELEASE_FLAGS%"
)

REM Add any custom defines from environment variable
IF DEFINED DEFINES (
  FOR %%d IN (%DEFINES%) DO (
    SET "BUILD_FLAGS=!BUILD_FLAGS! -d:%%d"
    CALL :log_info "Adding define: %%d"
  )
)

CALL :log_info "Building main module: %MAIN_MODULE%"

REM Execute the build
%NIM_COMPILER% c %BUILD_FLAGS% -o:"%BUILD_BIN%\%MAIN_MODULE%.exe" "%SRC_DIR%\%MAIN_MODULE%.nim"
IF %ERRORLEVEL% NEQ 0 (
  CALL :log_error "Build failed with error code %ERRORLEVEL%"
  EXIT /B %ERRORLEVEL%
)

CALL :log_success "Build completed successfully!"

REM Notify about the output location
CALL :log_info "Binary created at: %BUILD_BIN%\%MAIN_MODULE%.exe"

REM Show file info if verbose mode
IF /I "%VERBOSE%"=="true" (
  IF EXIST "%BUILD_BIN%\%MAIN_MODULE%.exe" (
    DIR "%BUILD_BIN%\%MAIN_MODULE%.exe"
  )
)

EXIT /B 0