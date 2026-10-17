import std/[os, strutils]

# Package

version       = "0.0.0"
author        = "jasagiri"
description   = "A Nim implementation of the Model Context Protocol (MCP)"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.12"
requires "uuids >= 0.1.12"  # UUID generation
requires "nimcrypto >= 0.7.3"  # SHA-256 and HMAC-SHA256: the standard library has neither
# Not in the nimble registry, so named by URL.
requires "https://github.com/jasagiri/nim-bearer-challenge >= 0.1.0"  # WWW-Authenticate challenges
requires "https://github.com/jasagiri/nim-secret >= 0.1.0"  # constant-time equality
requires "https://github.com/jasagiri/nim-loopback >= 0.1.0"  # whether a host or an address is loopback

# The property tests (tests/external/test_*_prop.nim); a program that uses the SDK does not need it.
taskRequires "test", "https://github.com/jasagiri/nim-propcheck >= 0.1.0"
taskRequires "testAllVersions", "https://github.com/jasagiri/nim-propcheck >= 0.1.0"
# The replay of saved fuzzing inputs (tests/internal/test_fuzz_regressions.nim); a program that uses the SDK does not need it.
taskRequires "test", "https://github.com/jasagiri/nim-fuzz >= 0.1.0"
taskRequires "testAllVersions", "https://github.com/jasagiri/nim-fuzz >= 0.1.0"

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

const testDirs = ["tests/external", "tests/internal"]
  ## Where the tests are (ADR-KURA-0008): the external tests, which reach
  ## the SDK through its entries only, and the internal ones.

proc testFiles(): seq[string] =
  for dir in testDirs:
    result.add nimFilesIn(dir, "test_*.nim")

proc testFile(name: string): string =
  ## The path of the test called `name`, whichever directory holds it.
  for dir in testDirs:
    if fileExists(dir & "/" & name & ".nim"):
      return dir & "/" & name & ".nim"
  raise newException(OSError, "no test called " & name & " under " & testDirs.join(" or "))

const sslTests = ["test_security_wire_tls", "test_security_trusted_ca"]
  ## Tests that need `-d:ssl` (a TLS server and the https client). Built
  ## without it they fail on purpose, so the generic loop leaves them out and
  ## `runSslTests` runs them with the flag. The other tests do not use TLS,
  ## and `-d:ssl` would make them depend on the system's OpenSSL for nothing.

const
  TestCache = "build/nimcache"
    ## Where tests/config.nims puts the compiler's cache of every test.
  ProgramCache = "build/nimcache/bin"
    ## The same for the examples and the interop programs.
  readNonNimFiles = ["test_spec_coverage", "test_docs_version"]
    ## Tests that read specs/, templates/ and the generated documents when
    ## they run. The compiler's record of sources does not show that, so
    ## they are never left out.

type Selection = object
  ## Which programs a run covers: all of them, or those that a change since
  ## the commit `base` can affect.
  base: string

proc everything(): Selection = Selection()

proc covered(selection: Selection, files: seq[string], cache: string): seq[string] =
  ## The programs among `files` that are built and run. Without a base, all.
  ## With one, those `tools/affected.nim` names, and the tests that read
  ## files the compiler knows nothing of.
  if selection.base.len == 0:
    return files
  let (output, code) = gorgeEx("nim r --hints:off --nimcache:build/nc_affected tools/affected.nim " &
                               quoteShell(selection.base) & " " & cache & " " & files.join(" "))
  if code != 0:
    raise newException(OSError, "cannot tell what changed since '" & selection.base & "': " & output)
  let named = output.splitLines()
  for file in files:
    if file in named or file.splitFile.name in readNonNimFiles:
      result.add file

proc runTests(extraFlags: string, selection = everything()) =
  exec "mkdir -p build/tests"
  let files = testFiles()
  if files.len == 0:
    raise newException(OSError, "No test files found in " & testDirs.join(" or "))
  let chosen = selection.covered(files, TestCache)
  for file in chosen:
    if file.splitFile.name in sslTests:
      continue
    echo "Running test: " & file
    exec "nim c -r " & extraFlags & " -o:build/tests/" & file.splitFile.name & " " & file
  if chosen.len < files.len:
    echo "Left out " & $(files.len - chosen.len) & " of " & $files.len &
         " tests: nothing they are built from differs from " & selection.base

proc runSslTests(extraFlags: string) =
  ## Needs the `openssl` command, which the tests use to make certificates.
  exec "mkdir -p build/tests"
  for name in sslTests:
    echo "Running test (-d:ssl): " & name
    exec "nim c -r -d:ssl " & extraFlags & " -o:build/tests/" & name & " " & testFile(name)

proc compileOnly(dir: string, extraFlags: string, selection = everything()) =
  ## Programs that are not tests but must keep compiling.
  exec "mkdir -p build/bin"
  for file in selection.covered(nimFilesIn(dir, "*.nim"), ProgramCache):
    echo "Compiling: " & file
    exec "nim c " & extraFlags & " --path:src --nimcache:" & ProgramCache &
         " -o:build/bin/" & file.splitFile.name & " " & file

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
         " --nimcache:build/nc_modern_only -o:build/tests/modern_only_" & name & " " & testFile(name)

task testSsl, "Run the tests that need -d:ssl":
  runSslTests("")

task test, "Run tests":
  runTests("")
  runSslTests("")
  if buildDefaultVersion() == "2026-07-28":
    runModernOnlyTests()
  compileOnly("tests/interop", "")
  compileOnly("examples", "")

task testAllVersions, "Run tests once per released protocol version as the build default":
  ## With MCP_TEST_BASE=<commit> in the environment, the other versions run
  ## only what a change since that commit can affect: a branch that adds to
  ## another (the extensions to a dated version, the drafts to the
  ## extensions) need not repeat, version by version, what was run on the
  ## branch below it. The build's own default version always runs in full,
  ## and it runs first: its compilations are the record the choice is read
  ## from. A source that only an older version compiles in is therefore not
  ## seen; run without MCP_TEST_BASE where that matters.
  let own = buildDefaultVersion()
  let base = getEnv("MCP_TEST_BASE")
  var versions = @[own]
  for version in releasedProtocolVersions:
    if version != own:
      versions.add version
  for version in versions:
    echo "=== default protocol version " & version & " ==="
    let flag = "-d:mcpDefaultProtocolVersion=" & version
    let selection = if base.len > 0 and version != own: Selection(base: base) else: everything()
    generateDocs(flag)  # tests/internal/test_docs_version.nim compares the files with the build's version
    runTests(flag, selection)
    compileOnly("tests/interop", flag, selection)
    compileOnly("examples", flag, selection)
  generateDocs("")  # leave the documents of the build's own default
  runModernOnlyTests()

task affectedTests, "List the tests that testAllVersions runs for the other versions with MCP_TEST_BASE=<commit>":
  let base = getEnv("MCP_TEST_BASE")
  if base.len == 0:
    raise newException(ValueError, "set MCP_TEST_BASE to the commit to compare with")
  for file in Selection(base: base).covered(testFiles(), TestCache):
    if file.splitFile.name notin sslTests:
      echo file

task genDocs, "Regenerate README.md and docs/ from templates/":
  generateDocs("")

task specCoverage, "Measure specification coverage (G1) with ../nim-spec-coverage and write build/g1-spec-coverage.md":
  # Fails when a declared specification has no external test in specs/tests.map,
  # or when an external test reads a module no entry exports.
  # The tool is a sibling package; NIM_SPEC_COVERAGE names it from a checkout that has no such sibling.
  let tool = getEnv("NIM_SPEC_COVERAGE", "../nim-spec-coverage")
  exec "nim c --hints:off --nimcache:build/nimcache/spec_coverage -o:build/bin/spec_coverage " & tool & "/src/spec_coverage.nim"
  # An identifier counts as covered by an external test only: a test under
  # tests/external, which may read the entries below and what they export
  # whole. The entries are what the README and the modules' documentation
  # tell a user to import; an extension is one module under src/ext.
  var entries = @["src/mcp.nim", "src/auth/client.nim", "src/auth/resource_server.nim",
                  "src/transport/http_compat.nim", "src/server/request_state.nim"]
  if dirExists("src/ext"):
    entries.add nimFilesIn("src/ext", "*.nim")
  var options = " --scenarios specs --tests tests/external --tests tests/internal --external tests/external"
  for entry in entries:
    options.add " --entry " & entry
  # The report is an output, not a record: it is written under build/ and not
  # committed, so that a commit cannot carry a report of another state.
  exec "build/bin/spec_coverage ." & options & " > build/g1-spec-coverage.md"

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
