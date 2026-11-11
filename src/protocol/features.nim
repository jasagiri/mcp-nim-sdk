## Which protocol version has which feature.
##
## The one table that code, tests and generated documentation agree on. A
## feature exists in a version when `since <= version < until`.
##
## Every row was checked against `changelog.mdx` and the specification text
## of its version (modelcontextprotocol/modelcontextprotocol at commit
## 75db1e98, `docs/specification/<version>/`). Where a feature is deprecated
## but still described by a later version it stays in that version: the
## specification still defines what an implementation does with it.

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
    ftHttpSse                ## the HTTP+SSE transport; deprecated since 2025-03-26, later
                             ## versions only describe how to probe for it
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
    ftToolInputErrors        ## a tool input that fails validation is a tool result with isError, not a protocol error
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
    # Found missing when the rows were checked against the changelogs.
    # 2025-03-26
    ftCompletionsCapability  ## `completions` capability
    ftDynamicClientRegistration
    ftAuthorizationServerMetadata ## RFC 8414
    # 2025-06-18
    ftResourceIndicators     ## RFC 8707
    # 2025-11-25
    ftOidcDiscovery
    ftIncrementalScopeConsent ## WWW-Authenticate scope challenges
    ftEnumSchemas            ## titled / untitled, single / multi-select
    ftElicitationDefaults
    ftSsePolling             ## the server may close an SSE stream at will
    ftImplementationDescription
    ftJsonSchema2020
    # 2026-07-28
    ftTraceContext           ## traceparent / tracestate / baggage in _meta
    ftIssuerParameter        ## RFC 9207 `iss`
    ftResourceNotFoundInvalidParams ## -32602 instead of -32002
    # Authorization (docs/quality/auth-requirements.md)
    ftAuthDefaultEndpoints   ## 2025-03-26 discovery: root metadata, /authorize /token /register

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
  of ftIcons, ftUrlElicitation, ftSamplingTools, ftToolInputErrors,
     ftClientIdMetadataDocuments:
    FeatureSpan(since: mpv20251125, until: forever())
  of ftPerRequestMetadata, ftDiscover, ftResultType, ftMultiRoundTripRequests,
     ftSubscriptionsListen, ftCacheHints, ftMirroredHeaders,
     ftParameterHeaders, ftExtensions:
    FeatureSpan(since: mpv20260728, until: forever())
  of ftCompletionsCapability, ftDynamicClientRegistration,
     ftAuthorizationServerMetadata:
    FeatureSpan(since: mpv20250326, until: forever())
  of ftResourceIndicators:
    FeatureSpan(since: mpv20250618, until: forever())
  of ftOidcDiscovery, ftIncrementalScopeConsent, ftEnumSchemas,
     ftElicitationDefaults, ftImplementationDescription, ftJsonSchema2020:
    FeatureSpan(since: mpv20251125, until: forever())
  of ftSsePolling:
    # Polling relies on Last-Event-ID, which 2026-07-28 removed.
    FeatureSpan(since: mpv20251125, until: before(mpv20260728))
  of ftTraceContext, ftIssuerParameter, ftResourceNotFoundInvalidParams:
    FeatureSpan(since: mpv20260728, until: forever())
  of ftAuthDefaultEndpoints:
    FeatureSpan(since: mpv20250326, until: before(mpv20250618))

func has*(version: McpProtocolVersion, feature: McpFeature): bool {.raises: [].} =
  ## Whether `version` of the protocol has `feature`.
  let s = span(feature)
  version >= s.since and (not s.until.present or version < s.until.version)
