## MCP stdio transport implementation

import asyncdispatch, json, streams, strutils
import ./transport
import ../protocol/types

type
  StdioTransport* = ref object of McpTransport
    ## Standard I/O transport

proc newStdioTransport*(input: Stream, output: Stream): StdioTransport =
  result = StdioTransport(
    kind: mtkStdio,
    inputStream: input,
    outputStream: output
  )

proc newStdioTransport*(): StdioTransport =
  ## Create a transport using system stdin/stdout
  result = newStdioTransport(newFileStream(stdin), newFileStream(stdout))

method sendRequest*(t: StdioTransport, request: JsonRpcRequest): Future[void] {.async.} =
  let message = encodeMessage(request)
  t.outputStream.writeLine(message)
  t.outputStream.flush()

method sendNotification*(t: StdioTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  let message = encodeMessage(notification)
  t.outputStream.writeLine(message)
  t.outputStream.flush()

method sendResponse*(t: StdioTransport, response: JsonRpcResponse): Future[void] {.async.} =
  let message = encodeMessage(response)
  t.outputStream.writeLine(message)
  t.outputStream.flush()

method receiveMessage*(t: StdioTransport): Future[JsonNode] {.async.} =
  if t.inputStream.atEnd():
    raise newException(McpTransportError, "EOF on input stream")
    
  let line = t.inputStream.readLine()
  if line.len == 0:
    raise newException(McpTransportError, "Empty message received")
    
  try:
    return parseJson(line)
  except JsonParsingError as e:
    raise newException(McpTransportError, "Invalid JSON: " & e.msg)

method close*(t: StdioTransport): Future[void] {.async.} =
  t.inputStream.close()
  t.outputStream.close()
