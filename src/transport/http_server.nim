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
## TODO (versions 2025-03-26 to 2025-11-25): sessions (Mcp-Session-Id),
## the GET stream for server-initiated messages, resumption with
## Last-Event-ID, DELETE, and JSON-RPC batches (2025-03-26 only).
## TODO: SSE responses, so that notifications reach the client during a
## request; until then `sendNotification` raises.

import std/[asyncdispatch, asynchttpserver, httpcore, json, tables,
             deques, options, uri, nativesockets]
import ./transport
import ../protocol/types
import ../protocol/modern

const
  DefaultMaxBodySize* = 4 * 1024 * 1024
  ErrParse = -32700
  ErrInvalidRequest = -32600

type
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
    requestQueue:     Deque[JsonNode]
    receiveWaiters:   Deque[Future[JsonNode]]
    pendingResponses: Table[string, Future[JsonRpcResponse]]
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
    requestQueue:     initDeque[JsonNode](),
    receiveWaiters:   initDeque[Future[JsonNode]](),
    pendingResponses: initTable[string, Future[JsonRpcResponse]](),
    started:          false,
  )

method receiveMessage*(t: HttpServerTransport): Future[JsonNode] {.async.} =
  if t.requestQueue.len > 0:
    return t.requestQueue.popFirst()
  let fut = newFuture[JsonNode]("HttpServerTransport.receiveMessage")
  t.receiveWaiters.addLast(fut)
  return await fut

method sendResponse*(t: HttpServerTransport,
                    response: JsonRpcResponse): Future[void] {.async.} =
  if not t.pendingResponses.hasKey(response.id):
    raise newException(McpTransportError,
      "no HTTP exchange is waiting for response id " & response.id)
  let fut = t.pendingResponses[response.id]
  t.pendingResponses.del(response.id)
  fut.complete(response)

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

proc respondJson(req: Request, code: HttpCode, body: JsonNode): Future[void] =
  req.respond(code, $body, securityHeaders("application/json"))

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

proc enqueue(t: HttpServerTransport, message: JsonNode) =
  if t.receiveWaiters.len > 0:
    t.receiveWaiters.popFirst().complete(message)
  else:
    t.requestQueue.addLast(message)

proc handle(t: HttpServerTransport, req: Request) {.async.} =
  if req.url.path != t.path:
    await req.respondEmpty(Http404)
    return
  if req.reqMethod != HttpPost:
    await req.respondEmpty(Http405, {"Allow": "POST"})
    return
  let origin = req.header("Origin")
  if origin.isSome and not t.originAllowed(origin.get):
    await req.respondEmpty(Http403)
    return
  var rpc: JsonNode
  try:
    rpc = parseJson(req.body)
  except CatchableError:
    await req.respondError(Http400, nil,
      JsonRpcError(code: ErrParse, message: "Parse error"))
    return
  if rpc.kind != JObject:
    # TODO: JSON-RPC batches (protocol version 2025-03-26 only).
    await req.respondError(Http400, nil,
      JsonRpcError(code: ErrInvalidRequest, message: "Request must be a JSON object"))
    return

  if not isRequest(rpc):
    # A notification or a response: nothing to answer on this exchange.
    t.enqueue(rpc)
    await req.respondEmpty(Http202)
    return

  let request = decodeRequest(rpc)
  let modern = isModern(t.protocolVersion) and isModernRequest(request.params)
  if modern:
    let mismatch = checkRequestHeaders(
      req.header(HeaderProtocolVersion), req.header(HeaderMethod),
      req.header(HeaderName), request.`method`, request.params)
    if mismatch.isSome:
      await req.respondError(Http400, request.idNode, mismatch.get)
      return
    let rejection = validateModernRequest(request.params, versionsUpTo(t.protocolVersion))
    if rejection.isSome:
      await req.respondError(Http400, request.idNode, rejection.get)
      return

  if t.pendingResponses.hasKey(request.id):
    await req.respondError(Http400, request.idNode,
      JsonRpcError(code: ErrInvalidRequest, message: "Request id is already in use"))
    return
  let answered = newFuture[JsonRpcResponse]("HttpServerTransport.response")
  t.pendingResponses[request.id] = answered
  t.enqueue(rpc)
  let response = await answered
  await req.respondJson(httpStatusFor(response, modern), response.toJson())

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
