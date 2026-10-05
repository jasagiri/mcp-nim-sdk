## Client-side Streamable HTTP transport for MCP.
##
## Every JSON-RPC message is POSTed to one endpoint. The server answers a
## request either with a JSON body or with an event stream that carries
## notifications about the request and then its response; both arrive
## through `receiveMessage`.
##
## A request of protocol version 2026-07-28 carries the headers that mirror
## its body (MCP-Protocol-Version, Mcp-Method, Mcp-Name). Requests of the
## earlier Streamable HTTP versions carry the session id the server issued
## and, once negotiated, the protocol version.
##
## TODO (versions 2025-03-26 to 2025-11-25): the GET stream for
## server-initiated messages, resumption with Last-Event-ID, DELETE.
## TODO (2026-07-28): Mcp-Param-* headers from x-mcp-header annotations.

import std/[asyncdispatch, httpclient, json, options, strutils, deques]
import ./transport
import ./event_stream
import ../protocol/types
import ../protocol/modern

const
  DefaultMaxResponseSize* = 16 * 1024 * 1024
  ErrStreamClosed* = -32000
    ## Local error (implementation-defined range): the event stream of a
    ## request ended before its response arrived. The request is lost; the
    ## caller may send it again.
  SessionHeader = "Mcp-Session-Id"
  ErrorBodyPreview = 512

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
    inbox: Deque[JsonNode]
    waiters: Deque[Future[JsonNode]]
    streams: seq[AsyncHttpClient]
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
    inbox: initDeque[JsonNode](),
    waiters: initDeque[Future[JsonNode]](),
  )

proc newHttpTransport*(baseUrl: string): HttpTransport =
  newStreamableHttpTransport(baseUrl)

proc deliver(t: StreamableHttpTransport, message: JsonNode) =
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

proc pump(t: StreamableHttpTransport, http: AsyncHttpClient,
          response: AsyncResponse, requestId: JsonNode) {.async.} =
  ## Deliver the messages of an event stream as they arrive. When the stream
  ## of a request ends without that request's response, say so in its place.
  var parser = initSseParser()
  var answered = requestId.isNil
  try:
    while true:
      let (hasData, chunk) = await response.bodyStream.read()
      if not hasData:
        break
      for event in parser.feed(chunk):
        let message = t.parseMessage(event.data)
        if not answered and isResponse(message) and message{"id"} == requestId:
          answered = true
        t.deliver(message)
  except CatchableError as e:
    # close() ends open streams on purpose; that is not a failure.
    if not t.closed:
      stderr.writeLine("[mcp-http] event stream from " & t.baseUrl &
                        " failed with " & $e.name & ": " & e.msg)
  finally:
    http.close()
    let index = t.streams.find(http)
    if index >= 0:
      t.streams.delete(index)
  if not answered and not t.closed:
    t.deliver(streamClosed(requestId))

proc post(t: StreamableHttpTransport, body: string,
          extraHeaders: seq[(string, string)], requestId: JsonNode) {.async.} =
  if t.closed:
    raise newException(McpTransportError, "transport is closed")
  let headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream"
  })
  for name, value in t.headers.pairs:
    headers[name] = value
  for (name, value) in extraHeaders:
    headers[name] = value

  let http = newAsyncHttpClient()
  var response: AsyncResponse
  try:
    response = await http.request(t.baseUrl, HttpPost, body, headers)
  except CatchableError as e:
    http.close()
    raise newException(McpTransportError,
      "POST " & t.baseUrl & " failed: " & e.msg)

  # Only a successful exchange establishes a session; some servers put a
  # throwaway session id on error responses too.
  if response.code.is2xx and response.headers.hasKey(SessionHeader):
    t.sessionId = some($response.headers[SessionHeader])

  let contentType = response.headers.getOrDefault("Content-Type").toLowerAscii()
  if response.code.is2xx and contentType.startsWith("text/event-stream"):
    t.streams.add http
    asyncCheck t.pump(http, response, requestId)
    return

  var text: string
  try:
    text = await response.body
  finally:
    http.close()

  if response.code.is2xx:
    if text.len > 0:
      t.deliver(t.parseMessage(text))
    return

  # 2026-07-28 servers report protocol errors with an HTTP error status and
  # a JSON-RPC error body; that is an answer, not a transport failure.
  if text.len > 0 and text.len <= t.maxResponseSize:
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
  raise newException(McpTransportError,
    "HTTP " & $response.code & " from " & t.baseUrl & ": " &
    text[0 ..< min(text.len, ErrorBodyPreview)])

proc legacyHeaders(t: StreamableHttpTransport): seq[(string, string)] =
  if t.sessionId.isSome:
    result.add (SessionHeader, t.sessionId.get)
  if t.protocolVersion.isSome:
    result.add (HeaderProtocolVersion, $t.protocolVersion.get)

method sendRequest*(t: StreamableHttpTransport, request: JsonRpcRequest): Future[void] {.async.} =
  let headers =
    if isModernRequest(request.params):
      modernRequestHeaders(request.`method`, request.params)
    else:
      t.legacyHeaders()
  let wire = request.toJson()
  await t.post($wire, headers, wire["id"])

method sendNotification*(t: StreamableHttpTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  await t.post(encodeMessage(notification), t.legacyHeaders(), nil)

method sendResponse*(t: StreamableHttpTransport, response: JsonRpcResponse): Future[void] {.async.} =
  ## Answers a request the server sent on a stream (versions before
  ## 2026-07-28).
  await t.post(encodeMessage(response), t.legacyHeaders(), nil)

method protocolVersionNegotiated*(t: StreamableHttpTransport, version: McpProtocolVersion) =
  # The header exists from 2025-06-18 on.
  if version >= mpv20250618 and not isModern(version):
    t.protocolVersion = some(version)

method receiveMessage*(t: StreamableHttpTransport): Future[JsonNode] {.async.} =
  if t.inbox.len > 0:
    return t.inbox.popFirst()
  if t.closed:
    raise newException(McpTransportError, "transport is closed")
  let waiter = newFuture[JsonNode]("StreamableHttpTransport.receiveMessage")
  t.waiters.addLast(waiter)
  return await waiter

method close*(t: StreamableHttpTransport): Future[void] {.async.} =
  t.closed = true
  for http in t.streams:
    http.close()
  t.streams.setLen(0)
  while t.waiters.len > 0:
    t.waiters.popFirst().fail(newException(McpTransportError, "transport is closed"))
