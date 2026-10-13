## MCP transport layer

import asyncdispatch, json, options, unicode
import ../protocol/types
from ../protocol/modern import ErrInternal
import ../protocol/diagnostic

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
    onRequestLost*: proc(requestId: string, reason: string) {.closure.}
      ## Called by a client transport when a request it sent will get no
      ## response (see `McpRequestLostError`). `requestId` is the id of the
      ## request. This is how a local loss is told apart from a response of
      ## the peer: the transport delivers nothing in `receiveMessage` for it.
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
    peer*: string
      ## The network address of the peer that sent the message, where the
      ## transport has one; empty where it has not (stdio). A header such as
      ## X-Forwarded-For is not trusted to name it.

  McpTransportError* = object of CatchableError
    code*: int

  McpAuthorizationError* = object of McpTransportError
    ## The server refused a request for want of authorization (HTTP 401 or
    ## 403) and the transport's authorization could not change that: there is
    ## none, it gave up, or it failed (its error is then `parent`). Trying
    ## again in another way does not help, so a client does not take this for
    ## a server that speaks another version.
    status*: int
      ## The HTTP status of the refusal.

  McpSessionExpiredError* = object of McpTransportError
    ## The server answered a request that carried a session id with HTTP 404:
    ## it ended that session. The request was not carried out and is not sent
    ## again; the caller decides whether to send it anew.
    current*: bool
      ## The session ended was the one the transport was using, which the
      ## transport has now dropped; false for a request of an older session.
    renewed*: bool
      ## A new session has been started (the client's doing, after this error
      ## was raised by the transport).

  McpRequestLostError* = object of McpTransportError
    ## The event stream of a request ended before its response arrived and
    ## could not be resumed. The request is lost; the caller may send it again.

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

func isUtf8(text: string): bool {.raises: [].} =
  ## Whether `text` is UTF-8 as RFC 3629 has it. `validateUtf8` lets the
  ## surrogates U+D800..U+DFFF through (ED A0..BF xx), which UTF-8 has not.
  if validateUtf8(text) != -1:
    return false
  for i in 0 ..< text.len - 1:
    if text[i] == '\xED' and text[i + 1] >= '\xA0':
      return false
  true

func notUtf8(node: JsonNode, at: string): string {.raises: [].} =
  ## Where in `node` a string (a value or a member name) is not UTF-8, as a
  ## path from `at`; "" when every string is.
  if node.isNil:
    return ""
  case node.kind
  of JString:
    if not isUtf8(node.str): return at
  of JArray:
    for i in 0 ..< node.len:
      let item = node[i]
      let found = notUtf8(item, at & "[" & $i & "]")
      if found.len > 0: return found
  of JObject:
    for name, value in node.pairs:
      if not isUtf8(name): return at & ": a member name"
      let found = notUtf8(value, at & "." & name)
      if found.len > 0: return found
  else:
    discard
  ""

proc requireUtf8(message: JsonNode, what: string) {.raises: [McpTransportError].} =
  ## JSON-RPC messages are UTF-8 (basic/transports). A string that is not
  ## would be written as it is and make the whole message something else, so
  ## the message is not sent. The bytes are not replaced: what would arrive
  ## is not what the caller meant.
  let where = notUtf8(message, what)
  if where.len > 0:
    raise newException(McpTransportError,
      "a message must be UTF-8, and a string is not: " & peerText(where))

proc toJson*(request: JsonRpcRequest): JsonNode =
  result = %*{
    "jsonrpc": request.jsonrpc,
    "id": wireId(request.id, request.idNode),
    "method": request.`method`
  }
  if not request.params.isNil:
    result["params"] = request.params
  requireUtf8(result, "request " & request.`method`)

proc toJson*(notification: JsonRpcNotification): JsonNode =
  result = %*{
    "jsonrpc": notification.jsonrpc,
    "method": notification.`method`
  }
  if not notification.params.isNil:
    result["params"] = notification.params
  requireUtf8(result, "notification " & notification.`method`)

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
  elif response.result.isSome:
    result["result"] = response.result.get
  else:
    # Not an empty success: the handler that built this has a defect, and the
    # peer is told only that, not where.
    stderr.writeLine("[mcp-transport] response " & peerText(response.id) &
                     " has neither a result nor an error; sent as an internal error")
    result["error"] = %*{"code": ErrInternal, "message": "Internal error"}
  # A response is owed: one that cannot be written as UTF-8 is answered with
  # an internal error instead, as a response without a result is above.
  let where = notUtf8(result, "response")
  if where.len > 0:
    stderr.writeLine("[mcp-transport] response " & peerText(response.id) &
                     " holds a string that is not UTF-8 (" & peerText(where) &
                     "); sent as an internal error")
    let id = result["id"]
    result = %*{"jsonrpc": response.jsonrpc,
                "id": (if notUtf8(id, "").len > 0: newJNull() else: id),
                "error": {"code": ErrInternal, "message": "Internal error"}}

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
