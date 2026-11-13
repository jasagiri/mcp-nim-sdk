## An McpTransport that takes what the client sends and ends nothing by
## itself: its receive loop is not woken by close(), and the sending of one
## chosen method never finishes (over HTTP it finishes when the server starts
## to answer). It records what the client asked of it.

import std/[asyncdispatch, deques, json]
import transport/transport
import protocol/types

type
  StuckTransport* = ref object of McpTransport
    sentMethods*: seq[string]
    sentIds*: seq[string]
    cancelled*: seq[string]  ## the ids passed to cancelRequest
    closeCalls*: int
    holdSend*: string        ## the method whose sending never finishes
    closeFailure*: string    ## when not empty, close() fails with this message
    inbox: Deque[JsonNode]
    waiters: Deque[Future[JsonNode]]

proc newStuckTransport*(holdSend = ""): StuckTransport =
  StuckTransport(kind: mtkStdio, holdSend: holdSend, inbox: initDeque[JsonNode](),
                 waiters: initDeque[Future[JsonNode]]())

proc inject*(t: StuckTransport, message: JsonNode) =
  ## Hand `message` to the client as if the server had sent it.
  if t.waiters.len > 0:
    t.waiters.popFirst().complete(message)
  else:
    t.inbox.addLast(message)

method sendRequest*(t: StuckTransport, request: JsonRpcRequest): Future[void] {.async.} =
  t.sentMethods.add request.`method`
  t.sentIds.add request.id
  if request.`method` == t.holdSend:
    await newFuture[void]("StuckTransport.sendRequest")

method sendNotification*(t: StuckTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  discard

method sendResponse*(t: StuckTransport, response: JsonRpcResponse): Future[void] {.async.} =
  discard

method receiveMessage*(t: StuckTransport): Future[JsonNode] {.async.} =
  if t.inbox.len > 0:
    return t.inbox.popFirst()
  let waiter = newFuture[JsonNode]("StuckTransport.receiveMessage")
  t.waiters.addLast(waiter)
  return await waiter

method close*(t: StuckTransport): Future[void] {.async.} =
  inc t.closeCalls
  if t.closeFailure.len > 0:
    raise newException(McpTransportError, t.closeFailure)

method cancelRequest*(t: StuckTransport, requestId: string) =
  t.cancelled.add requestId
