## Which features of the table in `features.nim` this tree implements.
##
## `features.nim` says what a version of the protocol contains; this says how
## much of that the SDK does. Generated documentation reads both, so it never
## calls a feature usable that is not.
##
## A feature is `isImplemented` only when a test names it: `evidence` lists
## test files (relative to the repository root) that exercise it, and
## `tests/internal/test_docs_version.nim` checks that they exist. The `case` has no
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

func implementationOf*(feature: McpFeature): Implementation {.raises: [].} =
  case feature
  of ftInitializeHandshake:
    done("tests/external/test_legacy_handshake.nim", "tests/external/test_era_matrix.nim")
  of ftPing:
    done("tests/external/test_era_matrix.nim")
  of ftTools:
    done("tests/external/test_era_matrix.nim", "tests/external/test_stdio.nim",
         "tests/external/test_streamable_http.nim")
  of ftStdio:
    done("tests/external/test_stdio.nim")
  of ftStreamableHttp:
    done("tests/external/test_streamable_http.nim")
  of ftHttpSessions:
    done("tests/external/test_streamable_http.nim", "tests/external/test_http_streams.nim",
         "tests/external/test_http_client_streams.nim")
  of ftProtocolVersionHeader:
    done("tests/external/test_http_streams.nim")
  of ftPerRequestMetadata:
    done("tests/external/test_modern_protocol.nim", "tests/external/test_era_matrix.nim")
  of ftDiscover:
    done("tests/external/test_era_matrix.nim")
  of ftResultType:
    done("tests/external/test_modern_protocol.nim", "tests/external/test_era_matrix.nim")
  of ftCacheHints:
    done("tests/external/test_modern_protocol.nim")
  of ftParameterHeaders:
    done("tests/external/test_param_headers.nim", "tests/external/test_param_headers_http.nim")
  of ftMirroredHeaders:
    done("tests/external/test_modern_protocol.nim", "tests/external/test_streamable_http.nim")
  of ftResources:
    done("tests/external/test_server_errors.nim", "tests/external/test_server_pagination.nim",
         "tests/external/test_server_resources_prompts.nim", "tests/external/test_client_operations.nim")
  of ftResourceTemplates:
    done("tests/external/test_server_pagination.nim", "tests/external/test_client_operations.nim")
  of ftResourceSubscribe:
    done("tests/external/test_server_notifications.nim", "tests/external/test_client_operations.nim")
  of ftResourceNotFoundInvalidParams:
    done("tests/external/test_server_errors.nim")
  of ftPrompts:
    done("tests/external/test_server_pagination.nim", "tests/external/test_server_resources_prompts.nim",
         "tests/external/test_client_operations.nim")
  of ftPagination:
    done("tests/external/test_server_pagination.nim", "tests/external/test_client_operations.nim")
  of ftCompletion, ftCompletionContext, ftCompletionsCapability:
    done("tests/external/test_server_completion.nim", "tests/external/test_client_operations.nim")
  of ftLogging, ftLoggingSetLevel:
    done("tests/external/test_server_logging.nim", "tests/external/test_client_operations.nim")
  of ftProgress, ftProgressMessage:
    done("tests/external/test_server_progress_cancel.nim", "tests/external/test_client_requests.nim")
  of ftCancellation:
    done("tests/external/test_server_progress_cancel.nim", "tests/external/test_client_requests.nim",
         "tests/external/test_http_streams.nim")
  of ftSampling, ftRoots, ftServerInitiatedRequests:
    done("tests/external/test_server_requests.nim", "tests/external/test_client_server_requests.nim")
  of ftRootsListChanged:
    done("tests/external/test_client_server_requests.nim")
  of ftHttpSse:
    done("tests/external/test_http_sse_legacy.nim")
  of ftHttpGetStream, ftHttpResumability, ftSsePolling:
    done("tests/external/test_http_streams.nim", "tests/external/test_http_client_streams.nim")
  of ftJsonRpcBatch:
    done("tests/external/test_http_streams.nim")
  of ftAuthorization:
    done("tests/external/test_auth_client_flow.nim", "tests/external/test_auth_resource_server.nim",
         "tests/external/test_auth_http_methods.nim", "tests/external/test_auth_oauth_basics.nim")
  of ftProtectedResourceMetadata, ftIncrementalScopeConsent:
    done("tests/external/test_auth_client_flow.nim", "tests/external/test_auth_resource_server.nim")
  of ftAuthorizationServerMetadata, ftOidcDiscovery:
    done("tests/external/test_auth_oauth_basics.nim", "tests/external/test_auth_client_flow.nim")
  of ftDynamicClientRegistration, ftClientIdMetadataDocuments,
     ftAuthDefaultEndpoints, ftResourceIndicators, ftIssuerParameter:
    done("tests/external/test_auth_client_flow.nim")
  of ftToolAnnotations:
    done("tests/external/test_tool_annotations.nim")
  of ftAudioContent:
    done("tests/external/test_audio_content.nim")
  of ftIcons:
    done("tests/external/test_icons.nim", "tests/external/test_icon_fetch.nim", "tests/external/test_implementation_info.nim")
  of ftTitleFields:
    done("tests/external/test_title_fields.nim", "tests/external/test_implementation_info.nim")
  of ftImplementationDescription:
    done("tests/external/test_implementation_info.nim")
  of ftResourceLinks:
    done("tests/external/test_resource_links.nim")
  of ftStructuredToolOutput:
    done("tests/external/test_structured_tool_output.nim")
  of ftJsonSchema2020:
    done("tests/external/test_json_schema.nim", "tests/external/test_structured_tool_output.nim")
  of ftElicitation:
    done("tests/external/test_elicitation_payload.nim", "tests/external/test_server_elicitation.nim",
         "tests/external/test_client_elicitation.nim")
  of ftEnumSchemas, ftElicitationDefaults, ftUrlElicitation:
    done("tests/external/test_elicitation_payload.nim", "tests/external/test_server_elicitation.nim",
         "tests/external/test_client_elicitation.nim")
  of ftSamplingTools:
    done("tests/external/test_sampling_tools_payload.nim", "tests/external/test_server_sampling_tools.nim",
         "tests/external/test_client_sampling_tools.nim")
  of ftToolInputErrors:
    done("tests/external/test_tool_input_validation.nim")
  of ftTasks:
    done("tests/external/test_tasks_store.nim", "tests/external/test_tasks_server.nim",
         "tests/external/test_tasks_client.nim", "tests/external/test_tasks_end_to_end.nim",
         "tests/external/test_tasks_http.nim", "tests/external/test_tasks_principal.nim")
  of ftMultiRoundTripRequests:
    done("tests/external/test_mrtr.nim")
  of ftTraceContext:
    done("tests/external/test_trace_context.nim")
  of ftExtensions:
    done("tests/external/test_extensions.nim")
  of ftSubscriptionsListen:
    done("tests/external/test_subscriptions.nim")
