## Which protocol version has which feature.
##
## The one table that code, tests and generated documentation agree on. A
## feature exists in a version when `since <= version < until`.
##
## TODO: every row is to be checked against the changelog of its version
## (docs/specification/<version>/changelog.mdx upstream); rows marked
## "unchecked" below come from memory of the specification.

import ./version

type
  McpFeature* = enum
    # 2024-11-05
    ftInitializeHandshake    ## initialize / notifications/initialized
    ftPing
    ftProgress
    ftCancellation
    ftPagination
    ftTools
    ftResources
    ftResourceTemplates
    ftResourceSubscribe      ## resources/subscribe, resources/unsubscribe
    ftPrompts
    ftCompletion
    ftLogging                ## notifications/message
    ftLoggingSetLevel        ## logging/setLevel
    ftSampling
    ftRoots
    ftRootsListChanged
    ftServerInitiatedRequests
    ftStdio
    ftHttpSse                ## the HTTP+SSE transport of 2024-11-05
    # 2025-03-26
    ftStreamableHttp
    ftHttpSessions           ## Mcp-Session-Id
    ftHttpGetStream          ## GET stream for server-initiated messages
    ftHttpResumability       ## Last-Event-ID
    ftJsonRpcBatch
    ftAuthorization
    ftToolAnnotations
    ftAudioContent
    ftProgressMessage
    # 2025-06-18
    ftProtocolVersionHeader
    ftStructuredToolOutput
    ftResourceLinks
    ftElicitation
    ftTitleFields
    ftCompletionContext
    ftProtectedResourceMetadata
    # 2025-11-25
    ftTasks
    ftIcons
    ftUrlElicitation
    ftSamplingTools
    ftClientIdMetadataDocuments
    # 2026-07-28
    ftPerRequestMetadata
    ftDiscover
    ftResultType
    ftMultiRoundTripRequests
    ftSubscriptionsListen
    ftCacheHints
    ftMirroredHeaders
    ftParameterHeaders       ## x-mcp-header
    ftExtensions

  McpProtocolVersionOrNone* = object
    present*: bool
    version*: McpProtocolVersion

  FeatureSpan* = object
    since*: McpProtocolVersion
    until*: McpProtocolVersionOrNone
      ## The first version that no longer has the feature.

func forever(): McpProtocolVersionOrNone {.raises: [].} =
  McpProtocolVersionOrNone(present: false)

func before(v: McpProtocolVersion): McpProtocolVersionOrNone {.raises: [].} =
  McpProtocolVersionOrNone(present: true, version: v)

func span*(feature: McpFeature): FeatureSpan {.raises: [].} =
  case feature
  of ftProgress, ftCancellation, ftPagination, ftTools, ftResources,
     ftResourceTemplates, ftPrompts, ftCompletion, ftLogging, ftSampling,
     ftRoots, ftStdio, ftHttpSse:
    FeatureSpan(since: mpv20241105, until: forever())
  of ftInitializeHandshake, ftPing, ftResourceSubscribe, ftLoggingSetLevel,
     ftRootsListChanged, ftServerInitiatedRequests:
    FeatureSpan(since: mpv20241105, until: before(mpv20260728))
  of ftStreamableHttp, ftAuthorization, ftToolAnnotations, ftAudioContent,
     ftProgressMessage:
    FeatureSpan(since: mpv20250326, until: forever())
  of ftHttpSessions, ftHttpGetStream, ftHttpResumability:
    FeatureSpan(since: mpv20250326, until: before(mpv20260728))
  of ftJsonRpcBatch:
    FeatureSpan(since: mpv20250326, until: before(mpv20250618))
  of ftProtocolVersionHeader, ftStructuredToolOutput, ftResourceLinks,
     ftElicitation, ftTitleFields, ftCompletionContext,
     ftProtectedResourceMetadata:
    FeatureSpan(since: mpv20250618, until: forever())
  of ftTasks:
    # Core only in 2025-11-25; an official extension afterwards.
    FeatureSpan(since: mpv20251125, until: before(mpv20260728))
  of ftIcons, ftUrlElicitation, ftSamplingTools, ftClientIdMetadataDocuments:
    FeatureSpan(since: mpv20251125, until: forever())
  of ftPerRequestMetadata, ftDiscover, ftResultType, ftMultiRoundTripRequests,
     ftSubscriptionsListen, ftCacheHints, ftMirroredHeaders,
     ftParameterHeaders, ftExtensions:
    FeatureSpan(since: mpv20260728, until: forever())

func has*(version: McpProtocolVersion, feature: McpFeature): bool {.raises: [].} =
  ## Whether `version` of the protocol has `feature`.
  let s = span(feature)
  version >= s.since and (not s.until.present or version < s.until.version)

func featuresOf*(version: McpProtocolVersion): seq[McpFeature] {.raises: [].} =
  for feature in McpFeature:
    if version.has(feature):
      result.add feature
