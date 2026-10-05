## Which features of the table in `features.nim` this tree implements.
##
## `features.nim` says what a version of the protocol contains; this says how
## much of that the SDK does. Generated documentation reads both, so it never
## calls a feature usable that is not.
##
## A feature is `isImplemented` only when a test names it: `evidence` lists
## test files (relative to the repository root) that exercise it, and
## `tests/test_docs_version.nim` checks that they exist. The `case` has no
## `else`, so a feature added to the table cannot be left unclassified.

import ./features

type
  ImplStatus* = enum
    isNotImplemented = "not implemented"
    isImplemented = "implemented"

  Implementation* = object
    status*: ImplStatus
    evidence*: seq[string]
      ## Test files that exercise the feature; empty exactly when the
      ## feature is not implemented.
    note*: string
      ## What exists of a feature that is not implemented, or what is missing.

func done(evidence: varargs[string]): Implementation {.raises: [].} =
  Implementation(status: isImplemented, evidence: @evidence)

func notYet(note = ""): Implementation {.raises: [].} =
  Implementation(status: isNotImplemented, note: note)

func implementationOf*(feature: McpFeature): Implementation {.raises: [].} =
  case feature
  of ftInitializeHandshake:
    done("tests/test_legacy_handshake.nim", "tests/test_era_matrix.nim")
  of ftPing:
    done("tests/test_era_matrix.nim")
  of ftTools:
    done("tests/test_era_matrix.nim", "tests/test_stdio.nim",
         "tests/test_streamable_http.nim")
  of ftStdio:
    done("tests/test_stdio.nim")
  of ftStreamableHttp:
    done("tests/test_streamable_http.nim")
  of ftHttpSessions:
    done("tests/test_streamable_http.nim")
  of ftProtocolVersionHeader:
    done("tests/test_streamable_http.nim")
  of ftPerRequestMetadata:
    done("tests/test_modern_protocol.nim", "tests/test_era_matrix.nim")
  of ftDiscover:
    done("tests/test_era_matrix.nim")
  of ftResultType:
    done("tests/test_modern_protocol.nim", "tests/test_era_matrix.nim")
  of ftCacheHints:
    done("tests/test_modern_protocol.nim")
  of ftMirroredHeaders:
    done("tests/test_modern_protocol.nim", "tests/test_streamable_http.nim")
  of ftResources, ftPrompts:
    notYet("requests are routed to handlers, but no test covers it yet")
  of ftLogging:
    notYet("the server can send a log message, but no test covers it and the " &
           "2026-07-28 per-request log level is not honoured")
  of ftMultiRoundTripRequests:
    notYet("the client raises on an input_required result")
  of ftCancellation, ftProgress, ftPagination, ftResourceTemplates,
     ftResourceSubscribe, ftCompletion, ftLoggingSetLevel, ftSampling, ftRoots,
     ftRootsListChanged, ftServerInitiatedRequests, ftHttpSse, ftHttpGetStream,
     ftHttpResumability, ftJsonRpcBatch, ftAuthorization, ftToolAnnotations,
     ftAudioContent, ftProgressMessage, ftStructuredToolOutput, ftResourceLinks,
     ftElicitation, ftTitleFields, ftCompletionContext,
     ftProtectedResourceMetadata, ftTasks, ftIcons, ftUrlElicitation,
     ftSamplingTools, ftClientIdMetadataDocuments, ftSubscriptionsListen,
     ftParameterHeaders, ftExtensions, ftCompletionsCapability,
     ftDynamicClientRegistration, ftAuthorizationServerMetadata,
     ftResourceIndicators, ftOidcDiscovery, ftIncrementalScopeConsent,
     ftEnumSchemas, ftElicitationDefaults, ftSsePolling,
     ftImplementationDescription, ftJsonSchema2020, ftTraceContext,
     ftIssuerParameter, ftResourceNotFoundInvalidParams:
    notYet()
