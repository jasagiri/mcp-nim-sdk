## In-process McpTransport pair: what one side sends, the other receives,
## after a round trip through the wire encoding.

import std/[asyncdispatch, deques, json]
import transport/transport
import protocol/types

type
  LoopbackTransport* = ref object of McpTransport
    peer: LoopbackTransport
    inbox: Deque[JsonNode]
    waiters: Deque[Future[JsonNode]]
    sent*: seq[JsonNode]  ## every message this side put on the wire
    closed: bool

proc deliver(t: LoopbackTransport, wire: string) =
  let message = parseJson(wire)
  if t.waiters.len > 0:
    t.waiters.popFirst().complete(message)
  else:
    t.inbox.addLast(message)

proc put(t: LoopbackTransport, wire: string) =
  t.sent.add parseJson(wire)
  t.peer.deliver(wire)

proc inject*(t: LoopbackTransport, message: JsonNode) =
  ## Hand `message` to this side as if its peer had sent it.
  t.deliver($message)

method sendRequest*(t: LoopbackTransport, request: JsonRpcRequest): Future[void] {.async.} =
  t.put(encodeMessage(request))

method sendNotification*(t: LoopbackTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  t.put(encodeMessage(notification))

method sendResponse*(t: LoopbackTransport, response: JsonRpcResponse): Future[void] {.async.} =
  t.put(encodeMessage(response))

method receiveMessage*(t: LoopbackTransport): Future[JsonNode] {.async.} =
  if t.closed:
    raise newException(McpTransportError, "loopback transport closed")
  if t.inbox.len > 0:
    return t.inbox.popFirst()
  let waiter = newFuture[JsonNode]("LoopbackTransport.receiveMessage")
  t.waiters.addLast(waiter)
  return await waiter

method close*(t: LoopbackTransport): Future[void] {.async.} =
  t.closed = true
  while t.waiters.len > 0:
    t.waiters.popFirst().fail(newException(McpTransportError, "loopback transport closed"))

proc newLoopbackPair*(): tuple[client, server: LoopbackTransport] =
  let a = LoopbackTransport(kind: mtkStdio, inbox: initDeque[JsonNode](),
                            waiters: initDeque[Future[JsonNode]]())
  let b = LoopbackTransport(kind: mtkStdio, inbox: initDeque[JsonNode](),
                            waiters: initDeque[Future[JsonNode]]())
  a.peer = b
  b.peer = a
  (client: a, server: b)
