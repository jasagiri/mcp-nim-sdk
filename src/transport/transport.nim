## MCP transport layer

import asyncdispatch, json, options
import ../protocol/types

type
  McpTransportKind* = enum
    mtkStdio,     # Standard input/output transport
    mtkHttp,      # HTTP transport
    mtkStreamable # Streamable HTTP transport

  McpTransport* = ref object of RootObj
    ## Base transport class
    kind*: McpTransportKind
    onSessionEnd*: proc(session: string) {.closure, gcsafe.}
      ## Called by a transport that serves several clients when one of
      ## them ends its session.
    onRequestCancelled*: proc(session, requestId: string) {.closure, gcsafe.}
      ## Called by a transport when the peer abandoned a request that was
      ## still being handled, e.g. by closing the HTTP connection that carried
      ## it (which is how a 2026-07-28 client cancels). `requestId` is the id
      ## the transport handed to `receive`. The server should stop working on
      ## the request; a response sent for it afterwards is dropped.
    servesExtensionMethod*: proc(methodName: string): bool {.closure, gcsafe.}
      ## Whether the server behind this transport serves `methodName` for an
      ## extension; nil when nobody said. A transport that applies rules per
      ## method (the `Mcp-Name` header of Streamable HTTP) asks it.

  MessageRoute* = object
    ## Where a message the server initiates belongs. A transport with one
    ## peer and one stream ignores it; Streamable HTTP uses it to pick the
    ## stream.
    session*: string
      ## The client to send to. Empty: every client (a notification) or the
      ## only one (a request).
    requestId*: string
      ## The id, as seen by the transport (`McpIncoming.message["id"]`), of
      ## the client request the message belongs to. The message then travels
      ## in the response to that request. Empty: not related to a request.

  McpIncoming* = object
    ## A received message and the connection it came from.
    message*: JsonNode
    session*: string
      ## Empty for a transport with a single peer.
    paramHeaders*: Option[seq[(string, string)]]
      ## The `Mcp-Param-*` headers of the HTTP request that carried the
      ## message, for the server to check against the arguments. None where
      ## the transport has no headers (stdio).
    principal*: Option[string]
      ## Who the transport's authorization says sent the message (the
      ## subject of the access token); none where there is no authorization.

  McpTransportError* = object of CatchableError
    code*: int

  McpTransportClosedError* = object of McpTransportError
    ## The peer closed the connection. For a stdio server this is how a
    ## session normally ends.

# Abstract methods that must be implemented by derived types
method sendRequest*(t: McpTransport, request: JsonRpcRequest): Future[void] {.base, async.} =
  raise newException(CatchableError, "Not implemented")

method sendNotification*(t: McpTransport, notification: JsonRpcNotification): Future[void] {.base, async.} =
  raise newException(CatchableError, "Not implemented")

method sendNotification*(t: McpTransport, notification: JsonRpcNotification,
                         route: MessageRoute): Future[void] {.base, async.} =
  ## Like `sendNotification`, to the client and request named by `route`.
  await t.sendNotification(notification)

method sendRequest*(t: McpTransport, request: JsonRpcRequest,
                    route: MessageRoute): Future[void] {.base, async.} =
  ## Like `sendRequest`, to the client and request named by `route`.
  await t.sendRequest(request)

method sendResponse*(t: McpTransport, response: JsonRpcResponse): Future[void] {.base, async.} =
  raise newException(CatchableError, "Not implemented")

method receiveMessage*(t: McpTransport): Future[JsonNode] {.base, async.} =
  raise newException(CatchableError, "Not implemented")

method receive*(t: McpTransport): Future[McpIncoming] {.base, async.} =
  ## The next message with the connection it came from. Transports with a
  ## single peer need only implement receiveMessage.
  return McpIncoming(message: await t.receiveMessage(), session: "")

method close*(t: McpTransport): Future[void] {.base, async.} =
  raise newException(CatchableError, "Not implemented")

method requestDropped*(t: McpTransport, session, requestId: string) {.base.} =
  ## The server will not answer request `requestId` of `session` (it was
  ## cancelled), so a transport that keeps something per request can let go.
  discard

method cancelRequest*(t: McpTransport, requestId: string) {.base.} =
  ## Give up on a request this side sent, the way the transport cancels:
  ## Streamable HTTP closes the connection that carries it. Transports that
  ## cancel with a `notifications/cancelled` message (stdio) leave this to the
  ## caller; the default does nothing.
  discard

method protocolVersionNegotiated*(t: McpTransport, version: McpProtocolVersion) {.base.} =
  ## Called once the initialize handshake has agreed on `version`, for
  ## transports that must state it on later messages. Most need not.
  discard

# Wire encoding

proc wireId(id: string, idNode: JsonNode): JsonNode =
  if idNode.isNil: %id else: idNode

proc toJson*(request: JsonRpcRequest): JsonNode =
  result = %*{
    "jsonrpc": request.jsonrpc,
    "id": wireId(request.id, request.idNode),
    "method": request.`method`
  }
  if not request.params.isNil:
    result["params"] = request.params

proc toJson*(notification: JsonRpcNotification): JsonNode =
  result = %*{
    "jsonrpc": notification.jsonrpc,
    "method": notification.`method`
  }
  if not notification.params.isNil:
    result["params"] = notification.params

proc toJson*(response: JsonRpcResponse): JsonNode =
  ## A response carries exactly one of result and error.
  result = %*{
    "jsonrpc": response.jsonrpc,
    "id": wireId(response.id, response.idNode)
  }
  if response.error.isSome:
    let error = response.error.get
    let errorJson = %*{"code": error.code, "message": error.message}
    if not error.data.isNil and error.data.kind != JNull:
      errorJson["data"] = error.data
    result["error"] = errorJson
  else:
    result["result"] = response.result.get(newJObject())

proc encodeMessage*(request: JsonRpcRequest): string = $request.toJson()
proc encodeMessage*(notification: JsonRpcNotification): string = $notification.toJson()
proc encodeMessage*(response: JsonRpcResponse): string = $response.toJson()

proc idText(node: JsonNode): string =
  ## Peers may use a string or a number as the id.
  if node.isNil: ""
  elif node.kind == JString: node.getStr()
  else: $node

proc paramsOf(json: JsonNode): JsonNode =
  let params = json{"params"}
  if params.isNil: newJObject() else: params

proc decodeRequest*(json: JsonNode): JsonRpcRequest =
  JsonRpcRequest(
    jsonrpc: json{"jsonrpc"}.getStr(),
    id: idText(json{"id"}),
    idNode: json{"id"},
    `method`: json{"method"}.getStr(),
    params: paramsOf(json)
  )

proc decodeResponse*(json: JsonNode): JsonRpcResponse =
  result = JsonRpcResponse(
    jsonrpc: json{"jsonrpc"}.getStr(),
    id: idText(json{"id"}),
    idNode: json{"id"},
    result: none(JsonNode),
    error: none(JsonRpcError)
  )
  let errorJson = json{"error"}
  if not errorJson.isNil and errorJson.kind == JObject:
    let data = errorJson{"data"}
    result.error = some(JsonRpcError(
      code: errorJson{"code"}.getInt(),
      message: errorJson{"message"}.getStr(),
      data: if data.isNil: newJNull() else: data
    ))
  elif json.hasKey("result"):
    result.result = some(json["result"])

proc decodeNotification*(json: JsonNode): JsonRpcNotification =
  JsonRpcNotification(
    jsonrpc: json{"jsonrpc"}.getStr(),
    `method`: json{"method"}.getStr(),
    params: paramsOf(json)
  )

proc isRequest*(json: JsonNode): bool =
  json.kind == JObject and json.hasKey("id") and json.hasKey("method")

proc isResponse*(json: JsonNode): bool =
  json.kind == JObject and json.hasKey("id") and
    (json.hasKey("result") or json.hasKey("error"))

proc isNotification*(json: JsonNode): bool =
  json.kind == JObject and (not json.hasKey("id")) and json.hasKey("method")
