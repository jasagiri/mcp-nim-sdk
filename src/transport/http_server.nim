## Server-side Streamable HTTP transport for MCP.
##
## Listens on `host:port` and accepts JSON-RPC 2.0 POSTs at `path`
## (default `/mcp`). Each request is handed to `McpServer` through the
## `receiveMessage` / `sendResponse` pipeline, and the matching response is
## written back on the HTTP exchange that carried the request.
##
## A request of protocol version 2026-07-28 is checked here before the
## server sees it: its headers must mirror its body, and its metadata must
## be complete, as that version requires of an HTTP endpoint.
##
## Clients of versions 2025-03-26 to 2025-11-25 each get a session: the
## answer to initialize carries Mcp-Session-Id, later requests must name it,
## and DELETE ends it. 2026-07-28 requests are stateless and carry none.
##
## A request is answered with a JSON body, or, when the server says something
## about it before it answers (progress, logs, requests of its own), with an
## event stream that ends with the response. The server tells the transport
## which request a message belongs to through `MessageRoute`. Versions
## 2025-03-26 to 2025-11-25 also have a GET stream for the messages that
## belong to no request, event ids and `Last-Event-ID` to resume a stream
## after a lost connection, and (2025-03-26 only) JSON-RPC batches.
##
## In 2026-07-28 closing the connection of a request in progress is how a
## client cancels it: the transport calls `onRequestCancelled`. Earlier
## versions treat a lost connection as a network failure and keep the
## request running, its stream resumable.
##
## Sessions that stay idle for `sessionIdleTimeoutMs` are dropped.
##
## The HTTP+SSE transport of 2024-11-05 is served alongside, for clients that
## only speak it: a GET on `legacySsePath` opens an event stream whose first
## event names the endpoint (`legacyMessagesPath`) to POST to, and the
## server's messages follow as `message` events. The connection is the
## session. Set `legacySsePath` to "" to turn it off.
##
## TODO (2026-07-28): `subscriptions/listen`.

import std/[asyncdispatch, asyncnet, asynchttpserver, httpcore, json, tables, deques,
             options, uri, nativesockets, sysrand, strutils, sequtils, times]
import ./transport
import ./sse_stream
import ./auth_hook
import ../protocol/types
import ../protocol/modern
import ../protocol/param_headers
import ../protocol/version
import ../protocol/features

const
  DefaultMaxBodySize* = 4 * 1024 * 1024
  DefaultMaxSessions* = 1024
  DefaultMaxStoredStreams* = 64
  DefaultSessionIdleTimeoutMs* = 30 * 60 * 1000
  SweepIntervalMs = 250
  SessionHeader = "Mcp-Session-Id"
  ErrParse = -32700
  ErrInvalidRequest = -32600

type
  Group = ref object
    ## The requests of one POST, and the stream their answers travel on.
    stream: SseStream
    session: string
    exchangeIds: seq[string]
    pending: int
    responses: seq[JsonRpcResponse]
    notified: bool
      ## The server sent something besides a response: it takes a stream.
    abandoned: bool
      ## The client cancelled; whatever the server still sends is dropped.
    opensSession: bool
    isBatch: bool
    modern: bool
    settled: Future[void]
      ## Completes when the answer's shape is known: the first message
      ## besides a response, or the last response.

  Exchange = object
    ## An HTTP request waiting for its JSON-RPC response.
    group: Group
      ## nil for a request of the HTTP+SSE transport: its answer goes to the
      ## event stream of `legacySession`.
    legacySession: string
    idNode: JsonNode  ## the id the client used, restored on the response

  Session = ref object
    version: McpProtocolVersion
      ## What initialize agreed; known from the server's answer to it.
    lastActive: float
    busy: int
      ## Requests and streams in progress; such a session is not idle.
    streams: OrderedTable[string, SseStream]
      ## Streams of POSTs that a client may resume.
    listen: SseStream
      ## The GET stream: what the server says outside any request.
    legacy: bool
      ## A session of the HTTP+SSE transport: `listen` is its only stream,
      ## and it lasts as long as the connection.

  HttpServerTransport* = ref object of McpTransport
    server*:          AsyncHttpServer
    host*:            string
    port*:            int
      ## The port to bind; 0 picks a free one. After `listen` it is the
      ## port actually bound.
    path*:            string
    protocolVersion*: McpProtocolVersion
      ## The newest version served here; set it to the server's.
    maxBodySize*:     int
      ## Enforced by the HTTP server itself (413); fixed at construction.
    auth*:            HttpServerAuth
      ## Authorization (see `auth/resource_server`): answers metadata
      ## requests and rejects requests without an acceptable token. Nil: the
      ## endpoint is open.
    allowedOrigins*:  seq[string]
      ## Origins accepted besides loopback ones, e.g. "https://app.example".
    maxSessions*:     int
      ## New clients are refused (503) while this many sessions are open.
    maxStreamEvents*: int
      ## Events each stream remembers for resumption; a client that falls
      ## further behind cannot resume.
    maxStoredStreams*: int
      ## Finished streams a session keeps for resumption.
    sessionIdleTimeoutMs*: int
      ## A session unused for this long, with nothing in progress, is
      ## dropped; 0 keeps sessions until DELETE.
    legacySsePath*: string
      ## Where the HTTP+SSE transport of 2024-11-05 opens its event stream;
      ## "" does not serve it.
    legacyMessagesPath*: string
      ## Where clients of that transport POST, named by the first event.
    sessions:         Table[string, Session]
    requestQueue:     Deque[McpIncoming]
    receiveWaiters:   Deque[Future[McpIncoming]]
    exchanges:        Table[string, Exchange]
      ## Keyed by an id made here: two clients may use the same JSON-RPC id.
    exchangeCount:    int
    started*:         bool

proc newHttpServerTransport*(host: string = "127.0.0.1",
                             port: int = 9011,
                             path: string = "/mcp",
                             protocolVersion: McpProtocolVersion = DefaultProtocolVersion,
                             maxBodySize: int = DefaultMaxBodySize): HttpServerTransport =
  requireSupported(protocolVersion)
  result = HttpServerTransport(
    kind:             mtkHttp,
    server:           newAsyncHttpServer(maxBody = maxBodySize),
    host:             host,
    port:             port,
    path:             path,
    protocolVersion:  protocolVersion,
    maxBodySize:      maxBodySize,
    allowedOrigins:   @[],
    maxSessions:      DefaultMaxSessions,
    maxStreamEvents:  DefaultMaxStreamEvents,
    maxStoredStreams: DefaultMaxStoredStreams,
    sessionIdleTimeoutMs: DefaultSessionIdleTimeoutMs,
    legacySsePath:    "/sse",
    legacyMessagesPath: "/messages",
    sessions:         initTable[string, Session](),
    requestQueue:     initDeque[McpIncoming](),
    receiveWaiters:   initDeque[Future[McpIncoming]](),
    exchanges:        initTable[string, Exchange](),
    started:          false,
  )

method receive*(t: HttpServerTransport): Future[McpIncoming] {.async.} =
  if t.requestQueue.len > 0:
    return t.requestQueue.popFirst()
  let fut = newFuture[McpIncoming]("HttpServerTransport.receive")
  t.receiveWaiters.addLast(fut)
  return await fut

method receiveMessage*(t: HttpServerTransport): Future[JsonNode] {.async.} =
  return (await t.receive()).message

proc sessionCount*(t: HttpServerTransport): int =
  t.sessions.len

proc pendingExchangeCount*(t: HttpServerTransport): int =
  ## Requests handed to the server and not yet answered.
  t.exchanges.len

proc settle(group: Group) =
  if not group.settled.finished:
    group.settled.complete()

method sendResponse*(t: HttpServerTransport,
                    response: JsonRpcResponse): Future[void] {.async.} =
  if not t.exchanges.hasKey(response.id):
    raise newException(McpTransportError,
      "no HTTP exchange is waiting for response id " & response.id)
  let exchange = t.exchanges[response.id]
  t.exchanges.del(response.id)
  var restored = response
  restored.idNode = exchange.idNode
  if exchange.group.isNil:
    # HTTP+SSE: the answer travels on the event stream. A client that has
    # left is not waiting for it.
    if t.sessions.hasKey(exchange.legacySession):
      discard t.sessions[exchange.legacySession].listen.push($restored.toJson(), "message")
    return
  let group = exchange.group
  if group.abandoned:
    # The client cancelled this request and does not wait for an answer.
    return
  group.responses.add restored
  discard group.stream.push($restored.toJson())
  dec group.pending
  if group.pending == 0:
    group.stream.finish()
  group.settle()

proc newToken(bytes: int): string =
  for b in urandom(bytes):
    result.add toHex(b.int, 2).toLowerAscii()

proc newSessionId(): string =
  ## Unguessable: the id is what ties later requests to a client.
  newToken(16)

proc newStreamId(): string =
  newToken(8)

proc listenStream(t: HttpServerTransport, session: Session): SseStream =
  if session.listen.isNil:
    session.listen = newSseStream(newStreamId(), t.maxStreamEvents)
  session.listen

proc pushTo(session: Session, data: string): bool =
  session.listen.push(data, if session.legacy: "message" else: "")

proc deliver(t: HttpServerTransport, route: MessageRoute, message: JsonNode,
             what: string) =
  ## Put a message the server initiates on the stream `route` names.
  let data = $message
  if route.requestId.len > 0:
    if not t.exchanges.hasKey(route.requestId):
      raise newException(McpTransportError,
        what & " names request " & route.requestId & ", which is not in progress")
    let exchange = t.exchanges[route.requestId]
    if exchange.group.isNil:
      if t.sessions.hasKey(exchange.legacySession):
        discard t.sessions[exchange.legacySession].pushTo(data)
      return
    let group = exchange.group
    if group.modern and what == "request":
      raise newException(McpTransportError,
        "a 2026-07-28 request's stream carries notifications only; " &
        "the server's own requests are part of its result")
    if group.abandoned:
      return
    discard group.stream.push(data)
    group.notified = true
    group.settle()
  elif route.session.len > 0:
    if not t.sessions.hasKey(route.session):
      raise newException(McpTransportError,
        what & " names an unknown session " & route.session)
    let session = t.sessions[route.session]
    discard t.listenStream(session)
    discard session.pushTo(data)
  else:
    # Every client hears a notification once; a request has one addressee.
    if what == "request":
      if t.sessions.len != 1:
        raise newException(McpTransportError,
          "a request needs a session to go to; there are " & $t.sessions.len)
    for session in t.sessions.values:
      discard t.listenStream(session)
      discard session.pushTo(data)

method sendNotification*(t: HttpServerTransport,
                        notification: JsonRpcNotification,
                        route: MessageRoute): Future[void] {.async.} =
  ## With `route.requestId` the notification joins the response stream of
  ## that request (and is dropped if the client has cancelled it); with only
  ## `route.session` it goes to that client's GET stream; with neither, to
  ## every client's. A client that has not opened a GET stream finds the
  ## notification waiting when it does, as far as `maxStreamEvents` allows.
  t.deliver(route, notification.toJson(), "notification " & notification.`method`)

method sendNotification*(t: HttpServerTransport,
                        notification: JsonRpcNotification): Future[void] {.async.} =
  t.deliver(MessageRoute(), notification.toJson(), "notification " & notification.`method`)

method sendRequest*(t: HttpServerTransport, request: JsonRpcRequest,
                    route: MessageRoute): Future[void] {.async.} =
  ## Like `sendNotification`. The client answers with a POST of the response,
  ## which `receive` hands over like any other message.
  t.deliver(route, request.toJson(), "request")

method sendRequest*(t: HttpServerTransport,
                   request: JsonRpcRequest): Future[void] {.async.} =
  t.deliver(MessageRoute(), request.toJson(), "request")

proc endSession*(t: HttpServerTransport, id: string) =
  ## Forget the session, end its streams and tell the server.
  if not t.sessions.hasKey(id):
    return
  let session = t.sessions[id]
  t.sessions.del(id)
  for stream in session.streams.values:
    stream.finish()
  if not session.listen.isNil:
    session.listen.finish()
  if not t.onSessionEnd.isNil:
    t.onSessionEnd(id)

proc expireIdleSessions*(t: HttpServerTransport) =
  ## Drop the sessions that have been unused for `sessionIdleTimeoutMs`.
  ## A session with a request or a stream in progress is in use.
  if t.sessionIdleTimeoutMs <= 0:
    return
  let now = epochTime()
  var idle: seq[string] = @[]
  for id, session in t.sessions:
    if not session.legacy and session.busy == 0 and
       (now - session.lastActive) * 1000 >= t.sessionIdleTimeoutMs.float:
      idle.add id
  for id in idle:
    t.endSession(id)

method close*(t: HttpServerTransport): Future[void] {.async.} =
  t.started = false
  t.server.close()
  var open: seq[string] = @[]
  for id in t.sessions.keys:
    open.add id
  for id in open:
    t.endSession(id)

proc securityHeaders(contentType = ""): HttpHeaders =
  result = newHttpHeaders({
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'self'",
    "Referrer-Policy": "strict-origin-when-cross-origin",
  })
  if contentType.len > 0:
    result["Content-Type"] = contentType

proc respondEmpty(req: Request, code: HttpCode,
                  extra: openArray[(string, string)] = []): Future[void] =
  let headers = securityHeaders()
  for (name, value) in extra:
    headers[name] = value
  req.respond(code, "", headers)

proc respondJson(req: Request, code: HttpCode, body: JsonNode,
                 extra: openArray[(string, string)] = []): Future[void] =
  let headers = securityHeaders("application/json")
  for (name, value) in extra:
    headers[name] = value
  req.respond(code, $body, headers)

proc respondError(req: Request, code: HttpCode, id: JsonNode,
                  error: JsonRpcError): Future[void] =
  var response = newJsonRpcErrorResponse("", error.code, error.message, error.data)
  response.idNode = if id.isNil: newJNull() else: id
  req.respondJson(code, response.toJson())

func isLoopbackOrigin(origin: string): bool =
  let host = parseUri(origin).hostname
  host in ["localhost", "127.0.0.1", "::1", "[::1]"]

func originAllowed(t: HttpServerTransport, origin: string): bool =
  ## A browser sends Origin; rejecting unknown ones stops a web page from
  ## reaching a local server through DNS rebinding.
  isLoopbackOrigin(origin) or origin in t.allowedOrigins

func header(req: Request, name: string): Option[string] =
  ## A header sent on several lines (Accept often is) reads as one value.
  ## Whitespace around a value is not part of it (RFC 9110 section 5.5).
  if req.headers.hasKey(name):
    some(seq[string](req.headers[name]).join(", ").strip(chars = {' ', '\t'}))
  else: none(string)

func paramHeaders(req: Request): seq[(string, string)] =
  ## The Mcp-Param-* headers of the request, one entry per line sent.
  let prefix = ParamHeaderPrefix.toLowerAscii()
  for name, values in req.headers.table.pairs:
    if name.toLowerAscii().startsWith(prefix):
      for value in values:
        result.add (name, value.strip(chars = {' ', '\t'}))

func namesModernVersion(req: Request): bool =
  ## Whether the version header says 2026-07-28 or later, which is how a
  ## request without the `_meta` fields still reveals its era.
  let named = req.header(HeaderProtocolVersion)
  if named.isNone:
    return false
  let parsed = parseProtocolVersion(named.get)
  parsed.isSome and isModern(parsed.get)

func httpStatusFor(response: JsonRpcResponse, modern: bool): HttpCode =
  ## 2026-07-28 maps some protocol errors onto HTTP statuses.
  if not modern or response.error.isNone:
    return Http200
  case response.error.get.code
  of ErrMethodNotFound: Http404
  of ErrMissingRequiredClientCapability, ErrUnsupportedProtocolVersion,
     ErrHeaderMismatch: Http400
  else: Http200

proc enqueue(t: HttpServerTransport, message: JsonNode, session: string,
             paramHeaders = none(seq[(string, string)])) =
  let incoming = McpIncoming(message: message, session: session,
                             paramHeaders: paramHeaders)
  if t.receiveWaiters.len > 0:
    t.receiveWaiters.popFirst().complete(incoming)
  else:
    t.requestQueue.addLast(incoming)

proc invalidRequest(message: string): JsonRpcError =
  JsonRpcError(code: ErrInvalidRequest, message: message)

proc touch(session: Session) =
  session.lastActive = epochTime()

proc legacyCeiling(t: HttpServerTransport): McpProtocolVersion =
  ## The newest version spoken with an initialize handshake.
  latestLegacyVersion(versionsUpTo(t.protocolVersion)).get(mpv20241105)

proc rememberStream(t: HttpServerTransport, session: Session, stream: SseStream) =
  session.streams[stream.id] = stream
  while session.streams.len > t.maxStoredStreams:
    var oldestFinished = ""
    for id, kept in session.streams:
      if kept.isFinished:
        oldestFinished = id
        break
    if oldestFinished.len == 0:
      break
    session.streams.del(oldestFinished)

proc cancel(t: HttpServerTransport, group: Group) =
  ## The client of a 2026-07-28 request closed its connection.
  group.abandoned = true
  for id in group.exchangeIds:
    if t.exchanges.hasKey(id) and not t.onRequestCancelled.isNil:
      t.onRequestCancelled(group.session, id)

proc versionHeaderError(t: HttpServerTransport, req: Request,
                        session: Session): Option[JsonRpcError] =
  ## From 2025-06-18 a client names the negotiated version on every request;
  ## naming one the server does not speak is a 400. A request without the
  ## header is taken as the version it was negotiated at.
  if not session.version.has(ftProtocolVersionHeader):
    return none(JsonRpcError)
  let named = req.header(HeaderProtocolVersion)
  if named.isNone:
    return none(JsonRpcError)
  let parsed = parseProtocolVersion(named.get)
  if parsed.isNone or isModern(parsed.get) or parsed.get > t.protocolVersion:
    return some(invalidRequest("Unsupported " & HeaderProtocolVersion & ": " &
                               named.get.substr(0, 40)))
  none(JsonRpcError)

proc sessionFor(t: HttpServerTransport, req: Request, id: JsonNode): Future[Session] {.async.} =
  ## The session the request names, or nil after having answered it with
  ## the error that says why there is none.
  let named = req.header(SessionHeader)
  if named.isNone:
    await req.respondError(Http400, id, invalidRequest(SessionHeader & " header is required"))
    return nil
  if not t.sessions.hasKey(named.get) or t.sessions[named.get].legacy:
    await req.respondError(Http404, id, invalidRequest("Session not found"))
    return nil
  result = t.sessions[named.get]

proc handleDelete(t: HttpServerTransport, req: Request) {.async.} =
  let session = req.header(SessionHeader)
  if session.isNone:
    await req.respondError(Http400, nil, invalidRequest(SessionHeader & " header is required"))
  elif session.get notin t.sessions or t.sessions[session.get].legacy:
    await req.respondError(Http404, nil, invalidRequest("Session not found"))
  else:
    t.endSession(session.get)
    await req.respondEmpty(Http200)

func getStreamAvailable(t: HttpServerTransport): bool =
  versionsUpTo(t.protocolVersion).anyIt(it.has(ftHttpGetStream))

proc handleGet(t: HttpServerTransport, req: Request) {.async.} =
  ## The stream of messages that belong to no request, or the rest of an
  ## earlier stream after a lost connection.
  let session = await t.sessionFor(req, nil)
  if session.isNil:
    return
  if not session.version.has(ftHttpGetStream):
    await req.respondEmpty(Http405, {"Allow": "POST, DELETE"})
    return
  let accept = req.header("Accept").get("")
  if "text/event-stream" notin accept:
    await req.respondEmpty(Http406)
    return
  let headerError = t.versionHeaderError(req, session)
  if headerError.isSome:
    await req.respondError(Http400, nil, headerError.get)
    return

  var stream: SseStream
  var after = 0
  let lastEventId = req.header("Last-Event-ID")
  if lastEventId.isSome:
    let parsed = parseEventId(lastEventId.get)
    if parsed.isSome:
      let (streamId, seqNo) = parsed.get
      if session.streams.hasKey(streamId):
        stream = session.streams[streamId]
      elif not session.listen.isNil and session.listen.id == streamId:
        stream = session.listen
      if not stream.isNil and stream.canResumeAfter(seqNo):
        after = seqNo
      else:
        stream = nil
    if stream.isNil:
      await req.respondError(Http400, nil,
        invalidRequest("Cannot resume after that event id"))
      return
  else:
    stream = t.listenStream(session)
    after = stream.writtenUpTo

  inc session.busy
  let gone = watchDisconnect(req.client)
  try:
    discard await serveStream(req, stream, after, securityHeaders(), gone)
  finally:
    dec session.busy
    session.touch()

proc openSession(t: HttpServerTransport, id: string, response: JsonRpcResponse) =
  ## The server accepted an initialize: the client now has a session, at the
  ## version the server's answer names.
  let named = parseProtocolVersion(response.result.get(newJObject()){"protocolVersion"}.getStr())
  let session = Session(version: named.get(t.legacyCeiling),
                        streams: initOrderedTable[string, SseStream]())
  session.touch()
  t.sessions[id] = session

proc answerWithJson(t: HttpServerTransport, req: Request, group: Group,
                    modern: bool) {.async.} =
  var extra = @[("Connection", "close")]
  if group.opensSession and group.responses[0].error.isNone:
    t.openSession(group.session, group.responses[0])
    extra.add (SessionHeader, group.session)
  if group.isBatch:
    await req.respondJson(Http200, %group.responses.mapIt(it.toJson()), extra)
  else:
    await req.respondJson(httpStatusFor(group.responses[0], modern),
                          group.responses[0].toJson(), extra)

proc handlePost(t: HttpServerTransport, req: Request) {.async.} =
  var body: JsonNode
  try:
    body = parseJson(req.body)
  except CatchableError:
    await req.respondError(Http400, nil,
      JsonRpcError(code: ErrParse, message: "Parse error"))
    return
  let isBatch = body.kind == JArray
  if body.kind notin {JObject, JArray}:
    await req.respondError(Http400, nil, invalidRequest("Request must be a JSON object"))
    return
  let items = if isBatch: body.elems else: @[body]
  if items.len == 0 or items.anyIt(it.kind != JObject):
    await req.respondError(Http400, nil,
      invalidRequest("A batch must be a non-empty array of JSON-RPC messages"))
    return

  let rpc = items[0]
  let isRpcRequest = not isBatch and isRequest(rpc)
  let methodName = rpc{"method"}.getStr()
  let params = rpc{"params"}
  let modern = isModern(t.protocolVersion) and isRpcRequest and
               (isModernRequest(params) or req.namesModernVersion)
  let opensSession = not modern and isRpcRequest and methodName == "initialize"
  if isBatch and items.anyIt(isRequest(it) and it{"method"}.getStr() == "initialize"):
    await req.respondError(Http400, nil,
      invalidRequest("initialize must not be part of a batch"))
    return

  var session: Session = nil
  var sessionId = ""
  if modern:
    # A request that lacks the per-request fields is malformed (-32602)
    # whatever its headers say; only a well-formed one can disagree with them.
    let rejection = validateModernRequest(params, versionsUpTo(t.protocolVersion))
    if rejection.isSome and rejection.get.code == ErrInvalidParams:
      await req.respondError(Http400, rpc{"id"}, rejection.get)
      return
    let mismatch = checkRequestHeaders(
      req.header(HeaderProtocolVersion), req.header(HeaderMethod),
      req.header(HeaderName), methodName, params)
    if mismatch.isSome:
      await req.respondError(Http400, rpc{"id"}, mismatch.get)
      return
    if rejection.isSome:
      await req.respondError(Http400, rpc{"id"}, rejection.get)
      return
  elif opensSession:
    if t.sessions.len >= t.maxSessions:
      t.expireIdleSessions()
    if t.sessions.len >= t.maxSessions:
      await req.respondEmpty(Http503)
      return
    sessionId = newSessionId()
  else:
    session = await t.sessionFor(req, rpc{"id"})
    if session.isNil:
      return
    sessionId = req.header(SessionHeader).get
    let headerError = t.versionHeaderError(req, session)
    if headerError.isSome:
      await req.respondError(Http400, rpc{"id"}, headerError.get)
      return
    if isBatch and not session.version.has(ftJsonRpcBatch):
      await req.respondError(Http400, nil, invalidRequest(
        "JSON-RPC batches are not supported by protocol version " & $session.version))
      return
    inc session.busy
  defer:
    if not session.isNil:
      dec session.busy
      session.touch()

  let requests = items.filterIt(isRequest(it))
  if requests.len == 0:
    # Notifications and responses: nothing to answer on this exchange.
    for item in items:
      t.enqueue(item, sessionId)
    await req.respondEmpty(Http202)
    return

  let group = Group(
    stream: newSseStream(newStreamId(), t.maxStreamEvents),
    session: sessionId, pending: requests.len, opensSession: opensSession,
    isBatch: isBatch, modern: modern, settled: newFuture[void]("HttpServerTransport.group"))
  if not session.isNil and session.version.has(ftSsePolling):
    discard group.stream.push("")
  for item in items:
    if not isRequest(item):
      t.enqueue(item, sessionId)
      continue
    inc t.exchangeCount
    let exchangeId = "http-" & $t.exchangeCount
    group.exchangeIds.add exchangeId
    t.exchanges[exchangeId] = Exchange(group: group, idNode: item["id"])
    let forwarded = item.copy()
    forwarded["id"] = %exchangeId
    t.enqueue(forwarded, sessionId,
              if modern: some(req.paramHeaders) else: none(seq[(string, string)]))

  # The connection is watched for the whole exchange, which is why it is
  # closed at the end: the watcher would otherwise eat the next request.
  let gone = watchDisconnect(req.client)
  await (group.settled or gone)
  if not group.settled.finished:
    if modern:
      t.cancel(group)
    req.client.close()
    return

  if group.pending == 0 and not group.notified:
    await t.answerWithJson(req, group, modern)
    req.client.close()
    return

  if not session.isNil:
    t.rememberStream(session, group.stream)
  let ended = await serveStream(req, group.stream, 0, securityHeaders(), gone)
  if ended == seClientGone and modern and group.pending > 0:
    t.cancel(group)

proc handleLegacySse(t: HttpServerTransport, req: Request) {.async.} =
  ## HTTP+SSE: the connection is the session. Its first event names where
  ## to POST.
  if t.sessions.len >= t.maxSessions:
    t.expireIdleSessions()
  if t.sessions.len >= t.maxSessions:
    await req.respondEmpty(Http503)
    return
  let id = newSessionId()
  let session = Session(version: mpv20241105, legacy: true,
                        streams: initOrderedTable[string, SseStream](),
                        listen: newSseStream(newStreamId(), t.maxStreamEvents,
                                             emitIds = false))
  session.touch()
  discard session.listen.push(t.legacyMessagesPath & "?sessionId=" & id, "endpoint")
  t.sessions[id] = session
  let gone = watchDisconnect(req.client)
  try:
    discard await serveStream(req, session.listen, 0, securityHeaders(), gone)
  finally:
    t.endSession(id)

proc handleLegacyPost(t: HttpServerTransport, req: Request) {.async.} =
  var id = ""
  for (name, value) in decodeQuery(req.url.query):
    if name == "sessionId":
      id = value
  if id.len == 0:
    await req.respondError(Http400, nil, invalidRequest("sessionId is required"))
    return
  if not t.sessions.hasKey(id) or not t.sessions[id].legacy:
    await req.respondError(Http404, nil, invalidRequest("Session not found"))
    return
  var message: JsonNode
  try:
    message = parseJson(req.body)
  except CatchableError:
    await req.respondError(Http400, nil, JsonRpcError(code: ErrParse, message: "Parse error"))
    return
  if message.kind != JObject:
    await req.respondError(Http400, nil, invalidRequest("Request must be a JSON object"))
    return
  if isRequest(message):
    inc t.exchangeCount
    let exchangeId = "http-" & $t.exchangeCount
    t.exchanges[exchangeId] = Exchange(legacySession: id, idNode: message["id"])
    let forwarded = message.copy()
    forwarded["id"] = %exchangeId
    t.enqueue(forwarded, id)
  else:
    t.enqueue(message, id)
  await req.respondEmpty(Http202)

proc authenticate(t: HttpServerTransport, req: Request): Future[bool] {.async.} =
  ## Whether the request was answered here, by the authorization hook.
  var answer: Option[HttpServerAuthResponse]
  try:
    answer = await t.auth.intercept($req.reqMethod, req.url.path, req.header("Authorization"))
  except CatchableError as e:
    # Fail closed: a hook that cannot decide lets nothing through.
    stderr.writeLine("[mcp-http] authorization hook failed: " & $e.name)
    await req.respondEmpty(Http500)
    return true
  if answer.isNone:
    return false
  let headers = securityHeaders()
  for (name, value) in answer.get.headers:
    headers[name] = value
  await req.respond(HttpCode(answer.get.code), answer.get.body, headers)
  return true

type Endpoint = enum
  epMcp, epLegacySse, epLegacyMessages, epNone

func endpointOf(t: HttpServerTransport, path: string): Endpoint =
  if path == t.path: epMcp
  elif t.legacySsePath.len > 0 and path == t.legacySsePath: epLegacySse
  elif t.legacySsePath.len > 0 and path == t.legacyMessagesPath: epLegacyMessages
  else: epNone

proc dispatch(t: HttpServerTransport, req: Request) {.async.} =
  # Before the path is looked at: the hook also serves its own documents.
  if not t.auth.isNil and await t.authenticate(req):
    return
  let endpoint = t.endpointOf(req.url.path)
  if endpoint == epNone:
    await req.respondEmpty(Http404)
    return
  let origin = req.header("Origin")
  if origin.isSome and not t.originAllowed(origin.get):
    await req.respondEmpty(Http403)
    return
  case endpoint
  of epLegacySse:
    if req.reqMethod == HttpGet:
      await t.handleLegacySse(req)
    else:
      await req.respondEmpty(Http405, {"Allow": "GET"})
  of epLegacyMessages:
    if req.reqMethod == HttpPost:
      await t.handleLegacyPost(req)
    else:
      await req.respondEmpty(Http405, {"Allow": "POST"})
  else:
    case req.reqMethod
    of HttpPost:
      await t.handlePost(req)
    of HttpDelete:
      await t.handleDelete(req)
    of HttpGet:
      if t.getStreamAvailable:
        await t.handleGet(req)
      else:
        await req.respondEmpty(Http405, {"Allow": "POST, DELETE"})
    else:
      let allowed = if t.getStreamAvailable: "POST, GET, DELETE" else: "POST, DELETE"
      await req.respondEmpty(Http405, {"Allow": allowed})

proc handle(t: HttpServerTransport, req: Request) {.async.} =
  try:
    await t.dispatch(req)
  except OSError, IOError:
    # A write failed: the peer closed its connection. Nobody is left to answer.
    req.client.close()
  except CatchableError as e:
    # What went wrong is for the log; the peer learns only that it did.
    stderr.writeLine("[mcp-http-server] " & $e.name & ": " & e.msg)
    try:
      await req.respondEmpty(Http500)
    except OSError, IOError:
      req.client.close()

proc listen*(t: HttpServerTransport) =
  ## Bind the socket. Afterwards `t.port` is the port actually bound.
  t.server.listen(Port(t.port), t.host)
  t.port = t.server.getPort.int
  t.started = true

proc sweepIdleSessions(t: HttpServerTransport) {.async.} =
  while t.started:
    await sleepAsync(SweepIntervalMs)
    t.expireIdleSessions()

proc serve*(t: HttpServerTransport): Future[void] {.async.} =
  ## Accept requests until `close`. Call `listen` first.
  proc requestHandler(req: Request) {.async, gcsafe.} =
    await t.handle(req)
  asyncCheck t.sweepIdleSessions()
  while t.started:
    if t.server.shouldAcceptRequest():
      try:
        await t.server.acceptRequest(requestHandler)
      except OSError:
        # `close` closes the listening socket under a pending accept.
        if t.started:
          raise
    else:
      # Out of file descriptors; let in-flight exchanges finish.
      await sleepAsync(50)

proc start*(t: HttpServerTransport): Future[void] {.async.} =
  ## Bind and serve. The returned future completes when the server stops.
  t.listen()
  await t.serve()
