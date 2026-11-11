## What documentation says about the features: which a version has, what
## each is called, and the page of the specification that defines it.
##
## This serves the generated documents (`tools/gen_docs.nim`) and the tests
## that hold them to the tree. It is not part of what `mcp` exports: a
## program that speaks the protocol asks `version.has(feature)`.

import ./version
import ./features

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
  of ftToolInputErrors: "input validation errors as tool results"
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
  of ftAuthDefaultEndpoints: "default authorization endpoints"
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
  of ftTools, ftToolInputErrors, ftToolAnnotations, ftAudioContent, ftStructuredToolOutput,
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
    if modern: "basic/transports/streamable-http" else: "basic/transports"
  of ftStreamableHttp, ftHttpSessions, ftHttpGetStream, ftHttpResumability,
     ftJsonRpcBatch, ftProtocolVersionHeader, ftSsePolling, ftMirroredHeaders,
     ftParameterHeaders:
    if modern: "basic/transports/streamable-http" else: "basic/transports"
  of ftAuthorization, ftProtectedResourceMetadata, ftResourceIndicators,
     ftIncrementalScopeConsent, ftAuthorizationServerMetadata,
     ftAuthDefaultEndpoints:
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
