import std/[os, strutils]

# Package

version       = "0.0.0"
author        = "jasagiri"
description   = "A Nim implementation of the Model Context Protocol (MCP)"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.2"
requires "uuids >= 0.1.12"  # UUID generation

# Tasks

const releasedProtocolVersions = [
  "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"
]

proc nimFilesIn(dir, pattern: string): seq[string] =
  when defined(windows):
    let files = staticExec("cmd /c dir /b " & dir.replace("/", "\\") & "\\" & pattern & " 2>nul")
    for file in files.splitLines():
      if file.len > 0:
        result.add(dir & "/" & file)
  else:
    let files = staticExec("find " & dir & " -maxdepth 1 -name '" & pattern & "' -type f | sort")
    for file in files.splitLines():
      if file.len > 0:
        result.add(file)

proc runTests(extraFlags: string) =
  exec "mkdir -p build/tests"
  let files = nimFilesIn("tests", "test_*.nim")
  if files.len == 0:
    raise newException(OSError, "No test files found in tests/")
  for file in files:
    echo "Running test: " & file
    exec "nim c -r " & extraFlags & " -o:build/tests/" & file.splitFile.name & " " & file

proc compileOnly(dir: string, extraFlags: string) =
  ## Programs that are not tests but must keep compiling.
  exec "mkdir -p build/bin"
  for file in nimFilesIn(dir, "*.nim"):
    echo "Compiling: " & file
    exec "nim c " & extraFlags & " --path:src -o:build/bin/" & file.splitFile.name & " " & file

task test, "Run tests":
  runTests("")
  compileOnly("tests/interop", "")

task testAllVersions, "Run tests once per released protocol version as the build default":
  for version in releasedProtocolVersions:
    echo "=== default protocol version " & version & " ==="
    let flag = "-d:mcpDefaultProtocolVersion=" & version
    runTests(flag)
    compileOnly("tests/interop", flag)

task docs, "Generate API documentation":
  exec "mkdir -p build/doc"
  exec "nim doc --project --index:on --outdir:build/doc src/mcp.nim"

task clean, "Remove build artifacts":
  rmDir "build"
