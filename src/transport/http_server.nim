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
## TODO (versions 2025-03-26 to 2025-11-25): the GET stream for
## server-initiated messages, resumption with Last-Event-ID, session expiry,
## and JSON-RPC batches (2025-03-26 only).
## TODO: SSE responses, so that notifications reach the client during a
## request; until then `sendNotification` raises.

import std/[asyncdispatch, asynchttpserver, httpcore, json, tables, sets,
             deques, options, uri, nativesockets, sysrand, strutils]
import ./transport
import ../protocol/types
import ../protocol/modern

const
  DefaultMaxBodySize* = 4 * 1024 * 1024
  DefaultMaxSessions* = 1024
  SessionHeader = "Mcp-Session-Id"
  ErrParse = -32700
  ErrInvalidRequest = -32600

type
  Exchange = object
    ## An HTTP request waiting for its JSON-RPC response.
    answered: Future[JsonRpcResponse]
    idNode: JsonNode  ## the id the client used, restored on the response

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
    allowedOrigins*:  seq[string]
      ## Origins accepted besides loopback ones, e.g. "https://app.example".
    maxSessions*:     int
      ## New clients are refused (503) while this many sessions are open.
    sessions:         HashSet[string]
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
    sessions:         initHashSet[string](),
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

method sendResponse*(t: HttpServerTransport,
                    response: JsonRpcResponse): Future[void] {.async.} =
  if not t.exchanges.hasKey(response.id):
    raise newException(McpTransportError,
      "no HTTP exchange is waiting for response id " & response.id)
  let exchange = t.exchanges[response.id]
  t.exchanges.del(response.id)
  var restored = response
  restored.idNode = exchange.idNode
  exchange.answered.complete(restored)

proc sessionCount*(t: HttpServerTransport): int =
  t.sessions.len

method sendNotification*(t: HttpServerTransport,
                        notification: JsonRpcNotification): Future[void] {.async.} =
  raise newException(McpTransportError,
    "HttpServerTransport has no stream to deliver " & notification.`method` & " on")

method sendRequest*(t: HttpServerTransport,
                   request: JsonRpcRequest): Future[void] {.async.} =
  raise newException(McpTransportError,
                     "HttpServerTransport.sendRequest is not supported")

method close*(t: HttpServerTransport): Future[void] {.async.} =
  t.started = false
  t.server.close()

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
  if req.headers.hasKey(name): some($req.headers[name]) else: none(string)

func httpStatusFor(response: JsonRpcResponse, modern: bool): HttpCode =
  ## 2026-07-28 maps some protocol errors onto HTTP statuses.
  if not modern or response.error.isNone:
    return Http200
  case response.error.get.code
  of ErrMethodNotFound: Http404
  of ErrMissingRequiredClientCapability, ErrUnsupportedProtocolVersion,
     ErrHeaderMismatch: Http400
  else: Http200

proc enqueue(t: HttpServerTransport, message: JsonNode, session: string) =
  let incoming = McpIncoming(message: message, session: session)
  if t.receiveWaiters.len > 0:
    t.receiveWaiters.popFirst().complete(incoming)
  else:
    t.requestQueue.addLast(incoming)

proc newSessionId(): string =
  ## Unguessable: the id is what ties later requests to a client.
  for b in urandom(16):
    result.add toHex(b.int, 2).toLowerAscii()

proc invalidRequest(message: string): JsonRpcError =
  JsonRpcError(code: ErrInvalidRequest, message: message)

proc handleDelete(t: HttpServerTransport, req: Request) {.async.} =
  let session = req.header(SessionHeader)
  if session.isNone:
    await req.respondError(Http400, nil, invalidRequest(SessionHeader & " header is required"))
  elif session.get notin t.sessions:
    await req.respondError(Http404, nil, invalidRequest("Session not found"))
  else:
    t.sessions.excl(session.get)
    if not t.onSessionEnd.isNil:
      t.onSessionEnd(session.get)
    await req.respondEmpty(Http200)

proc handlePost(t: HttpServerTransport, req: Request) {.async.} =
  var rpc: JsonNode
  try:
    rpc = parseJson(req.body)
  except CatchableError:
    await req.respondError(Http400, nil,
      JsonRpcError(code: ErrParse, message: "Parse error"))
    return
  if rpc.kind != JObject:
    # TODO: JSON-RPC batches (protocol version 2025-03-26 only).
    await req.respondError(Http400, nil, invalidRequest("Request must be a JSON object"))
    return

  let isRpcRequest = isRequest(rpc)
  let methodName = rpc{"method"}.getStr()
  let params = rpc{"params"}
  let modern = isModern(t.protocolVersion) and isRpcRequest and isModernRequest(params)
  let opensSession = not modern and isRpcRequest and methodName == "initialize"

  var session = ""
  if modern:
    let mismatch = checkRequestHeaders(
      req.header(HeaderProtocolVersion), req.header(HeaderMethod),
      req.header(HeaderName), methodName, params)
    if mismatch.isSome:
      await req.respondError(Http400, rpc{"id"}, mismatch.get)
      return
    let rejection = validateModernRequest(params, versionsUpTo(t.protocolVersion))
    if rejection.isSome:
      await req.respondError(Http400, rpc{"id"}, rejection.get)
      return
  elif opensSession:
    if t.sessions.len >= t.maxSessions:
      await req.respondEmpty(Http503)
      return
    session = newSessionId()
  else:
    let named = req.header(SessionHeader)
    if named.isNone:
      await req.respondError(Http400, rpc{"id"},
        invalidRequest(SessionHeader & " header is required"))
      return
    if named.get notin t.sessions:
      await req.respondError(Http404, rpc{"id"}, invalidRequest("Session not found"))
      return
    session = named.get

  if not isRpcRequest:
    # A notification or a response: nothing to answer on this exchange.
    t.enqueue(rpc, session)
    await req.respondEmpty(Http202)
    return

  inc t.exchangeCount
  let exchangeId = "http-" & $t.exchangeCount
  let answered = newFuture[JsonRpcResponse]("HttpServerTransport.response")
  t.exchanges[exchangeId] = Exchange(answered: answered, idNode: rpc["id"])
  let forwarded = rpc.copy()
  forwarded["id"] = %exchangeId
  t.enqueue(forwarded, session)
  let response = await answered

  if opensSession and response.error.isNone:
    t.sessions.incl(session)
    await req.respondJson(Http200, response.toJson(), {SessionHeader: session})
  else:
    await req.respondJson(httpStatusFor(response, modern), response.toJson())

proc handle(t: HttpServerTransport, req: Request) {.async.} =
  if req.url.path != t.path:
    await req.respondEmpty(Http404)
    return
  let origin = req.header("Origin")
  if origin.isSome and not t.originAllowed(origin.get):
    await req.respondEmpty(Http403)
    return
  case req.reqMethod
  of HttpPost:
    await t.handlePost(req)
  of HttpDelete:
    await t.handleDelete(req)
  else:
    # TODO: GET opens the stream for server-initiated messages.
    await req.respondEmpty(Http405, {"Allow": "POST, DELETE"})

proc listen*(t: HttpServerTransport) =
  ## Bind the socket. Afterwards `t.port` is the port actually bound.
  t.server.listen(Port(t.port), t.host)
  t.port = t.server.getPort.int
  t.started = true

proc serve*(t: HttpServerTransport): Future[void] {.async.} =
  ## Accept requests until `close`. Call `listen` first.
  proc requestHandler(req: Request) {.async, gcsafe.} =
    await t.handle(req)
  while t.started:
    if t.server.shouldAcceptRequest():
      await t.server.acceptRequest(requestHandler)
    else:
      # Out of file descriptors; let in-flight exchanges finish.
      await sleepAsync(50)

proc start*(t: HttpServerTransport): Future[void] {.async.} =
  ## Bind and serve. The returned future completes when the server stops.
  t.listen()
  await t.serve()
