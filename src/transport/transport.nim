## MCP transport layer

import asyncdispatch, json, options, streams
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

# Helper functions for encoding/decoding
proc encodeMessage*[T](message: T): string =
  # Convert message to JSON string
  let jsonNode = %message
  return $jsonNode

proc decodeRequest*(json: JsonNode): JsonRpcRequest =
  # Convert JSON to JsonRpcRequest
  var request = JsonRpcRequest(
    jsonrpc: json["jsonrpc"].getStr(),
    id: json["id"].getStr(),
    `method`: json["method"].getStr()
  )

  if json.hasKey("params"):
    request.params = json["params"]
  else:
    request.params = newJObject()

  return request

proc decodeResponse*(json: JsonNode): JsonRpcResponse =
  # Convert JSON to JsonRpcResponse
  var response = JsonRpcResponse(
    jsonrpc: json["jsonrpc"].getStr(),
    id: json["id"].getStr()
  )

  if json.hasKey("result"):
    response.result = some(json["result"])
    response.error = none(JsonRpcError)
  elif json.hasKey("error"):
    let errorJson = json["error"]
    var error = JsonRpcError(
      code: errorJson["code"].getInt(),
      message: errorJson["message"].getStr()
    )

    if errorJson.hasKey("data"):
      error.data = errorJson["data"]
    else:
      error.data = newJNull()

    response.result = none(JsonNode)
    response.error = some(error)

  return response

proc decodeNotification*(json: JsonNode): JsonRpcNotification =
  # Convert JSON to JsonRpcNotification
  var notification = JsonRpcNotification(
    jsonrpc: json["jsonrpc"].getStr(),
    `method`: json["method"].getStr()
  )

  if json.hasKey("params"):
    notification.params = json["params"]
  else:
    notification.params = newJObject()

  return notification

proc isRequest*(json: JsonNode): bool =
  return json.hasKey("id") and json.hasKey("method")

proc isResponse*(json: JsonNode): bool =
  return json.hasKey("id") and (json.hasKey("result") or json.hasKey("error"))

proc isNotification*(json: JsonNode): bool =
  return (not json.hasKey("id")) and json.hasKey("method")
