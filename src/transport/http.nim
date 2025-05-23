## MCP HTTP transport implementation

import asyncdispatch, httpclient, json, options, strutils, asynchttpserver
import ./transport
import ../protocol/types

type
  HttpTransport* = ref object of McpTransport
    ## HTTP transport
    client*: AsyncHttpClient
    headers*: HttpHeaders

  StreamableHttpTransport* = ref object of McpTransport
    ## Streamable HTTP transport
    client*: AsyncHttpClient
    headers*: HttpHeaders
    sseStream*: string  # SSE stream connection URL

proc newHttpTransport*(baseUrl: string): HttpTransport =
  let client = newAsyncHttpClient()
  var headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json"
  })
  
  result = HttpTransport(
    kind: mtkHttp,
    baseUrl: baseUrl,
    sessionId: none(string),
    client: client,
    headers: headers
  )

proc newStreamableHttpTransport*(baseUrl: string): StreamableHttpTransport =
  let client = newAsyncHttpClient()
  var headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream"
  })
  
  result = StreamableHttpTransport(
    kind: mtkStreamable,
    baseUrl: baseUrl,
    sessionId: none(string),
    client: client,
    headers: headers,
    sseStream: ""
  )

method sendRequest*(t: HttpTransport, request: JsonRpcRequest): Future[void] {.async.} =
  let message = encodeMessage(request)
  var reqHeaders = t.headers

  if t.sessionId.isSome:
    reqHeaders["Mcp-Session-Id"] = t.sessionId.get
    
  discard await t.client.post(t.baseUrl, body = message, headers = reqHeaders)

method sendNotification*(t: HttpTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  let message = encodeMessage(notification)
  var reqHeaders = t.headers

  if t.sessionId.isSome:
    reqHeaders["Mcp-Session-Id"] = t.sessionId.get
    
  discard await t.client.post(t.baseUrl, body = message, headers = reqHeaders)

method sendResponse*(t: HttpTransport, response: JsonRpcResponse): Future[void] {.async.} =
  # Not typically used for client-side HTTP transport
  raise newException(McpTransportError, "sendResponse not applicable for HTTP client transport")

method receiveMessage*(t: HttpTransport): Future[JsonNode] {.async.} =
  # HTTP transport doesn't support direct message reception
  # Instead, the response is obtained from the POST request
  raise newException(McpTransportError, "receiveMessage not applicable for HTTP client transport")

method close*(t: HttpTransport): Future[void] {.async.} =
  t.client.close()

# Streamable HTTP transport methods
method sendRequest*(t: StreamableHttpTransport, request: JsonRpcRequest): Future[void] {.async.} =
  let message = encodeMessage(request)
  var reqHeaders = t.headers

  if t.sessionId.isSome:
    reqHeaders["Mcp-Session-Id"] = t.sessionId.get
    
  discard await t.client.post(t.baseUrl, body = message, headers = reqHeaders)

method sendNotification*(t: StreamableHttpTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  let message = encodeMessage(notification)
  var reqHeaders = t.headers

  if t.sessionId.isSome:
    reqHeaders["Mcp-Session-Id"] = t.sessionId.get
    
  discard await t.client.post(t.baseUrl, body = message, headers = reqHeaders)

method sendResponse*(t: StreamableHttpTransport, response: JsonRpcResponse): Future[void] {.async.} =
  # Not typically used for client-side HTTP transport
  raise newException(McpTransportError, "sendResponse not applicable for HTTP client transport")

proc openSseStream*(t: StreamableHttpTransport): Future[void] {.async.} =
  var reqHeaders = newHttpHeaders({
    "Accept": "text/event-stream"
  })

  if t.sessionId.isSome:
    reqHeaders["Mcp-Session-Id"] = t.sessionId.get
    
  # Open GET request for SSE streaming
  let response = await t.client.get(t.baseUrl, reqHeaders)
  
  if response.status.startsWith("2"):
    t.sseStream = t.baseUrl
  else:
    raise newException(McpTransportError, "Failed to open SSE stream: " & response.status)

method close*(t: StreamableHttpTransport): Future[void] {.async.} =
  t.client.close()
