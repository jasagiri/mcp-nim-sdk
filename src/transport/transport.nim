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

method sendResponse*(t: McpTransport, response: JsonRpcResponse): Future[void] {.base, async.} =
  raise newException(CatchableError, "Not implemented")

method receiveMessage*(t: McpTransport): Future[JsonNode] {.base, async.} =
  raise newException(CatchableError, "Not implemented")

method close*(t: McpTransport): Future[void] {.base, async.} =
  raise newException(CatchableError, "Not implemented")

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
