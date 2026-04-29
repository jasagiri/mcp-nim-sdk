## MCP HTTP transport implementation
##
## Phase 2 completion: each `sendRequest` POSTs the JSON-RPC envelope
## and pushes the parsed response body onto an internal queue, so that a
## subsequent `receiveMessage` call (driven by McpClient.processMessages)
## can pop the matching reply. The MCP HTTP profile uses a single endpoint
## that returns the response body directly in the same HTTP exchange, so
## the queue acts as a per-transport mailbox keeping the asynchronous
## send/receive abstraction consistent across stdio and HTTP transports.

import asyncdispatch, httpclient, json, options, strutils, asynchttpserver,
       deques
import ./transport
import ../protocol/types

type
  HttpTransport* = ref object of McpTransport
    ## HTTP transport
    baseUrl*: string
    sessionId*: Option[string]
    client*: AsyncHttpClient
    headers*: HttpHeaders
    responseQueue*: Deque[JsonNode]

  StreamableHttpTransport* = ref object of McpTransport
    ## Streamable HTTP transport
    baseUrl*: string
    sessionId*: Option[string]
    client*: AsyncHttpClient
    headers*: HttpHeaders
    sseStream*: string  # SSE stream connection URL
    responseQueue*: Deque[JsonNode]

proc newHttpTransport*(baseUrl: string): HttpTransport =
  let client = newAsyncHttpClient()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json"
  })

  result = HttpTransport(
    kind: mtkHttp,
    baseUrl: baseUrl,
    sessionId: none(string),
    client: client,
    headers: client.headers,
    responseQueue: initDeque[JsonNode](),
  )

proc newStreamableHttpTransport*(baseUrl: string): StreamableHttpTransport =
  let client = newAsyncHttpClient()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream"
  })

  result = StreamableHttpTransport(
    kind: mtkStreamable,
    baseUrl: baseUrl,
    sessionId: none(string),
    client: client,
    headers: client.headers,
    sseStream: "",
    responseQueue: initDeque[JsonNode](),
  )

proc enqueueResponseBody(queue: var Deque[JsonNode], body: string,
                         baseUrl: string) {.raises: [McpTransportError].} =
  ## Best-effort: a non-empty body is parsed and appended; an empty body
  ## (server returned 204-equivalent for a notification ack) is ignored.
  if body.len == 0: return
  var parsed: JsonNode
  try: parsed = parseJson(body)
  except CatchableError as e:
    raise newException(McpTransportError,
      "invalid JSON-RPC response from " & baseUrl & ": " & e.msg)
  queue.addLast(parsed)

method sendRequest*(t: HttpTransport, request: JsonRpcRequest): Future[void] {.async.} =
  let message = encodeMessage(request)

  if t.sessionId.isSome:
    t.client.headers["Mcp-Session-Id"] = t.sessionId.get

  let resp = await t.client.post(t.baseUrl, body = message)
  let body = await resp.body
  if not resp.code.is2xx:
    raise newException(McpTransportError,
      "HTTP " & $resp.code & " from " & t.baseUrl & ": " & body)
  enqueueResponseBody(t.responseQueue, body, t.baseUrl)

method sendNotification*(t: HttpTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  let message = encodeMessage(notification)

  if t.sessionId.isSome:
    t.client.headers["Mcp-Session-Id"] = t.sessionId.get

  let resp = await t.client.post(t.baseUrl, body = message)
  let body = await resp.body
  if not resp.code.is2xx:
    raise newException(McpTransportError,
      "HTTP " & $resp.code & " from " & t.baseUrl & ": " & body)
  # Notifications carry no JSON-RPC response per spec; tolerate either
  # an empty body or stray server output without queuing.
  discard body

method sendResponse*(t: HttpTransport, response: JsonRpcResponse): Future[void] {.async.} =
  # Not typically used for client-side HTTP transport
  raise newException(McpTransportError, "sendResponse not applicable for HTTP client transport")

method receiveMessage*(t: HttpTransport): Future[JsonNode] {.async.} =
  ## Pop the next queued JSON-RPC response. Yields until sendRequest puts
  ## something in the queue. The 10ms poll matches the cadence used by
  ## stdio transport when its underlying stream is empty.
  while t.responseQueue.len == 0:
    await sleepAsync(10)
  return t.responseQueue.popFirst()

method close*(t: HttpTransport): Future[void] {.async.} =
  t.client.close()

# Streamable HTTP transport methods
method sendRequest*(t: StreamableHttpTransport, request: JsonRpcRequest): Future[void] {.async.} =
  let message = encodeMessage(request)

  if t.sessionId.isSome:
    t.client.headers["Mcp-Session-Id"] = t.sessionId.get

  let resp = await t.client.post(t.baseUrl, body = message)
  let body = await resp.body
  if not resp.code.is2xx:
    raise newException(McpTransportError,
      "HTTP " & $resp.code & " from " & t.baseUrl & ": " & body)
  enqueueResponseBody(t.responseQueue, body, t.baseUrl)

method sendNotification*(t: StreamableHttpTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  let message = encodeMessage(notification)

  if t.sessionId.isSome:
    t.client.headers["Mcp-Session-Id"] = t.sessionId.get

  let resp = await t.client.post(t.baseUrl, body = message)
  let body = await resp.body
  if not resp.code.is2xx:
    raise newException(McpTransportError,
      "HTTP " & $resp.code & " from " & t.baseUrl & ": " & body)
  discard body

method sendResponse*(t: StreamableHttpTransport, response: JsonRpcResponse): Future[void] {.async.} =
  # Not typically used for client-side HTTP transport
  raise newException(McpTransportError, "sendResponse not applicable for HTTP client transport")

method receiveMessage*(t: StreamableHttpTransport): Future[JsonNode] {.async.} =
  while t.responseQueue.len == 0:
    await sleepAsync(10)
  return t.responseQueue.popFirst()

proc openSseStream*(t: StreamableHttpTransport): Future[void] {.async.} =
  t.client.headers["Accept"] = "text/event-stream"

  if t.sessionId.isSome:
    t.client.headers["Mcp-Session-Id"] = t.sessionId.get

  # Open GET request for SSE streaming
  let response = await t.client.get(t.baseUrl)

  if response.status.startsWith("2"):
    t.sseStream = t.baseUrl
  else:
    raise newException(McpTransportError, "Failed to open SSE stream: " & response.status)

method close*(t: StreamableHttpTransport): Future[void] {.async.} =
  t.client.close()
