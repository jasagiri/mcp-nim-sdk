## Test helpers for MCP protocol tests

import asyncdispatch, json, options, tables
import ../src/mcp/transport/base
import ../src/mcp/protocol

type
  InMemoryTransport* = ref object of Transport
    ## In-memory transport for testing
    responseQueue: seq[string]  # Queue of predefined responses
    sentMessages: seq[string]   # History of sent messages

proc newInMemoryTransport*(): InMemoryTransport =
  ## Create a new in-memory transport for testing
  result = InMemoryTransport(
    responseQueue: @[],
    sentMessages: @[],
    state: NotStarted
  )

method start*(t: InMemoryTransport): Future[void] {.async.} =
  ## Start the in-memory transport
  t.state = Started

method stop*(t: InMemoryTransport): Future[void] {.async.} =
  ## Stop the in-memory transport
  t.state = Closed

method send*(t: InMemoryTransport, msg: string): Future[void] {.async, gcsafe.} =
  ## Send a message through the in-memory transport
  t.sentMessages.add(msg)
  if t.onMessageCallback != nil and t.responseQueue.len > 0:
    let response = t.responseQueue[0]
    t.responseQueue.delete(0)
    await t.onMessageCallback(response)

method sendRequest*(t: InMemoryTransport, request: RequestMessage): Future[ResponseMessage] {.async.} =
  ## Send a request and get a predefined response
  let jsonStr = requestToJson(request)
  t.sentMessages.add(jsonStr)
  
  if t.responseQueue.len == 0:
    raise newException(MCPTransportError, "No predefined response available")
  
  let responseJson = t.responseQueue[0]
  t.responseQueue.delete(0)
  
  let (_, _, isResponse, jsonNode) = base.parseJsonRpc(responseJson)
  if not isResponse:
    raise newException(MCPTransportError, "Predefined response is not a valid JSON-RPC response")
  
  return parseResponse(responseJson)

proc addResponse*(t: InMemoryTransport, response: string) =
  ## Add a predefined response to the queue
  t.responseQueue.add(response)

proc getSentMessages*(t: InMemoryTransport): seq[string] =
  ## Get all sent messages
  return t.sentMessages

proc clear*(t: InMemoryTransport) =
  ## Clear the transport state
  t.responseQueue = @[]
  t.sentMessages = @[]
  t.state = NotStarted