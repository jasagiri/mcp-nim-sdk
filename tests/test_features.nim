## The table of which protocol version has which feature.

import std/unittest
import protocol/version
import protocol/features

suite "protocol features by version":

  test "Given the first version, when asked for the baseline features, then it has them":
    for feature in [ftInitializeHandshake, ftPing, ftTools, ftResources, ftPrompts,
                    ftSampling, ftRoots, ftLogging, ftCompletion, ftStdio, ftHttpSse]:
      check mpv20241105.has(feature)

  test "Given the first version, when asked for later features, then it has none of them":
    for feature in [ftStreamableHttp, ftAuthorization, ftElicitation,
                    ftStructuredToolOutput, ftTasks, ftDiscover, ftResultType]:
      check not mpv20241105.has(feature)

  test "Given JSON-RPC batches, when each version is asked, then only 2025-03-26 has them":
    for v in McpProtocolVersion:
      check v.has(ftJsonRpcBatch) == (v == mpv20250326)

  test "Given tasks, when each version is asked, then only 2025-11-25 has them in the core":
    for v in McpProtocolVersion:
      check v.has(ftTasks) == (v == mpv20251125)

  test "Given 2026-07-28, when asked for what it removed, then it has none of it":
    for feature in [ftInitializeHandshake, ftPing, ftLoggingSetLevel, ftResourceSubscribe,
                    ftRootsListChanged, ftServerInitiatedRequests, ftHttpSessions,
                    ftHttpGetStream, ftHttpResumability, ftTasks]:
      check mpv20251125.has(feature)
      check not mpv20260728.has(feature)

  test "Given 2026-07-28, when asked for what it introduced, then no earlier version has it":
    for feature in [ftPerRequestMetadata, ftDiscover, ftResultType, ftMultiRoundTripRequests,
                    ftSubscriptionsListen, ftCacheHints, ftMirroredHeaders,
                    ftParameterHeaders, ftExtensions]:
      check mpv20260728.has(feature)
      check not mpv20251125.has(feature)

  test "Given any feature, when its span is read, then it ends after it starts":
    for feature in McpFeature:
      let s = span(feature)
      if s.until.present:
        check s.until.version > s.since

  test "Given a version, when its features are listed, then the list is exactly the features it has":
    for v in McpProtocolVersion:
      let listed = featuresOf(v)
      for feature in McpFeature:
        check (feature in listed) == v.has(feature)
