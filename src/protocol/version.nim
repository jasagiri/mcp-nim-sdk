## Protocol versions this SDK knows, and which of them this build speaks.

import std/options

type
  McpProtocolVersion* = enum
    mpv20241105 = "2024-11-05"
    mpv20250326 = "2025-03-26"
    mpv20250618 = "2025-06-18"
    mpv20251125 = "2025-11-25"
    mpv20260728 = "2026-07-28"

const
  mcpDefaultProtocolVersion {.strdefine.} = "2026-07-28"
    ## The newest version this build speaks. Each `mcp-<version>` release
    ## branch changes only this string; `-d:mcpDefaultProtocolVersion=...`
    ## overrides it so one tree can be tested as every release.

  FirstModernProtocolVersion* = mpv20260728
    ## From this version on there is no initialize handshake: every request
    ## carries its own protocol version and client capabilities.

func parseProtocolVersion*(s: string): Option[McpProtocolVersion] {.raises: [].} =
  for v in McpProtocolVersion:
    if $v == s:
      return some(v)
  none(McpProtocolVersion)

const
  DefaultProtocolVersion* = block:
    let parsed = parseProtocolVersion(mcpDefaultProtocolVersion)
    doAssert parsed.isSome,
      "mcpDefaultProtocolVersion is not a released MCP version: " &
      mcpDefaultProtocolVersion
    parsed.get

  SupportedProtocolVersions* = block:
    var versions: seq[McpProtocolVersion] = @[]
    for v in McpProtocolVersion:
      if v <= DefaultProtocolVersion:
        versions.add v
    versions

func isSupported*(v: McpProtocolVersion): bool {.raises: [].} =
  v <= DefaultProtocolVersion

func requireSupported*(v: McpProtocolVersion) {.raises: [ValueError].} =
  if not isSupported(v):
    raise newException(ValueError,
      "protocol version " & $v & " is newer than this build's default " &
      $DefaultProtocolVersion)

func isModern*(v: McpProtocolVersion): bool {.raises: [].} =
  v >= FirstModernProtocolVersion

func versionsUpTo*(ceiling: McpProtocolVersion): seq[McpProtocolVersion] {.raises: [].} =
  for v in McpProtocolVersion:
    if v <= ceiling:
      result.add v

func latestLegacyVersion*(supported: openArray[McpProtocolVersion]): Option[McpProtocolVersion] {.raises: [].} =
  for v in supported:
    if not isModern(v) and (result.isNone or v > result.get):
      result = some(v)

func negotiateLegacyVersion*(requested: string,
                             supported: openArray[McpProtocolVersion]): Option[McpProtocolVersion] {.raises: [].} =
  ## The version an `initialize` response carries: the requested one when
  ## this side speaks it, otherwise the latest legacy version it does speak.
  ## `none` when this side speaks no legacy version at all.
  let parsed = parseProtocolVersion(requested)
  if parsed.isSome and not isModern(parsed.get) and parsed.get in supported:
    parsed
  else:
    latestLegacyVersion(supported)
