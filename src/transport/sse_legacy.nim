## Client side of the HTTP+SSE transport of protocol version 2024-11-05.
##
## The client opens an event stream with GET. The server's first event,
## `endpoint`, names the URL to POST messages to; from then on the client
## sends by POST and the server's messages arrive as `message` events on the
## stream. The connection is made when the first message is sent.
##
## The server side is part of `HttpServerTransport` (`legacySsePath`).

import std/[asyncdispatch, httpcore, json, strutils, deques, uri]
import ./transport
import ./event_stream
import ./http_wire as wire
import ./deadline_watch
from nim_url_resolve import resolveReference
from nim_outcome import isOk, get, error
import ../protocol/types
import ../protocol/diagnostic

const
  DefaultMaxResponseSize* = 16 * 1024 * 1024
  DefaultConnectTimeoutMs* = 10_000
  ErrorBodyPreview = 512

type
  SseLegacyTransport* = ref object of McpTransport
    sseUrl*: string
    headers*: HttpHeaders
      ## Sent with every request, e.g. Authorization.
    maxResponseSize*: int
    connectTimeoutMs*: int
      ## How long to wait for the `endpoint` event.
    caFile*: string
      ## A PEM file of the certificate authorities to trust for https,
      ## instead of the system's: a private CA, or one in front of the server.
      ## Empty: the system's. The certificate still has to name the host.
    endpoint: string
    stream: WireResponse
    connecting: Future[void]
    inbox: Deque[JsonNode]
    waiters: Deque[Future[JsonNode]]
    streamEnded: bool
    closed: bool

proc newSseLegacyTransport*(sseUrl: string): SseLegacyTransport =
  SseLegacyTransport(
    kind: mtkHttp,
    sseUrl: sseUrl,
    headers: newHttpHeaders(),
    maxResponseSize: DefaultMaxResponseSize,
    connectTimeoutMs: DefaultConnectTimeoutMs,
    inbox: initDeque[JsonNode](),
    waiters: initDeque[Future[JsonNode]](),
  )

func sameOrigin(a, b: Uri): bool =
  a.scheme == b.scheme and a.hostname.toLowerAscii() == b.hostname.toLowerAscii() and
    a.port == b.port

proc deliver(t: SseLegacyTransport, message: JsonNode) =
  if t.waiters.len > 0:
    t.waiters.popFirst().complete(message)
  else:
    t.inbox.addLast message

proc failure(message: string, code = 0): ref McpTransportError =
  result = newException(McpTransportError, message)
  result.code = code

proc endStream(t: SseLegacyTransport) =
  t.streamEnded = true
  while t.waiters.len > 0:
    t.waiters.popFirst().fail(newException(McpTransportClosedError,
      "the event stream of " & t.sseUrl & " ended"))

proc resolveEndpoint(t: SseLegacyTransport, data: string): string =
  ## The POST URL the server named. It must be on the server that was
  ## asked: an `endpoint` event must not send what we post elsewhere.
  let resolved = resolveReference(t.sseUrl, data.strip())
  if not resolved.isOk:
    raise failure("the endpoint " & data[0 ..< min(data.len, 100)] &
                  " cannot be resolved against " & t.sseUrl & ": " & resolved.error)
  let target = resolved.get
  if not sameOrigin(parseUri(t.sseUrl), parseUri(target)):
    raise failure("the endpoint " & data[0 ..< min(data.len, 100)] &
                  " is not on the server " & t.sseUrl & " answered from")
  target

proc readLoop(t: SseLegacyTransport, response: WireResponse,
              ready: Future[void]) {.async.} =
  # The parser refuses an event longer than `maxResponseSize` bytes (SseLimitError),
  # so no message that reaches `deliver` is over the limit.
  var parser = initSseParser(t.maxResponseSize, t.maxResponseSize)
  try:
    while true:
      let chunk = await response.readSome()
      if chunk.len == 0:
        break
      for event in parser.feed(chunk):
        if event.event == "endpoint":
          if not ready.finished:
            try:
              t.endpoint = t.resolveEndpoint(event.data)
              ready.complete()
            except McpTransportError as e:
              ready.fail(e)
        elif event.event in ["", "message"] and event.data.len > 0:
          t.deliver(parseJson(event.data))
  except CatchableError as e:
    # close() ends the stream on purpose; that is not a failure.
    if not t.closed:
      stderr.writeLine("[mcp-sse] event stream from " & t.sseUrl &
                        " failed with " & $e.name & ": " & peerText(e.msg))
  finally:
    response.close()
    if not ready.finished:
      ready.fail(failure("the event stream of " & t.sseUrl &
                         " ended before it named an endpoint"))
    t.endStream()

proc connect(t: SseLegacyTransport) {.async.} =
  let headers = newHttpHeaders({"Accept": "text/event-stream"})
  for name, value in t.headers.pairs:
    headers[name] = value
  # The head of an event stream comes at once; `connectTimeoutMs` (the wait
  # for the endpoint event) bounds the wait for it too.
  let response = await wire.request(t.sseUrl, HttpGet, headers, caFile = t.caFile,
                                    connectTimeoutMs = t.connectTimeoutMs,
                                    headerTimeoutMs = t.connectTimeoutMs)
  if not response.code.is2xx:
    var text: string
    try:
      text = await response.readPrefix(ErrorBodyPreview)
    finally:
      response.close()
    raise failure("HTTP " & $response.code & " from " & t.sseUrl & ": " & text,
                  response.code.int)
  if not response.headers.getOrDefault("Content-Type").toLowerAscii().startsWith("text/event-stream"):
    response.close()
    raise failure(t.sseUrl & " did not answer with an event stream")
  t.stream = response
  let ready = newFuture[void]("SseLegacyTransport.endpoint")
  asyncCheck t.readLoop(response, ready)
  if not await ready.withLimit(t.connectTimeoutMs):
    response.close()
    raise failure(t.sseUrl & " sent no endpoint within " & $t.connectTimeoutMs & " ms")
  await ready

proc ensureConnected(t: SseLegacyTransport) {.async.} =
  if t.closed:
    raise failure("transport is closed")
  if t.connecting.isNil:
    t.connecting = t.connect()
  try:
    await t.connecting
  except CatchableError:
    # A failed connection is tried again by the next message.
    t.connecting = nil
    raise

proc post(t: SseLegacyTransport, body: string) {.async.} =
  await t.ensureConnected()
  let headers = newHttpHeaders({"Content-Type": "application/json"})
  for name, value in t.headers.pairs:
    headers[name] = value
  let response = await wire.request(t.endpoint, HttpPost, headers, body, caFile = t.caFile)
  var text: string
  try:
    text = await response.readPrefix(ErrorBodyPreview)
  finally:
    response.close()
  if not response.code.is2xx:
    raise failure("HTTP " & $response.code & " from " & t.endpoint & ": " & text,
                  response.code.int)

method sendRequest*(t: SseLegacyTransport, request: JsonRpcRequest): Future[void] {.async.} =
  await t.post(encodeMessage(request))

method sendNotification*(t: SseLegacyTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  await t.post(encodeMessage(notification))

method sendResponse*(t: SseLegacyTransport, response: JsonRpcResponse): Future[void] {.async.} =
  await t.post(encodeMessage(response))

method receiveMessage*(t: SseLegacyTransport): Future[JsonNode] {.async.} =
  if t.inbox.len > 0:
    return t.inbox.popFirst()
  if t.closed:
    raise failure("transport is closed")
  if t.streamEnded:
    raise newException(McpTransportClosedError,
      "the event stream of " & t.sseUrl & " ended")
  let waiter = newFuture[JsonNode]("SseLegacyTransport.receiveMessage")
  t.waiters.addLast(waiter)
  return await waiter

method close*(t: SseLegacyTransport): Future[void] {.async.} =
  if t.closed:
    return
  t.closed = true
  if not t.stream.isNil:
    t.stream.close()
  while t.waiters.len > 0:
    t.waiters.popFirst().fail(failure("transport is closed"))
