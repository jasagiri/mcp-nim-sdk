## The build-time version settings are checked when the SDK is compiled: a
## version that was never released, or an oldest version newer than the
## default, stops the build and says which setting is wrong.
##
## Each case compiles a one-line program against `src/protocol/version.nim`
## with `nim check`, so no C compiler runs.

import std/[unittest, os, osproc, strutils]

const SourceDir = currentSourcePath().parentDir.parentDir / "src"

proc checkWith(defines: string): tuple[output: string, exitCode: int] =
  let dir = getTempDir() / ("mcp_version_config_" & $getCurrentProcessId())
  createDir dir
  defer: removeDir dir
  writeFile(dir / "probe.nim", "import protocol/version\necho DefaultProtocolVersion\n")
  execCmdEx("nim check --hints:off --path:" & quoteShell(SourceDir) &
            " --nimcache:" & quoteShell(dir / "cache") & " " & defines &
            " " & quoteShell(dir / "probe.nim"))

suite "protocol version: build-time settings":

  test "Given an oldest version that is not newer than the default, when the build is checked, then it is accepted":
    let (output, exitCode) = checkWith(
      "-d:mcpOldestProtocolVersion=2025-06-18 -d:mcpDefaultProtocolVersion=2025-11-25")
    check exitCode == 0
    check "Error" notin output

  test "Given a default version that was never released, when the build is checked, then it fails naming the setting":
    let (output, exitCode) = checkWith("-d:mcpDefaultProtocolVersion=2099-01-01")
    check exitCode != 0
    check "mcpDefaultProtocolVersion is not a released MCP version: 2099-01-01" in output

  test "Given an oldest version that was never released, when the build is checked, then it fails naming the setting":
    let (output, exitCode) = checkWith("-d:mcpOldestProtocolVersion=2099-01-01")
    check exitCode != 0
    check "mcpOldestProtocolVersion is not a released MCP version: 2099-01-01" in output

  test "Given an oldest version newer than the default, when the build is checked, then it fails naming both":
    let (output, exitCode) = checkWith(
      "-d:mcpDefaultProtocolVersion=2024-11-05 -d:mcpOldestProtocolVersion=2026-07-28")
    check exitCode != 0
    check "mcpOldestProtocolVersion 2026-07-28 is newer than mcpDefaultProtocolVersion 2024-11-05" in output
