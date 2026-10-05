## MCP client implementation

import asyncdispatch, json, options, tables, strutils, sequtils, uuids
import ../protocol/types
import ../protocol/lifecycle
import ../protocol/modern
import ../protocol/features
import ../transport/transport
import ../mcp/types as mcpTypes

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
    requestHandlers*: Table[string, McpServerRequestHandler]
    notificationHandlers*: Table[string, proc(notification: JsonRpcNotification): Future[void] {.async.}]
    onLogMessage*: proc(message: McpLogMessage) {.closure.}
    onResourceUpdated*: proc(uri: string) {.closure.}
    onToolsListChanged*: proc() {.closure.}
    onResourcesListChanged*: proc() {.closure.}
    onPromptsListChanged*: proc() {.closure.}
    lastTransportError*: ref CatchableError
      ## Set when the message-processing loop terminates due to a transport
      ## error. Mirrors McpServer.lastTransportError — see audit finding #5.

const DefaultRequestTimeoutMs* = 60_000

proc newMcpCancelToken*(): McpCancelToken =
  McpCancelToken(signal: newFuture[void]("McpCancelToken"))

proc cancel*(token: McpCancelToken, reason: string = "") =
  ## Idempotent: only the first call counts.
  if not token.signal.finished:
    token.reason = reason
    token.signal.complete()

proc isCancelled*(token: McpCancelToken): bool = token.signal.finished

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
  else: true

proc logHandlerFailure(what: string) =
  stderr.writeLine("[mcp-client] " & what & " raised " &
                   $getCurrentException().name & ": " & getCurrentExceptionMsg())

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
      logHandlerFailure("handler for " & request.`method`)
      response = newJsonRpcErrorResponse(request.id, -32603, e.msg)
  response.idNode = request.idNode
  await client.transport.sendResponse(response)

proc notify(callback: proc() {.closure.}, what: string) =
  if callback.isNil: return
  try:
    callback()
  except CatchableError:
    logHandlerFailure(what)

proc processNotification(client: McpClient, notification: JsonRpcNotification): Future[void] {.async.} =
  let params = notification.params
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
  else:
    discard
  if notification.`method` in client.notificationHandlers:
    let handler = client.notificationHandlers[notification.`method`]
    try:
      await handler(notification)
    except CatchableError:
      logHandlerFailure("handler for " & notification.`method`)

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
        stderr.writeLine("[mcp-client] invalid message received: " & $json)
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
                      $e.name & ": " & e.msg)
    client.failPending("the transport failed: " & e.msg)

proc ensureOpen(client: McpClient) =
  if client.transport.isNil or client.state == mlsShutdown:
    raise newException(McpConnectionClosedError, "the client is not connected")

proc startRequest(client: McpClient, methodName: string,
                  params: JsonNode): Future[tuple[id: string, response: Future[JsonRpcResponse]]] {.async.} =
  client.ensureOpen()
  let id = $genUUID()
  let promise = newFuture[JsonRpcResponse]("McpClient.request")
  client.pendingRequests[id] = promise
  try:
    await client.transport.sendRequest(newJsonRpcRequest(id, methodName, params))
  except CatchableError as e:
    client.pendingRequests.del(id)
    raise e
  return (id: id, response: promise)

proc sendNotification*(client: McpClient, methodName: string, params: JsonNode): Future[void] {.async.} =
  client.ensureOpen()
  let notification = newJsonRpcNotification(methodName, params)
  await client.transport.sendNotification(notification)

proc abandon(client: McpClient, id, methodName, reason: string) {.async.} =
  ## Stop waiting for `id` and tell the server to stop working on it.
  client.pendingRequests.del(id)
  # initialize must not be cancelled. Over HTTP the 2026-07-28 protocol
  # cancels by closing the request's response stream, not by a message.
  if methodName == "initialize" or client.state == mlsShutdown:
    return
  if client.usesModernProtocol and client.transport.kind != mtkStdio:
    return
  try:
    await client.sendNotification("notifications/cancelled",
      %*{"requestId": id, "reason": reason})
  except CatchableError as e:
    stderr.writeLine("[mcp-client] could not cancel request " & id & ": " & e.msg)

proc sendRequest*(client: McpClient, methodName: string, params: JsonNode,
                  options: McpRequestOptions = McpRequestOptions()): Future[JsonRpcResponse] {.async.} =
  ## Send a request and wait for its response. A JSON-RPC error response is
  ## returned, not raised; see `callMethod` for the raising form. Raises
  ## McpTimeoutError, McpCancelledError or McpConnectionClosedError when no
  ## response will come.
  if not options.cancel.isNil and options.cancel.isCancelled:
    raise newException(McpCancelledError, methodName & ": cancelled before it was sent")
  let modern = client.usesModernProtocol
  var wireParams = params
  var progressKey = ""
  if not options.onProgress.isNil:
    inc client.nextProgressToken
    progressKey = "mcp-progress-" & $client.nextProgressToken
    wireParams = withRequestMeta(params, %*{"progressToken": progressKey})
  if modern:
    wireParams = withRequestMeta(wireParams, requestMeta(
      client.negotiatedVersion.get, client.clientInfo, client.capabilities.toJson()))
  # Registered before sending: a progress notification may be the first
  # thing to come back.
  if progressKey.len > 0:
    client.progressCallbacks[progressKey] = options.onProgress
  var response: JsonRpcResponse
  try:
    let started = await client.startRequest(methodName, wireParams)
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
      await client.abandon(started.id, methodName, reason)
      raise newException(McpCancelledError, methodName & ": cancelled" &
        (if reason.len > 0: " (" & reason & ")" else: ""))
    else:
      await client.abandon(started.id, methodName,
        "no response within " & $timeoutMs & " ms")
      raise newException(McpTimeoutError,
        methodName & ": no response within " & $timeoutMs & " ms")
  finally:
    if progressKey.len > 0:
      client.progressCallbacks.del(progressKey)

  if modern and response.result.isSome:
    case resultKind(response.result.get)
    of rkComplete:
      discard
    of rkInputRequired:
      # TODO: multi round-trip requests (answer inputRequests and resend).
      raise newException(ValueError,
        methodName & ": the server asked for client input (resultType " &
        "input_required), which this client does not support yet")
    of rkUnknown:
      raise newException(ValueError,
        methodName & ": the server answered with unknown resultType " &
        $response.result.get{"resultType"})
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

  let experimentalJson = declared("experimental")
  if not experimentalJson.isNil:
    result.experimental = some(experimentalJson)

proc initialize*(client: McpClient): Future[McpServerCapabilities] {.async.} =
  if client.state != mlsUninitialized:
    raise newException(ValueError, "Client already initialized")

  let supported = versionsUpTo(client.protocolVersion)
  let offered = latestLegacyVersion(supported)
  if offered.isNone:
    raise newException(ValueError,
      "initialize needs a protocol version before " & $FirstModernProtocolVersion)

  let request = createInitializeRequest(
    client.clientInfo,
    offered.get,
    client.capabilities
  )

  let response = await client.sendRequest("initialize", request.params)

  if response.error.isSome:
    let error = response.error.get
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

proc discover(client: McpClient): Future[bool] {.async.} =
  ## Probe for a 2026-07-28 server. True when the connection is established
  ## in that era; false when the server is a legacy one and `initialize`
  ## must follow. Raises when the server is modern but shares no version.
  var version = client.protocolVersion
  for attempt in 0 .. 1:
    let meta = requestMeta(version, client.clientInfo, client.capabilities.toJson())
    var started: tuple[id: string, response: Future[JsonRpcResponse]]
    try:
      started = await client.startRequest(DiscoverMethod, withRequestMeta(nil, meta))
    except McpTransportError:
      # A legacy HTTP server rejects the probe without a JSON-RPC body.
      return false
    if not await withTimeout(started.response, client.probeTimeoutMs):
      # A legacy stdio server may not answer a request before initialize.
      client.pendingRequests.del(started.id)
      return false

    let response = started.response.read
    if response.error.isSome:
      let error = response.error.get
      if error.code != ErrUnsupportedProtocolVersion:
        # Legacy servers answer the probe with implementation-defined errors.
        return false
      let offered = error.data{"supported"}
      let common = client.spokenVersions(offered)
      let modernChoice = newestModern(common)
      if modernChoice.isSome and attempt == 0:
        version = modernChoice.get
        continue
      if common.len > 0 and modernChoice.isNone:
        return false
      raise client.noCommonVersion(offered)

    let discovered = response.result.get
    let offered = discovered{"supportedVersions"}
    let common = client.spokenVersions(offered)
    let modernChoice = newestModern(common)
    if modernChoice.isNone:
      if common.len > 0:
        return false
      raise client.noCommonVersion(offered)

    client.negotiatedVersion = modernChoice
    client.serverCapabilities = some(extractServerCapabilities(discovered{"capabilities"}))
    client.serverInstructions = discovered{"instructions"}.getStr()
    let identity = discovered{"_meta", MetaServerInfo}
    if not identity.isNil and identity.kind == JObject:
      client.serverInfo = some(McpServerInfo(
        name: identity{"name"}.getStr(), version: identity{"version"}.getStr()))
    client.state = mlsOperational
    return true
  return false

proc connect*(client: McpClient, transport: McpTransport): Future[void] {.async.} =
  ## Attach `transport` and establish the connection: with server/discover
  ## when this client speaks 2026-07-28 and the server does too, otherwise
  ## with the initialize handshake.
  client.transport = transport

  # Start message processing
  asyncCheck client.processMessages()

  if isModern(client.protocolVersion) and await client.discover():
    return

  # The returned capabilities are stored on `client.serverCapabilities`
  # (audit #9); callers can inspect them via `client.capabilities()`.
  discard await client.initialize()

proc close*(client: McpClient): Future[void] {.async.} =
  client.state = mlsShutdown
  client.failPending("the client was closed")
  if not client.transport.isNil:
    await client.transport.close()

# High-level Client interface for easier usage
type
  Client* = ref object
    ## High-level client object for MCP operations
    name*: string
    version*: string
    capabilities*: mcpTypes.ClientCapabilities
    transport*: McpTransport
    serverInfo*: Option[mcpTypes.ServerMetadata]
    isInitialized*: bool
    mcpClient*: McpClient

proc newClient*(name: string, version: string, capabilities: mcpTypes.ClientCapabilities,
                protocolVersion: McpProtocolVersion = DefaultProtocolVersion): Client =
  ## Creates a new high-level MCP client that speaks `protocolVersion` and
  ## every earlier version
  let clientInfo = McpClientInfo(
    name: name,
    version: version
  )
  # Convert mcpTypes.ClientCapabilities to McpClientCapabilities
  var mcpCaps = McpClientCapabilities()
  if capabilities.roots.isSome and capabilities.roots.get:
    mcpCaps.roots = some(McpRootsCapability(listChanged: false))
  if capabilities.sampling.isSome and capabilities.sampling.get:
    mcpCaps.sampling = some(McpSamplingCapability())
  if capabilities.experimental.isSome:
    mcpCaps.experimental = capabilities.experimental

  result = Client(
    name: name,
    version: version,
    capabilities: capabilities,
    transport: nil,
    serverInfo: none(mcpTypes.ServerMetadata),
    isInitialized: false,
    mcpClient: newMcpClient(clientInfo, protocolVersion, mcpCaps)
  )
