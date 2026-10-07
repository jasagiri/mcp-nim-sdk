## Client-side Streamable HTTP transport for MCP.
##
## Every JSON-RPC message is POSTed to one endpoint. The server answers a
## request either with a JSON body or with an event stream that carries
## notifications about the request and then its response; both arrive
## through `receiveMessage`, an event at a time as the server sends it.
##
## A request of protocol version 2026-07-28 carries the headers that mirror
## its body (MCP-Protocol-Version, Mcp-Method, Mcp-Name). Requests of the
## earlier Streamable HTTP versions carry the session id the server issued
## and, once negotiated, the protocol version.
##
## Versions 2025-03-26 to 2025-11-25 also have a GET stream, opened once the
## client has said it is initialized, for what the server says outside any
## request; a stream that breaks, GET or POST, is resumed from the last event
## id seen, up to `maxReconnects` times; and `close` ends the session with
## DELETE.
##
## `cancelRequest` gives up on a request by closing its connection, which is
## how a 2026-07-28 client cancels.
##
## From 2026-07-28 a `tools/call` also carries the `Mcp-Param-*` headers its
## tool declared with `x-mcp-header`. The transport learns the declarations
## from the `tools/list` results that pass through it, and drops from those
## results the tools whose declarations are invalid. A call to a tool never
## listed through this transport carries no such headers.

import std/[asyncdispatch, httpcore, json, options, strutils, deques, tables, sets]
import ./transport
import ./event_stream
import ./http_wire as wire
import ./auth_hook
import ../protocol/types
import ../protocol/diagnostic
import ../protocol/modern
import ../protocol/param_headers
import ../protocol/version
import ../protocol/features

const
  DefaultMaxResponseSize* = 16 * 1024 * 1024
  DefaultStreamOpenTimeoutMs* = 30_000
    ## A server that accepted a GET for its stream sends the head at once;
    ## 30 s allows for a slow link and a busy server, not for a silent one.
  DefaultReconnectDelayMs* = 500
  DefaultMaxReconnects* = 5
  ErrStreamClosed* = -32000
    ## Local error (implementation-defined range): the event stream of a
    ## request ended before its response arrived. The request is lost; the
    ## caller may send it again.
  SessionHeader = "Mcp-Session-Id"
  ErrorBodyPreview = 512
  DeleteTimeoutMs = 5000
  MaxAuthRetries = 3

type
  StreamableHttpTransport* = ref object of McpTransport
    baseUrl*: string
    headers*: HttpHeaders
      ## Sent with every request, e.g. Authorization.
    sessionId*: Option[string]
      ## Issued by servers of versions 2025-03-26 to 2025-11-25.
    protocolVersion*: Option[McpProtocolVersion]
      ## The version agreed by initialize; sent as MCP-Protocol-Version.
    maxResponseSize*: int
    connectTimeoutMs*: int
      ## How long to wait for the connection (TCP and, for https, the TLS
      ## handshake) of every request.
    streamOpenTimeoutMs*: int
      ## How long the server may take to start answering a GET that opens its
      ## stream. Not applied to a POST: the answer to a request (a tool call)
      ## may take as long as the caller allows, and the client's own request
      ## timeout (`McpClient.requestTimeoutMs`, applied from `beginRequest`)
      ## ends that wait; a limit here would end it earlier without telling it.
    reconnectDelayMs*: int
      ## How long to wait before resuming a broken stream, unless the server
      ## asked for another delay with `retry`.
    maxReconnects*: int
      ## Consecutive attempts to resume a stream before giving up.
    listenForServerMessages*: bool
      ## Open the GET stream once initialized (versions 2025-03-26 to
      ## 2025-11-25). Turn off for a client that needs nothing from it.
    negotiated: Option[McpProtocolVersion]
    auth*: HttpClientAuth
      ## Authorization (see `auth/client`): adds the Authorization header and
      ## reacts to 401 and 403. Nil: requests carry only `headers`.
    inbox: Deque[JsonNode]
    waiters: Deque[Future[JsonNode]]
    streams: seq[WireResponse]
    inflight: Table[string, WireResponse]
      ## POSTs of requests, by JSON-RPC id, from connecting until answered.
    abandoned: HashSet[string]
    toolListIds: HashSet[string]
      ## Ids of `tools/list` requests of an era with parameter headers.
    paramBindings: Table[string, seq[ParamBinding]]
      ## The `x-mcp-header` properties of each listed tool, by tool name.
    listening: bool
    closed: bool

  HttpTransport* = StreamableHttpTransport

proc newStreamableHttpTransport*(baseUrl: string): StreamableHttpTransport =
  StreamableHttpTransport(
    kind: mtkStreamable,
    baseUrl: baseUrl,
    headers: newHttpHeaders(),
    sessionId: none(string),
    protocolVersion: none(McpProtocolVersion),
    maxResponseSize: DefaultMaxResponseSize,
    connectTimeoutMs: wire.DefaultConnectTimeoutMs,
    streamOpenTimeoutMs: DefaultStreamOpenTimeoutMs,
    reconnectDelayMs: DefaultReconnectDelayMs,
    maxReconnects: DefaultMaxReconnects,
    listenForServerMessages: true,
    inbox: initDeque[JsonNode](),
    waiters: initDeque[Future[JsonNode]](),
    inflight: initTable[string, WireResponse](),
    abandoned: initHashSet[string](),
    toolListIds: initHashSet[string](),
    paramBindings: initTable[string, seq[ParamBinding]](),
  )

proc newHttpTransport*(baseUrl: string): HttpTransport =
  newStreamableHttpTransport(baseUrl)

func idKey(id: JsonNode): string =
  if id.kind == JString: id.getStr() else: $id

proc learnToolHeaders(t: StreamableHttpTransport, result: JsonNode) =
  ## A `tools/list` result: remember what each tool mirrors into headers and
  ## leave out the tools whose declarations are invalid, so one malformed
  ## definition does not keep the others from being used.
  let tools = result{"tools"}
  if tools.isNil or tools.kind != JArray:
    return
  var kept = newJArray()
  for tool in tools:
    let name = tool{"name"}.getStr()
    let declared = declaredParamHeaders(tool{"inputSchema"})
    if declared.invalid.isSome:
      stderr.writeLine("[mcp-http] ignoring tool '" & peerText(name) & "' of " & t.baseUrl &
                       ": " & declared.invalid.get)
      t.paramBindings.del name
      continue
    if declared.bindings.len > 0:
      t.paramBindings[name] = declared.bindings
    else:
      t.paramBindings.del name
    kept.add tool
  result["tools"] = kept

proc deliver(t: StreamableHttpTransport, message: JsonNode) =
  if isResponse(message) and message.hasKey("id") and idKey(message["id"]) in t.toolListIds:
    t.toolListIds.excl idKey(message["id"])
    let listed = message{"result"}
    if not listed.isNil and listed.kind == JObject:
      t.learnToolHeaders(listed)
  if t.waiters.len > 0:
    t.waiters.popFirst().complete(message)
  else:
    t.inbox.addLast(message)

proc parseMessage(t: StreamableHttpTransport, text: string): JsonNode =
  if text.len > t.maxResponseSize:
    raise newException(McpTransportError,
      "message from " & t.baseUrl & " exceeds " & $t.maxResponseSize & " bytes")
  try:
    result = parseJson(text)
  except CatchableError as e:
    raise newException(McpTransportError,
      "invalid JSON-RPC message from " & t.baseUrl & ": " & e.msg)

func jsonRpcErrorIn(body: JsonNode): bool =
  ## Whether an HTTP error body is a JSON-RPC error response, as opposed to
  ## whatever an unrelated server or proxy put there.
  body.kind == JObject and body{"jsonrpc"}.getStr() == "2.0" and
    body{"error"}.kind == JObject and body{"error", "code"}.kind == JInt

proc streamClosed(requestId: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": requestId, "error": {
    "code": ErrStreamClosed,
    "message": "The event stream ended before the response arrived"}}

proc httpError(response: WireResponse, url, text: string): ref McpTransportError =
  result = newException(McpTransportError,
    "HTTP " & $response.code & " from " & url & ": " &
    text[0 ..< min(text.len, ErrorBodyPreview)])
  result.code = response.code.int

proc legacyHeaders(t: StreamableHttpTransport): seq[(string, string)] =
  if t.sessionId.isSome:
    result.add (SessionHeader, t.sessionId.get)
  if t.protocolVersion.isSome:
    result.add (HeaderProtocolVersion, $t.protocolVersion.get)

proc requestHeaders(t: StreamableHttpTransport, accept: string,
                    extra: openArray[(string, string)]): HttpHeaders =
  result = newHttpHeaders({"Accept": accept})
  for name, value in t.headers.pairs:
    result[name] = value
  for (name, value) in extra:
    result[name] = value

proc authorize(t: StreamableHttpTransport, headers: HttpHeaders) {.async.} =
  ## A protected server wants the token on every request, the GET stream and
  ## DELETE included.
  if not t.auth.isNil:
    let authorization = await t.auth.authorization()
    if authorization.isSome:
      headers["Authorization"] = authorization.get

func isEventStream(response: WireResponse): bool =
  response.headers.getOrDefault("Content-Type").toLowerAscii().startsWith("text/event-stream")

proc track(t: StreamableHttpTransport, response: WireResponse) =
  t.streams.add response

proc untrack(t: StreamableHttpTransport, response: WireResponse) =
  response.close()
  let index = t.streams.find(response)
  if index >= 0:
    t.streams.delete(index)

type StreamOutcome = object
  answered: bool
  lastEventId: string
  retryMs: Option[int]
  delivered: bool
    ## At least one message arrived, so the server is working.

proc consume(t: StreamableHttpTransport, response: WireResponse,
             requestId: JsonNode): Future[StreamOutcome] {.async.} =
  ## Deliver the messages of an event stream as they arrive, until it ends
  ## or breaks. Events without data (a priming event) only move the last
  ## event id. A broken stream is logged, and reported by what was learned.
  var parser = initSseParser(t.maxResponseSize, t.maxResponseSize)
  result.answered = requestId.isNil
  try:
    while true:
      let chunk = await response.readSome()
      if chunk.len == 0:
        break
      for event in parser.feed(chunk):
        if event.id.len > 0:
          result.lastEventId = event.id
        if event.data.len == 0:
          continue
        let message = t.parseMessage(event.data)
        if not result.answered and isResponse(message) and message{"id"} == requestId:
          result.answered = true
        result.delivered = true
        t.deliver(message)
  except CatchableError as e:
    # close() and cancelRequest end open streams on purpose; that is not a
    # failure.
    if not t.closed and (requestId.isNil or idKey(requestId) notin t.abandoned):
      stderr.writeLine("[mcp-http] event stream from " & t.baseUrl &
                        " failed with " & $e.name & ": " & peerText(e.msg))
  finally:
    t.untrack(response)
  result.retryMs = parser.retryMs

proc canResume(t: StreamableHttpTransport): bool =
  t.negotiated.isSome and t.negotiated.get.has(ftHttpResumability)

proc openStream(t: StreamableHttpTransport, lastEventId: string): Future[Option[WireResponse]] {.async.} =
  ## GET the stream, naming the last event seen. None when the server
  ## offers none (405) or refuses; the refusal is logged.
  var extra = t.legacyHeaders()
  if lastEventId.len > 0:
    extra.add ("Last-Event-ID", lastEventId)
  let headers = t.requestHeaders("text/event-stream", extra)
  await t.authorize(headers)
  var response: WireResponse
  try:
    response = await wire.request(t.baseUrl, HttpGet, headers,
      connectTimeoutMs = t.connectTimeoutMs, headerTimeoutMs = t.streamOpenTimeoutMs)
  except McpTransportError as e:
    stderr.writeLine("[mcp-http] GET " & t.baseUrl & " failed: " & peerText(e.msg))
    return none(WireResponse)
  if response.code.is2xx and response.isEventStream:
    t.track response
    return some(response)
  response.close()
  if response.code != Http405:
    stderr.writeLine("[mcp-http] GET " & t.baseUrl & " answered HTTP " &
                     $response.code & "; not resuming")
  none(WireResponse)

proc resume(t: StreamableHttpTransport, first: StreamOutcome,
            requestId: JsonNode): Future[bool] {.async.} =
  ## Pick a POST stream up again after it broke. True when the response
  ## arrived.
  var outcome = first
  var attempts = 0
  while not outcome.answered and not t.closed and outcome.lastEventId.len > 0 and
        attempts < t.maxReconnects:
    inc attempts
    await sleepAsync(outcome.retryMs.get(t.reconnectDelayMs))
    if t.closed:
      break
    let response = await t.openStream(outcome.lastEventId)
    if response.isNone:
      break
    let next = await t.consume(response.get, requestId)
    if next.delivered:
      attempts = 0
    outcome = StreamOutcome(answered: next.answered, delivered: next.delivered,
      retryMs: next.retryMs,
      lastEventId: if next.lastEventId.len > 0: next.lastEventId else: outcome.lastEventId)
  return outcome.answered

proc pump(t: StreamableHttpTransport, response: WireResponse,
          requestId: JsonNode) {.async.} =
  ## Deliver the stream of a request. When it ends without that request's
  ## response and cannot be resumed, say so in its place.
  let outcome = await t.consume(response, requestId)
  var answered = outcome.answered
  if not answered and t.canResume:
    answered = await t.resume(outcome, requestId)
  if not answered and not t.closed and idKey(requestId) notin t.abandoned:
    t.deliver(streamClosed(requestId))
  t.abandoned.excl idKey(requestId)

proc listen(t: StreamableHttpTransport) {.async.} =
  ## The GET stream: what the server says outside any request. Kept open for
  ## the life of the transport; a break is followed by a resumption.
  var lastEventId = ""
  var attempts = 0
  while not t.closed and attempts <= t.maxReconnects:
    let response = await t.openStream(lastEventId)
    if response.isNone:
      break
    let outcome = await t.consume(response.get, nil)
    if outcome.lastEventId.len > 0:
      lastEventId = outcome.lastEventId
    if outcome.delivered:
      attempts = 0
    else:
      inc attempts
    if not t.closed:
      await sleepAsync(outcome.retryMs.get(t.reconnectDelayMs))
  t.listening = false

proc startListening(t: StreamableHttpTransport) =
  if t.listening or t.closed or not t.listenForServerMessages or
     t.negotiated.isNone or not t.negotiated.get.has(ftHttpGetStream):
    return
  t.listening = true
  asyncCheck t.listen()

func notAuthorized(status: int, message: string,
                   cause: ref Exception = nil): ref McpAuthorizationError =
  result = newException(McpAuthorizationError, message, cause)
  result.status = status

type AuthChallenged = object of CatchableError
  ## The server answered 401 or 403; `post` hands this to `t.auth`.
  status: int
  wwwAuthenticate: seq[string]

proc pumpAnswer(t: StreamableHttpTransport, response: WireResponse,
                requestId: JsonNode) {.async.} =
  ## `pump`, then forget the request: once its stream is over there is
  ## nothing left to cancel, and `cancelRequest` must do nothing for it.
  try:
    await t.pump(response, requestId)
  finally:
    if not requestId.isNil:
      t.inflight.del idKey(requestId)

proc postOnce(t: StreamableHttpTransport, body: string,
              extraHeaders: seq[(string, string)], requestId: JsonNode) {.async.} =
  if t.closed:
    raise newException(McpTransportError, "transport is closed")
  let headers = t.requestHeaders("application/json, text/event-stream", extraHeaders)
  headers["Content-Type"] = "application/json"
  await t.authorize(headers)

  let key = if requestId.isNil: "" else: idKey(requestId)
  let connected: wire.Connected = proc(connection: WireResponse) {.closure, gcsafe.} =
    if key.len > 0:
      t.inflight[key] = connection
  var response: WireResponse
  try:
    response = await wire.request(t.baseUrl, HttpPost, headers, body, connected,
      connectTimeoutMs = t.connectTimeoutMs)
  except McpTransportError:
    if key.len > 0:
      t.inflight.del key
    if key in t.abandoned:
      # Cancelled while waiting: nobody wants an answer or an error.
      t.abandoned.excl key
      return
    raise

  # Only a successful exchange establishes a session; some servers put a
  # throwaway session id on error responses too.
  if response.code.is2xx and response.headers.hasKey(SessionHeader):
    t.sessionId = some($response.headers[SessionHeader])

  if response.code.is2xx and response.isEventStream:
    t.track response
    asyncCheck t.pumpAnswer(response, requestId)
    return

  var text: string
  try:
    text = await response.readAll(t.maxResponseSize)
  except McpTransportError:
    if key in t.abandoned:
      t.abandoned.excl key
      return
    raise
  finally:
    if key.len > 0:
      t.inflight.del key
    response.close()

  if response.code.is2xx:
    if text.len > 0:
      t.deliver(t.parseMessage(text))
    return

  if not t.auth.isNil and response.code.int in [401, 403]:
    var challenged = newException(AuthChallenged, "HTTP " & $response.code & " from " & t.baseUrl)
    challenged.status = response.code.int
    for value in seq[string](response.headers.getOrDefault("WWW-Authenticate")):
      challenged.wwwAuthenticate.add value
    raise challenged

  # 2026-07-28 servers report protocol errors with an HTTP error status and
  # a JSON-RPC error body; that is an answer, not a transport failure.
  if text.len > 0:
    var errorBody: JsonNode = nil
    try:
      errorBody = parseJson(text)
    except CatchableError:
      errorBody = nil
    if not errorBody.isNil and jsonRpcErrorIn(errorBody):
      # An HTTP error answers the request that was posted, whatever id the
      # server wrote: servers reject before reading the id, and then send
      # null or a placeholder.
      if not requestId.isNil:
        errorBody["id"] = requestId
      t.deliver(errorBody)
      return
  if response.code.int in [401, 403]:
    # Reached without `t.auth`: nothing here can answer the refusal.
    raise notAuthorized(response.code.int, httpError(response, t.baseUrl, text).msg)
  raise httpError(response, t.baseUrl, text)

method cancelRequest*(t: StreamableHttpTransport, requestId: string) =
  ## Give up on a request that was sent, by closing the connection that
  ## carries it: for a 2026-07-28 server that is the cancellation. Nothing
  ## is delivered for the request afterwards, not even an error. Does
  ## nothing for a request that has been answered.
  if not t.inflight.hasKey(requestId):
    return
  t.abandoned.incl requestId
  t.inflight[requestId].close()
  t.inflight.del requestId

proc post(t: StreamableHttpTransport, body: string,
          extraHeaders: seq[(string, string)], requestId: JsonNode) {.async.} =
  ## `postOnce`, repeated when `t.auth` improved the situation after a 401
  ## or 403.
  var retries = 0
  while true:
    try:
      await t.postOnce(body, extraHeaders, requestId)
      return
    except AuthChallenged as challenged:
      if retries >= MaxAuthRetries:
        raise notAuthorized(challenged.status,
          "HTTP " & $challenged.status & " from " & t.baseUrl &
          " after " & $retries & " authorization attempts")
      var retry = false
      try:
        retry = await t.auth.onChallenge(challenged.status, challenged.wwwAuthenticate)
      except CatchableError as e:
        raise notAuthorized(challenged.status,
          "authorization for " & t.baseUrl & " failed: " & e.msg, e)
      if not retry:
        raise notAuthorized(challenged.status,
          "HTTP " & $challenged.status & " from " & t.baseUrl & ": not authorized")
      inc retries


func hasParamHeaders(params: JsonNode): bool =
  ## Whether the request names a version with parameter headers.
  let named = params{"_meta", MetaProtocolVersion}
  if named.isNil or named.kind != JString:
    return false
  let parsed = parseProtocolVersion(named.getStr())
  parsed.isSome and parsed.get.has(ftParameterHeaders)

proc paramHeaderFor(t: StreamableHttpTransport, request: JsonRpcRequest,
                    headers: var seq[(string, string)]) =
  ## Add the `Mcp-Param-*` headers of a `tools/call`. A value that cannot be
  ## mirrored is an error here, not a request the server must reject.
  let name = request.params{"name"}
  if name.isNil or name.kind != JString or not t.paramBindings.hasKey(name.getStr()):
    return
  let refusal = paramHeadersFor(t.paramBindings[name.getStr()],
                                request.params{"arguments"}, headers)
  if refusal.isSome:
    raise newException(McpTransportError,
      "tools/call " & name.getStr() & ": " & refusal.get)

method sendRequest*(t: StreamableHttpTransport, request: JsonRpcRequest): Future[void] {.async.} =
  var headers =
    if isModernRequest(request.params):
      modernRequestHeaders(request.`method`, request.params)
    else:
      t.legacyHeaders()
  let message = request.toJson()
  if request.params.hasParamHeaders:
    case request.`method`
    of "tools/list":
      t.toolListIds.incl idKey(message["id"])
    of "tools/call":
      t.paramHeaderFor(request, headers)
    else:
      discard
  try:
    await t.post($message, headers, message["id"])
  except CatchableError:
    t.toolListIds.excl idKey(message["id"])
    raise

method sendNotification*(t: StreamableHttpTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  await t.post(encodeMessage(notification), t.legacyHeaders(), nil)
  if notification.`method` == "notifications/initialized":
    t.startListening()

method sendResponse*(t: StreamableHttpTransport, response: JsonRpcResponse): Future[void] {.async.} =
  ## Answers a request the server sent on a stream (versions before
  ## 2026-07-28).
  await t.post(encodeMessage(response), t.legacyHeaders(), nil)

method protocolVersionNegotiated*(t: StreamableHttpTransport, version: McpProtocolVersion) =
  t.negotiated = some(version)
  # The header exists from 2025-06-18 on.
  if version.has(ftProtocolVersionHeader) and not isModern(version):
    t.protocolVersion = some(version)

method receiveMessage*(t: StreamableHttpTransport): Future[JsonNode] {.async.} =
  if t.inbox.len > 0:
    return t.inbox.popFirst()
  if t.closed:
    raise newException(McpTransportError, "transport is closed")
  let waiter = newFuture[JsonNode]("StreamableHttpTransport.receiveMessage")
  t.waiters.addLast(waiter)
  return await waiter

proc endSession(t: StreamableHttpTransport) {.async.} =
  ## Tell the server the session is over (DELETE). A server may refuse
  ## (405); any other refusal or failure is logged, as the client is
  ## leaving either way.
  let headers = t.requestHeaders("application/json", t.legacyHeaders())
  await t.authorize(headers)
  try:
    let attempt = wire.request(t.baseUrl, HttpDelete, headers,
      connectTimeoutMs = t.connectTimeoutMs, headerTimeoutMs = DeleteTimeoutMs)
    if not await withTimeout(attempt, DeleteTimeoutMs):
      stderr.writeLine("[mcp-http] DELETE " & t.baseUrl & " timed out")
      return
    let response = attempt.read()
    response.close()
    if not response.code.is2xx and response.code != Http405:
      stderr.writeLine("[mcp-http] DELETE " & t.baseUrl & " answered HTTP " & $response.code)
  except McpTransportError as e:
    stderr.writeLine("[mcp-http] DELETE " & t.baseUrl & " failed: " & peerText(e.msg))

method close*(t: StreamableHttpTransport): Future[void] {.async.} =
  if t.closed:
    return
  t.closed = true
  for response in t.streams:
    response.close()
  t.streams.setLen(0)
  while t.waiters.len > 0:
    t.waiters.popFirst().fail(newException(McpTransportError, "transport is closed"))
  if t.sessionId.isSome and t.negotiated.isSome and t.negotiated.get.has(ftHttpSessions):
    await t.endSession()
