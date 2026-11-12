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
## Sessions that stay idle for `sessionIdleTimeoutMs` are dropped. What one
## caller can take from the others is limited: sessions (`maxSessions`,
## `maxSessionsPerPeer`), batch length, requests in progress, messages
## waiting for the server.
##
## A client has `readTimeoutMs` (30 s unless given) to send its request
## line, headers and body; one that sends nothing, or stops halfway, loses
## the connection instead of holding it and a file descriptor. On a
## keep-alive connection the time also bounds the wait between requests. The
## time a handler takes, an event stream included, is not limited.
##
## The HTTP+SSE transport of 2024-11-05 is served alongside, for clients that
## only speak it: a GET on `legacySsePath` opens an event stream whose first
## event names the endpoint (`legacyMessagesPath`) to POST to, and the
## server's messages follow as `message` events. The connection is the
## session. Set `legacySsePath` to "" to turn it off.
##
## A `subscriptions/listen` request (2026-07-28) is answered with an event
## stream that stays open: the server's notifications for it travel on it, and
## closing the connection cancels it like any other request.

import std/[asyncdispatch, asyncnet, httpcore, json, tables, deques,
             options, uri, nativesockets, sysrand, strutils, sequtils, times]
import nim_loopback   # foundation/nim-loopback — one rule for loopback
import ./asynchttpserver_compat
import ./transport
import ./sse_stream
import ./first_of
import ./auth_hook
export auth_hook  # the type of the `auth` field
import ../protocol/types
import ../protocol/diagnostic
import ../protocol/modern
import ../protocol/param_headers
import ../protocol/version
import ../protocol/features

const
  DefaultMaxBodySize* = 4 * 1024 * 1024
  DefaultReadTimeoutMs* = 30_000
    ## How long a client has to send a whole request (see `readTimeoutMs`).
  DefaultMaxSessions* = 1024
  DefaultMaxSessionsPerPeer* = 64
    ## One address holding 64 sessions is a busy gateway or a program that
    ## leaks them; 16 addresses are needed to take 1024 slots. Behind a
    ## reverse proxy every client has the proxy's address: raise it, or set
    ## 0 and limit at the proxy.
  DefaultMaxBatchItems* = 100
    ## A batch (2025-03-26 only) is answered as a whole, each item is a task
    ## for the server; 100 is far above what a client batches by hand.
  DefaultMaxPendingRequests* = 4096
    ## Requests handed to the server and not yet answered, 2026-07-28
    ## subscription streams included (each holds one for its whole life).
    ## About four times the default session count: ordinary clients have a
    ## few in progress each.
  DefaultMaxQueuedMessages* = 4096
    ## Messages received and not yet taken by the server (a server busy or
    ## stuck is what makes this grow); each is at most `maxBodySize`.
  DefaultMaxStoredStreams* = 64
  DefaultSessionIdleTimeoutMs* = 30 * 60 * 1000
  DefaultSseRetryMs* = 1000
    ## What a client of 2025-11-25 or later is told to wait before it
    ## reconnects to a stream whose connection the server closes. A second
    ## per second is far below what makes a takeover loop a flood.
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
    principal: Option[string]
      ## Who sent the POST; the owner of the session it opens.
    peer: string
      ## The address it came from.
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
    owner: Option[string]
      ## The principal that made the session (the authorization hook names
      ## it). Another principal that uses the id finds no such session. None
      ## where the endpoint is open, or the hook names nobody.
    peer: string
      ## The address that made the session (see `maxSessionsPerPeer`).
    used: bool
      ## Some request named the session after the one that made it.
    created: float
    legacy: bool
      ## A session of the HTTP+SSE transport: `listen` is its only stream,
      ## and it lasts as long as the connection.

  HttpDocument* = object
    ## A fixed document the transport serves with GET (and HEAD and OPTIONS)
    ## at a path of its own, outside the MCP protocol: what an extension
    ## publishes for discovery, such as a Server Card.
    contentType*: string
    body*: string
    etag*: string
      ## Sent as `ETag`; a GET whose `If-None-Match` names it gets 304.
    headers*: seq[(string, string)]
      ## Sent with every answer: `Cache-Control`, CORS headers.

  HttpServerTransport* = ref object of McpTransport
    server:           AsyncHttpServer
      # Not exported: on a Nim whose standard library lacks `readTimeout`
      # or `Request.headerFields` this is the type of the copy in
      # `vendor/asynchttpserver`, which a program importing
      # `std/asynchttpserver` could not use.
    host*:            string
    port*:            int
      ## The port to bind; 0 picks a free one. After `listen` it is the
      ## port actually bound.
    path*:            string
    protocolVersion*: McpProtocolVersion
      ## The newest version served here; set it to the server's.
    maxBodySize*:     int
      ## Enforced by the HTTP server itself (413); fixed at construction.
    readTimeoutMs*:   int
      ## Milliseconds a client has to send a whole request; 0: no limit.
      ## Enforced by the HTTP server itself (408, or closing the connection
      ## when not even the request line came); fixed at construction.
    auth*:            HttpServerAuth
      ## Authorization (see `auth/resource_server`): answers metadata
      ## requests and rejects requests without an acceptable token. Nil: the
      ## endpoint is open.
    allowedOrigins*:  seq[string]
      ## Origins accepted besides loopback ones, e.g. "https://app.example".
    allowedHosts*:    seq[string]
      ## Host names a request may carry in its `Host` header (without a port,
      ## or with the one the request names), besides the loopback ones, e.g.
      ## "mcp.example.com". A transport bound to a loopback address accepts
      ## loopback names only, so a web page cannot reach it under a DNS name
      ## that it has made point at 127.0.0.1 (DNS rebinding): the request
      ## then carries no Origin when it is a GET, and Host is all that tells
      ## it from a local client. Behind a reverse proxy that passes the
      ## public name on, list that name. A transport bound elsewhere checks
      ## Host only when this list is not empty.
    maxSessions*:     int
      ## While this many sessions are open, a new client takes the place of
      ## the oldest session that was never used after it was made (a flood
      ## of initialize requests thus costs only its own sessions); when
      ## there is none, it is refused (503).
    maxSessionsPerPeer*: int
      ## Sessions (and HTTP+SSE connections) one client address may hold; a
      ## client at its limit loses its own oldest session that was never
      ## used again, else is refused (503). 0: no limit. The address is the
      ## peer of the TCP connection; a header such as X-Forwarded-For is not
      ## trusted, as anyone can write it.
    maxBatchItems*: int
      ## Messages in one batch; a longer one is refused (400).
    maxPendingRequests*: int
      ## Requests in progress; another is refused (503, Retry-After).
    maxQueuedMessages*: int
      ## Messages waiting for the server to receive them; more are refused
      ## (503, Retry-After).
    maxStreamEvents*: int
      ## Events each stream remembers for resumption; a client that falls
      ## further behind cannot resume.
    maxStoredStreams*: int
      ## Finished streams a session keeps for resumption.
    sessionIdleTimeoutMs*: int
      ## A session unused for this long, with nothing in progress, is
      ## dropped; 0 keeps sessions until DELETE.
    sseRetryMs*: int
      ## 2025-11-25 and later: the `retry` field the server sends before it
      ## closes the connection of a stream it keeps, which is when a newer
      ## connection takes the stream over. 0 sends none.
    sseKeepAliveMs*: int
      ## How long an event stream may be silent before the server writes a
      ## comment line to it, so that the connection is not taken for dead;
      ## 0 or less sends none.
    legacySsePath*: string
      ## Where the HTTP+SSE transport of 2024-11-05 opens its event stream;
      ## "" does not serve it.
    legacyMessagesPath*: string
      ## Where clients of that transport POST, named by the first event.
    documents*:       Table[string, HttpDocument]
      ## Documents served at their paths, by path; none unless added. They
      ## are public: the authorization hook sees the request first, and the
      ## ones of `resource_server` ask for a token only on the MCP path.
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
                             maxBodySize: int = DefaultMaxBodySize,
                             readTimeoutMs: int = DefaultReadTimeoutMs): HttpServerTransport =
  requireSupported(protocolVersion)
  result = HttpServerTransport(
    kind:             mtkHttp,
    server:           newAsyncHttpServer(maxBody = maxBodySize, readTimeout = readTimeoutMs),
    host:             host,
    port:             port,
    path:             path,
    protocolVersion:  protocolVersion,
    maxBodySize:      maxBodySize,
    readTimeoutMs:    readTimeoutMs,
    allowedOrigins:   @[],
    allowedHosts:     @[],
    maxSessions:      DefaultMaxSessions,
    maxSessionsPerPeer: DefaultMaxSessionsPerPeer,
    maxBatchItems:    DefaultMaxBatchItems,
    maxPendingRequests: DefaultMaxPendingRequests,
    maxQueuedMessages: DefaultMaxQueuedMessages,
    maxStreamEvents:  DefaultMaxStreamEvents,
    maxStoredStreams: DefaultMaxStoredStreams,
    sessionIdleTimeoutMs: DefaultSessionIdleTimeoutMs,
    sseRetryMs:       DefaultSseRetryMs,
    sseKeepAliveMs:   DefaultKeepAliveMs,
    legacySsePath:    "/sse",
    legacyMessagesPath: "/messages",
    documents:        initTable[string, HttpDocument](),
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

proc withClientId(body: JsonNode, exchangeId: string, clientId: JsonNode): JsonNode =
  ## The params or result of a `subscriptions/listen` stream's message name
  ## the subscription by the id of the request, which this transport renamed
  ## on the way in (`exchangeId`); the client knows the id it chose.
  if body.isNil or body.kind != JObject or clientId.isNil:
    return body
  let meta = body{"_meta"}
  if meta.isNil or meta.kind != JObject:
    return body
  let named = meta{MetaSubscriptionId}
  if named.isNil or named.kind != JString or named.getStr() != exchangeId:
    return body
  result = body.copy()
  result["_meta"][MetaSubscriptionId] = clientId

proc forClient(message: JsonNode, exchangeId: string, clientId: JsonNode): JsonNode =
  result = message
  for key in ["params", "result"]:
    if message.hasKey(key):
      let renamed = withClientId(message[key], exchangeId, clientId)
      if renamed != message[key]:
        result = message.copy()
        result[key] = renamed

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
  if restored.result.isSome:
    restored.result = some(withClientId(restored.result.get, response.id, exchange.idNode))
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
  var data = $message
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
    data = $message.forClient(route.requestId, exchange.idNode)
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

method requestDropped*(t: HttpServerTransport, session, requestId: string) =
  ## The server will not answer this request (it was cancelled): its exchange
  ## ends here, so that a stream that lasts as long as a subscription leaves
  ## nothing behind.
  t.exchanges.del(requestId)

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
  ## Routed by what the notification says about itself: the request it
  ## belongs to, else the session it is for, else every client.
  t.deliver(MessageRoute(session: notification.session,
                         requestId: notification.relatedRequestId),
            notification.toJson(), "notification " & notification.`method`)

method sendRequest*(t: HttpServerTransport, request: JsonRpcRequest,
                    route: MessageRoute): Future[void] {.async.} =
  ## Like `sendNotification`. The client answers with a POST of the response,
  ## which `receive` hands over like any other message.
  t.deliver(route, request.toJson(), "request")

method sendRequest*(t: HttpServerTransport,
                   request: JsonRpcRequest): Future[void] {.async.} =
  ## Routed by what the request says about itself, as a notification is: the
  ## request it belongs to, else the session it is for, else the only client.
  t.deliver(MessageRoute(session: request.session, requestId: request.relatedRequestId),
            request.toJson(), "request")

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
  isLoopbackUrl(origin)   # foundation/nim-loopback LB-05

func hostName(hostHeader: string): string =
  ## The name in a Host header value: lower case, without port or brackets.
  let value = hostHeader.strip().toLowerAscii()
  if value.startsWith("["):
    let close = value.find(']')
    return if close < 0: value else: value[1 ..< close]
  let colon = value.rfind(':')
  if colon >= 0 and value.count(':') == 1: value[0 ..< colon] else: value

func bindsLoopback(t: HttpServerTransport): bool =
  isLoopbackAuthority(t.host.strip())   # foundation/nim-loopback LB-01..04

func hostAllowed(t: HttpServerTransport, hostHeader: Option[string]): bool =
  ## Whether the request is addressed to this server (see `allowedHosts`).
  if not t.bindsLoopback and t.allowedHosts.len == 0:
    return true
  if hostHeader.isNone:
    return false
  let name = hostHeader.get.hostName
  let full = hostHeader.get.strip().toLowerAscii()
  isLoopbackAuthority(full) or
    t.allowedHosts.anyIt(it.toLowerAscii() == name or it.toLowerAscii() == full)

func originAllowed(t: HttpServerTransport, origin: string): bool =
  ## A browser sends Origin; rejecting unknown ones stops a web page from
  ## reaching a local server through DNS rebinding.
  isLoopbackOrigin(origin) or origin in t.allowedOrigins

func header(req: Request, name: string): Option[string] =
  ## A header sent on several lines (Accept often is) reads as one value, the
  ## lines joined with ", " (RFC 9110 section 5.3). Read from the lines as they
  ## arrived: `req.headers` splits a value at its commas, so "a,b" would read
  ## back as "a, b".
  var values: seq[string] = @[]
  for field in req.headerFields:
    if cmpIgnoreCase(field.name, name) == 0:
      values.add field.value
  if values.len > 0: some(values.join(", ")) else: none(string)

func paramHeaders(req: Request): seq[(string, string)] =
  ## The Mcp-Param-* headers of the request, one entry per line sent, each
  ## value as it was sent.
  let prefix = ParamHeaderPrefix.toLowerAscii()
  for field in req.headerFields:
    if field.name.toLowerAscii().startsWith(prefix):
      result.add (field.name, field.value)

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
             principal: Option[string], peer: string,
             paramHeaders = none(seq[(string, string)])) =
  let incoming = McpIncoming(message: message, session: session,
                             paramHeaders: paramHeaders, principal: principal,
                             peer: peer)
  if t.receiveWaiters.len > 0:
    t.receiveWaiters.popFirst().complete(incoming)
  else:
    t.requestQueue.addLast(incoming)

proc exchangeOf(t: HttpServerTransport, session: string, clientId: JsonNode): Option[string] =
  ## The id this transport gave to the request `session` sent with the id
  ## `clientId`; ids are the client's to choose, so only the session says
  ## whose request is meant.
  for key, exchange in t.exchanges:
    let owner = if exchange.group.isNil: exchange.legacySession else: exchange.group.session
    if owner == session and exchange.idNode == clientId:
      return some(key)
  none(string)

proc enqueueFromClient(t: HttpServerTransport, message: JsonNode, session: string,
                       principal: Option[string], peer: string) =
  ## A notification or response the client posted. The server knows requests
  ## by the ids this transport made, not by the ones clients chose, so a
  ## `notifications/cancelled` is rewritten to name the sender's own request
  ## by that id, and is dropped when the sender has no such request in
  ## progress (the specification lets a server ignore a cancellation of an
  ## unknown request). Without a session there is no telling clients apart:
  ## 2026-07-28 cancels an HTTP request by closing its connection
  ## (basic/patterns/cancellation, "Transport-Specific Cancellation"), so
  ## the notification is dropped there; letting it through would let any
  ## client cancel any request by guessing an exchange id.
  if message{"method"}.getStr() == "notifications/cancelled":
    let named = message{"params"}{"requestId"}
    if session.len == 0 or named.isNil:
      return
    let exchangeId = t.exchangeOf(session, named)
    if exchangeId.isNone:
      return
    let rewritten = message.copy()
    rewritten["params"]["requestId"] = %exchangeId.get
    t.enqueue(rewritten, session, principal, peer)
    return
  t.enqueue(message, session, principal, peer)

proc invalidRequest(message: string): JsonRpcError =
  JsonRpcError(code: ErrInvalidRequest, message: message)

proc touch(session: Session) =
  session.lastActive = epochTime()

proc evictUnused(t: HttpServerTransport, peer = ""): bool =
  ## Drop the oldest session of the Streamable HTTP kind that no request
  ## named after the one that made it (of `peer`, when given). A session of
  ## HTTP+SSE lasts as long as its connection and is the client's to close.
  var oldest = ""
  var oldestAt = 0.0
  for id, session in t.sessions:
    if not session.legacy and not session.used and session.busy == 0 and
       (peer.len == 0 or session.peer == peer) and
       (oldest.len == 0 or session.created < oldestAt):
      oldest = id
      oldestAt = session.created
  if oldest.len == 0:
    return false
  t.endSession(oldest)
  true

proc claimSessionSlot(t: HttpServerTransport, peer: string): bool =
  ## Whether a session may be made for `peer` now, after making room where
  ## the policy allows (see `maxSessions`, `maxSessionsPerPeer`).
  if t.maxSessionsPerPeer > 0:
    while t.sessions.values.toSeq.countIt(it.peer == peer) >= t.maxSessionsPerPeer:
      if not t.evictUnused(peer):
        return false
  if t.sessions.len >= t.maxSessions:
    t.expireIdleSessions()
  while t.sessions.len >= t.maxSessions:
    if not t.evictUnused():
      return false
  true

proc overloaded(t: HttpServerTransport, adding: int): bool =
  ## Whether `adding` more messages would exceed the limits on work waiting.
  t.requestQueue.len + adding > t.maxQueuedMessages or
    t.exchanges.len + adding > t.maxPendingRequests

proc refuseOverload(req: Request): Future[void] =
  req.respondEmpty(Http503, {"Retry-After": "1"})

proc legacyCeiling(t: HttpServerTransport): McpProtocolVersion =
  ## The newest version spoken with an initialize handshake.
  latestLegacyVersion(spokenVersionsUpTo(t.protocolVersion)).get(mpv20241105)

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

func belongsTo(session: Session, principal: Option[string]): bool =
  ## A session made by a principal is that principal's alone; to anyone else
  ## it does not exist (404, not 403: the id is not confirmed).
  session.owner.isNone or session.owner == principal

proc sessionFor(t: HttpServerTransport, req: Request, id: JsonNode,
                principal: Option[string]): Future[Session] {.async.} =
  ## The session the request names, or nil after having answered it with
  ## the error that says why there is none.
  let named = req.header(SessionHeader)
  if named.isNone:
    await req.respondError(Http400, id, invalidRequest(SessionHeader & " header is required"))
    return nil
  if not t.sessions.hasKey(named.get) or t.sessions[named.get].legacy or
     not t.sessions[named.get].belongsTo(principal):
    await req.respondError(Http404, id, invalidRequest("Session not found"))
    return nil
  result = t.sessions[named.get]
  result.used = true

proc handleDelete(t: HttpServerTransport, req: Request,
                  principal: Option[string]) {.async.} =
  let session = req.header(SessionHeader)
  if session.isNone:
    await req.respondError(Http400, nil, invalidRequest(SessionHeader & " header is required"))
  elif session.get notin t.sessions or t.sessions[session.get].legacy or
       not t.sessions[session.get].belongsTo(principal):
    await req.respondError(Http404, nil, invalidRequest("Session not found"))
  else:
    t.endSession(session.get)
    await req.respondEmpty(Http200)

func speaks(t: HttpServerTransport, feature: McpFeature): bool =
  ## Whether some version this transport speaks has `feature`.
  spokenVersionsUpTo(t.protocolVersion).anyIt(it.has(feature))

func speaksLegacy(t: HttpServerTransport): bool =
  latestLegacyVersion(spokenVersionsUpTo(t.protocolVersion)).isSome

func allowedMethods(t: HttpServerTransport, req: Request): seq[HttpMethod] =
  ## What the MCP endpoint serves for this request. GET (the stream of
  ## 2025-03-26 to 2025-11-25) and DELETE (the end of a session) exist only
  ## where a spoken version has them, and never for a request that names
  ## 2026-07-28, which has neither. A request that names no version may come
  ## from 2025-03-26, which has no version header, so it is not refused here.
  result = @[HttpPost]
  if req.namesModernVersion:
    return
  if t.speaks(ftHttpGetStream): result.add HttpGet
  # DELETE ends a session, and this transport gives one to every client of a
  # version with the initialize handshake, also to one of 2024-11-05 that
  # posts here instead of using HTTP+SSE.
  if t.speaksLegacy: result.add HttpDelete

proc serveSessionStream(t: HttpServerTransport, req: Request, session: Session,
                        stream: SseStream, after: int, gone: Future[void],
                        kind: string): Future[SseEnd] {.async.} =
  ## Serve `stream` to a client of `session`. When a newer connection takes it
  ## over, the client of this one is told how long to wait before it
  ## reconnects (2025-11-25 and later), and the takeover is recorded: a second
  ## connection that names the session is also what a leaked session id looks
  ## like. The record leaves out the id.
  let polling = not session.isNil and session.version.has(ftSsePolling)
  result = await serveStream(req, stream, after, securityHeaders(), gone,
                             keepAliveMs = t.sseKeepAliveMs,
                             retryMs = if polling: t.sseRetryMs else: 0)
  if result == seReplaced:
    stderr.writeLine("[mcp-http-server] the " & kind & " was taken over by connection " &
                     $stream.attachments)

proc handleGet(t: HttpServerTransport, req: Request,
               principal: Option[string]) {.async.} =
  ## The stream of messages that belong to no request, or the rest of an
  ## earlier stream after a lost connection.
  let session = await t.sessionFor(req, nil, principal)
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
    discard await t.serveSessionStream(req, session, stream, after, gone,
      if lastEventId.isSome: "stream resumed by GET" else: "GET stream")
  finally:
    dec session.busy
    session.touch()

proc openSession(t: HttpServerTransport, id: string, response: JsonRpcResponse,
                 owner: Option[string], peer: string) =
  ## The server accepted an initialize: the client now has a session, at the
  ## version the server's answer names.
  let named = parseProtocolVersion(response.result.get(newJObject()){"protocolVersion"}.getStr())
  let session = Session(version: named.get(t.legacyCeiling), owner: owner,
                        peer: peer, streams: initOrderedTable[string, SseStream]())
  session.created = epochTime()
  session.touch()
  t.sessions[id] = session

proc answerWithJson(t: HttpServerTransport, req: Request, group: Group,
                    modern: bool) {.async.} =
  var extra = @[("Connection", "close")]
  if group.opensSession and group.responses[0].error.isNone:
    t.openSession(group.session, group.responses[0], group.principal, group.peer)
    extra.add (SessionHeader, group.session)
  if group.isBatch:
    await req.respondJson(Http200, %group.responses.mapIt(it.toJson()), extra)
  else:
    await req.respondJson(httpStatusFor(group.responses[0], modern),
                          group.responses[0].toJson(), extra)

proc handlePost(t: HttpServerTransport, req: Request,
                principal: Option[string]) {.async.} =
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

  if items.len > t.maxBatchItems:
    await req.respondError(Http400, nil, invalidRequest(
      "A batch of " & $items.len & " messages exceeds the limit of " & $t.maxBatchItems))
    return
  if t.overloaded(items.len):
    await req.refuseOverload()
    return

  let rpc = items[0]
  let isRpcRequest = not isBatch and isRequest(rpc)
  let methodName = rpc{"method"}.getStr()
  let params = rpc{"params"}
  let sessionless = not t.speaksLegacy
  let modern = isModern(t.protocolVersion) and isRpcRequest and
               (isModernRequest(params) or req.namesModernVersion or sessionless)
  let opensSession = not modern and isRpcRequest and methodName == "initialize"
  if isBatch and items.anyIt(isRequest(it) and it{"method"}.getStr() == "initialize"):
    await req.respondError(Http400, nil,
      invalidRequest("initialize must not be part of a batch"))
    return

  var session: Session = nil
  var sessionId = ""
  if modern and sessionless and methodName == "initialize" and not isModernRequest(params):
    # A legacy client cannot move forward; the versions named here are all
    # it can show its user.
    await req.respondError(Http400, rpc{"id"}, unsupportedVersionError(
      params{"protocolVersion"}.getStr(), spokenVersionsUpTo(t.protocolVersion)))
    return
  if modern:
    # A request that lacks the per-request fields is malformed (-32602)
    # whatever its headers say; only a well-formed one can disagree with them.
    let rejection = validateModernRequest(params, spokenVersionsUpTo(t.protocolVersion))
    if rejection.isSome and rejection.get.code == ErrInvalidParams:
      await req.respondError(Http400, rpc{"id"}, rejection.get)
      return
    let mismatch = checkRequestHeaders(
      req.header(HeaderProtocolVersion), req.header(HeaderMethod),
      req.header(HeaderName), methodName, params,
      extensionMethodServed = not t.servesExtensionMethod.isNil and
                              t.servesExtensionMethod(methodName))
    if mismatch.isSome:
      await req.respondError(Http400, rpc{"id"}, mismatch.get)
      return
    if rejection.isSome:
      await req.respondError(Http400, rpc{"id"}, rejection.get)
      return
  elif opensSession:
    if not t.claimSessionSlot(req.hostname):
      await req.respondEmpty(Http503, {"Retry-After": "1"})
      return
    sessionId = newSessionId()
  elif sessionless:
    # Notifications and responses of 2026-07-28: there is no session to
    # name, and Mcp-Session-Id is ignored when a client sends one.
    if isBatch:
      await req.respondError(Http400, nil, invalidRequest(
        "JSON-RPC batches are not supported by protocol version " & $t.protocolVersion))
      return
  else:
    session = await t.sessionFor(req, rpc{"id"}, principal)
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
      t.enqueueFromClient(item, sessionId, principal, req.hostname)
    await req.respondEmpty(Http202)
    return

  let group = Group(
    stream: newSseStream(newStreamId(), t.maxStreamEvents),
    session: sessionId, pending: requests.len, opensSession: opensSession,
    principal: principal, peer: req.hostname,
    isBatch: isBatch, modern: modern, settled: newFuture[void]("HttpServerTransport.group"))
  if not session.isNil and session.version.has(ftSsePolling):
    discard group.stream.push("")
  for item in items:
    if not isRequest(item):
      t.enqueueFromClient(item, sessionId, principal, req.hostname)
      continue
    inc t.exchangeCount
    let exchangeId = "http-" & $t.exchangeCount
    group.exchangeIds.add exchangeId
    t.exchanges[exchangeId] = Exchange(group: group, idNode: item["id"])
    let forwarded = item.copy()
    forwarded["id"] = %exchangeId
    t.enqueue(forwarded, sessionId, principal, req.hostname,
              if modern: some(req.paramHeaders) else: none(seq[(string, string)]))

  # The connection is watched for the whole exchange, which is why it is
  # closed at the end: the watcher would otherwise eat the next request.
  let gone = watchDisconnect(req.client)
  await firstOf(group.settled, gone)
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
  let ended = await t.serveSessionStream(req, session, group.stream, 0, gone,
                                         "stream of a request")
  if ended == seClientGone and modern and group.pending > 0:
    t.cancel(group)

proc handleLegacySse(t: HttpServerTransport, req: Request,
                     principal: Option[string]) {.async.} =
  ## HTTP+SSE: the connection is the session. Its first event names where
  ## to POST.
  if not t.claimSessionSlot(req.hostname):
    await req.respondEmpty(Http503, {"Retry-After": "1"})
    return
  let id = newSessionId()
  let session = Session(version: mpv20241105, legacy: true, owner: principal,
                        peer: req.hostname, created: epochTime(),
                        streams: initOrderedTable[string, SseStream](),
                        listen: newSseStream(newStreamId(), t.maxStreamEvents,
                                             emitIds = false))
  discard session.listen.push(t.legacyMessagesPath & "?sessionId=" & id, "endpoint")
  t.sessions[id] = session
  let gone = watchDisconnect(req.client)
  try:
    discard await serveStream(req, session.listen, 0, securityHeaders(), gone,
                              keepAliveMs = t.sseKeepAliveMs)
  finally:
    t.endSession(id)

proc handleLegacyPost(t: HttpServerTransport, req: Request,
                      principal: Option[string]) {.async.} =
  var id = ""
  for (name, value) in decodeQuery(req.url.query):
    if name == "sessionId":
      id = value
  if id.len == 0:
    await req.respondError(Http400, nil, invalidRequest("sessionId is required"))
    return
  if not t.sessions.hasKey(id) or not t.sessions[id].legacy or
     not t.sessions[id].belongsTo(principal):
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
  if t.overloaded(1):
    await req.refuseOverload()
    return
  if isRequest(message):
    inc t.exchangeCount
    let exchangeId = "http-" & $t.exchangeCount
    t.exchanges[exchangeId] = Exchange(legacySession: id, idNode: message["id"])
    let forwarded = message.copy()
    forwarded["id"] = %exchangeId
    t.enqueue(forwarded, id, principal, req.hostname)
  else:
    t.enqueueFromClient(message, id, principal, req.hostname)
  await req.respondEmpty(Http202)

proc authenticate(t: HttpServerTransport, req: Request
                 ): Future[tuple[answered: bool, principal: Option[string]]] {.async.} =
  ## Whether the request was answered here, by the authorization hook; when it
  ## was not, who the hook says sent it.
  var outcome: HttpServerAuthOutcome
  try:
    if t.auth.check.isNil:
      outcome.answer = await t.auth.intercept($req.reqMethod, req.url.path,
                                              req.header("Authorization"))
    else:
      outcome = await t.auth.check($req.reqMethod, req.url.path, req.header("Authorization"))
  except CatchableError as e:
    # Fail closed: a hook that cannot decide lets nothing through.
    stderr.writeLine("[mcp-http] authorization hook failed: " & $e.name)
    await req.respondEmpty(Http500)
    return (answered: true, principal: none(string))
  if outcome.answer.isNone:
    return (answered: false, principal: outcome.principal)
  let answer = outcome.answer.get
  let headers = securityHeaders()
  for (name, value) in answer.headers:
    headers[name] = value
  await req.respond(HttpCode(answer.code), answer.body, headers)
  return (answered: true, principal: none(string))

proc serveDocument(req: Request, document: HttpDocument) {.async.} =
  let extra = document.headers
  case req.reqMethod
  of HttpOptions:
    await req.respondEmpty(Http204, extra)
  of HttpGet, HttpHead:
    var named = false
    let wanted = req.header("If-None-Match")
    if wanted.isSome and document.etag.len > 0:
      for candidate in wanted.get.split(','):
        let tag = candidate.strip()
        if tag == "*" or tag == document.etag or tag == "W/" & document.etag:
          named = true
    var headers = @extra
    if document.etag.len > 0:
      headers.add ("ETag", document.etag)
    if named:
      await req.respondEmpty(Http304, headers)
    else:
      let responseHeaders = securityHeaders(document.contentType)
      for (name, value) in headers:
        responseHeaders[name] = value
      await req.respond(Http200, if req.reqMethod == HttpHead: "" else: document.body,
                        responseHeaders)
  else:
    await req.respondEmpty(Http405, {"Allow": "GET, HEAD, OPTIONS"})

type Endpoint = enum
  epMcp, epLegacySse, epLegacyMessages, epNone

func endpointOf(t: HttpServerTransport, path: string): Endpoint =
  ## The HTTP+SSE paths exist only where a spoken version has that transport.
  let legacySse = t.legacySsePath.len > 0 and t.speaks(ftHttpSse)
  if path == t.path: epMcp
  elif legacySse and path == t.legacySsePath: epLegacySse
  elif legacySse and path == t.legacyMessagesPath: epLegacyMessages
  else: epNone

proc dispatch(t: HttpServerTransport, req: Request) {.async.} =
  # The hook is asked about every MCP endpoint (so that none is left open by
  # a hook that does not know the path) and about the documents it serves
  # itself; fixed documents and unknown paths are public.
  if not t.hostAllowed(req.header("Host")):
    await req.respondEmpty(Http403)
    return
  let endpoint = t.endpointOf(req.url.path)
  var principal = none(string)
  if not t.auth.isNil and (endpoint != epNone or req.url.path in t.auth.ownPaths):
    let verdict = await t.authenticate(req)
    if verdict.answered:
      return
    principal = verdict.principal
  if req.url.path in t.documents:
    await serveDocument(req, t.documents[req.url.path])
    return
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
      await t.handleLegacySse(req, principal)
    else:
      await req.respondEmpty(Http405, {"Allow": "GET"})
  of epLegacyMessages:
    if req.reqMethod == HttpPost:
      await t.handleLegacyPost(req, principal)
    else:
      await req.respondEmpty(Http405, {"Allow": "POST"})
  else:
    let allowed = t.allowedMethods(req)
    if req.reqMethod notin allowed:
      await req.respondEmpty(Http405, {"Allow": allowed.mapIt(($it).toUpperAscii).join(", ")})
    elif req.reqMethod == HttpPost:
      await t.handlePost(req, principal)
    elif req.reqMethod == HttpDelete:
      await t.handleDelete(req, principal)
    else:
      await t.handleGet(req, principal)

proc handle(t: HttpServerTransport, req: Request) {.async.} =
  try:
    await t.dispatch(req)
  except OSError, IOError:
    # A write failed: the peer closed its connection. Nobody is left to answer.
    req.client.close()
  except CatchableError as e:
    # What went wrong is for the log; the peer learns only that it did.
    stderr.writeLine("[mcp-http-server] " & $e.name & ": " & peerText(e.msg))
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
