## MCP server implementation

import std/[asyncdispatch, json, options, sequtils, sets, strutils, tables]
import ../protocol/types
import ../protocol/lifecycle
import ../protocol/modern
import ../protocol/param_headers
import ../protocol/features
import ../protocol/content
import ../protocol/log_level
import ../protocol/sampling_tools
import ../protocol/trace_context
import ../protocol/extensions
import ../protocol/mrtr
import ../transport/transport
import ./errors
import ./pagination
import ./completion

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
    version*: McpProtocolVersion
      ## The version this request is served in.
    progressToken: JsonNode
      ## nil when the client did not ask for progress.
    logLevel*: Option[McpLogLevel]
      ## 2026-07-28: the level the request asked for in its `_meta`.
    clientCapabilities*: JsonNode
      ## 2026-07-28: what the request declared in its `_meta`; nil in
      ## earlier versions.
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

  ExtensionMethodHandler* = proc(ctx: McpRequestContext,
                                 params: JsonNode): Future[JsonNode] {.async.}
    ## Returns the result object of an extension's request. It may set its
    ## own `resultType` when the extension declared that type.

  ExtensionMethod* = object
    extensionId*: string
    handler*: ExtensionMethodHandler

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
    extensionMethods*: Table[string, ExtensionMethod]
      ## The methods extensions define, by method name; see `registerExtensionMethod`.
    extensionResultTypes*: Table[string, string]
      ## The result types extensions define, mapped to the extension.
    requestHandlers*: Table[string, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.}]
    notificationHandlers*: Table[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]
    inFlight: Table[string, McpRequestContext]
      ## The requests being served, by session and id.
    pending: Table[string, Future[JsonRpcResponse]]
      ## The requests of this server awaiting the client's response.
    nextRequestNumber: int
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

# Handlers of the standard methods

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
  let supported = versionsUpTo(server.protocolVersion)
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
    server.capabilities.forVersion(negotiated.get)
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
    stderr.writeLine("[mcp-server] request " & requestId.get & " cancelled by the client" &
                     (if reason.len > 0: ": " & reason else: ""))

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

  let experimentalJson = json{"experimental"}
  if not experimentalJson.isNil and experimentalJson.kind == JObject:
    result.experimental = some(experimentalJson)

# Request context

proc legacyVersionOf(server: McpServer, session: string): McpProtocolVersion =
  ## The version of a client that has handshaken; a client that has not is
  ## served as the newest legacy version this server speaks.
  let known = server.sessions.getOrDefault(session)
  if not known.isNil and known.negotiatedVersion.isSome:
    known.negotiatedVersion.get
  else:
    latestLegacyVersion(versionsUpTo(server.protocolVersion)).get

proc isModernPath(server: McpServer, request: JsonRpcRequest): bool =
  isModern(server.protocolVersion) and isModernRequest(request.params)

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
    version: requested.get(server.legacyVersionOf(request.session)),
    cancellable: request.`method` != "initialize",
    cancelSignal: newFuture[void]("McpRequestContext.cancelSignal"))
  if not meta.isNil and meta.kind == JObject:
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
              timeoutMs = DefaultRequestTimeoutMs): Future[JsonRpcResponse] {.async.} =
  ## Send a request to the client on `session` and wait for its response,
  ## which may carry a JSON-RPC error. Raises `McpCapabilityError` when there
  ## is no initialized client there or its version has no requests from the
  ## server, `McpRequestTimeout` when `timeoutMs` (0: no limit) passes first.
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
  var outgoing = newJsonRpcRequest(id, methodName, params)
  outgoing.session = session
  outgoing.relatedRequestId = relatedRequestId
  try:
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
                       ": " & e.msg)
    raise newException(McpRequestTimeout,
      "the client did not answer " & methodName & " within " & $timeoutMs & " ms")
  return await answer

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

proc ping*(server: McpServer, session = "", relatedRequestId = ""): Future[void] {.async.} =
  ## Check that the client on `session` is alive.
  discard resultOf(await server.request(session, "ping", newJObject(), relatedRequestId), "ping")

proc listRoots*(server: McpServer, session = "",
                relatedRequestId = ""): Future[seq[JsonNode]] {.async.} =
  ## The roots the client on `session` offers; needs its `roots` capability.
  server.requireClientCapability(session, "roots",
    proc(c: McpClientCapabilities): bool = c.roots.isSome)
  let answer = resultOf(await server.request(session, "roots/list", newJObject(),
                                             relatedRequestId), "roots/list")
  let roots = answer{"roots"}
  if roots.isNil or roots.kind != JArray:
    raise newException(McpRemoteError, "roots/list: the result has no roots array")
  return roots.getElems()

proc createMessage*(server: McpServer, session: string, params: JsonNode,
                    relatedRequestId = ""): Future[JsonNode] {.async.} =
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
                                             relatedRequestId), "sampling/createMessage")
  if params.usesTools:
    # An answer to a request without tools is passed on as received.
    raiseIfAny("sampling/createMessage result",
               createMessageResultProblems(answer, params, version))
  return answer

proc ping*(ctx: McpRequestContext): Future[void] =
  ctx.server.ping(ctx.session, ctx.requestId)

proc listRoots*(ctx: McpRequestContext): Future[seq[JsonNode]] =
  ctx.server.listRoots(ctx.session, ctx.requestId)

proc createMessage*(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] =
  ctx.server.createMessage(ctx.session, params, ctx.requestId)

proc resolveResponse(server: McpServer, session: string, response: JsonRpcResponse) =
  let key = inFlightKey(session, response.id)
  if key notin server.pending:
    stderr.writeLine("[mcp-server] response to unknown request id '" & response.id & "' ignored")
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

proc toolInputSchema(server: McpServer, name: string): Future[Option[JsonNode]] {.async.} =
  ## The `inputSchema` the tool list publishes for `name`. The list is read
  ## afresh: tools may change between calls.
  if server.toolsList.isNil:
    return none(JsonNode)
  var cursor = none(string)
  for _ in 1 .. MaxToolListPages:
    let page = await server.toolsList(cursor)
    for tool in page.items:
      if tool{"name"}.getStr() == name:
        let schema = tool{"inputSchema"}
        return if schema.isNil: none(JsonNode) else: some(schema)
    if page.nextCursor.isNone:
      return none(JsonNode)
    cursor = page.nextCursor
  stderr.writeLine("[mcp-server] tools/list of this server has more than " &
                   $MaxToolListPages & " pages; '" & name & "' was not found")
  none(JsonNode)

proc paramHeaderMismatch(server: McpServer, name: string, arguments: JsonNode,
                         received: seq[(string, string)]): Future[Option[JsonRpcError]] {.async.} =
  ## Whether the `Mcp-Param-*` headers of an HTTP call disagree with the
  ## arguments, by what the tool declared. A tool the server does not list,
  ## or lists with invalid declarations, has nothing to check.
  let schema = await server.toolInputSchema(name)
  if schema.isNone:
    return none(JsonRpcError)
  let declared = declaredParamHeaders(schema.get)
  if declared.invalid.isSome:
    return none(JsonRpcError)
  return checkParamHeaders(declared.bindings, arguments, received)

proc clientDeclaresExtension(ctx: McpRequestContext, id: string): bool =
  settingsOf(ctx.clientCapabilities, id).isSome

proc dispatchExtension(server: McpServer, request: JsonRpcRequest,
                       ctx: McpRequestContext): Future[JsonRpcResponse] {.async.} =
  ## A method an extension defines; the client must have declared the
  ## extension, otherwise the request needs a capability it did not offer.
  let registered = server.extensionMethods[request.`method`]
  if not ctx.clientDeclaresExtension(registered.extensionId):
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
  case request.`method`
  of "resources/list":
    if caps.resources.isNone or server.resourcesList.isNil:
      return notSupported(request)
    return await listPage(request, server.resourcesList, "resources", ctx.version, resourceFor)

  of "resources/templates/list":
    if caps.resources.isNone:
      return notSupported(request)
    if server.resourceTemplatesList.isNil:
      return newJsonRpcResponse(request.id, %*{"resourceTemplates": []})
    return await listPage(request, server.resourceTemplatesList, "resourceTemplates",
                           ctx.version, resourceFor)

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

  of "tools/list":
    if caps.tools.isNone or server.toolsList.isNil:
      return notSupported(request)
    let page = await listPage(request, server.toolsList, "tools", ctx.version, toolFor)
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
    if request.paramHeaders.isSome and ctx.version.has(ftParameterHeaders):
      let mismatch = await server.paramHeaderMismatch(name.get, arguments,
                                                      request.paramHeaders.get)
      if mismatch.isSome:
        return newJsonRpcErrorResponse(request.id, mismatch.get.code, mismatch.get.message)
    var callResult: JsonNode
    try:
      callResult = await server.toolCall(ctx, name.get,
        if arguments.isNil: newJObject() else: arguments)
    except McpToolFailure as e:
      callResult = toolFailureResult(e.plainMessage)
    let malformed = requireObjectResult(request, callResult)
    if malformed.isSome:
      return malformed.get
    return newJsonRpcResponse(request.id, toolResultFor(ctx.version, callResult))

  of "prompts/list":
    if caps.prompts.isNone or server.promptsList.isNil:
      return notSupported(request)
    return await listPage(request, server.promptsList, "prompts", ctx.version, promptFor)

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
    stderr.writeLine("[mcp-server] " & request.`method` & ": " & why)
    newJsonRpcErrorResponse(request.id, ErrInternal, "Internal error")
  if not ctx.version.has(ftMultiRoundTripRequests):
    return defect("input_required is not part of protocol version " & $ctx.version)
  if not supportsInputRequired(request.`method`):
    return defect("input_required is not allowed for " & request.`method`)
  let problem = invalidInputRequired(asked.inputRequests, asked.requestState)
  if problem.isSome:
    return defect(problem.get)
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
    return await server.dispatchStandard(request, ctx)
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
    stderr.writeLine("[mcp-server] " & request.`method` & " returned resultType '" &
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
  let supported = versionsUpTo(server.protocolVersion)
  let rejection = validateModernRequest(request.params, supported)
  if rejection.isSome:
    return newJsonRpcErrorResponse(request.id, rejection.get.code,
      rejection.get.message, rejection.get.data)
  if isRemovedInModern(request.`method`):
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
        supported, server.capabilities.toJson(), server.instructions))
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
          stderr.writeLine("[mcp-server] cancelled " & request.`method` &
                           " ended with " & handling.error.msg))
      stderr.writeLine("[mcp-server] " & request.`method` & " " & request.id &
                       " cancelled; no response sent")
    else:
      response = handling.read()
  except CatchableError as e:
    # The cause stays on this side; a peer gets no internal detail.
    stderr.writeLine("[mcp-server] " & request.`method` & " failed with " &
                      $e.name & ": " & e.msg)
    response = newJsonRpcErrorResponse(request.id, ErrInternal, "Internal error")
    response.idNode = request.idNode
  finally:
    ctx.finished = true
    if server.inFlight.getOrDefault(key) == ctx:
      server.inFlight.del(key)
  if not ctx.cancelled:
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
        asyncCheck server.processRequest(request)
      elif isNotification(json):
        var notification = decodeNotification(json)
        notification.session = incoming.session
        asyncCheck server.processNotification(notification)
      elif isResponse(json):
        server.resolveResponse(incoming.session, decodeResponse(json))
      else:
        stderr.writeLine("[mcp-server] invalid message received: " & $json)
  except McpTransportClosedError as e:
    server.sessions[""] = McpSession(state: mlsShutdown)
    for session in server.sessions.keys.toSeq:
      server.cancelSession(session)
    server.failPending(none(string), e)
  except CatchableError as e:
    server.lastTransportError = e
    server.failPending(none(string), e)
    stderr.writeLine("[mcp-server] transport loop ended with " &
                      $e.name & ": " & e.msg)

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
                       " to session '" & id & "': " & e.msg)
      if firstFailure.isNil:
        firstFailure = e
  if not firstFailure.isNil:
    raise firstFailure

# TODO: 2026-07-28 clients learn of changes through subscriptions/listen (a
# later change); until then the notify* procs reach the clients that
# handshaked, which are the ones of the earlier versions.

proc notifyResourceListChanged*(server: McpServer): Future[void] {.async.} =
  if server.capabilities.resources.isSome and
     server.capabilities.resources.get.listChanged:
    await server.deliverEach(server.operationalSessions,
      "notifications/resources/list_changed", newJObject())

proc subscribersOf*(server: McpServer, uri: string): seq[string] =
  ## The sessions subscribed to `uri`.
  for id, known in server.sessions.pairs:
    if known.state == mlsOperational and uri in known.subscriptions:
      result.add id

proc notifyResourceUpdated*(server: McpServer, uri: string): Future[void] {.async.} =
  ## Tell the clients subscribed to `uri` that it changed.
  if server.capabilities.resources.isSome and
     server.capabilities.resources.get.subscribe:
    await server.deliverEach(server.subscribersOf(uri),
      "notifications/resources/updated", %*{"uri": uri})

proc notifyToolListChanged*(server: McpServer): Future[void] {.async.} =
  if server.capabilities.tools.isSome and
     server.capabilities.tools.get.listChanged:
    await server.deliverEach(server.operationalSessions,
      "notifications/tools/list_changed", newJObject())

proc notifyPromptListChanged*(server: McpServer): Future[void] {.async.} =
  if server.capabilities.prompts.isSome and
     server.capabilities.prompts.get.listChanged:
    await server.deliverEach(server.operationalSessions,
      "notifications/prompts/list_changed", newJObject())

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
