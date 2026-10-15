## Which protocol versions this build knows and speaks.
##
## Expectations are derived from `DefaultProtocolVersion`, so the same file
## passes on every `mcp-<version>` release branch.

import std/[unittest, options, strutils]
import protocol/version

suite "protocol version: parsing":

  test "Given a released version string, when parsed, then the matching version is returned":
    check parseProtocolVersion("2024-11-05") == some(mpv20241105)
    check parseProtocolVersion("2025-03-26") == some(mpv20250326)
    check parseProtocolVersion("2025-06-18") == some(mpv20250618)
    check parseProtocolVersion("2025-11-25") == some(mpv20251125)
    check parseProtocolVersion("2026-07-28") == some(mpv20260728)

  test "Given a string that is not a released version, when parsed, then none is returned":
    check parseProtocolVersion("2099-01-01").isNone
    check parseProtocolVersion("1.0.0").isNone
    check parseProtocolVersion("").isNone

  test "Given a version, when rendered, then it is the wire string":
    check $mpv20241105 == "2024-11-05"
    check $mpv20260728 == "2026-07-28"

suite "protocol version: what this build speaks":

  test "Given the oldest and the default version, when listing supported versions, then they are every version between them in ascending order":
    var expected: seq[McpProtocolVersion] = @[]
    for v in McpProtocolVersion:
      if v >= OldestProtocolVersion and v <= DefaultProtocolVersion:
        expected.add v
    check SupportedProtocolVersions == expected
    check SupportedProtocolVersions[0] == OldestProtocolVersion
    check SupportedProtocolVersions[^1] == DefaultProtocolVersion

  test "Given a version outside the build's range, when checked, then it is not supported":
    for v in McpProtocolVersion:
      check isSupported(v) == (v >= OldestProtocolVersion and v <= DefaultProtocolVersion)

  test "Given a version outside the build's range, when required, then ValueError names it and both ends of the range":
    for v in McpProtocolVersion:
      if isSupported(v):
        requireSupported(v)
      else:
        var message = ""
        try:
          requireSupported(v)
        except ValueError as e:
          message = e.msg
        check $v in message
        check $OldestProtocolVersion in message
        check $DefaultProtocolVersion in message

  test "Given a registration that targets a version, when a side limited to each ceiling makes it, then it is refused exactly when that side speaks neither the target nor a later version":
    for ceiling in SupportedProtocolVersions:
      for target in McpProtocolVersion:
        checkpoint $ceiling & " / " & $target
        if target <= ceiling:
          requireVersionSpoken(ceiling, target, "the widgets extension")
        else:
          var message = ""
          try:
            requireVersionSpoken(ceiling, target, "the widgets extension")
          except ValueError as e:
            message = e.msg
          check "the widgets extension" in message
          check $target in message
          check $ceiling in message

suite "protocol version: eras":

  test "Given each version, when asked whether it is modern, then only 2026-07-28 onward is":
    check not isModern(mpv20241105)
    check not isModern(mpv20250326)
    check not isModern(mpv20250618)
    check not isModern(mpv20251125)
    check isModern(mpv20260728)

  test "Given a ceiling, when listing versions up to it, then every version at or below it is listed in ascending order":
    check versionsUpTo(mpv20241105) == @[mpv20241105]
    check versionsUpTo(mpv20250618) == @[mpv20241105, mpv20250326, mpv20250618]
    check versionsUpTo(mpv20260728).len == 5

  test "Given a supported set, when asking for its latest legacy version, then it is the newest one before 2026-07-28":
    check latestLegacyVersion(versionsUpTo(mpv20241105)) == some(mpv20241105)
    check latestLegacyVersion(versionsUpTo(mpv20250618)) == some(mpv20250618)
    check latestLegacyVersion(versionsUpTo(mpv20260728)) == some(mpv20251125)
    check latestLegacyVersion([mpv20250326, mpv20241105]) == some(mpv20250326)

  test "Given a supported set with no legacy version, when asking for its latest legacy version, then none is returned":
    check latestLegacyVersion([mpv20260728]).isNone
    check latestLegacyVersion(newSeq[McpProtocolVersion]()).isNone

suite "protocol version: initialize negotiation":

  test "Given a requested legacy version that is supported, when negotiated, then the same version is chosen":
    let all = versionsUpTo(mpv20260728)
    check negotiateLegacyVersion("2024-11-05", all) == some(mpv20241105)
    check negotiateLegacyVersion("2025-03-26", all) == some(mpv20250326)
    check negotiateLegacyVersion("2025-06-18", all) == some(mpv20250618)
    check negotiateLegacyVersion("2025-11-25", all) == some(mpv20251125)

  test "Given a requested version that is not supported, when negotiated, then the latest supported legacy version is chosen":
    check negotiateLegacyVersion("2025-11-25", versionsUpTo(mpv20250618)) == some(mpv20250618)
    check negotiateLegacyVersion("2025-06-18", versionsUpTo(mpv20241105)) == some(mpv20241105)
    check negotiateLegacyVersion("2025-03-26", [mpv20241105, mpv20250618]) == some(mpv20250618)

  test "Given an unknown version string, when negotiated, then the latest supported legacy version is chosen":
    check negotiateLegacyVersion("2099-01-01", versionsUpTo(mpv20260728)) == some(mpv20251125)
    check negotiateLegacyVersion("1.0.0", versionsUpTo(mpv20250326)) == some(mpv20250326)
    check negotiateLegacyVersion("", versionsUpTo(mpv20241105)) == some(mpv20241105)

  test "Given the modern version requested through initialize, when negotiated, then a legacy version is chosen":
    # initialize is the legacy handshake; it never yields a modern version.
    check negotiateLegacyVersion("2026-07-28", versionsUpTo(mpv20260728)) == some(mpv20251125)

  test "Given a side that speaks no legacy version, when negotiated, then none is returned":
    check negotiateLegacyVersion("2025-11-25", [mpv20260728]).isNone
