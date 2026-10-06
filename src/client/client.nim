## MCP client implementation

import asyncdispatch, json, options, tables, strutils, sequtils, uuids
import ../protocol/types
import ../protocol/diagnostic
import ../protocol/lifecycle
import ../protocol/modern
import ../protocol/features
import ../protocol/content as wire
import ../protocol/trace_context
import ../protocol/mrtr
import ../protocol/subscriptions
import ../transport/transport

type
  McpError* = object of CatchableError
    ## Base of every failure an operation of this client reports.

  McpRequestError* = object of McpError
    ## The peer answered with a JSON-RPC error.
    code*: int
    data*: JsonNode

  McpTimeoutError* = object of McpError
    ## No response arrived within the request's timeout.

  McpCancelledError* = object of McpError
    ## The caller cancelled the request through its McpCancelToken.

  McpConnectionClosedError* = object of McpError
    ## The client is not connected, was closed, or lost its transport
    ## while a request was waiting.

  McpUnsupportedError* = object of McpError
    ## The negotiated version or the server's capabilities do not include
    ## what the operation needs. Nothing was sent.

  McpProtocolError* = object of McpError
    ## The peer's answer does not have the shape the specification gives.

  McpInputRoundsError* = object of McpError
    ## The server kept answering a request with `input_required` beyond
    ## `maxInputRounds` retries.

  McpSubscriptionEnd* = enum
    ## How a `subscriptions/listen` stream ended.
    sbGraceful         ## the server answered the request: it ended on purpose
    sbServerCancelled  ## the server sent notifications/cancelled for it (stdio)
    sbCancelled        ## this client cancelled it
    sbLost             ## the transport closed or failed; the server held no
                       ## state worth keeping, so listening again starts afresh
    sbFailed           ## the server answered the request with an error

  McpSubscription* = ref object
    ## One open `subscriptions/listen` stream; see `listen`.
    id*: string
      ## The id of the request, which tags every notification of the stream.
    requested*: SubscriptionFilter
    acknowledged*: Option[SubscriptionFilter]
      ## What the server agreed to honor, once it has said so.
    acknowledgement*: Future[void]
      ## Completes when the server's acknowledgment has been processed (or
      ## the stream ended first); `acknowledged` and `problem` say what it was.
    problem*: Option[string]
      ## What was wrong with the acknowledgment, when it was malformed.
    owner*: McpClient
    ended*: Future[void]
      ## Completes when the stream is over, whichever way; `endedBy` says how.
    endedBy*: Option[McpSubscriptionEnd]
    failure*: Option[JsonRpcError]
      ## The error the server answered the request with (`sbFailed`).
    onNotification*: proc(methodName: string, params: JsonNode) {.closure.}
      ## Every notification delivered on this stream, after the client's own
      ## callbacks (`onToolsListChanged` and the like) have run for it.

  McpCancelToken* = ref object
    ## Lets the caller of an operation withdraw it. Pass it in
    ## McpRequestOptions; `cancel` makes the waiting call raise
    ## McpCancelledError and tells the server to stop.
    reason: string
    signal: Future[void]

  McpProgress* = object
    ## One notifications/progress for a request that asked for them.
    progress*: float
    total*: Option[float]
    message*: string

  McpProgressCallback* = proc(update: McpProgress) {.closure.}

  McpRequestOptions* = object
    timeoutMs*: Option[int]
      ## none: the client's requestTimeoutMs. some(0): wait without limit.
    onProgress*: McpProgressCallback
      ## When set, the request carries a progressToken and every matching
      ## notifications/progress is passed here.
    cancel*: McpCancelToken
    traceContext*: TraceContext
      ## 2026-07-28: sent in the request's `_meta`. A malformed value raises
      ## ValueError before anything is sent; a connection in an earlier
      ## version does not carry trace context, so it is left out.

  McpLogMessage* = object
    ## A notifications/message from the server.
    level*: string
    logger*: Option[string]
    data*: JsonNode

  McpServerRequestHandler* = proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.closure.}

  McpClient* = ref object
    transport*: McpTransport
    state*: McpLifecycleState
    protocolVersion*: McpProtocolVersion
      ## The newest version this client speaks; it also speaks every
      ## earlier one.
    negotiatedVersion*: Option[McpProtocolVersion]
      ## The version in use with the connected server.
    clientInfo*: McpClientInfo
    capabilities*: McpClientCapabilities
    serverCapabilities*: Option[McpServerCapabilities]
    serverInfo*: Option[McpServerInfo]
      ## The server's identity, when it stated one.
    serverInstructions*: string
    probeTimeoutMs*: int
      ## How long connect() waits for an answer to the 2026-07-28
      ## server/discover probe before treating the server as a legacy one.
    requestTimeoutMs*: int
      ## How long a request waits for its response unless its
      ## McpRequestOptions say otherwise. 0 waits without limit.
    pendingRequests*: Table[string, Future[JsonRpcResponse]]
    progressCallbacks: Table[string, McpProgressCallback]
    nextProgressToken: int
    subscriptions*: Table[string, McpSubscription]
      ## The open `subscriptions/listen` streams, by request id.
    maxInputRounds*: int
      ## How many times a request may be retried with input the server asked
      ## for (multi round-trip requests, 2026-07-28) before it raises
      ## McpInputRoundsError.
    legacyExtensions*: seq[string]
      ## The extensions declared with `onLegacyHandshake`: the only ones sent
      ## in the `initialize` request of a version before 2026-07-28.
    extensionResultTypes*: seq[string]
      ## The `resultType` values of the extensions this client declared;
      ## see `declareExtension`.
    requestHandlers*: Table[string, McpServerRequestHandler]
    notificationHandlers*: Table[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]
    toolOutputSchemas*: Table[string, JsonNode]
      ## The outputSchema of each tool listed so far, to check what callTool
      ## returns against.
    onLogMessage*: proc(message: McpLogMessage) {.closure.}
    onResourceUpdated*: proc(uri: string) {.closure.}
    onToolsListChanged*: proc() {.closure.}
    onResourcesListChanged*: proc() {.closure.}
    onPromptsListChanged*: proc() {.closure.}
    lastTransportError*: ref CatchableError
      ## Set when the message-processing loop terminates due to a transport
      ## error. Mirrors McpServer.lastTransportError — see audit finding #5.

const
  DefaultRequestTimeoutMs* = 60_000
  DefaultMaxInputRounds* = 10

proc newMcpCancelToken*(): McpCancelToken =
  McpCancelToken(signal: newFuture[void]("McpCancelToken"))

proc cancel*(token: McpCancelToken, reason: string = "") =
  ## Idempotent: only the first call counts.
  if not token.signal.finished:
    token.reason = reason
    token.signal.complete()

proc isCancelled*(token: McpCancelToken): bool = token.signal.finished

proc whenCancelled*(token: McpCancelToken): Future[void] = token.signal
  ## Completes when the token is cancelled.

proc cancelReason*(token: McpCancelToken): string = token.reason

proc newMcpClient*(
  clientInfo: McpClientInfo,
  protocolVersion: McpProtocolVersion = DefaultProtocolVersion,
  capabilities: McpClientCapabilities = McpClientCapabilities()
): McpClient =
  requireSupported(protocolVersion)
  result = McpClient(
    state: mlsUninitialized,
    protocolVersion: protocolVersion,
    clientInfo: clientInfo,
    capabilities: capabilities,
    serverCapabilities: none(McpServerCapabilities),
    serverInfo: none(McpServerInfo),
    probeTimeoutMs: 5000,
    requestTimeoutMs: DefaultRequestTimeoutMs,
    maxInputRounds: DefaultMaxInputRounds,
    subscriptions: initTable[string, McpSubscription](),
    pendingRequests: initTable[string, Future[JsonRpcResponse]](),
    progressCallbacks: initTable[string, McpProgressCallback](),
    requestHandlers: initTable[string, McpServerRequestHandler](),
    notificationHandlers: initTable[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]()
  )

proc registerRequestHandler*(client: McpClient, methodName: string,
    handler: McpServerRequestHandler) =
  client.requestHandlers[methodName] = handler

proc registerNotificationHandler*(client: McpClient, methodName: string,
    handler: proc(notification: JsonRpcNotification): Future[void] {.async.}) =
  client.notificationHandlers[methodName] = handler

proc requireNotConnected*(client: McpClient, what: string) =
  ## Capabilities are declared once, in the handshake; a handler that adds
  ## one afterwards would be a capability the server never heard of.
  if client.state != mlsUninitialized:
    raise newException(McpError, what & " must be set before connect()")

proc usesModernProtocol*(client: McpClient): bool =
  ## Whether the connection uses 2026-07-28 or later, where every request
  ## carries its own protocol version and client capabilities.
  client.negotiatedVersion.isSome and isModern(client.negotiatedVersion.get)

proc failPending(client: McpClient, reason: string) =
  ## Nobody will answer these requests any more.
  let waiting = toSeq(client.pendingRequests.values)
  client.pendingRequests.clear()
  for future in waiting:
    if not future.finished:
      future.fail(newException(McpConnectionClosedError, reason))

proc requestAllowed(client: McpClient, methodName: string): bool =
  ## Whether the server may send `methodName` to this client: only when the
  ## client declared the capability behind it, and never in the era without
  ## server-initiated requests.
  if client.usesModernProtocol:
    return false
  case methodName
  of "sampling/createMessage": client.capabilities.sampling.isSome
  of "roots/list": client.capabilities.roots.isSome
  of "elicitation/create":
    client.capabilities.elicitation.isSome and
      client.negotiatedVersion.get.has(ftElicitation)
  else: true

proc logHandlerFailure(what: string) =
  stderr.writeLine("[mcp-client] " & what & " raised " &
                   $getCurrentException().name & ": " & peerText(getCurrentExceptionMsg()))

proc processRequest(client: McpClient, request: JsonRpcRequest): Future[void] {.async.} =
  var response: JsonRpcResponse
  if request.`method` == "ping" and not client.usesModernProtocol and
     "ping" notin client.requestHandlers:
    response = newJsonRpcResponse(request.id, newJObject())
  elif request.`method` notin client.requestHandlers or
       not client.requestAllowed(request.`method`):
    response = newJsonRpcErrorResponse(
      request.id, -32601, "Method not found: " & request.`method`)
  else:
    try:
      response = await client.requestHandlers[request.`method`](request)
    except McpRequestError as e:
      response = newJsonRpcErrorResponse(request.id, e.code, e.msg, e.data)
    except CatchableError as e:
      logHandlerFailure("handler for " & peerText(request.`method`))
      response = newJsonRpcErrorResponse(request.id, -32603, e.msg)
  response.idNode = request.idNode
  await client.transport.sendResponse(response)

proc notify(callback: proc() {.closure.}, what: string) =
  if callback.isNil: return
  try:
    callback()
  except CatchableError:
    logHandlerFailure(what)

proc endSubscription*(client: McpClient, id: string, how: McpSubscriptionEnd) =
  ## The stream `id` is over. Idempotent: the first reason counts.
  let subscription = client.subscriptions.getOrDefault(id)
  if subscription.isNil:
    return
  client.subscriptions.del(id)
  subscription.endedBy = some(how)
  if not subscription.ended.finished:
    subscription.ended.complete()

proc routeToSubscription(client: McpClient, notification: JsonRpcNotification): bool =
  ## Notifications tagged with a subscription id belong to that stream. False
  ## when the notification is not to be processed further: the acknowledgment
  ## (consumed here) or one for a stream that has ended.
  let tagged = subscriptionIdOf(notification.params)
  if tagged.isNone:
    return notification.`method` != AcknowledgedMethod
  let subscription = client.subscriptions.getOrDefault(tagged.get)
  if subscription.isNil:
    return false
  if notification.`method` == AcknowledgedMethod:
    let (honored, problem) = parseSubscriptionFilter(notification.params{"notifications"})
    if not subscription.acknowledgement.finished:
      if problem.isSome:
        subscription.problem = problem
      else:
        subscription.acknowledged = some(honored)
      subscription.acknowledgement.complete()
    return false
  true

proc processNotification(client: McpClient, notification: JsonRpcNotification): Future[void] {.async.} =
  let params = notification.params
  if not client.routeToSubscription(notification):
    return
  case notification.`method`
  of "notifications/progress":
    let token = params{"progressToken"}
    if not token.isNil:
      let key = if token.kind == JString: token.getStr() else: $token
      if key in client.progressCallbacks:
        let update = McpProgress(
          progress: params{"progress"}.getFloat(),
          total: (if params.hasKey("total"): some(params["total"].getFloat()) else: none(float)),
          message: params{"message"}.getStr())
        let callback = client.progressCallbacks[key]
        try:
          callback(update)
        except CatchableError:
          logHandlerFailure("progress callback")
  of "notifications/message":
    if not client.onLogMessage.isNil:
      let message = McpLogMessage(
        level: params{"level"}.getStr(),
        logger: (if params.hasKey("logger"): some(params["logger"].getStr()) else: none(string)),
        data: params{"data"})
      try:
        client.onLogMessage(message)
      except CatchableError:
        logHandlerFailure("log callback")
  of "notifications/resources/updated":
    if not client.onResourceUpdated.isNil:
      let uri = params{"uri"}.getStr()
      try:
        client.onResourceUpdated(uri)
      except CatchableError:
        logHandlerFailure("resource-updated callback")
  of "notifications/tools/list_changed":
    notify(client.onToolsListChanged, "tools list_changed callback")
  of "notifications/resources/list_changed":
    notify(client.onResourcesListChanged, "resources list_changed callback")
  of "notifications/prompts/list_changed":
    notify(client.onPromptsListChanged, "prompts list_changed callback")
  of "notifications/cancelled":
    # A server cancels nothing but a subscriptions/listen stream.
    let target = params{"requestId"}
    if not target.isNil and target.kind in {JString, JInt}:
      client.endSubscription(if target.kind == JString: target.getStr() else: $target.getInt(),
                             sbServerCancelled)
  else:
    discard
  let tagged = subscriptionIdOf(params)
  if tagged.isSome:
    let subscription = client.subscriptions.getOrDefault(tagged.get)
    if not subscription.isNil and not subscription.onNotification.isNil:
      try:
        subscription.onNotification(notification.`method`, params)
      except CatchableError:
        logHandlerFailure("subscription callback")
  if notification.`method` in client.notificationHandlers:
    let handler = client.notificationHandlers[notification.`method`]
    try:
      await handler(notification)
    except CatchableError:
      logHandlerFailure("handler for " & peerText(notification.`method`))

proc processResponse(client: McpClient, response: JsonRpcResponse): Future[void] {.async.} =
  # A response nobody waits for belongs to a request that timed out or
  # was cancelled; the specification tells the sender to ignore it.
  if response.id in client.pendingRequests:
    let promise = client.pendingRequests[response.id]
    client.pendingRequests.del(response.id)
    promise.complete(response)

proc processMessages*(client: McpClient): Future[void] {.async.} =
  ## Run the receive loop until the transport raises. On termination, the
  ## raising error is stored on `client.lastTransportError` so callers can
  ## diagnose the silent-dead condition, and every request still waiting
  ## fails. Defects propagate.
  try:
    while true:
      let json = await client.transport.receiveMessage()

      if isRequest(json):
        let request = decodeRequest(json)
        asyncCheck client.processRequest(request)
      elif isResponse(json):
        let response = decodeResponse(json)
        asyncCheck client.processResponse(response)
      elif isNotification(json):
        let notification = decodeNotification(json)
        asyncCheck client.processNotification(notification)
      else:
        stderr.writeLine("[mcp-client] invalid message received: " & peerText($json))
  except McpTransportClosedError:
    client.state = mlsShutdown
    client.failPending("the transport was closed")
  except CatchableError as e:
    if client.state == mlsShutdown:
      # close() ends the loop on purpose; that is not an error.
      client.failPending("the client was closed")
      return
    client.lastTransportError = e
    stderr.writeLine("[mcp-client] transport loop ended with " &
                      $e.name & ": " & peerText(e.msg))
    client.failPending("the transport failed: " & e.msg)

proc ensureOpen(client: McpClient) =
  if client.transport.isNil or client.state == mlsShutdown:
    raise newException(McpConnectionClosedError, "the client is not connected")

type StartedRequest = tuple[id: string, response: Future[JsonRpcResponse], sent: Future[void]]

proc beginRequest(client: McpClient, methodName: string, params: JsonNode,
                  id = ""): StartedRequest =
  ## Hand the request to the transport without waiting for it to be sent.
  ## Over HTTP sending ends only when the server starts to answer, so a
  ## caller that waited for it could not time out on a server that never
  ## does. When sending fails, `response` fails with the transport's error.
  client.ensureOpen()
  let id = if id.len > 0: id else: $genUUID()
  let promise = newFuture[JsonRpcResponse]("McpClient.request")
  client.pendingRequests[id] = promise
  let sent = client.transport.sendRequest(newJsonRpcRequest(id, methodName, params))
  sent.addCallback(proc() =
    if not sent.failed:
      return
    let error = sent.readError()
    if client.pendingRequests.getOrDefault(id) == promise and not promise.finished:
      client.pendingRequests.del(id)
      promise.fail(error)
    else:
      # Nobody waits for this request any more (it timed out or was cancelled).
      stderr.writeLine("[mcp-client] sending " & methodName & " failed after the request " &
                       "was given up: " & peerText(error.msg)))
  (id: id, response: promise, sent: sent)

proc startRequest*(client: McpClient, methodName: string, params: JsonNode,
                   id = ""): Future[tuple[id: string, response: Future[JsonRpcResponse]]] {.async.} =
  ## Send a request and hand back its response as a future, without waiting
  ## for the response. `params` go as given: a 2026-07-28 request needs its
  ## `_meta` already in them (`sendRequest` adds it). `id` names the request;
  ## empty picks one. Raises what the transport raises when sending fails.
  let started = client.beginRequest(methodName, params, id)
  # Whichever comes first: the request is out, or sending failed and the
  # response carries the error.
  await (started.sent or started.response)
  if started.response.failed:
    raise started.response.readError()
  return (id: started.id, response: started.response)

proc sendNotification*(client: McpClient, methodName: string, params: JsonNode): Future[void] {.async.} =
  client.ensureOpen()
  let notification = newJsonRpcNotification(methodName, params)
  await client.transport.sendNotification(notification)

proc abandon*(client: McpClient, id, methodName, reason: string,
              unsent = false) {.async.} =
  ## Stop waiting for `id` and tell the server to stop working on it.
  ## `unsent`: the transport is still sending the request (over HTTP, still
  ## waiting for the server to start answering), so that is given up too.
  client.pendingRequests.del(id)
  if unsent:
    client.transport.cancelRequest(id)
  # initialize must not be cancelled. Over HTTP the 2026-07-28 protocol
  # cancels by closing the request's response stream, not by a message.
  if methodName == "initialize" or client.state == mlsShutdown:
    return
  if client.usesModernProtocol and client.transport.kind != mtkStdio:
    client.transport.cancelRequest(id)
    return
  # Not awaited: over HTTP a notification is sent only when the server
  # answers the POST, and a server that has stopped answering is a common
  # reason to be here.
  var cancelling: Future[void]
  try:
    cancelling = client.sendNotification("notifications/cancelled",
      %*{"requestId": id, "reason": reason})
  except CatchableError as e:
    stderr.writeLine("[mcp-client] could not cancel request " & id & ": " & peerText(e.msg))
    return
  cancelling.addCallback(proc() =
    if cancelling.failed:
      stderr.writeLine("[mcp-client] could not cancel request " & id & ": " &
                       peerText(cancelling.readError().msg)))

proc sendOnce(client: McpClient, methodName: string, params: JsonNode,
              options: McpRequestOptions): Future[JsonRpcResponse] {.async.} =
  ## One request and its response, with none of the retrying of multi
  ## round-trip requests.
  if not options.cancel.isNil and options.cancel.isCancelled:
    raise newException(McpCancelledError, methodName & ": cancelled before it was sent")
  let modern = client.usesModernProtocol
  var wireParams = params
  if modern and not options.traceContext.isEmpty:
    let problem = options.traceContext.validate
    if problem.isSome:
      raise newException(ValueError, methodName & ": " & problem.get)
    wireParams = withTraceContext(wireParams, options.traceContext)
  var progressKey = ""
  if not options.onProgress.isNil:
    inc client.nextProgressToken
    progressKey = "mcp-progress-" & $client.nextProgressToken
    wireParams = withRequestMeta(params, %*{"progressToken": progressKey})
  if modern:
    wireParams = withRequestMeta(wireParams, requestMeta(
      client.negotiatedVersion.get, client.clientInfo,
      client.capabilities.forVersion(client.negotiatedVersion.get).toJson()))
  # Registered before sending: a progress notification may be the first
  # thing to come back.
  if progressKey.len > 0:
    client.progressCallbacks[progressKey] = options.onProgress
  var response: JsonRpcResponse
  try:
    let started = client.beginRequest(methodName, wireParams)
    let timeoutMs = options.timeoutMs.get(client.requestTimeoutMs)
    let timer = if timeoutMs > 0: sleepAsync(timeoutMs)
                else: newFuture[void]("McpClient.noTimeout")
    let cancelled = if options.cancel.isNil: newFuture[void]("McpClient.noCancel")
                    else: options.cancel.signal
    await (started.response or timer or cancelled)
    if started.response.finished:
      response = started.response.read
    elif cancelled.finished:
      let reason = options.cancel.reason
      await client.abandon(started.id, methodName, reason, unsent = not started.sent.finished)
      raise newException(McpCancelledError, methodName & ": cancelled" &
        (if reason.len > 0: " (" & reason & ")" else: ""))
    else:
      await client.abandon(started.id, methodName,
        "no response within " & $timeoutMs & " ms", unsent = not started.sent.finished)
      raise newException(McpTimeoutError,
        methodName & ": no response within " & $timeoutMs & " ms")
  finally:
    if progressKey.len > 0:
      client.progressCallbacks.del(progressKey)
  return response

proc answerInputRequests(client: McpClient, methodName: string,
                         pending: InputRequired): Future[JsonNode] {.async.} =
  ## The `inputResponses` for a request the server answered with
  ## `input_required`: each input request goes to the handler the client
  ## registered for its method (the same handlers that serve the server's
  ## requests in earlier versions), one after the other. Raises
  ## McpProtocolError for a request the client did not declare the
  ## capability for, McpUnsupportedError for one it has no handler for, and
  ## McpRequestError when a handler answers with an error: an
  ## `InputResponse` cannot carry one, so the request is abandoned.
  result = newJObject()
  if pending.inputRequests.isNil:
    return
  let declared = client.capabilities.toJson()
  for key, entry in pending.inputRequests.pairs:
    let inputMethod = entry{"method"}.getStr()
    let undeclared = missingCapabilities(%*{key: entry}, declared)
    if undeclared.len > 0:
      raise newException(McpProtocolError, methodName & ": the server asked for " &
        inputMethod & ", but this client did not declare " & $undeclared)
    if inputMethod notin client.requestHandlers:
      raise newException(McpUnsupportedError, methodName & ": this client has no " &
        "handler for " & inputMethod)
    let asked = newJsonRpcRequest(key, inputMethod, entry{"params"})
    let answer = await client.requestHandlers[inputMethod](asked)
    if answer.error.isSome:
      let error = answer.error.get
      var failure = newException(McpRequestError, inputMethod & ": " & error.message)
      failure.code = error.code
      failure.data = error.data
      raise failure
    result[key] = answer.result.get(newJObject())

const MaxToolListPagesOnMismatch = 100
  ## How many pages of tools/list are read to find one tool again.

proc refusedForParamHeaders(client: McpClient, methodName: string,
                            response: JsonRpcResponse): bool =
  ## Whether a tools/call was refused as a header mismatch over a transport
  ## that carries `Mcp-Param-*` headers (2026-07-28, Streamable HTTP).
  methodName == "tools/call" and response.error.isSome and
    response.error.get.code == ErrHeaderMismatch and
    client.usesModernProtocol and client.negotiatedVersion.get.has(ftParameterHeaders) and
    client.transport.kind != mtkStdio

proc listToolsAgainFor(client: McpClient, toolName: string,
                       options: McpRequestOptions): Future[bool] {.async.} =
  ## Read tools/list until `toolName` is seen, so the transport learns the
  ## headers the tool declares now. False when the list could not be read
  ## or does not have the tool; the caller then keeps the refusal it got.
  var cursor = none(string)
  for _ in 1 .. MaxToolListPagesOnMismatch:
    let params = if cursor.isSome: %*{"cursor": cursor.get} else: newJObject()
    let page = await client.sendOnce("tools/list", params,
      McpRequestOptions(timeoutMs: options.timeoutMs, cancel: options.cancel))
    if page.error.isSome:
      stderr.writeLine("[mcp-client] tools/list after a header mismatch failed: " &
                       peerText(page.error.get.message))
      return false
    let listed = page.result.get(newJObject())
    for tool in listed{"tools"}.getElems():
      if tool{"name"}.getStr() == toolName:
        return true
    let next = listed{"nextCursor"}
    if next.isNil or next.kind != JString:
      return false
    cursor = some(next.getStr())
  stderr.writeLine("[mcp-client] tools/list after a header mismatch has more than " &
                   $MaxToolListPagesOnMismatch & " pages; '" & toolName & "' was not found")
  return false

proc sendRequest*(client: McpClient, methodName: string, params: JsonNode,
                  options: McpRequestOptions = McpRequestOptions()): Future[JsonRpcResponse] {.async.} =
  ## Send a request and wait for its response. A JSON-RPC error response is
  ## returned, not raised; see `callMethod` for the raising form. Raises
  ## McpTimeoutError, McpCancelledError or McpConnectionClosedError when no
  ## response will come.
  ##
  ## In 2026-07-28 a server may answer `tools/call`, `prompts/get` and
  ## `resources/read` with `input_required` and the requests it needs
  ## answered. This collects the answers (see `answerInputRequests`) and
  ## retries the request, with a new id each time, until it completes; the
  ## timeout of the options applies to each attempt, not to the time spent
  ## answering. More than `maxInputRounds` retries raise McpInputRoundsError.
  ##
  ## Over Streamable HTTP in 2026-07-28, a `tools/call` refused as a header
  ## mismatch (-32020) is retried once after tools/list has been read again,
  ## in case the tool's `x-mcp-header` declarations changed; a second
  ## refusal, or a list without the tool, returns the refusal.
  var current = params
  var rounds = 0
  var toolsListedAgain = false
  while true:
    let response = await client.sendOnce(methodName, current, options)
    if not toolsListedAgain and client.refusedForParamHeaders(methodName, response):
      # The tool's `x-mcp-header` declarations may have changed since the
      # client last listed it: list again and retry, once.
      toolsListedAgain = true
      if await client.listToolsAgainFor(current{"name"}.getStr(), options):
        continue
      return response
    if not client.usesModernProtocol or response.result.isNone:
      return response
    case resultKind(response.result.get)
    of rkComplete:
      return response
    of rkInputRequired:
      if not supportsInputRequired(methodName):
        raise newException(McpProtocolError, methodName &
          ": the server answered with input_required, which this request does not allow")
      let (pending, problem) = parseInputRequired(response.result.get)
      if problem.isSome:
        raise newException(McpProtocolError, methodName & ": " & problem.get)
      inc rounds
      if rounds > client.maxInputRounds:
        raise newException(McpInputRoundsError, methodName & ": the server asked for " &
          "input more than " & $client.maxInputRounds & " times")
      let responses = await client.answerInputRequests(methodName, pending)
      current = retryParams(params, responses, pending.requestState)
    of rkUnknown:
      let declared = response.result.get{"resultType"}
      if declared.kind != JString or declared.getStr() notin client.extensionResultTypes:
        raise newException(ValueError,
          methodName & ": the server answered with unknown resultType " & $declared)
      return response

proc requireFeature*(client: McpClient, feature: McpFeature, operation: string) =
  ## Raise McpUnsupportedError unless the negotiated version has `feature`.
  if client.negotiatedVersion.isNone:
    raise newException(McpConnectionClosedError,
      operation & ": the client is not connected")
  if not client.negotiatedVersion.get.has(feature):
    raise newException(McpUnsupportedError,
      operation & ": " & $feature & " is not part of protocol version " &
      $client.negotiatedVersion.get)

proc requireServerCapability*(client: McpClient, declared: bool, operation: string,
                              capability: string) =
  ## `declared` is whether the server's capabilities include `capability`.
  if not declared:
    raise newException(McpUnsupportedError,
      operation & ": the server does not declare the " & capability & " capability")

proc callMethod*(client: McpClient, methodName: string, params: JsonNode,
                 options: McpRequestOptions = McpRequestOptions()): Future[JsonNode] {.async.} =
  ## Like sendRequest, but a JSON-RPC error response raises McpRequestError
  ## and the result is returned directly. Every typed operation of this
  ## client goes through here, so they all report failures the same way.
  let response = await client.sendRequest(methodName, params, options)
  if response.error.isSome:
    let error = response.error.get
    var failure = newException(McpRequestError, methodName & ": " & error.message)
    failure.code = error.code
    failure.data = error.data
    raise failure
  if response.result.isNone:
    raise newException(McpProtocolError, methodName & ": the response has neither result nor error")
  return response.result.get

proc extractServerCapabilities(json: JsonNode): McpServerCapabilities =
  result = McpServerCapabilities()

  # A peer that sends null for a capability has not declared it.
  proc declared(name: string): JsonNode =
    let node = json{name}
    if not node.isNil and node.kind == JObject: node else: nil

  let promptsJson = declared("prompts")
  if not promptsJson.isNil:
    result.prompts = some(McpPromptsCapability(
      listChanged: promptsJson{"listChanged"}.getBool()
    ))

  let resourcesJson = declared("resources")
  if not resourcesJson.isNil:
    result.resources = some(McpResourcesCapability(
      subscribe: resourcesJson{"subscribe"}.getBool(),
      listChanged: resourcesJson{"listChanged"}.getBool()
    ))

  let toolsJson = declared("tools")
  if not toolsJson.isNil:
    result.tools = some(McpToolsCapability(
      listChanged: toolsJson{"listChanged"}.getBool()
    ))

  if not declared("logging").isNil:
    result.logging = some(McpLoggingCapability())

  if not declared("completions").isNil:
    result.completions = some(McpCompletionsCapability())

  result.tasks = tasksCapabilityFromJson(json{"tasks"})

  let experimentalJson = declared("experimental")
  if not experimentalJson.isNil:
    result.experimental = some(experimentalJson)

  let extensionsJson = declared("extensions")
  if not extensionsJson.isNil:
    result.extensions = some(extensionsJson)

  # What the core does not define is kept for the extensions that read it.
  const known = ["prompts", "resources", "tools", "logging", "completions", "tasks",
                 "experimental", "extensions"]
  if not json.isNil and json.kind == JObject:
    var other = newJObject()
    for name, settings in json.pairs:
      if name notin known and settings.kind == JObject:
        other[name] = settings
    if other.len > 0:
      result.additional = some(other)

type ModernServerRefusedInitialize = object of ValueError
  ## The server answered initialize with a 2026-07-28 error: it is a
  ## modern server, whatever the probe showed.

proc spokenVersions(client: McpClient, offered: JsonNode): seq[McpProtocolVersion]

proc parseServerIdentity(client: McpClient, node: JsonNode,
                         context: string): McpServerInfo =
  ## The server's Implementation; a field of the wrong type is a protocol error.
  try:
    wire.parseServerInfo(node)
  except McpShapeError as e:
    raise newException(McpProtocolError, context & ": serverInfo: " & e.msg)

proc initialize*(client: McpClient): Future[McpServerCapabilities] {.async.} =
  if client.state != mlsUninitialized:
    raise newException(ValueError, "Client already initialized")

  let supported = spokenVersionsUpTo(client.protocolVersion)
  let offered = latestLegacyVersion(supported)
  if offered.isNone:
    raise newException(ValueError,
      "initialize needs a protocol version before " & $FirstModernProtocolVersion)

  let request = createInitializeRequest(
    client.clientInfo,
    offered.get,
    client.capabilities,
    client.legacyExtensions
  )

  let response = await client.sendRequest("initialize", request.params)

  if response.error.isSome:
    let error = response.error.get
    if error.code == ErrUnsupportedProtocolVersion and not error.data.isNil and
       client.spokenVersions(error.data{"supported"}).anyIt(isModern(it)):
      raise newException(ModernServerRefusedInitialize,
        "Initialization failed: " & error.message)
    raise newException(ValueError, "Initialization failed: " & error.message)

  let resultData = response.result.get

  let serverVersionText = resultData{"protocolVersion"}.getStr()
  let serverVersion = parseProtocolVersion(serverVersionText)
  if serverVersion.isNone or isModern(serverVersion.get) or
     serverVersion.get notin supported:
    raise newException(ValueError,
      "Server chose protocol version '" & serverVersionText &
      "', which this client does not speak")
  client.negotiatedVersion = serverVersion
  client.transport.protocolVersionNegotiated(serverVersion.get)

  # Extract server capabilities
  let capabilities = extractServerCapabilities(resultData{"capabilities"})
  client.serverCapabilities = some(capabilities)
  if resultData.hasKey("serverInfo"):
    client.serverInfo = some(client.parseServerIdentity(resultData["serverInfo"], "initialize"))

  # Change state
  client.state = mlsInitializing

  # Send initialized notification
  await client.sendNotification("notifications/initialized", newJObject())

  # Change state
  client.state = mlsOperational

  return capabilities

proc capabilities*(client: McpClient): Option[McpServerCapabilities] =
  ## Server capabilities learned during `connect()`.
  ## Returns `none` until the connection is established.
  client.serverCapabilities

proc spokenVersions(client: McpClient, offered: JsonNode): seq[McpProtocolVersion] =
  ## The versions in a peer's list that this client speaks too.
  if offered.isNil or offered.kind != JArray:
    return @[]
  for node in offered:
    let parsed = parseProtocolVersion(node.getStr())
    if parsed.isSome and parsed.get <= client.protocolVersion:
      result.add parsed.get

proc newestModern(versions: seq[McpProtocolVersion]): Option[McpProtocolVersion] =
  for v in versions:
    if isModern(v) and (result.isNone or v > result.get):
      result = some(v)

proc noCommonVersion(client: McpClient, offered: JsonNode): ref ValueError =
  newException(ValueError,
    "No protocol version in common: the server supports " &
    (if offered.isNil: "none" else: $offered) & ", this client speaks up to " &
    $client.protocolVersion)

type ProbeVerdict = enum
  pvModern   ## the connection is established in that era
  pvLegacy   ## the server answered like a legacy one
  pvSilent   ## no answer in time: a legacy stdio server may never answer

proc discover(client: McpClient, timeoutMs: int): Future[ProbeVerdict] {.async.} =
  ## Probe for a 2026-07-28 server. Raises when the server is modern but
  ## shares no version.
  var version = client.protocolVersion
  for attempt in 0 .. 1:
    let meta = requestMeta(version, client.clientInfo,
                           client.capabilities.forVersion(version).toJson())
    let started = client.beginRequest(DiscoverMethod, withRequestMeta(nil, meta))
    var answered = false
    try:
      answered = await withTimeout(started.response, timeoutMs)
    except McpAuthorizationError as e:
      # Not an answer about versions: the handshake of another era would be
      # refused the same way, and its failure would hide this one.
      raise e
    except McpTransportError:
      # A legacy HTTP server rejects the probe without a JSON-RPC body.
      return pvLegacy
    if not answered:
      # A legacy stdio server may not answer a request before initialize.
      client.pendingRequests.del(started.id)
      if not started.sent.finished:
        client.transport.cancelRequest(started.id)
      return pvSilent

    let response = started.response.read
    if response.error.isSome:
      let error = response.error.get
      if error.code != ErrUnsupportedProtocolVersion:
        # Legacy servers answer the probe with implementation-defined errors.
        return pvLegacy
      let offered = error.data{"supported"}
      let common = client.spokenVersions(offered)
      let modernChoice = newestModern(common)
      if modernChoice.isSome and attempt == 0:
        version = modernChoice.get
        continue
      if common.len > 0 and modernChoice.isNone:
        return pvLegacy
      raise client.noCommonVersion(offered)

    let discovered = response.result.get
    let offered = discovered{"supportedVersions"}
    let common = client.spokenVersions(offered)
    let modernChoice = newestModern(common)
    if modernChoice.isNone:
      if common.len > 0:
        return pvLegacy
      raise client.noCommonVersion(offered)

    client.negotiatedVersion = modernChoice
    client.serverCapabilities = some(extractServerCapabilities(discovered{"capabilities"}))
    client.serverInstructions = discovered{"instructions"}.getStr()
    let identity = discovered{"_meta", MetaServerInfo}
    if not identity.isNil and identity.kind == JObject:
      client.serverInfo = some(client.parseServerIdentity(identity, DiscoverMethod))
    client.state = mlsOperational
    return pvModern
  return pvLegacy

proc connect*(client: McpClient, transport: McpTransport): Future[void] {.async.} =
  ## Attach `transport` and establish the connection: with server/discover
  ## when this client speaks 2026-07-28 and the server does too, otherwise
  ## with the initialize handshake.
  client.transport = transport

  # Start message processing
  asyncCheck client.processMessages()

  var verdict = pvLegacy
  if isModern(client.protocolVersion):
    verdict = await client.discover(client.probeTimeoutMs)
    if verdict == pvModern:
      return

  # The returned capabilities are stored on `client.serverCapabilities`
  # (audit #9); callers can inspect them via `client.capabilities()`.
  try:
    discard await client.initialize()
  except ModernServerRefusedInitialize:
    # A server too slow to answer the probe in time shows what it is by
    # refusing initialize with a modern error. Ask again, now that it is
    # known to answer, for as long as any request may take.
    if verdict != pvSilent:
      raise
    let confirmed = await client.discover(client.requestTimeoutMs)
    if confirmed != pvModern:
      raise

proc close*(client: McpClient): Future[void] {.async.} =
  client.state = mlsShutdown
  client.failPending("the client was closed")
  if not client.transport.isNil:
    await client.transport.close()
