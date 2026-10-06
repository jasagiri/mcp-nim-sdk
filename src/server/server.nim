## MCP server implementation

import std/[asyncdispatch, json, options, sequtils, sets, strutils, tables]
import ../protocol/types
import ../protocol/diagnostic
import ../protocol/lifecycle
import ../protocol/modern
import ../protocol/param_headers
import ../protocol/features
import ../protocol/content
import ../jsonschema/json_schema
import ../protocol/log_level
import ../protocol/sampling_tools
import ../protocol/trace_context
import ../protocol/extensions
import ../protocol/mrtr
import ../protocol/subscriptions
import ./subscriptions
import ../transport/transport
import ./errors
import ./pagination
import ./completion
import ../protocol/tasks

export errors, pagination, completion, log_level, sampling_tools, trace_context

const
  DefaultRequestTimeoutMs* = 60_000
    ## How long a request of the server waits for the client's answer.

type
  McpSession* = ref object
    ## The state of one client of the versions before 2026-07-28.
    state*: McpLifecycleState
    negotiatedVersion*: Option[McpProtocolVersion]
      ## The version agreed in the initialize handshake.
    clientCapabilities*: Option[McpClientCapabilities]
    clientInfo*: Option[McpClientInfo]
      ## Who the client said it is in the initialize request.
    subscriptions*: HashSet[string]
      ## The URIs of the resources this client subscribed to.
    logLevel*: Option[McpLogLevel]
      ## What `logging/setLevel` asked for; none until it is sent, and the
      ## server then sends every message.

  McpRequestContext* = ref object
    ## What a handler knows about the request it serves, and how it reports
    ## back while it works: progress, log messages, requests to the client.
    server*: McpServer
    session*: string
      ## The connection the request arrived on; empty on stdio and, in
      ## 2026-07-28, on every transport.
    requestId*: string
    principal*: Option[string]
      ## Who the transport's authorization says sent the request (the subject
      ## of the access token); none without authorization.
    idNode*: JsonNode
      ## The id as the client wrote it (a string or a number); nil for a
      ## request built without one. What a stream of the request repeats as
      ## its subscription id.
    version*: McpProtocolVersion
      ## The version this request is served in.
    progressToken: JsonNode
      ## nil when the client did not ask for progress.
    logLevel*: Option[McpLogLevel]
      ## 2026-07-28: the level the request asked for in its `_meta`.
    clientCapabilities*: JsonNode
      ## 2026-07-28: what the request declared in its `_meta`; nil in
      ## earlier versions.
    meta*: JsonNode
      ## The request's `_meta` object as it arrived, in every version; nil
      ## when the request had none. For extensions that select behaviour by
      ## an `_meta` key of their own; treat it as untrusted input.
    inputResponses*: JsonNode
      ## 2026-07-28, on a retry of a request that was answered with
      ## `input_required`: the client's responses, key -> result object.
      ## An empty object on a first attempt.
    requestState*: Option[string]
      ## 2026-07-28, on such a retry: the state the server sent, which the
      ## client is to echo and the server must treat as untrusted input.
    traceContext*: TraceContext
      ## 2026-07-28: the trace context the request carried in its `_meta`;
      ## empty when it carried none. What the server sends for this request
      ## carries it too.
    lastProgress: float
    progressSent: bool
    cancellable: bool
    cancelled*: bool
    cancelReason*: string
    cancelSignal: Future[void]
    finished: bool
    taskScope*: TaskScope
      ## Set while the request runs as a task (2025-11-25).

  TaskScope* = ref object
    ## What ties a request that runs as a task to its task: what it asks of
    ## the client is marked as belonging to the task, and the task needs input
    ## while the client has not answered.
    taskId*: string
    awaitingInput*: proc(waiting: bool) {.closure.}
      ## Called with true when the first request to the client goes out and
      ## with false when the last one is answered.
    resultStream*: proc(): string {.closure.}
      ## The id of the `tasks/result` request that waits on the task, or "".
    inputsOpen: int

  RequestInterceptor* = proc(ctx: McpRequestContext,
                             request: JsonRpcRequest): Future[Option[JsonRpcResponse]] {.async.}
    ## Looks at a request before the server's own handling of it. Some answer
    ## ends the matter; none lets the server carry on. Raise
    ## `McpRequestError` for a JSON-RPC error.

  ResponseFilter* = proc(ctx: McpRequestContext, request: JsonRpcRequest,
                         response: JsonRpcResponse): Future[JsonRpcResponse] {.async.}
    ## Looks at the answer to a request of the standard methods, after the
    ## server's own handling and before the answer is completed for the wire.
    ## Returns the answer to give instead (the same one to leave it). Only
    ## results pass through; an error answer is not filtered. Raise
    ## `McpRequestError` for a JSON-RPC error.

  ListScope* = proc(ctx: McpRequestContext, methodName: string): ListHandler
    ## Chooses the list handler that serves one request of `tools/list`,
    ## `resources/list`, `resources/templates/list` or `prompts/list`; nil
    ## leaves the request to the handler registered with `onToolsList` and
    ## its siblings. The choice also decides what the input of a `tools/call`
    ## is validated against.

  ToolCallHandler* = proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.}
    ## Returns the CallToolResult. Raise `newUnknownTool(name)` for a tool
    ## that does not exist (a JSON-RPC error) and `newToolFailure(message)`
    ## when the tool ran and failed (a result with `isError: true`).

  ResourceReadHandler* = proc(ctx: McpRequestContext,
                              uri: string): Future[seq[JsonNode]] {.async.}
    ## Returns the `contents` of the result. Raise `newResourceNotFound(uri)`
    ## for a resource that does not exist.

  PromptGetHandler* = proc(ctx: McpRequestContext, name: string,
                           arguments: JsonNode): Future[JsonNode] {.async.}
    ## Returns the GetPromptResult. Raise `newInvalidParams` for an unknown
    ## prompt or a missing argument.

  CompletionHandler* = proc(ctx: McpRequestContext,
                            request: McpCompletionRequest): Future[McpCompletion] {.async.}

  ToolListTransform* = proc(ctx: McpRequestContext, tool: JsonNode): JsonNode
    ## Rewrites one tool definition for the client of the request that lists
    ## it, e.g. to leave out what that client did not declare support for.

  ListenFilterHook* = proc(ctx: McpRequestContext, requested: SubscriptionFilter,
                           honored: var SubscriptionFilter) {.closure.}
    ## How an extension takes part in `subscriptions/listen`: it sees what the
    ## client asked for and may add to what the server agrees to (the filter
    ## keys the core does not know are the extension'"'"'s), or raise
    ## `McpRequestError` to refuse the request.

  ExtensionMethodHandler* = proc(ctx: McpRequestContext,
                                 params: JsonNode): Future[JsonNode] {.async.}
    ## Returns the result object of an extension's request. It may set its
    ## own `resultType` when the extension declared that type.

  ExtensionMethod* = object
    extensionId*: string
    handler*: ExtensionMethodHandler
    servedUndeclared*: bool
      ## The extension asks no declaration of the client, so the method is
      ## served to any client.

  SubscriptionHandler* = proc(ctx: McpRequestContext, uri: string): Future[void] {.async.}
    ## Called when a client subscribes to, or unsubscribes from, `uri`; the
    ## server keeps the subscriptions itself.

  McpServer* = ref object
    sessions: Table[string, McpSession]
      ## Keyed by the transport's session; "" is the only one on stdio.
    protocolVersion*: McpProtocolVersion
      ## The newest version this server speaks; it also speaks every
      ## earlier one.
    serverInfo*: McpServerInfo
    instructions*: string
      ## How to use this server; sent with server/discover when not empty.
    cachePolicy*: CachePolicy
      ## What 2026-07-28 clients are told about reusing list and read
      ## results. The default tells them not to.
    capabilities*: McpServerCapabilities
    transport*: McpTransport
    toolsList: ListHandler
    toolCall: ToolCallHandler
    resourcesList: ListHandler
    resourceTemplatesList: ListHandler
    resourceRead: ResourceReadHandler
    resourceSubscribe: SubscriptionHandler
    resourceUnsubscribe: SubscriptionHandler
    promptsList: ListHandler
    promptGet: PromptGetHandler
    completer: CompletionHandler
    subscriptions*: SubscriptionRegistry
      ## The open `subscriptions/listen` requests (2026-07-28).
    extensionMethods*: Table[string, ExtensionMethod]
      ## The methods extensions define, by method name; see `registerExtensionMethod`.
    legacyExtensions*: seq[string]
      ## The extensions registered with `onLegacyHandshake`: the only ones
      ## announced in the `initialize` result of a version before 2026-07-28.
    extensionResultTypes*: Table[string, string]
      ## The result types extensions define, mapped to the extension.
    interceptors: seq[RequestInterceptor]
    toolListTransforms: seq[ToolListTransform]
    listenFilterHooks: seq[ListenFilterHook]
    responseFilters: seq[ResponseFilter]
    listScope: ListScope
    requestHandlers*: Table[string, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}]
    notificationHandlers*: Table[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]
    inFlight: Table[string, McpRequestContext]
      ## The requests being served, by session and id.
    pending: Table[string, Future[JsonRpcResponse]]
      ## The requests of this server awaiting the client's response.
    nextRequestNumber: int
    holdForTask*: proc(taskId: string, request: JsonRpcRequest): bool {.closure.}
      ## Asked before a request that belongs to a task goes out while no
      ## `tasks/result` request waits on that task. True: the request is held
      ## and will be sent with `sendHeld` (2025-11-25: `enableTasks` sets it).
      ## It raises to refuse the request.
    lastTransportError*: ref CatchableError
      ## Set when the message-processing loop terminates due to a transport
      ## error. `nil` if the loop has not yet ended (or ended cleanly). Lets
      ## callers detect "silent dead" conditions instead of relying on an
      ## asyncCheck'd future that completes with no signal.

  McpResourceHandlers* = object
    ## The context-free handlers of `setResourceHandlers`.
    listHandler*: Option[proc(): Future[seq[JsonNode]] {.async.}]
    readHandler*: Option[proc(uri: string): Future[JsonNode] {.async.}]
    listTemplatesHandler*: Option[proc(): Future[seq[JsonNode]] {.async.}]
    subscribeHandler*: Option[proc(uri: string): Future[void] {.async.}]
    unsubscribeHandler*: Option[proc(uri: string): Future[void] {.async.}]

  McpToolHandlers* = object
    ## The context-free handlers of `setToolHandlers`.
    listHandler*: Option[proc(): Future[seq[JsonNode]] {.async.}]
    callHandler*: Option[proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.}]

  McpPromptHandlers* = object
    ## The context-free handlers of `setPromptHandlers`.
    listHandler*: Option[proc(): Future[seq[JsonNode]] {.async.}]
    getHandler*: Option[proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.}]

# Forward declarations
proc registerRequestHandler*(server: McpServer, methodName: string,
    handler: proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.})
proc registerNotificationHandler*(server: McpServer, methodName: string,
    handler: proc(notification: JsonRpcNotification): Future[void] {.async.})
proc handleInitialize(server: McpServer, request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}
proc handleInitialized(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.}
proc handleCancelled(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.}
proc extractClientCapabilities(json: JsonNode): McpClientCapabilities

proc newMcpServer*(
  serverInfo: McpServerInfo,
  protocolVersion: McpProtocolVersion = DefaultProtocolVersion,
  capabilities: McpServerCapabilities = McpServerCapabilities()
): McpServer =
  requireSupported(protocolVersion)
  let server = McpServer(
    sessions: initTable[string, McpSession](),
    protocolVersion: protocolVersion,
    serverInfo: serverInfo,
    cachePolicy: UncachedPolicy,
    capabilities: capabilities,
    extensionMethods: initTable[string, ExtensionMethod](),
    extensionResultTypes: initTable[string, string](),
    requestHandlers: initTable[string, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}](),
    notificationHandlers: initTable[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]()
  )

  # Register built-in request handlers
  server.registerRequestHandler("initialize", proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
    return await server.handleInitialize(request)
  )

  server.registerRequestHandler("ping", proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
    return createPingResponse(request.id)
  )

  # Register built-in notification handlers
  server.registerNotificationHandler("notifications/initialized", proc(notification: JsonRpcNotification): Future[void] {.async.} =
    await server.handleInitialized(notification)
  )

  server.registerNotificationHandler("notifications/cancelled", proc(notification: JsonRpcNotification): Future[void] {.async.} =
    await server.handleCancelled(notification)
  )

  return server

proc session*(server: McpServer, id = ""): McpSession =
  ## The handshake state of the client on session `id`; a client that has
  ## not sent initialize is uninitialized.
  server.sessions.getOrDefault(id, McpSession(state: mlsUninitialized))

proc state*(server: McpServer): McpLifecycleState =
  ## The state of the single client of a single-peer transport such as stdio.
  server.session().state

proc negotiatedVersion*(server: McpServer): Option[McpProtocolVersion] =
  server.session().negotiatedVersion

proc clientCapabilities*(server: McpServer): Option[McpClientCapabilities] =
  server.session().clientCapabilities

proc sessionCount*(server: McpServer): int =
  server.sessions.len

func inFlightKey(session, id: string): string =
  session & '\x00' & id

proc failPending(server: McpServer, session: Option[string], reason: ref CatchableError) =
  ## Fail the requests of this server that await an answer from `session`
  ## (every session when none is named): that answer will never come.
  var keys: seq[string]
  for key in server.pending.keys:
    if session.isNone or key.startsWith(session.get & '\x00'):
      keys.add key
  for key in keys:
    let waiting = server.pending[key]
    server.pending.del(key)
    waiting.fail(reason)

proc cancelRequest*(server: McpServer, session, requestId: string,
                    reason = ""): bool =
  ## Stop waiting for the handler of request `requestId` on `session`: its
  ## response will not be sent. A handler that is running cannot be
  ## interrupted; it sees `ctx.cancelled` and `whenCancelled`. False when the
  ## request is unknown, already answered, or cannot be cancelled
  ## (`initialize`).
  let key = inFlightKey(session, requestId)
  if key notin server.inFlight:
    return false
  let ctx = server.inFlight[key]
  if ctx.cancelled or ctx.finished or not ctx.cancellable:
    return false
  ctx.cancelled = true
  ctx.cancelReason = reason
  ctx.cancelSignal.complete()
  true

proc cancelSession(server: McpServer, session: string) =
  ## The session is over: whatever it still has in flight is moot.
  var ids: seq[string]
  for ctx in server.inFlight.values:
    if ctx.session == session:
      ids.add ctx.requestId
  for id in ids:
    discard server.cancelRequest(session, id, "session ended")
  server.failPending(some(session), newException(McpTransportClosedError,
    "session " & session & " ended before the client answered"))

proc endSession*(server: McpServer, id: string) =
  ## Forget the client on session `id`.
  server.cancelSession(id)
  server.sessions.del(id)

proc registerRequestHandler*(server: McpServer, methodName: string,
    handler: proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}) =
  server.requestHandlers[methodName] = handler

proc registerNotificationHandler*(server: McpServer, methodName: string,
    handler: proc(notification: JsonRpcNotification): Future[void] {.async.}) =
  server.notificationHandlers[methodName] = handler

proc addListenFilterHook*(server: McpServer, hook: ListenFilterHook) =
  ## Hooks run in the order they were added, for every `subscriptions/listen`.
  server.listenFilterHooks.add hook

proc addRequestInterceptor*(server: McpServer, interceptor: RequestInterceptor) =
  ## Interceptors see every request of the standard methods, in the order
  ## they were added, before the server's own handling.
  server.interceptors.add interceptor

proc addResponseFilter*(server: McpServer, filter: ResponseFilter) =
  ## Filters see the result of every request of the standard methods, in the
  ## order they were added, once the server has handled it.
  server.responseFilters.add filter

proc onListScope*(server: McpServer, scope: ListScope) =
  ## Replaces the scope; there is one per server.
  server.listScope = scope

# Handlers of the standard methods

proc addToolListTransform*(server: McpServer, transform: ToolListTransform) =
  ## Every tool of a `tools/list` answer goes through the transforms, in the
  ## order they were added, before it is shaped for the client's version.
  server.toolListTransforms.add transform

proc onToolsList*(server: McpServer, handler: ListHandler) =
  server.toolsList = handler

proc onToolCall*(server: McpServer, handler: ToolCallHandler) =
  server.toolCall = handler

proc onResourcesList*(server: McpServer, handler: ListHandler) =
  server.resourcesList = handler

proc onResourceTemplatesList*(server: McpServer, handler: ListHandler) =
  ## Without one, `resources/templates/list` answers with no templates.
  server.resourceTemplatesList = handler

proc onResourceRead*(server: McpServer, handler: ResourceReadHandler) =
  server.resourceRead = handler

proc onResourceSubscribe*(server: McpServer, handler: SubscriptionHandler) =
  server.resourceSubscribe = handler

proc onResourceUnsubscribe*(server: McpServer, handler: SubscriptionHandler) =
  server.resourceUnsubscribe = handler

proc onPromptsList*(server: McpServer, handler: ListHandler) =
  server.promptsList = handler

proc onPromptGet*(server: McpServer, handler: PromptGetHandler) =
  server.promptGet = handler

proc onComplete*(server: McpServer, handler: CompletionHandler) =
  server.completer = handler

proc setToolHandlers*(server: McpServer, handlers: McpToolHandlers) =
  ## The handlers of a server that needs no context: whole lists, no
  ## pagination. Replaces every tool handler.
  server.toolsList = nil
  server.toolCall = nil
  if handlers.listHandler.isSome:
    server.toolsList = pagedList(handlers.listHandler.get, 0)
  if handlers.callHandler.isSome:
    let call = handlers.callHandler.get
    server.toolCall = proc(ctx: McpRequestContext, name: string,
                           arguments: JsonNode): Future[JsonNode] {.async.} =
      return await call(name, arguments)

proc setResourceHandlers*(server: McpServer, handlers: McpResourceHandlers) =
  ## The handlers of a server that needs no context. `readHandler` returns
  ## one content. Replaces every resource handler.
  server.resourcesList = nil
  server.resourceTemplatesList = nil
  server.resourceRead = nil
  server.resourceSubscribe = nil
  server.resourceUnsubscribe = nil
  if handlers.listHandler.isSome:
    server.resourcesList = pagedList(handlers.listHandler.get, 0)
  if handlers.listTemplatesHandler.isSome:
    server.resourceTemplatesList = pagedList(handlers.listTemplatesHandler.get, 0)
  if handlers.readHandler.isSome:
    let read = handlers.readHandler.get
    server.resourceRead = proc(ctx: McpRequestContext,
                               uri: string): Future[seq[JsonNode]] {.async.} =
      return @[await read(uri)]
  if handlers.subscribeHandler.isSome:
    let subscribe = handlers.subscribeHandler.get
    server.resourceSubscribe = proc(ctx: McpRequestContext, uri: string): Future[void] {.async.} =
      await subscribe(uri)
  if handlers.unsubscribeHandler.isSome:
    let unsubscribe = handlers.unsubscribeHandler.get
    server.resourceUnsubscribe = proc(ctx: McpRequestContext, uri: string): Future[void] {.async.} =
      await unsubscribe(uri)

proc setPromptHandlers*(server: McpServer, handlers: McpPromptHandlers) =
  ## The handlers of a server that needs no context. Replaces every prompt
  ## handler.
  server.promptsList = nil
  server.promptGet = nil
  if handlers.listHandler.isSome:
    server.promptsList = pagedList(handlers.listHandler.get, 0)
  if handlers.getHandler.isSome:
    let get = handlers.getHandler.get
    server.promptGet = proc(ctx: McpRequestContext, name: string,
                            arguments: JsonNode): Future[JsonNode] {.async.} =
      return await get(name, arguments)

# The handshake of the versions before 2026-07-28

proc handleInitialize(server: McpServer, request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
  if server.session(request.session).state != mlsUninitialized:
    return newJsonRpcErrorResponse(
      request.id,
      -32600,
      "Server already initialized"
    )
  
  let params = request.params
  if params.isNil or params.kind != JObject or
     not params.hasKey("protocolVersion") or
     params["protocolVersion"].kind != JString:
    return newJsonRpcErrorResponse(
      request.id,
      -32602,
      "initialize requires a string protocolVersion"
    )

  let requested = params["protocolVersion"].getStr()
  let supported = spokenVersionsUpTo(server.protocolVersion)
  let negotiated = negotiateLegacyVersion(requested, supported)
  if negotiated.isNone:
    var supportedJson = newJArray()
    for v in supported:
      supportedJson.add %($v)
    return newJsonRpcErrorResponse(
      request.id,
      -32022,
      "Unsupported protocol version",
      %*{"supported": supportedJson, "requested": requested}
    )

  let clientCapabilities =
    if params.hasKey("capabilities") and params["capabilities"].kind == JObject:
      extractClientCapabilities(params["capabilities"])
    else:
      McpClientCapabilities()
  var clientInfo = none(McpClientInfo)
  if params.hasKey("clientInfo"):
    try:
      clientInfo = some(parseClientInfo(params["clientInfo"]))
    except McpShapeError as e:
      return newJsonRpcErrorResponse(request.id, ErrInvalidParams,
        "initialize: clientInfo: " & e.msg)
  server.sessions[request.session] = McpSession(
    state: mlsInitializing,
    negotiatedVersion: negotiated,
    clientCapabilities: some(clientCapabilities),
    clientInfo: clientInfo)
  
  # Create response
  return createInitializeResponse(
    request.id,
    server.serverInfo,
    negotiated.get,
    server.capabilities.forVersion(negotiated.get, server.legacyExtensions)
  )

proc handleInitialized(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.} =
  let session = server.session(notification.session)
  if session.state != mlsInitializing:
    stderr.writeLine("[mcp-server] initialized notification in state " &
                      $session.state & " ignored")
    return

  session.state = mlsOperational

proc handleCancelled(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.} =
  # An invalid notification is ignored, as the specification asks; the
  # diagnostic is for whoever debugs the client.
  let node = notification.params{"requestId"}
  let requestId =
    if node.isNil: none(string)
    elif node.kind == JString: some(node.getStr())
    elif node.kind == JInt: some($node.getInt())
    else: none(string)
  if requestId.isNone:
    stderr.writeLine("[mcp-server] notifications/cancelled without a usable requestId ignored")
    return
  let reasonNode = notification.params{"reason"}
  let reason = if reasonNode.isNil or reasonNode.kind != JString: "" else: reasonNode.getStr()
  if server.cancelRequest(notification.session, requestId.get, reason):
    stderr.writeLine("[mcp-server] request " & peerText(requestId.get) &
                     " cancelled by the client" &
                     (if reason.len > 0: ": " & peerText(reason) else: ""))

proc extractClientCapabilities(json: JsonNode): McpClientCapabilities =
  result = McpClientCapabilities()
  
  # A peer that sends null for a capability has not declared it.
  let rootsJson = json{"roots"}
  if not rootsJson.isNil and rootsJson.kind == JObject:
    result.roots = some(McpRootsCapability(
      listChanged: rootsJson{"listChanged"}.getBool()
    ))

  let samplingJson = json{"sampling"}
  if not samplingJson.isNil and samplingJson.kind == JObject:
    result.sampling = some(McpSamplingCapability(
      tools: samplingJson.hasKey("tools") and samplingJson["tools"].kind == JObject,
      context: samplingJson.hasKey("context") and samplingJson["context"].kind == JObject))

  let elicitationJson = json{"elicitation"}
  if not elicitationJson.isNil and elicitationJson.kind == JObject:
    result.elicitation = some(elicitationJson.fromJson(McpElicitationCapability))

  result.tasks = tasksCapabilityFromJson(json{"tasks"})

  let experimentalJson = json{"experimental"}
  if not experimentalJson.isNil and experimentalJson.kind == JObject:
    result.experimental = some(experimentalJson)

  let extensionsJson = json{"extensions"}
  if not extensionsJson.isNil and extensionsJson.kind == JObject:
    result.extensions = some(extensionsJson)

# Request context

proc legacyVersionOf(server: McpServer, session: string): McpProtocolVersion =
  ## The version of a client that has handshaken; a client that has not is
  ## served as the newest legacy version this server speaks.
  let known = server.sessions.getOrDefault(session)
  if not known.isNil and known.negotiatedVersion.isSome:
    known.negotiatedVersion.get
  else:
    # A server that speaks no legacy version serves no request this way; the
    # context of one it is about to refuse still needs a version.
    latestLegacyVersion(spokenVersionsUpTo(server.protocolVersion)).get(server.protocolVersion)

func speaksLegacy(server: McpServer): bool =
  latestLegacyVersion(spokenVersionsUpTo(server.protocolVersion)).isSome

proc isModernPath(server: McpServer, request: JsonRpcRequest): bool =
  ## A request that names its own protocol version, or any request at all
  ## when the server speaks nothing older than 2026-07-28.
  isModern(server.protocolVersion) and
    (isModernRequest(request.params) or not server.speaksLegacy)

proc newContext(server: McpServer, request: JsonRpcRequest): McpRequestContext =
  ## The context of `request`. What the request's `_meta` gets wrong is
  ## reported by `metaRejection`, not here.
  let modernPath = server.isModernPath(request)
  let meta = request.params{"_meta"}
  let requested =
    if modernPath: parseProtocolVersion(meta{MetaProtocolVersion}.getStr()) else: none(McpProtocolVersion)
  result = McpRequestContext(
    server: server,
    session: request.session,
    requestId: request.id,
    principal: request.principal,
    idNode: request.idNode,
    version: requested.get(server.legacyVersionOf(request.session)),
    cancellable: request.`method` != "initialize",
    cancelSignal: newFuture[void]("McpRequestContext.cancelSignal"))
  if not meta.isNil and meta.kind == JObject:
    result.meta = meta
    let token = meta{"progressToken"}
    if not token.isNil and token.kind in {JString, JInt}:
      result.progressToken = token
    if modernPath:
      let level = meta{MetaLogLevel}
      if not level.isNil and level.kind == JString:
        result.logLevel = parseLogLevel(level.getStr())
      result.traceContext = traceContextOf(request.params)
      result.clientCapabilities = meta{MetaClientCapabilities}
      result.inputResponses = inputResponsesOf(request.params)
      result.requestState = requestStateOf(request.params)

proc metaRejection(request: JsonRpcRequest, version: McpProtocolVersion): Option[JsonRpcError] =
  ## Why the request's own `_meta` entries cannot be served.
  let meta = request.params{"_meta"}
  if meta.isNil or meta.kind != JObject:
    return none(JsonRpcError)
  let token = meta{"progressToken"}
  if not token.isNil and token.kind notin {JString, JInt}:
    return some(JsonRpcError(code: ErrInvalidParams,
      message: "_meta.progressToken must be a string or an integer"))
  if isModern(version):
    let level = meta{MetaLogLevel}
    if not level.isNil and (level.kind != JString or parseLogLevel(level.getStr()).isNone):
      return some(JsonRpcError(code: ErrInvalidParams,
        message: "_meta[\"" & MetaLogLevel & "\"] is not a log level"))
    return rejectInvalidTraceContext(request.params)
  none(JsonRpcError)

proc checkCancelled*(ctx: McpRequestContext) {.raises: [McpCancelled].} =
  ## For a handler that works in steps: stop once the client cancelled.
  if ctx.cancelled:
    raise newException(McpCancelled, "request " & ctx.requestId & " was cancelled")

proc completesWith[T](source: Future[T], target: Future[void]) =
  ## `or` on a future that others also wait on is unsafe: it replaces the
  ## callbacks those others registered. This adds one instead.
  source.addCallback(proc() =
    if not target.finished:
      target.complete())

proc whenCancelled*(ctx: McpRequestContext): Future[void] =
  ## A future that completes when the client cancels the request; for a
  ## handler to race its own work against.
  result = newFuture[void]("McpRequestContext.whenCancelled")
  ctx.cancelSignal.completesWith(result)

proc wantsProgress*(ctx: McpRequestContext): bool =
  not ctx.progressToken.isNil

proc relatedNotification(ctx: McpRequestContext, methodName: string, params: JsonNode): JsonRpcNotification =
  ## A notification that belongs to the request of `ctx`.
  result = newJsonRpcNotification(
    methodName, withTraceContext(params, ctx.traceContext))
  result.session = ctx.session
  result.relatedRequestId = ctx.requestId
  let scope = ctx.taskScope
  if not scope.isNil:
    # The request that started the task has ended with its CreateTaskResult:
    # what the task says goes to the `tasks/result` request waiting on it, or
    # else to the session's own stream.
    result.params = withRelatedTask(result.params, scope.taskId)
    result.relatedRequestId = scope.resultStream()

proc reportProgress*(ctx: McpRequestContext, progress: float,
                     total: Option[float] = none(float),
                     message = ""): Future[void] {.async.} =
  ## Tell the client how far the request has got. Nothing is sent when the
  ## client gave no progress token, and none once the request is answered or
  ## cancelled: the specification asks for exactly that. `progress` must
  ## grow with every call. `message` goes to clients of 2025-03-26 and later.
  if ctx.progressToken.isNil or ctx.finished or ctx.cancelled:
    return
  if ctx.progressSent and progress <= ctx.lastProgress:
    raise newException(ValueError, "progress must increase with every notification")
  ctx.progressSent = true
  ctx.lastProgress = progress
  var params = %*{"progressToken": ctx.progressToken, "progress": progress}
  if total.isSome:
    params["total"] = %total.get
  if message.len > 0 and ctx.version.has(ftProgressMessage):
    params["message"] = %message
  await ctx.server.transport.sendNotification(ctx.relatedNotification("notifications/progress", params))

func logParams(level: McpLogLevel, data: JsonNode, logger: string): JsonNode =
  result = %*{"level": $level, "data": data}
  if logger.len > 0:
    result["logger"] = %logger

proc log*(ctx: McpRequestContext, level: McpLogLevel, data: JsonNode,
          logger = ""): Future[void] {.async.} =
  ## Send a log message to the client of this request, when the client wants
  ## messages of this level: in 2026-07-28 when the request asked for a level
  ## in its `_meta` (the server must not log otherwise), before that when
  ## `logging/setLevel` allows it. Raises when the server has not declared
  ## the `logging` capability.
  if ctx.server.capabilities.logging.isNone:
    raise newException(McpCapabilityError,
      "the server must declare the logging capability to send log messages")
  if ctx.finished or ctx.cancelled:
    return
  let threshold =
    if isModern(ctx.version):
      ctx.logLevel
    else:
      ctx.server.sessions.getOrDefault(ctx.session, McpSession()).logLevel
  if isModern(ctx.version) and threshold.isNone:
    return
  if threshold.isSome and level < threshold.get:
    return
  await ctx.server.transport.sendNotification(
    ctx.relatedNotification("notifications/message", logParams(level, data, logger)))

# Requests of the server to the client (the versions before 2026-07-28)

proc request*(server: McpServer, session: string, methodName: string,
              params: JsonNode, relatedRequestId = "",
              timeoutMs = DefaultRequestTimeoutMs,
              relatedTask = ""): Future[JsonRpcResponse] {.async.} =
  ## Send a request to the client on `session` and wait for its response,
  ## which may carry a JSON-RPC error. Raises `McpCapabilityError` when there
  ## is no initialized client there or its version has no requests from the
  ## server, `McpRequestTimeout` when `timeoutMs` (0: no limit) passes first.
  ## A `relatedTask` marks the request as belonging to that task (2025-11-25).
  let known = server.sessions.getOrDefault(session)
  if known.isNil or known.state != mlsOperational:
    raise newException(McpCapabilityError,
      "no initialized client on session '" & session & "' to send " & methodName & " to")
  if not known.negotiatedVersion.get.has(ftServerInitiatedRequests):
    raise newException(McpCapabilityError,
      methodName & ": the server cannot send requests in protocol version " &
      $known.negotiatedVersion.get)
  inc server.nextRequestNumber
  let id = "srv-" & $server.nextRequestNumber
  let key = inFlightKey(session, id)
  let answer = newFuture[JsonRpcResponse]("McpServer.request")
  server.pending[key] = answer
  var outgoing = newJsonRpcRequest(id, methodName,
    if relatedTask.len > 0: withRelatedTask(params, relatedTask) else: params)
  outgoing.session = session
  outgoing.relatedRequestId = relatedRequestId
  try:
    let held = relatedTask.len > 0 and relatedRequestId.len == 0 and
               not server.holdForTask.isNil and server.holdForTask(relatedTask, outgoing)
    if not held:
      await server.transport.sendRequest(outgoing)
  except CatchableError:
    server.pending.del(key)
    raise
  if timeoutMs > 0 and not await answer.withTimeout(timeoutMs):
    server.pending.del(key)
    var cancelled = newJsonRpcNotification("notifications/cancelled",
      %*{"requestId": id, "reason": "timed out"})
    cancelled.session = session
    try:
      await server.transport.sendNotification(cancelled)
    except CatchableError as e:
      stderr.writeLine("[mcp-server] could not cancel timed out " & methodName &
                       ": " & peerText(e.msg))
    raise newException(McpRequestTimeout,
      "the client did not answer " & methodName & " within " & $timeoutMs & " ms")
  return await answer

proc sendHeld*(server: McpServer, request: JsonRpcRequest, streamRequestId: string) {.async.} =
  ## Send a request that `holdForTask` kept, on the stream of the
  ## `tasks/result` request `streamRequestId`. Its answer is awaited by the
  ## `request` call that made it.
  if inFlightKey(request.session, request.id) notin server.pending:
    return  # timed out while held: the requestor has been told so
  var outgoing = request
  outgoing.relatedRequestId = streamRequestId
  await server.transport.sendRequest(outgoing)

proc resultOf*(response: JsonRpcResponse, methodName: string): JsonNode =
  if response.error.isSome:
    let error = response.error.get
    var failure = newException(McpRemoteError, methodName & " failed: " & error.message)
    failure.code = error.code
    failure.data = error.data
    raise failure
  response.result.get(newJObject())

proc requireClientCapability(server: McpServer, session: string, name: string,
                             has: proc(c: McpClientCapabilities): bool) =
  let known = server.sessions.getOrDefault(session)
  if known.isNil or known.clientCapabilities.isNone or not has(known.clientCapabilities.get):
    raise newException(McpCapabilityError,
      "the client on session '" & session & "' did not declare the " & name & " capability")

proc ping*(server: McpServer, session = "", relatedRequestId = "",
           relatedTask = ""): Future[void] {.async.} =
  ## Check that the client on `session` is alive.
  discard resultOf(await server.request(session, "ping", newJObject(), relatedRequestId,
                                        relatedTask = relatedTask), "ping")

proc listRoots*(server: McpServer, session = "", relatedRequestId = "",
                relatedTask = ""): Future[seq[JsonNode]] {.async.} =
  ## The roots the client on `session` offers; needs its `roots` capability.
  server.requireClientCapability(session, "roots",
    proc(c: McpClientCapabilities): bool = c.roots.isSome)
  let answer = resultOf(await server.request(session, "roots/list", newJObject(),
                                             relatedRequestId, relatedTask = relatedTask),
                        "roots/list")
  let roots = answer{"roots"}
  if roots.isNil or roots.kind != JArray:
    raise newException(McpRemoteError, "roots/list: the result has no roots array")
  return roots.getElems()

proc createMessage*(server: McpServer, session: string, params: JsonNode,
                    relatedRequestId = "", relatedTask = ""): Future[JsonNode] {.async.} =
  ## Ask the client on `session` for an LLM completion (`sampling/createMessage`);
  ## `params` is the CreateMessageRequest. Needs its `sampling` capability.
  server.requireClientCapability(session, "sampling",
    proc(c: McpClientCapabilities): bool = c.sampling.isSome)
  let known = server.session(session)
  let version = known.negotiatedVersion.get
  let unavailable = samplingToolsUnavailable(params, version,
                                             known.clientCapabilities.get.sampling.get)
  if unavailable.isSome:
    raise newException(McpCapabilityError, "sampling/createMessage: " & unavailable.get)
  raiseIfAny("sampling/createMessage", createMessageParamsProblems(params, version))
  let answer = resultOf(await server.request(session, "sampling/createMessage", params,
                                             relatedRequestId, relatedTask = relatedTask),
                        "sampling/createMessage")
  if params.usesTools:
    # An answer to a request without tools is passed on as received.
    raiseIfAny("sampling/createMessage result",
               createMessageResultProblems(answer, params, version))
  return answer

type InputScope* = tuple[task, relatedRequestId: string]

proc beginInput*(ctx: McpRequestContext): InputScope =
  ## Where a request of the server to the client belongs. For a request that
  ## runs as a task: to the task, and to the `tasks/result` request waiting
  ## on it, if any; the task needs input until the client answers.
  let scope = ctx.taskScope
  if scope.isNil:
    return (task: "", relatedRequestId: ctx.requestId)
  inc scope.inputsOpen
  if scope.inputsOpen == 1:
    scope.awaitingInput(true)
  (task: scope.taskId, relatedRequestId: scope.resultStream())

proc endInput*(ctx: McpRequestContext) =
  let scope = ctx.taskScope
  if scope.isNil:
    return
  dec scope.inputsOpen
  if scope.inputsOpen == 0:
    scope.awaitingInput(false)

proc ping*(ctx: McpRequestContext): Future[void] {.async.} =
  let input = ctx.beginInput()
  try:
    await ctx.server.ping(ctx.session, input.relatedRequestId, input.task)
  finally:
    ctx.endInput()

proc listRoots*(ctx: McpRequestContext): Future[seq[JsonNode]] {.async.} =
  let input = ctx.beginInput()
  try:
    return await ctx.server.listRoots(ctx.session, input.relatedRequestId, input.task)
  finally:
    ctx.endInput()

proc createMessage*(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} =
  let input = ctx.beginInput()
  try:
    return await ctx.server.createMessage(ctx.session, params, input.relatedRequestId, input.task)
  finally:
    ctx.endInput()

proc resolveResponse(server: McpServer, session: string, response: JsonRpcResponse) =
  let key = inFlightKey(session, response.id)
  if key notin server.pending:
    stderr.writeLine("[mcp-server] response to unknown request id '" & peerText(response.id) & "' ignored")
    return
  let waiting = server.pending[key]
  server.pending.del(key)
  waiting.complete(response)

# Standard methods

proc notSupported(request: JsonRpcRequest): JsonRpcResponse =
  newJsonRpcErrorResponse(request.id, ErrMethodNotFound, "Method not supported")

proc stringParam(request: JsonRpcRequest, name: string): Option[string] =
  let node = request.params{name}
  if node.isNil or node.kind != JString: none(string) else: some(node.getStr())

proc missingParam(request: JsonRpcRequest, name: string): JsonRpcResponse =
  newJsonRpcErrorResponse(request.id, ErrInvalidParams,
    request.`method` & " requires a string " & name)

proc listPage(request: JsonRpcRequest, handler: ListHandler, key: string,
              version: McpProtocolVersion,
              forVersion: proc(version: McpProtocolVersion, item: JsonNode): JsonNode
             ): Future[JsonRpcResponse] {.async.} =
  let cursor = request.params{"cursor"}
  if not cursor.isNil and cursor.kind != JString:
    raise newInvalidParams("cursor must be a string")
  let page = await handler(if cursor.isNil: none(string) else: some(cursor.getStr()))
  var payload = newJObject()
  payload[key] = newJArray()
  for item in page.items:
    payload[key].add forVersion(version, item)
  if page.nextCursor.isSome:
    payload["nextCursor"] = %page.nextCursor.get
  return newJsonRpcResponse(request.id, payload)

proc withoutInvalidParamHeaders(response: JsonRpcResponse): JsonRpcResponse =
  ## A tool whose `x-mcp-header` declarations are invalid cannot be called
  ## over HTTP, and clients drop it; the server does not publish it. The
  ## handler's mistake is logged, not hidden.
  result = response
  if response.result.isNone:
    return
  let tools = response.result.get{"tools"}
  if tools.isNil or tools.kind != JArray:
    return
  var kept = newJArray()
  for tool in tools:
    let declared = declaredParamHeaders(tool{"inputSchema"})
    if declared.invalid.isSome:
      stderr.writeLine("[mcp-server] not listing tool '" & tool{"name"}.getStr() &
                       "': " & declared.invalid.get)
    else:
      kept.add tool
  response.result.get["tools"] = kept

proc toolFailureResult(message: string): JsonNode =
  %*{"content": [{"type": "text", "text": message}], "isError": true}

proc requireObjectResult(request: JsonRpcRequest, node: JsonNode): Option[JsonRpcResponse] =
  if node.isNil or node.kind != JObject:
    some(newJsonRpcErrorResponse(request.id, ErrInternal,
      "Handler for " & request.`method` & " returned a result that is not an object"))
  else:
    none(JsonRpcResponse)

const MaxToolListPages = 1000
  ## A handler that never stops issuing cursors must not hold a request.

proc scoped(server: McpServer, ctx: McpRequestContext, methodName: string,
            registered: ListHandler): ListHandler =
  ## The handler that serves `methodName` for this request.
  if server.listScope.isNil:
    return registered
  let chosen = server.listScope(ctx, methodName)
  if chosen.isNil: registered else: chosen

proc toolDefinition(server: McpServer, ctx: McpRequestContext,
                    name: string): Future[Option[JsonNode]] {.async.} =
  ## The entry the tool list publishes for `name`: what the server says about
  ## a tool is stated once, there. The list is read afresh: tools may change
  ## between calls.
  let toolsList = server.scoped(ctx, "tools/list", server.toolsList)
  if toolsList.isNil:
    return none(JsonNode)
  var cursor = none(string)
  for _ in 1 .. MaxToolListPages:
    let page = await toolsList(cursor)
    for tool in page.items:
      if tool{"name"}.getStr() == name:
        return some(tool)
    if page.nextCursor.isNone:
      return none(JsonNode)
    cursor = page.nextCursor
  stderr.writeLine("[mcp-server] tools/list of this server has more than " &
                   $MaxToolListPages & " pages; '" & name & "' was not found")
  none(JsonNode)

proc outputProblems(name: string, version: McpProtocolVersion, schema,
                    callResult: JsonNode): seq[string] =
  ## What is wrong with `callResult` under the `outputSchema` the server lists
  ## for the tool. "Servers MUST provide structured results that conform to
  ## this schema" (2025-06-18 and later, server/tools): a result that does not
  ## is the server's defect, and the client is told so instead of receiving
  ## data its schema disowns. A schema that cannot be checked is the same.
  try:
    return content.outputProblems(version, schema, callResult)
  except InvalidSchemaError as e:
    raise newRequestError(ErrInternal,
      "tools/call: the outputSchema of tool '" & name & "' cannot be checked: " & e.msg)

func schemaOf(tool: Option[JsonNode], key: string): Option[JsonNode] =
  if tool.isNone or tool.get{key}.isNil: none(JsonNode) else: some(tool.get{key})

func paramHeaderMismatch(schema: Option[JsonNode], arguments: JsonNode,
                         received: seq[(string, string)]): Option[JsonRpcError] =
  ## Whether the `Mcp-Param-*` headers of an HTTP call disagree with the
  ## arguments, by what the tool's `inputSchema` declares. A tool the server
  ## does not list, or lists with invalid declarations, has nothing to check.
  if schema.isNone:
    return none(JsonRpcError)
  let declared = declaredParamHeaders(schema.get)
  if declared.invalid.isSome:
    return none(JsonRpcError)
  checkParamHeaders(declared.bindings, arguments, received)

proc inputProblems(name: string, schema: Option[JsonNode], arguments: JsonNode): string =
  ## What is wrong with `arguments` under the `inputSchema` the server lists
  ## for the tool; empty when they conform or the tool has no schema.
  ## "Servers MUST validate all tool inputs" (server/tools). A schema that
  ## cannot be checked is the server's defect: nothing is passed as valid.
  if schema.isNone:
    return ""
  try:
    return describe(validate(schema.get, arguments))
  except InvalidSchemaError as e:
    stderr.writeLine("[mcp-server] tools/call: the inputSchema of tool '" & name &
                     "' cannot be checked: " & e.msg)
    raise newRequestError(ErrInternal, "Internal error")

func honoredFilter(capabilities: McpServerCapabilities,
                    requested: SubscriptionFilter): SubscriptionFilter =
  ## What of `requested` this server can deliver: a notification type it did
  ## not declare is left out of the acknowledgment.
  if capabilities.tools.isSome and capabilities.tools.get.listChanged:
    result.toolsListChanged = requested.toolsListChanged
  if capabilities.prompts.isSome and capabilities.prompts.get.listChanged:
    result.promptsListChanged = requested.promptsListChanged
  if capabilities.resources.isSome:
    if capabilities.resources.get.listChanged:
      result.resourcesListChanged = requested.resourcesListChanged
    if capabilities.resources.get.subscribe:
      result.resourceSubscriptions = requested.resourceSubscriptions

proc listen(server: McpServer, request: JsonRpcRequest,
            ctx: McpRequestContext): Future[JsonRpcResponse] {.async.} =
  ## `subscriptions/listen`: acknowledge, then stay open until the client
  ## cancels it or the server ends it with `endSubscriptions`.
  let notifications = request.params{"notifications"}
  let (requested, problem) = parseSubscriptionFilter(notifications)
  if problem.isSome:
    return newJsonRpcErrorResponse(request.id, ErrInvalidParams, problem.get)
  let idNode = if request.idNode.isNil: %request.id else: request.idNode
  var honored = honoredFilter(server.capabilities, requested)
  for hook in server.listenFilterHooks:
    hook(ctx, requested, honored)
  let subscription = Subscription(
    session: request.session, requestId: request.id, idNode: idNode,
    filter: honored,
    closed: newFuture[void]("McpServer.subscription"))
  server.subscriptions.add subscription
  try:
    await server.transport.sendNotification(ctx.relatedNotification(
      AcknowledgedMethod, acknowledgementParams(idNode, subscription.filter)))
    let ended = newFuture[void]("McpServer.listen")
    subscription.closed.completesWith(ended)
    ctx.cancelSignal.completesWith(ended)
    await ended
  finally:
    server.subscriptions.remove subscription
  return newJsonRpcResponse(request.id, listenResult(idNode))

proc declaredCapabilities*(ctx: McpRequestContext): JsonNode =
  ## What the client declared, as a capabilities object: the request's own
  ## in 2026-07-28, the `initialize` request's before it (only `extensions`
  ## is carried over). JSON null when nothing is known.
  if not ctx.clientCapabilities.isNil:
    return ctx.clientCapabilities
  let known = ctx.server.session(ctx.session)
  if known.clientCapabilities.isSome and known.clientCapabilities.get.extensions.isSome:
    return %*{"extensions": known.clientCapabilities.get.extensions.get}
  newJNull()

proc clientDeclaresExtension(ctx: McpRequestContext, id: string): bool =
  settingsOf(ctx.declaredCapabilities, id).isSome

proc dispatchExtension(server: McpServer, request: JsonRpcRequest,
                       ctx: McpRequestContext): Future[JsonRpcResponse] {.async.} =
  ## A method an extension defines. Where the extension has the client
  ## declare it, a client that did not is told the capability it lacks.
  let registered = server.extensionMethods[request.`method`]
  # An empty extension id is a method of a specification that asks nothing
  # of the client's declaration (see `registerOpenMethod`).
  if registered.extensionId.len > 0 and not registered.servedUndeclared and
     not ctx.clientDeclaresExtension(registered.extensionId):
    let error = missingCapabilityError(
      "Method " & request.`method` & " needs the extension " & registered.extensionId,
      requiredExtension(registered.extensionId))
    return newJsonRpcErrorResponse(request.id, error.code, error.message, error.data)
  let answer = await registered.handler(ctx, request.params)
  let malformed = requireObjectResult(request, answer)
  if malformed.isSome:
    return malformed.get
  return newJsonRpcResponse(request.id, answer)

proc dispatchStandard(server: McpServer, request: JsonRpcRequest,
                      ctx: McpRequestContext): Future[JsonRpcResponse] {.async.} =
  let caps = server.capabilities
  for interceptor in server.interceptors:
    let answer = await interceptor(ctx, request)
    if answer.isSome:
      return answer.get
  case request.`method`
  of "resources/list":
    if caps.resources.isNone or server.resourcesList.isNil:
      return notSupported(request)
    return await listPage(request, server.scoped(ctx, "resources/list", server.resourcesList),
                           "resources", ctx.version, resourceFor)

  of "resources/templates/list":
    if caps.resources.isNone:
      return notSupported(request)
    if server.resourceTemplatesList.isNil:
      return newJsonRpcResponse(request.id, %*{"resourceTemplates": []})
    return await listPage(request,
      server.scoped(ctx, "resources/templates/list", server.resourceTemplatesList),
      "resourceTemplates", ctx.version, resourceFor)

  of "resources/read":
    if caps.resources.isNone or server.resourceRead.isNil:
      return notSupported(request)
    let uri = stringParam(request, "uri")
    if uri.isNone:
      return missingParam(request, "uri")
    let contents = await server.resourceRead(ctx, uri.get)
    return newJsonRpcResponse(request.id, %*{"contents": contents})

  of "resources/subscribe", "resources/unsubscribe":
    if caps.resources.isNone or not caps.resources.get.subscribe or
       not ctx.version.has(ftResourceSubscribe):
      return notSupported(request)
    let uri = stringParam(request, "uri")
    if uri.isNone:
      return missingParam(request, "uri")
    let subscriber = server.sessions.getOrDefault(request.session)
    if subscriber.isNil:
      return newJsonRpcErrorResponse(request.id, ErrInvalidRequest,
        "Subscriptions belong to an initialized client")
    if request.`method` == "resources/subscribe":
      if not server.resourceSubscribe.isNil:
        await server.resourceSubscribe(ctx, uri.get)
      subscriber.subscriptions.incl(uri.get)
    else:
      if not server.resourceUnsubscribe.isNil:
        await server.resourceUnsubscribe(ctx, uri.get)
      subscriber.subscriptions.excl(uri.get)
    return newJsonRpcResponse(request.id, newJObject())

  of ListenMethod:
    if not ctx.version.has(ftSubscriptionsListen):
      return notSupported(request)
    return await server.listen(request, ctx)

  of "tools/list":
    if caps.tools.isNone or server.toolsList.isNil:
      return notSupported(request)
    let transforms = server.toolListTransforms
    let page = await listPage(request, server.scoped(ctx, "tools/list", server.toolsList),
      "tools", ctx.version,
      proc(version: McpProtocolVersion, item: JsonNode): JsonNode =
        var tool = item
        for transform in transforms:
          tool = transform(ctx, tool)
        toolFor(version, tool))
    if ctx.version.has(ftParameterHeaders):
      return withoutInvalidParamHeaders(page)
    return page

  of "tools/call":
    if caps.tools.isNone or server.toolCall.isNil:
      return notSupported(request)
    let name = stringParam(request, "name")
    if name.isNone:
      return missingParam(request, "name")
    let arguments = request.params{"arguments"}
    if not arguments.isNil and arguments.kind != JObject:
      return newJsonRpcErrorResponse(request.id, ErrInvalidParams,
        "tools/call arguments must be an object")
    let definition = await server.toolDefinition(ctx, name.get)
    let inputSchema = definition.schemaOf("inputSchema")
    if request.paramHeaders.isSome and ctx.version.has(ftParameterHeaders):
      let mismatch = paramHeaderMismatch(inputSchema, arguments, request.paramHeaders.get)
      if mismatch.isSome:
        return newJsonRpcErrorResponse(request.id, mismatch.get.code, mismatch.get.message)
    let given = if arguments.isNil: newJObject() else: arguments
    let invalid = inputProblems(name.get, inputSchema, given)
    if invalid.len > 0:
      # Before 2025-11-25 invalid arguments are a protocol error; from then
      # on they are a tool result the model can read and correct.
      let message = "Invalid arguments for tool '" & name.get & "': " & invalid
      if not ctx.version.has(ftToolInputErrors):
        return newJsonRpcErrorResponse(request.id, ErrInvalidParams, message)
      return newJsonRpcResponse(request.id,
        toolResultFor(ctx.version, toolFailureResult(message)))
    var callResult: JsonNode
    try:
      callResult = await server.toolCall(ctx, name.get, given)
    except McpToolFailure as e:
      callResult = toolFailureResult(e.plainMessage)
    let malformed = requireObjectResult(request, callResult)
    if malformed.isSome:
      return malformed.get
    callResult = withSerializedText(callResult)
    let outputSchema = definition.schemaOf("outputSchema")
    if outputSchema.isSome:
      let faults = outputProblems(name.get, ctx.version, outputSchema.get, callResult)
      if faults.len > 0:
        raise newRequestError(ErrInternal,
          "tools/call: the result of tool '" & name.get &
          "' does not conform to its outputSchema: " & faults.join("; "))
    return newJsonRpcResponse(request.id, toolResultFor(ctx.version, callResult))

  of "prompts/list":
    if caps.prompts.isNone or server.promptsList.isNil:
      return notSupported(request)
    return await listPage(request, server.scoped(ctx, "prompts/list", server.promptsList),
                           "prompts", ctx.version, promptFor)

  of "prompts/get":
    if caps.prompts.isNone or server.promptGet.isNil:
      return notSupported(request)
    let name = stringParam(request, "name")
    if name.isNone:
      return missingParam(request, "name")
    let arguments = request.params{"arguments"}
    let prompt = await server.promptGet(ctx, name.get,
      if arguments.isNil: newJObject() else: arguments)
    let malformed = requireObjectResult(request, prompt)
    if malformed.isSome:
      return malformed.get
    return newJsonRpcResponse(request.id, promptResultFor(ctx.version, prompt))

  of "completion/complete":
    if caps.completions.isNone or server.completer.isNil:
      return notSupported(request)
    let completionRequest = parseCompletionRequest(request.params,
      withContext = ctx.version.has(ftCompletionContext))
    let completion = await server.completer(ctx, completionRequest)
    return newJsonRpcResponse(request.id, %*{"completion": completion.toJson()})

  of "logging/setLevel":
    if caps.logging.isNone or not ctx.version.has(ftLoggingSetLevel):
      return notSupported(request)
    let level = stringParam(request, "level")
    if level.isNone:
      return missingParam(request, "level")
    let parsed = parseLogLevel(level.get)
    if parsed.isNone:
      return newJsonRpcErrorResponse(request.id, ErrInvalidParams,
        "Unknown log level: " & level.get)
    let subscriber = server.sessions.getOrDefault(request.session)
    if subscriber.isNil:
      return newJsonRpcErrorResponse(request.id, ErrInvalidRequest,
        "The log level belongs to an initialized client")
    subscriber.logLevel = parsed
    return newJsonRpcResponse(request.id, newJObject())

  else:
    if request.`method` in server.extensionMethods and ctx.version.has(ftExtensions):
      return await server.dispatchExtension(request, ctx)
    return newJsonRpcErrorResponse(request.id, ErrMethodNotFound,
      "Method not found: " & request.`method`)

proc inputRequiredResponse(request: JsonRpcRequest, ctx: McpRequestContext,
                           asked: ref McpInputRequired): JsonRpcResponse =
  ## What a handler's `McpInputRequired` becomes. A handler that cannot ask
  ## (an earlier version, a method without multi round-trips, nothing to ask)
  ## is a defect of the server; a request for something the client did not
  ## declare is the missing-capability error.
  proc defect(why: string): JsonRpcResponse =
    stderr.writeLine("[mcp-server] " & peerText(request.`method`) & ": " & why)
    newJsonRpcErrorResponse(request.id, ErrInternal, "Internal error")
  if not ctx.version.has(ftMultiRoundTripRequests):
    return defect("input_required is not part of protocol version " & $ctx.version)
  if not supportsInputRequired(request.`method`):
    return defect("input_required is not allowed for " & request.`method`)
  let problem = invalidInputRequired(asked.inputRequests, asked.requestState)
  if problem.isSome:
    return defect(problem.get)
  let payloadProblems = inputRequestProblems(asked.inputRequests, ctx.version)
  if payloadProblems.len > 0:
    return defect(payloadProblems.join("; "))
  let missing = missingCapabilities(asked.inputRequests, ctx.clientCapabilities)
  if missing.len > 0:
    let error = missingCapabilityError(
      "The client did not declare the capabilities these input requests need", missing)
    return newJsonRpcErrorResponse(request.id, error.code, error.message, error.data)
  var requests = asked.inputRequests
  if not requests.isNil:
    requests = newJObject()
    for key, entry in asked.inputRequests.pairs:
      requests[key] = %*{"method": entry{"method"},
        "params": withTraceContext(entry{"params"}, ctx.traceContext)}
  newJsonRpcResponse(request.id, inputRequiredPayload(requests, asked.requestState))

proc handleStandardRequest(server: McpServer, request: JsonRpcRequest,
                           ctx: McpRequestContext): Future[JsonRpcResponse] {.async.} =
  ## What a method does, independent of the protocol era it arrived in.
  if request.`method` in server.requestHandlers:
    return await server.requestHandlers[request.`method`](request)

  try:
    var response = await server.dispatchStandard(request, ctx)
    if response.result.isSome:
      for filter in server.responseFilters:
        response = await filter(ctx, request, response)
        if response.result.isNone:
          break
    return response
  except McpInputRequired as e:
    return inputRequiredResponse(request, ctx, e)
  except McpRequestError as e:
    return newJsonRpcErrorResponse(request.id, e.code, e.plainMessage, e.data)
  except McpResourceNotFound as e:
    let code =
      if ctx.version.has(ftResourceNotFoundInvalidParams): ErrInvalidParams
      else: ErrResourceNotFoundLegacy
    return newJsonRpcErrorResponse(request.id, code, e.plainMessage, %*{"uri": e.uri})

proc unusableResultType(server: McpServer, request: JsonRpcRequest,
                        ctx: McpRequestContext,
                        payload: JsonNode): Option[JsonRpcResponse] =
  ## An answer whose `resultType` is neither a core one nor defined by an
  ## extension is a defect of the server; one defined by an extension the
  ## client did not declare is not something the client can read.
  let node = payload{"resultType"}
  if node.isNil:
    return none(JsonRpcResponse)
  if node.kind != JString:
    return some(newJsonRpcErrorResponse(request.id, ErrInternal,
      "Handler for " & request.`method` & " returned a resultType that is not a string"))
  let resultType = node.getStr()
  if resultType in CoreResultTypes:
    return none(JsonRpcResponse)
  let owner = server.extensionResultTypes.getOrDefault(resultType)
  if owner.len == 0:
    stderr.writeLine("[mcp-server] " & peerText(request.`method`) & " returned resultType '" &
                     resultType & "', which no extension defines")
    return some(newJsonRpcErrorResponse(request.id, ErrInternal, "Internal error"))
  if not ctx.clientDeclaresExtension(owner):
    let error = missingCapabilityError(
      "Result type " & resultType & " needs the extension " & owner,
      requiredExtension(owner))
    return some(newJsonRpcErrorResponse(request.id, error.code, error.message, error.data))
  none(JsonRpcResponse)

proc handleModernRequest(server: McpServer, request: JsonRpcRequest,
                         ctx: McpRequestContext): Future[JsonRpcResponse] {.async.} =
  ## A 2026-07-28 request: validated on its own metadata, served without
  ## any handshake state.
  let supported = spokenVersionsUpTo(server.protocolVersion)
  if request.`method` == "initialize" and not isModernRequest(request.params):
    # A legacy client at a server without legacy versions cannot move
    # forward; the versions named here are all it can show its user.
    let refusal = unsupportedVersionError(request.params{"protocolVersion"}.getStr(), supported)
    return newJsonRpcErrorResponse(request.id, refusal.code, refusal.message, refusal.data)
  let rejection = validateModernRequest(request.params, supported)
  if rejection.isSome:
    return newJsonRpcErrorResponse(request.id, rejection.get.code,
      rejection.get.message, rejection.get.data)
  if isRemovedInModern(request.`method`) and request.`method` notin server.extensionMethods:
    return newJsonRpcErrorResponse(request.id, ErrMethodNotFound,
      "Method not found: " & request.`method`)
  let metaError = metaRejection(request, ctx.version)
  if metaError.isSome:
    return newJsonRpcErrorResponse(request.id, metaError.get.code, metaError.get.message)
  if supportsInputRequired(request.`method`):
    let inputError = rejectInvalidInputParams(request.params)
    if inputError.isSome:
      return newJsonRpcErrorResponse(request.id, inputError.get.code, inputError.get.message)

  var response =
    if request.`method` == DiscoverMethod:
      newJsonRpcResponse(request.id, discoverPayload(
        supported, server.capabilities.forVersion(ctx.version).toJson(),
        server.instructions))
    else:
      await server.handleStandardRequest(request, ctx)

  if response.result.isSome:
    let payload = response.result.get
    if payload.isNil or payload.kind != JObject:
      return newJsonRpcErrorResponse(request.id, ErrInternal,
        "Handler for " & request.`method` & " returned a result that is not an object")
    let unusable = server.unusableResultType(request, ctx, payload)
    if unusable.isSome:
      return unusable.get
    response.result = some(completeResult(
      request.`method`, payload, server.serverInfo, server.cachePolicy))
  return response

proc serve(server: McpServer, request: JsonRpcRequest,
           ctx: McpRequestContext): Future[JsonRpcResponse] {.async.} =
  var response: JsonRpcResponse
  if server.isModernPath(request):
    response = await server.handleModernRequest(request, ctx)
  else:
    let metaError = metaRejection(request, ctx.version)
    if metaError.isSome:
      response = newJsonRpcErrorResponse(request.id, metaError.get.code, metaError.get.message)
    else:
      response = await server.handleStandardRequest(request, ctx)
  response.idNode = request.idNode
  return response

proc handleRequest*(server: McpServer, request: JsonRpcRequest): Future[JsonRpcResponse] =
  ## The response to `request`. A server that speaks 2026-07-28 serves a
  ## request in that era when the request names its own protocol version;
  ## a server limited to earlier versions does not know that era at all.
  ## The request cannot be cancelled this way; `processMessages` can.
  server.serve(request, server.newContext(request))

proc serveDetached*(server: McpServer, request: JsonRpcRequest,
                    scope: TaskScope = nil): tuple[response: Future[JsonRpcResponse],
                                                   cancel: proc(reason: string) {.closure.}] =
  ## Serve `request` as `handleRequest` does, but with a way to stop it: its
  ## handler sees `ctx.cancelled` and `whenCancelled` once `cancel` is
  ## called. `scope` ties it to a task. For work that outlives the request
  ## that started it, as a task does.
  let ctx = server.newContext(request)
  ctx.taskScope = scope
  let handling = server.serve(request, ctx)
  handling.addCallback(proc() = ctx.finished = true)
  result.response = handling
  result.cancel = proc(reason: string) =
    if not ctx.finished and not ctx.cancelled:
      ctx.cancelled = true
      ctx.cancelReason = reason
      ctx.cancelSignal.complete()

proc processRequest(server: McpServer, request: JsonRpcRequest): Future[void] {.async.} =
  let ctx = server.newContext(request)
  let key = inFlightKey(request.session, request.id)
  server.inFlight[key] = ctx
  var response: JsonRpcResponse
  try:
    let handling = server.serve(request, ctx)
    let settled = newFuture[void]("McpServer.processRequest")
    handling.completesWith(settled)
    ctx.cancelSignal.completesWith(settled)
    await settled
    if not handling.finished:
      # The handler cannot be stopped, only abandoned; what it does
      # afterwards must still be seen.
      handling.addCallback(proc() =
        if handling.failed:
          stderr.writeLine("[mcp-server] cancelled " & peerText(request.`method`) &
                           " ended with " & peerText(handling.error.msg)))
      stderr.writeLine("[mcp-server] " & peerText(request.`method`) & " " &
                       peerText(request.id) & " cancelled; no response sent")
    else:
      response = handling.read()
  except CatchableError as e:
    # The cause stays on this side; a peer gets no internal detail.
    stderr.writeLine("[mcp-server] " & peerText(request.`method`) & " failed with " &
                      $e.name & ": " & peerText(e.msg))
    response = newJsonRpcErrorResponse(request.id, ErrInternal, "Internal error")
    response.idNode = request.idNode
  finally:
    ctx.finished = true
    if server.inFlight.getOrDefault(key) == ctx:
      server.inFlight.del(key)
  if ctx.cancelled:
    server.transport.requestDropped(request.session, request.id)
  else:
    await server.transport.sendResponse(response)

proc processNotification(server: McpServer, notification: JsonRpcNotification): Future[void] {.async.} =
  if notification.`method` in server.notificationHandlers:
    let handler = server.notificationHandlers[notification.`method`]
    await handler(notification)
  # If no handler, silently ignore

proc processMessages*(server: McpServer): Future[void] {.async.} =
  ## Run the receive loop until the transport raises. On termination, the
  ## raising error is stored on `server.lastTransportError` so callers can
  ## diagnose; we do not silently swallow it. Defects (programmer errors)
  ## are not caught and propagate normally — we only handle CatchableError.
  try:
    while true:
      let incoming = await server.transport.receive()
      let json = incoming.message

      if isRequest(json):
        var request = decodeRequest(json)
        request.session = incoming.session
        request.paramHeaders = incoming.paramHeaders
        request.principal = incoming.principal
        asyncCheck server.processRequest(request)
      elif isNotification(json):
        var notification = decodeNotification(json)
        notification.session = incoming.session
        asyncCheck server.processNotification(notification)
      elif isResponse(json):
        server.resolveResponse(incoming.session, decodeResponse(json))
      else:
        stderr.writeLine("[mcp-server] invalid message received: " & peerText($json))
  except McpTransportClosedError as e:
    server.sessions[""] = McpSession(state: mlsShutdown)
    for session in server.sessions.keys.toSeq:
      server.cancelSession(session)
    server.failPending(none(string), e)
  except CatchableError as e:
    server.lastTransportError = e
    server.failPending(none(string), e)
    stderr.writeLine("[mcp-server] transport loop ended with " &
                      $e.name & ": " & peerText(e.msg))

proc sendNotification*(server: McpServer, methodName: string, params: JsonNode,
                       session = ""): Future[void] {.async.} =
  ## Send a notification to the client on `session`.
  var notification = newJsonRpcNotification(methodName, params)
  notification.session = session
  await server.transport.sendNotification(notification)

proc attachTransport*(server: McpServer, transport: McpTransport): Future[void] {.async.} =
  server.transport = transport
  transport.onSessionEnd = proc(session: string) {.closure, gcsafe.} =
    server.endSession(session)
  transport.onRequestCancelled = proc(session, requestId: string) {.closure, gcsafe.} =
    discard server.cancelRequest(session, requestId, "the client closed the connection")
  transport.servesExtensionMethod = proc(methodName: string): bool {.closure, gcsafe.} =
    methodName in server.extensionMethods

  # Start message processing
  asyncCheck server.processMessages()

# Notifications to every client that should have them

proc operationalSessions(server: McpServer): seq[string] =
  for id, known in server.sessions.pairs:
    if known.state == mlsOperational:
      result.add id

proc deliverEach(server: McpServer, sessions: seq[string], methodName: string,
                 params: JsonNode): Future[void] {.async.} =
  ## One failing session does not keep the others from being told; the first
  ## failure is raised once all have been tried.
  var firstFailure: ref CatchableError
  for id in sessions:
    try:
      await server.sendNotification(methodName, params, id)
    except CatchableError as e:
      stderr.writeLine("[mcp-server] could not send " & methodName &
                       " to session '" & peerText(id) & "': " & peerText(e.msg))
      if firstFailure.isNil:
        firstFailure = e
  if not firstFailure.isNil:
    raise firstFailure

proc deliverToSubscribers(server: McpServer, methodName: string,
                          params: JsonNode): Future[void] {.async.} =
  ## The `subscriptions/listen` streams that asked for this notification, each
  ## told on its own stream and tagged with its own subscription id.
  var firstFailure: ref CatchableError
  for subscription in server.subscriptions.receiving(methodName, params):
    var notification = newJsonRpcNotification(
      methodName, withSubscriptionId(params, subscription.idNode))
    notification.session = subscription.session
    notification.relatedRequestId = subscription.requestId
    try:
      await server.transport.sendNotification(notification)
    except CatchableError as e:
      stderr.writeLine("[mcp-server] could not send " & methodName &
                       " to subscription '" & peerText(subscription.requestId) & "': " & peerText(e.msg))
      if firstFailure.isNil:
        firstFailure = e
  if not firstFailure.isNil:
    raise firstFailure

proc notifySubscribers*(server: McpServer, methodName: string,
                        params: JsonNode): Future[void] =
  ## Send `methodName` to the `subscriptions/listen` streams whose filter wants
  ## it, for the notifications an extension defines.
  server.deliverToSubscribers(methodName, params)

proc deliverAll(server: McpServer, sessions: seq[string], methodName: string,
                params: JsonNode): Future[void] {.async.} =
  ## To the clients of the earlier versions in `sessions` and to the
  ## subscriptions of 2026-07-28; the first failure is raised once both have
  ## been tried.
  var firstFailure: ref CatchableError
  try:
    await server.deliverEach(sessions, methodName, params)
  except CatchableError as e:
    firstFailure = e
  try:
    await server.deliverToSubscribers(methodName, params)
  except CatchableError as e:
    if firstFailure.isNil:
      firstFailure = e
  if not firstFailure.isNil:
    raise firstFailure

proc notifyResourceListChanged*(server: McpServer): Future[void] {.async.} =
  if server.capabilities.resources.isSome and
     server.capabilities.resources.get.listChanged:
    await server.deliverAll(server.operationalSessions,
      ResourcesListChangedMethod, newJObject())

proc subscribersOf*(server: McpServer, uri: string): seq[string] =
  ## The sessions subscribed to `uri` with `resources/subscribe`.
  for id, known in server.sessions.pairs:
    if known.state == mlsOperational and uri in known.subscriptions:
      result.add id

proc notifyResourceUpdated*(server: McpServer, uri: string): Future[void] {.async.} =
  ## Tell the clients subscribed to `uri` that it changed: those of the
  ## earlier versions that called `resources/subscribe`, and the
  ## `subscriptions/listen` streams that named it.
  if server.capabilities.resources.isSome and
     server.capabilities.resources.get.subscribe:
    await server.deliverAll(server.subscribersOf(uri),
      ResourceUpdatedMethod, %*{"uri": uri})

proc notifyListChanged*(server: McpServer, methodName: string,
                        params: JsonNode = nil): Future[void] {.async.} =
  ## A list-changed notification (`notifications/tools/list_changed`,
  ## `notifications/prompts/list_changed` or
  ## `notifications/resources/list_changed`) that carries `params`, for an
  ## extension that scopes the change by an `_meta` key of its own. Goes to
  ## the same clients as `notifyToolListChanged` and its siblings, and only
  ## when the server declared `listChanged` for that list. Raises ValueError
  ## for any other method.
  let capabilities = server.capabilities
  let declared =
    case methodName
    of ToolsListChangedMethod:
      capabilities.tools.isSome and capabilities.tools.get.listChanged
    of PromptsListChangedMethod:
      capabilities.prompts.isSome and capabilities.prompts.get.listChanged
    of ResourcesListChangedMethod:
      capabilities.resources.isSome and capabilities.resources.get.listChanged
    else:
      raise newException(ValueError, methodName & " is not a list-changed notification")
  if declared:
    await server.deliverAll(server.operationalSessions, methodName,
                            if params.isNil: newJObject() else: params)

proc notifyToolListChanged*(server: McpServer): Future[void] {.async.} =
  if server.capabilities.tools.isSome and
     server.capabilities.tools.get.listChanged:
    await server.deliverAll(server.operationalSessions,
      ToolsListChangedMethod, newJObject())

proc notifyPromptListChanged*(server: McpServer): Future[void] {.async.} =
  if server.capabilities.prompts.isSome and
     server.capabilities.prompts.get.listChanged:
    await server.deliverAll(server.operationalSessions,
      PromptsListChangedMethod, newJObject())

proc subscriptionCount*(server: McpServer): int =
  ## The `subscriptions/listen` requests being served.
  server.subscriptions.count

proc endSubscriptions*(server: McpServer): Future[void] {.async.} =
  ## Tear every subscription down, as a server does when it shuts down: each
  ## `subscriptions/listen` request is answered with a result that says the
  ## subscription ended gracefully. On stdio the server first sends
  ## `notifications/cancelled` for it, which the specification requires of a
  ## server that tears a subscription down (its transport rules for HTTP
  ## ask only for the response).
  for subscription in server.subscriptions.all:
    if subscription.tornDown:
      continue
    subscription.tornDown = true
    if server.transport.kind == mtkStdio:
      var cancelled = newJsonRpcNotification("notifications/cancelled",
        %*{"requestId": subscription.idNode, "reason": "the server ended the subscription"})
      cancelled.session = subscription.session
      try:
        await server.transport.sendNotification(cancelled)
      except CatchableError as e:
        stderr.writeLine("[mcp-server] could not cancel subscription '" &
                         peerText(subscription.requestId) & "': " & peerText(e.msg))
    subscription.closed.complete()

proc log*(server: McpServer, level: McpLogLevel, data: JsonNode,
          logger = ""): Future[void] {.async.} =
  ## Send a log message to every client of the earlier versions that
  ## `logging/setLevel` has not shut out. A 2026-07-28 client gets log
  ## messages only for its own requests: use `ctx.log`. Raises when the
  ## server has not declared the `logging` capability.
  if server.capabilities.logging.isNone:
    raise newException(McpCapabilityError,
      "the server must declare the logging capability to send log messages")
  var targets: seq[string]
  for id, known in server.sessions.pairs:
    if known.state == mlsOperational and
       (known.logLevel.isNone or level >= known.logLevel.get):
      targets.add id
  await server.deliverEach(targets, "notifications/message", logParams(level, data, logger))
