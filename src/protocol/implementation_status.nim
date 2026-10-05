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
    done("tests/test_streamable_http.nim", "tests/test_http_streams.nim",
         "tests/test_http_client_streams.nim")
  of ftProtocolVersionHeader:
    done("tests/test_http_streams.nim")
  of ftPerRequestMetadata:
    done("tests/test_modern_protocol.nim", "tests/test_era_matrix.nim")
  of ftDiscover:
    done("tests/test_era_matrix.nim")
  of ftResultType:
    done("tests/test_modern_protocol.nim", "tests/test_era_matrix.nim")
  of ftCacheHints:
    done("tests/test_modern_protocol.nim")
  of ftParameterHeaders:
    done("tests/test_param_headers.nim", "tests/test_param_headers_http.nim")
  of ftMirroredHeaders:
    done("tests/test_modern_protocol.nim", "tests/test_streamable_http.nim")
  of ftResources:
    done("tests/test_server_errors.nim", "tests/test_server_pagination.nim",
         "tests/test_server_resources_prompts.nim", "tests/test_client_operations.nim")
  of ftResourceTemplates:
    done("tests/test_server_pagination.nim", "tests/test_client_operations.nim")
  of ftResourceSubscribe:
    done("tests/test_server_notifications.nim", "tests/test_client_operations.nim")
  of ftResourceNotFoundInvalidParams:
    done("tests/test_server_errors.nim")
  of ftPrompts:
    done("tests/test_server_pagination.nim", "tests/test_server_resources_prompts.nim",
         "tests/test_client_operations.nim")
  of ftPagination:
    done("tests/test_server_pagination.nim", "tests/test_client_operations.nim")
  of ftCompletion, ftCompletionContext, ftCompletionsCapability:
    done("tests/test_server_completion.nim", "tests/test_client_operations.nim")
  of ftLogging, ftLoggingSetLevel:
    done("tests/test_server_logging.nim", "tests/test_client_operations.nim")
  of ftProgress, ftProgressMessage:
    done("tests/test_server_progress_cancel.nim", "tests/test_client_requests.nim")
  of ftCancellation:
    done("tests/test_server_progress_cancel.nim", "tests/test_client_requests.nim",
         "tests/test_http_streams.nim")
  of ftSampling, ftRoots, ftServerInitiatedRequests:
    done("tests/test_server_requests.nim", "tests/test_client_server_requests.nim")
  of ftRootsListChanged:
    done("tests/test_client_server_requests.nim")
  of ftHttpSse:
    done("tests/test_http_sse_legacy.nim")
  of ftHttpGetStream, ftHttpResumability, ftSsePolling:
    done("tests/test_http_streams.nim", "tests/test_http_client_streams.nim")
  of ftJsonRpcBatch:
    done("tests/test_http_streams.nim")
  of ftAuthorization:
    done("tests/test_auth_client_flow.nim", "tests/test_auth_resource_server.nim",
         "tests/test_auth_http_methods.nim", "tests/test_auth_oauth_basics.nim")
  of ftProtectedResourceMetadata, ftIncrementalScopeConsent:
    done("tests/test_auth_client_flow.nim", "tests/test_auth_resource_server.nim")
  of ftAuthorizationServerMetadata, ftOidcDiscovery:
    done("tests/test_auth_oauth_basics.nim", "tests/test_auth_client_flow.nim")
  of ftDynamicClientRegistration, ftClientIdMetadataDocuments,
     ftAuthDefaultEndpoints, ftResourceIndicators, ftIssuerParameter:
    done("tests/test_auth_client_flow.nim")
  of ftJsonSchema2020:
    done("tests/test_json_schema.nim")
  of ftMultiRoundTripRequests:
    notYet("the client raises on an input_required result")
  of ftToolAnnotations, ftAudioContent, ftStructuredToolOutput, ftResourceLinks,
     ftElicitation, ftTitleFields, ftTasks, ftIcons, ftUrlElicitation,
     ftSamplingTools, ftSubscriptionsListen, ftExtensions,
     ftEnumSchemas, ftElicitationDefaults, ftImplementationDescription,
     ftTraceContext:
    notYet()
