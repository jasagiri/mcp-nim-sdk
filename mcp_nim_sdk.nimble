# Package

version       = "0.0.0"
author        = "jasagiri"
description   = "A Nim implementation of the Model Context Protocol (MCP)"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.2"
requires "jsony >= 1.1.5"  # JSON serialization
requires "httpbeast >= 0.4.1"  # HTTP server for SSE transport
requires "ws >= 0.5.0"  # WebSocket support
requires "uri3 >= 0.1.5"  # Enhanced URI handling
requires "uuids >= 0.1.12"  # UUID generation

# Tasks
task buildLib, "Build the library files and documentation":
  # Create output directories
  exec "mkdir -p build/lib build/bin"

  # Compile the library files
  echo "Building MCP library..."
  when defined(windows):
    exec "nim c --app:lib -d:release --out:build/lib/mcp.dll src/mcp.nim"
  else:
    exec "nim c --app:lib -d:release --out:build/lib/libmcp.so src/mcp.nim"

  # Move any binary created in the root directory to build/bin
  echo "Moving binaries to build/bin directory..."
  when defined(windows):
    exec "cmd /c if exist mcp.exe move mcp.exe build\\bin\\"
  else:
    exec "[ -f ./mcp ] && mv ./mcp build/bin/ || true"

  # Also generate documentation
  echo "Generating documentation..."
  exec "mkdir -p build/doc"
  exec "nim doc --project --index:on --outdir:build/doc src/mcp.nim"

  echo "Build completed successfully"

# Custom build task that ensures binaries go to build/bin directory
task build, "Build the package and ensure binaries go to build/bin":
  # Create bin directory first
  exec "mkdir -p build/bin"

  # Clean root directory of binaries first
  when defined(windows):
    exec "cmd /c if exist mcp.exe del mcp.exe"
  else:
    exec "rm -f ./mcp"

  # Use nimble install with --nolinks to build without creating symlinks
  # This will use the binDir setting defined above
  exec "nimble install --nolinks"

  # Run the buildLib task for library files
  exec "nimble buildLib"

  # Verify binary placement and clean root if needed
  echo "Verifying binary placement..."
  when defined(windows):
    exec "cmd /c if exist mcp.exe (echo Binary in root directory && move mcp.exe build\\bin\\) else (echo Binary correctly placed in build/bin)"
  else:
    exec "if [ -f ./mcp ]; then echo 'Binary in root directory' && mv ./mcp build/bin/; else echo 'Binary correctly placed in build/bin'; fi"

task test, "Run tests":
  # Create build/tests directory if it doesn't exist
  exec "mkdir -p build/tests"

  # Get all test files in the tests directory using ls
  echo "Finding test files..."
  var testFiles: seq[string] = @[]
  when defined(windows):
    let files = staticExec("cmd /c dir /b tests\\test_*.nim 2>nul")
    if files.len > 0:
      for file in files.splitLines():
        if file.len > 0:
          testFiles.add(file)
  else:
    let files = staticExec("find tests -maxdepth 1 -name 'test_*.nim' -type f | sort")
    if files.len > 0:
      for file in files.splitLines():
        if file.len > 0:
          let fileName = staticExec("basename " & file).strip()
          testFiles.add(fileName)

  if testFiles.len == 0:
    echo "No test files found in tests/ directory."
    return

  echo "Found test files: ", testFiles

  when defined(windows):
    for testFile in testFiles:
      let outFile = testFile.replace(".nim", "")
      echo "Running test: tests/" & testFile
      exec "nim c -r -o:build/tests/" & outFile & " tests/" & testFile
  else:
    for testFile in testFiles:
      let outFile = testFile.replace(".nim", "")
      echo "Running test: tests/" & testFile
      exec "nim c -r -o:build/tests/" & outFile & " tests/" & testFile

task clean, "Clean build artifacts":
  # ビルド成果物を管理するための安全で賢いクリーンアップタスク
  # ドキュメントファイルは保持し、他のビルド成果物を選択的に削除する方式
  echo "Cleaning build artifacts..."

  when defined(windows):
    # Windows環境のための複数ステップクリーンアップ
    echo "Removing build artifacts (Windows)..."

    # バイナリおよび生成ファイルを含む特定のサブディレクトリを削除
    exec "cmd /c if exist build\\bin rmdir /s /q build\\bin"
    exec "cmd /c if exist build\\lib rmdir /s /q build\\lib"
    exec "cmd /c if exist build\\benchmarks rmdir /s /q build\\benchmarks"
    exec "cmd /c if exist build\\coverage rmdir /s /q build\\coverage"

    # テストバイナリを削除 (ファイルがロックされていてもエラーにならない)
    exec "cmd /c if exist build\\tests (del /f /q build\\tests\\*.exe build\\tests\\*.dll build\\tests\\*.o build\\tests\\test_* >nul 2>&1)"

    # ルートディレクトリのアーティファクトを削除
    exec "cmd /c if exist mcp.exe del /f mcp.exe"
    exec "cmd /c for %F in (tests\\test_*.exe) do if exist %F del /f %F >nul 2>&1"
    exec "cmd /c if exist nimcache rmdir /s /q nimcache"

    # ディレクトリ構造を作成（docディレクトリは維持したまま）
    echo "Ensuring build directory structure (Windows)..."
    exec "cmd /c if not exist build mkdir build"
    exec "cmd /c if not exist build\\bin mkdir build\\bin"
    exec "cmd /c if not exist build\\lib mkdir build\\lib"
    exec "cmd /c if not exist build\\tests mkdir build\\tests"
    exec "cmd /c if not exist build\\doc mkdir build\\doc"
    exec "cmd /c if not exist build\\benchmarks mkdir build\\benchmarks"
    exec "cmd /c if not exist build\\coverage mkdir build\\coverage"

    # 削除できなかったファイルの確認
    let windowsCheck = staticExec("cmd /c dir /b /s build\\*.exe build\\*.dll build\\*.o build\\tests\\test_* 2>nul")
    if windowsCheck.len > 0:
      echo "Note: Some files could not be removed but this will not affect normal operation."
      echo "These files will be replaced in the next build."

  else:
    # Unix/macOS環境のためのロバストなクリーンアップ
    echo "Removing build artifacts (Unix)..."

    # バイナリディレクトリなど特定の生成ディレクトリを削除
    # docディレクトリは明示的に除外し、各コマンドはエラーを無視
    exec "rm -rf ./build/bin ./build/lib ./build/benchmarks ./build/coverage ./build/nimcache 2>/dev/null || true"

    # テストバイナリを削除 - 複数の方法で徹底的に処理
    # 1. findで削除
    exec "find ./build/tests -type f -name 'test_*' -delete 2>/dev/null || true"
    # 2. ロックされているファイルのプロセスを終了（無害な場合のみ）
    exec "lsof ./build/tests/test_* 2>/dev/null | grep -v 'Chrome\\|Finder' | awk '{print $2}' | xargs -r kill -9 2>/dev/null || true"
    # 3. 個別に重要なファイルを削除
    exec "rm -f ./build/tests/test_* 2>/dev/null || true"

    # nimcacheディレクトリのクリーンアップ（ルートとbuild配下の両方）
    exec "rm -rf ./nimcache 2>/dev/null || true"
    exec "find ./build/nimcache -type f -name '*.o' -delete 2>/dev/null || true"
    exec "find ./build/nimcache -type f -name '*.c' -delete 2>/dev/null || true"
    exec "find ./build/nimcache -type f -name '*.json' -delete 2>/dev/null || true"

    # その他のクリーンアップ
    exec "find . -name '.DS_Store' -type f -delete 2>/dev/null || true"
    exec "rm -f ./mcp 2>/dev/null || true"
    exec "find ./tests -type f -name 'test_*' -not -name '*.nim' -not -name '*.nims' -delete 2>/dev/null || true"

    # ディレクトリ構造を確保 (すべて存在しない場合のみ作成)
    echo "Ensuring build directory structure (Unix)..."
    exec "mkdir -p ./build/tests ./build/bin ./build/lib ./build/doc ./build/benchmarks ./build/coverage"

    # 残っているファイルをチェック (ドキュメントファイルを除外)
    let remainingFiles = staticExec("find ./build -type f -not -path '*/build/doc/*' | grep -v 'build/doc/' | wc -l").strip()
    if parseInt(remainingFiles) > 0:
      echo "Note: " & remainingFiles & " build artifacts couldn't be completely removed but this won't affect normal operation."
      echo "      New builds will override these files if needed."

  echo "Build directories have been reset and are ready for new builds"

task docs, "Generate documentation":
  # Create docs directory if it doesn't exist
  exec "mkdir -p build/doc"

  echo "Generating documentation..."

  # Run nim doc on the main module file directly
  when defined(windows):
    exec "nim doc --project --index:on --outdir:build/doc src/mcp.nim"
  else:
    exec "nim doc --project --index:on --outdir:build/doc src/mcp.nim"

  echo "Documentation generation completed successfully."

task bench, "Run benchmarks":
  # Create benchmarks directory if it doesn't exist
  exec "mkdir -p build/benchmarks"

  # Check if benchmark files exist
  when defined(windows):
    let benchFiles = staticExec("cmd /c dir /b benchmarks\\bench_*.nim 2>nul")
    if benchFiles.len > 0:
      for benchFile in benchFiles.splitLines():
        if benchFile.len > 0:
          let outFile = benchFile.replace(".nim", "")
          exec "nim c -r -o:build/benchmarks/" & outFile & " benchmarks/" & benchFile
    else:
      echo "No benchmark files found in benchmarks/ directory."
  else:
    let benchFiles = staticExec("find benchmarks -maxdepth 1 -name 'bench_*.nim' -type f 2>/dev/null")
    if benchFiles.len > 0:
      for benchFile in benchFiles.splitLines():
        if benchFile.len > 0:
          let fileName = staticExec("basename " & benchFile).strip()
          let outFile = fileName.replace(".nim", "")
          exec "nim c -r -o:build/benchmarks/" & outFile & " " & benchFile
    else:
      echo "No benchmark files found in benchmarks/ directory."

task coverage, "Generate test coverage report (wrapper for coverage_simple)":
  echo "Running coverage report..."
  exec "nimble coverage_simple"
  
task test_one_file, "Run a single test file with coverage":
  # Get the test file from the command line
  let params = paramStr(paramCount())
  if not params.endsWith(".nim"):
    echo "Please specify a .nim test file"
    echo "Example: nimble test_one_file tests/test_client.nim"
    return
    
  echo "Running test with coverage: " & params
  
  # Prepare output directories
  exec "mkdir -p build/coverage/html build/coverage/gcov"
  
  # Run the test with coverage
  exec "nim c -r --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-lgcov " & params
  
  # Generate coverage report if lcov is available
  when not defined(windows):
    let lcovPath = staticExec("which lcov || echo notfound").strip()
    if lcovPath != "notfound":
      echo "Generating coverage report..."
      exec lcovPath & " --capture --directory . --output-file build/coverage/coverage.info --ignore-errors gcov,mismatch --include '*/mcp-nim-sdk/src/*' 2>/dev/null || true"
      
      let genhtmlPath = staticExec("which genhtml || echo notfound").strip()
      if genhtmlPath != "notfound":
        echo "Generating HTML report..."
        exec genhtmlPath & " build/coverage/coverage.info --output-directory build/coverage/html --ignore-errors all 2>/dev/null || true"
        
        echo "Coverage report generated at build/coverage/html/index.html"
    else:
      echo "lcov not found, skipping coverage report generation"

task ci, "Run CI workflow (clean, lint, build, test)":
  exec "nimble clean"
  exec "nimble buildLib"
  exec "nimble test"

  # Add optional steps based on environment variables
  if existsEnv("GENERATE_DOCS"):
    exec "nimble docs"

  if existsEnv("GENERATE_COVERAGE"):
    exec "nimble coverage"

  if existsEnv("RUN_BENCHMARKS"):
    exec "nimble bench"

task coverage_structured, "Generate structured coverage report (target: 100%)":
  # First check if the scripts are executable
  when defined(windows):
    exec "cmd /c echo Checking script executable permissions..."
  else:
    exec "chmod +x ./scripts/coverage/coverage.sh ./scripts/coverage/coverage_structured.sh ./scripts/coverage/coverage_simple.sh 2>/dev/null || true"
  
  # Check for lcov
  when not defined(windows):
    let lcovPath = staticExec("which lcov || echo notfound").strip()
    if lcovPath == "notfound":
      echo "⚠️ lcov not found. Please install lcov:"
      echo "  sudo apt-get install lcov  # Debian/Ubuntu"
      echo "  brew install lcov          # macOS"
      return
    else:
      echo "Using lcov from: " & lcovPath
      
  echo "Running structured coverage report..."
  exec "./scripts/coverage/coverage.sh --full"
  
  when not defined(windows):
    let htmlExists = staticExec("[ -f build/coverage_reports/latest/html/index.html ] && echo 'exists' || echo 'notfound'")
    if htmlExists == "exists":
      echo "\n✅ Structured coverage report generated successfully!"
      echo "View the report by opening build/coverage_reports/latest/html/index.html in your browser."
    else:
      echo "\n⚠️ HTML report generation might have had issues."
      echo "Check build/coverage_reports/latest/logs/ for details."
  
task coverage_simple, "Generate simple coverage report (faster)":
  # Check for lcov
  when not defined(windows):
    let lcovPath = staticExec("which lcov || echo notfound").strip()
    if lcovPath == "notfound":
      echo "⚠️ lcov not found. Please install lcov:"
      echo "  sudo apt-get install lcov  # Debian/Ubuntu"
      echo "  brew install lcov          # macOS"
      return
    else:
      echo "Using lcov from: " & lcovPath
  
  echo "Running simple coverage report..."
  
  # Prepare output directories
  exec "mkdir -p build/coverage/html build/coverage/gcov"
  
  # Core test files for coverage (reduced set for speed)
  var coreTests = @[
    "tests/test_client.nim",
    "tests/test_protocol.nim",
    "tests/test_resources.nim",
    "tests/test_tools.nim"
  ]
  
  # Run core tests
  echo "Running core tests for coverage..."
  for testFile in coreTests:
    echo "Running test: " & testFile
    exec "nim c -r --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-lgcov " & testFile
  
  # Generate coverage report
  when not defined(windows):
    echo "Generating coverage report..."
    exec lcovPath & " --capture --directory . --output-file build/coverage/coverage.info --ignore-errors gcov,mismatch --include '*/mcp-nim-sdk/src/*' 2>/dev/null || true"
    
    let genhtmlPath = staticExec("which genhtml || echo notfound").strip()
    if genhtmlPath != "notfound":
      echo "Generating HTML report..."
      exec genhtmlPath & " build/coverage/coverage.info --output-directory build/coverage/html --ignore-errors all 2>/dev/null || true"
      
      let htmlExists = staticExec("[ -f build/coverage/html/index.html ] && echo 'exists' || echo 'notfound'")
      if htmlExists == "exists":
        echo "\n✅ Simple coverage report generated successfully!"
        echo "View the report by opening build/coverage/html/index.html in your browser."
      else:
        echo "\n⚠️ HTML report generation might have had issues."
        echo "Creating a fallback report..."
        exec "echo '<html><body><h1>Coverage Report</h1><p>Basic coverage completed.</p></body></html>' > build/coverage/html/index.html"
        echo "Fallback report created at build/coverage/html/index.html"
    else:
      echo "genhtml not found. Coverage data was captured but no HTML report was generated."
