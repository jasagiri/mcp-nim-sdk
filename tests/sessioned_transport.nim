## A server-side McpTransport that serves several clients, as Streamable HTTP
## does: every received message names its session, and everything the server
## sends is recorded with the session it is addressed to.

import std/[asyncdispatch, deques, json, tables]
import transport/transport
import protocol/types

type
  Sent* = object
    session*: string
    message*: JsonNode
    related*: string
      ## The client request a notification or a request of the server belongs to.

  SessionedTransport* = ref object of McpTransport
    inbox: Deque[McpIncoming]
    waiters: Deque[Future[McpIncoming]]
    owners: Table[string, string]
      ## Which session sent the request with this id.
    sent*: seq[Sent]
    failFor*: string
      ## A session that notifications cannot be delivered to.
    dropped*: seq[tuple[session, requestId: string]]
      ## The requests the server told the transport it will not answer.

proc newSessionedTransport*(): SessionedTransport =
  SessionedTransport(kind: mtkStreamable, inbox: initDeque[McpIncoming](),
                     waiters: initDeque[Future[McpIncoming]](),
                     owners: initTable[string, string]())

func idText(id: JsonNode): string =
  if id.kind == JString: id.getStr() else: $id

proc inject*(t: SessionedTransport, session: string, message: JsonNode) =
  ## Hand `message` to the server as if the client of `session` had sent it.
  if isRequest(message):
    t.owners[idText(message["id"])] = session
  let wire = parseJson($message)
  let incoming = McpIncoming(message: wire, session: session)
  if t.waiters.len > 0:
    t.waiters.popFirst().complete(incoming)
  else:
    t.inbox.addLast(incoming)

proc record(t: SessionedTransport, session: string, wire: JsonNode, related = "") =
  t.sent.add Sent(session: session, message: wire, related: related)

method requestDropped*(t: SessionedTransport, session, requestId: string) =
  t.dropped.add (session: session, requestId: requestId)

method sendRequest*(t: SessionedTransport, request: JsonRpcRequest): Future[void] {.async.} =
  t.record(request.session, parseJson(encodeMessage(request)), request.relatedRequestId)

method sendNotification*(t: SessionedTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  if t.failFor.len > 0 and notification.session == t.failFor:
    raise newException(McpTransportError, "no stream for session " & t.failFor)
  t.record(notification.session, parseJson(encodeMessage(notification)),
           notification.relatedRequestId)

method sendResponse*(t: SessionedTransport, response: JsonRpcResponse): Future[void] {.async.} =
  t.record(t.owners.getOrDefault(response.id), parseJson(encodeMessage(response)))

method receive*(t: SessionedTransport): Future[McpIncoming] {.async.} =
  if t.inbox.len > 0:
    return t.inbox.popFirst()
  let waiter = newFuture[McpIncoming]("SessionedTransport.receive")
  t.waiters.addLast(waiter)
  return await waiter

method receiveMessage*(t: SessionedTransport): Future[JsonNode] {.async.} =
  return (await t.receive()).message

proc hangUp*(t: SessionedTransport) =
  ## The peer closes the connection: the server's pending receive fails.
  while t.waiters.len > 0:
    t.waiters.popFirst().fail(newException(McpTransportClosedError, "peer hung up"))

method close*(t: SessionedTransport): Future[void] {.async.} =
  t.hangUp()
