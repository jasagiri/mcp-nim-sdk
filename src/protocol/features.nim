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

func has*(version: McpProtocolVersion, feature: McpFeature): bool {.raises: [].} =
  ## Whether `version` of the protocol has `feature`.
  let s = span(feature)
  version >= s.since and (not s.until.present or version < s.until.version)

func featuresOf*(version: McpProtocolVersion): seq[McpFeature] {.raises: [].} =
  for feature in McpFeature:
    if version.has(feature):
      result.add feature

func displayName*(feature: McpFeature): string {.raises: [].} =
  ## What documentation calls the feature.
  case feature
  of ftInitializeHandshake: "initialize handshake"
  of ftPing: "ping"
  of ftProgress: "progress notifications"
  of ftCancellation: "cancellation"
  of ftPagination: "pagination"
  of ftTools: "tools"
  of ftResources: "resources"
  of ftResourceTemplates: "resource templates"
  of ftResourceSubscribe: "resource subscriptions"
  of ftPrompts: "prompts"
  of ftCompletion: "argument completion"
  of ftLogging: "logging"
  of ftLoggingSetLevel: "logging/setLevel"
  of ftSampling: "sampling"
  of ftRoots: "roots"
  of ftRootsListChanged: "roots list-changed notification"
  of ftServerInitiatedRequests: "server-initiated requests"
  of ftStdio: "stdio transport"
  of ftHttpSse: "HTTP+SSE transport (deprecated)"
  of ftStreamableHttp: "Streamable HTTP transport"
  of ftHttpSessions: "HTTP sessions (Mcp-Session-Id)"
  of ftHttpGetStream: "HTTP GET stream"
  of ftHttpResumability: "SSE resumability (Last-Event-ID)"
  of ftJsonRpcBatch: "JSON-RPC batches"
  of ftAuthorization: "authorization (OAuth)"
  of ftToolAnnotations: "tool annotations"
  of ftAudioContent: "audio content"
  of ftProgressMessage: "progress messages"
  of ftProtocolVersionHeader: "MCP-Protocol-Version header"
  of ftStructuredToolOutput: "structured tool output"
  of ftResourceLinks: "resource links in tool results"
  of ftElicitation: "elicitation"
  of ftTitleFields: "title fields"
  of ftCompletionContext: "completion context"
  of ftProtectedResourceMetadata: "protected resource metadata"
  of ftTasks: "tasks"
  of ftIcons: "icons"
  of ftUrlElicitation: "URL-mode elicitation"
  of ftSamplingTools: "tool use in sampling"
  of ftClientIdMetadataDocuments: "client ID metadata documents"
  of ftPerRequestMetadata: "per-request protocol metadata"
  of ftDiscover: "server/discover"
  of ftResultType: "resultType"
  of ftMultiRoundTripRequests: "multi round-trip requests"
  of ftSubscriptionsListen: "subscriptions/listen"
  of ftCacheHints: "cache hints (ttlMs, cacheScope)"
  of ftMirroredHeaders: "mirrored request headers (Mcp-Method, Mcp-Name)"
  of ftParameterHeaders: "parameter headers (x-mcp-header)"
  of ftExtensions: "extensions"
  of ftCompletionsCapability: "completions capability"
  of ftDynamicClientRegistration: "dynamic client registration"
  of ftAuthorizationServerMetadata: "authorization server metadata"
  of ftResourceIndicators: "resource indicators"
  of ftOidcDiscovery: "OpenID Connect discovery"
  of ftIncrementalScopeConsent: "incremental scope consent"
  of ftEnumSchemas: "enum schemas in elicitation"
  of ftElicitationDefaults: "elicitation default values"
  of ftSsePolling: "SSE polling"
  of ftImplementationDescription: "implementation description"
  of ftJsonSchema2020: "JSON Schema 2020-12"
  of ftTraceContext: "trace context in _meta"
  of ftIssuerParameter: "authorization response issuer (iss)"
  of ftResourceNotFoundInvalidParams: "resource-not-found as invalid params"

func specPage*(feature: McpFeature, version: McpProtocolVersion): string {.raises: [].} =
  ## The page of the specification for `version` that defines the feature,
  ## relative to `docs/specification/<version>/`, without the extension.
  let modern = version >= mpv20260728
  case feature
  of ftInitializeHandshake: "basic/lifecycle"
  of ftImplementationDescription:
    if modern: "server/discover" else: "basic/lifecycle"
  of ftPing: "basic/utilities/ping"
  of ftProgress, ftProgressMessage:
    if modern: "basic/patterns/progress" else: "basic/utilities/progress"
  of ftCancellation:
    if modern: "basic/patterns/cancellation" else: "basic/utilities/cancellation"
  of ftPagination: "server/utilities/pagination"
  of ftTools, ftToolAnnotations, ftAudioContent, ftStructuredToolOutput,
     ftResourceLinks, ftTitleFields, ftIcons, ftJsonSchema2020: "server/tools"
  of ftResources, ftResourceTemplates, ftResourceSubscribe,
     ftResourceNotFoundInvalidParams: "server/resources"
  of ftPrompts: "server/prompts"
  of ftCompletion, ftCompletionContext, ftCompletionsCapability:
    "server/utilities/completion"
  of ftLogging, ftLoggingSetLevel: "server/utilities/logging"
  of ftSampling, ftSamplingTools: "client/sampling"
  of ftRoots, ftRootsListChanged: "client/roots"
  of ftElicitation, ftUrlElicitation, ftEnumSchemas, ftElicitationDefaults:
    "client/elicitation"
  of ftServerInitiatedRequests: "architecture/index"
  of ftStdio:
    if modern: "basic/transports/stdio" else: "basic/transports"
  of ftHttpSse:
    if version == mpv20241105: "basic/transports"
    elif modern: "basic/transports/streamable-http"
    else: "basic/transports"
  of ftStreamableHttp, ftHttpSessions, ftHttpGetStream, ftHttpResumability,
     ftJsonRpcBatch, ftProtocolVersionHeader, ftSsePolling, ftMirroredHeaders,
     ftParameterHeaders:
    if modern: "basic/transports/streamable-http" else: "basic/transports"
  of ftAuthorization, ftProtectedResourceMetadata, ftResourceIndicators,
     ftIncrementalScopeConsent, ftAuthorizationServerMetadata:
    if modern: "basic/authorization/index" else: "basic/authorization"
  of ftOidcDiscovery:
    if modern: "basic/authorization/authorization-server-discovery"
    else: "basic/authorization"
  of ftClientIdMetadataDocuments, ftDynamicClientRegistration:
    if modern: "basic/authorization/client-registration"
    else: "basic/authorization"
  of ftIssuerParameter: "basic/authorization/security-considerations"
  of ftTasks: "basic/utilities/tasks"
  of ftPerRequestMetadata, ftTraceContext, ftExtensions, ftResultType:
    "basic/index"
  of ftDiscover: "server/discover"
  of ftMultiRoundTripRequests: "basic/patterns/mrtr"
  of ftSubscriptionsListen: "basic/patterns/subscriptions"
  of ftCacheHints: "server/utilities/caching"
