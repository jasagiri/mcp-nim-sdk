## The table of which protocol version has which feature.

import std/[strutils, unittest]
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

  test "Given the rows added after checking the changelogs, when each version is asked, then each appears in the version its changelog names":
    let introduced = [
      (ftCompletionsCapability, mpv20250326), (ftDynamicClientRegistration, mpv20250326),
      (ftAuthorizationServerMetadata, mpv20250326), (ftResourceIndicators, mpv20250618),
      (ftOidcDiscovery, mpv20251125), (ftIncrementalScopeConsent, mpv20251125),
      (ftEnumSchemas, mpv20251125), (ftElicitationDefaults, mpv20251125),
      (ftSsePolling, mpv20251125), (ftImplementationDescription, mpv20251125),
      (ftJsonSchema2020, mpv20251125), (ftTraceContext, mpv20260728),
      (ftIssuerParameter, mpv20260728), (ftResourceNotFoundInvalidParams, mpv20260728)]
    for (feature, since) in introduced:
      for v in McpProtocolVersion:
        if feature == ftSsePolling:
          check v.has(feature) == (v == mpv20251125)
        else:
          check v.has(feature) == (v >= since)

  test "Given any feature, when it is documented, then it has a name and a specification page in every version that has it":
    for v in McpProtocolVersion:
      for feature in featuresOf(v):
        check displayName(feature).len > 0
        check specPage(feature, v).len > 0
        check not specPage(feature, v).endsWith(".mdx")

  test "Given the 2026-07-28 reorganisation, when the page of a moved feature is asked, then each version names its own page":
    check specPage(ftStdio, mpv20251125) == "basic/transports"
    check specPage(ftStdio, mpv20260728) == "basic/transports/stdio"
    check specPage(ftAuthorization, mpv20251125) == "basic/authorization"
    check specPage(ftAuthorization, mpv20260728) == "basic/authorization/index"
