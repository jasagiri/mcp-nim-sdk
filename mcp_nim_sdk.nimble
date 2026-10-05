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

proc generateDocs(extraFlags: string) =
  ## README.md and docs/*.md for the protocol version the flags select.
  exec "nim r --hints:off --nimcache:build/nc_gen --path:src " & extraFlags & " tools/gen_docs.nim"

const modernOnlyTests = [
  "test_version_floor", "test_version", "test_features", "test_modern_protocol",
  "test_mrtr", "test_subscriptions", "test_trace_context", "test_param_headers"
]
  ## What holds on a build that speaks 2026-07-28 alone. The other tests need
  ## a legacy peer and cannot run there.

proc buildDefaultVersion(): string =
  ## The default version written in src/protocol/version.nim.
  result = staticExec("sed -n 's/.*mcpDefaultProtocolVersion {.strdefine.} = \"\\(.*\\)\"/\\1/p' src/protocol/version.nim").strip()
  if result notin releasedProtocolVersions:
    raise newException(ValueError, "could not read the default protocol version from src/protocol/version.nim: '" & result & "'")

proc runModernOnlyTests() =
  ## The build without the initialize handshake (`mcpOldestProtocolVersion`).
  exec "mkdir -p build/tests"
  for name in modernOnlyTests:
    echo "Running test (2026-07-28 only): " & name
    exec "nim c -r -d:mcpDefaultProtocolVersion=2026-07-28 -d:mcpOldestProtocolVersion=2026-07-28" &
         " --nimcache:build/nc_modern_only -o:build/tests/modern_only_" & name & " tests/" & name & ".nim"

task test, "Run tests":
  runTests("")
  if buildDefaultVersion() == "2026-07-28":
    runModernOnlyTests()
  compileOnly("tests/interop", "")
  compileOnly("examples", "")

task testAllVersions, "Run tests once per released protocol version as the build default":
  for version in releasedProtocolVersions:
    echo "=== default protocol version " & version & " ==="
    let flag = "-d:mcpDefaultProtocolVersion=" & version
    generateDocs(flag)  # tests/test_docs_version.nim compares the files with the build's version
    runTests(flag)
    compileOnly("tests/interop", flag)
    compileOnly("examples", flag)
  generateDocs("")  # leave the documents of the build's own default
  runModernOnlyTests()

task genDocs, "Regenerate README.md and docs/ from templates/":
  generateDocs("")

task docs, "Generate API documentation":
  exec "mkdir -p build/doc"
  exec "nim doc --project --index:on --outdir:build/doc src/mcp.nim"

task clean, "Remove build artifacts":
  rmDir "build"

proc interopEnvironment() =
  ## The official Python / TypeScript SDKs and the conformance suite, pinned (needs uv, node, npm).
  if not dirExists("build/interop/conformance"):
    exec "sh tests/interop/peers/setup.sh build/interop"

task interop, "Interop matrix: Nim against the official SDKs, per protocol version (slow; needs network and uv/node/npm; not part of test)":
  interopEnvironment()
  exec "python3 tests/interop/peers/run_nim.py --env build/interop "

task conformance, "Run the official conformance suite against the Nim server and client (needs uv/node/npm; not part of test)":
  interopEnvironment()
  exec "python3 tests/interop/peers/run_conformance.py --env build/interop"
