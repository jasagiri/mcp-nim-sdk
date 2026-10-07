## What every transport shares: the default of a send that names a route, and
## the shape by which a JSON-RPC message is told to be a request, a response
## or a notification.

import std/[unittest, asyncdispatch, json]
import transport/transport
import protocol/types

type
  PlainTransport = ref object of McpTransport
    ## Implements only the sends without a route, as a transport with one peer does.
    requests: seq[string]
    notifications: seq[string]

method sendRequest*(t: PlainTransport, request: JsonRpcRequest): Future[void] {.async.} =
  t.requests.add request.`method`

method sendNotification*(t: PlainTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  t.notifications.add notification.`method`

suite "a send that names a route":
  test "Given a transport that ignores routes, when a request is sent with one, then the plain send gets it":
    let t = PlainTransport()
    waitFor t.sendRequest(newJsonRpcRequest("1", "sampling/createMessage", newJObject()),
                          MessageRoute(session: "s", requestId: "r"))
    check t.requests == @["sampling/createMessage"]

  test "Given a transport that ignores routes, when a notification is sent with one, then the plain send gets it":
    let t = PlainTransport()
    waitFor t.sendNotification(newJsonRpcNotification("notifications/progress", newJObject()),
                               MessageRoute(session: "s", requestId: "r"))
    check t.notifications == @["notifications/progress"]

suite "telling JSON-RPC messages apart":
  # JSON-RPC 2.0: a request has an id and a method, a notification a method
  # and no id, a response an id and a result or an error.
  let
    request = %*{"jsonrpc": "2.0", "id": 1, "method": "ping"}
    notification = %*{"jsonrpc": "2.0", "method": "notifications/initialized"}
    success = %*{"jsonrpc": "2.0", "id": 1, "result": {}}
    failure = %*{"jsonrpc": "2.0", "id": 1, "error": {"code": -32600, "message": "x"}}
    withoutId = %*{"jsonrpc": "2.0", "result": {}}

  test "Given a request, when classified, then it is a request only":
    check isRequest(request)
    check not isResponse(request)
    check not isNotification(request)

  test "Given a notification, when classified, then it is a notification only":
    check isNotification(notification)
    check not isRequest(notification)
    check not isResponse(notification)

  test "Given a result or an error with an id, when classified, then it is a response only":
    for message in [success, failure]:
      check isResponse(message)
      check not isRequest(message)
      check not isNotification(message)

  test "Given a result without an id, when classified, then it is nothing":
    check not isResponse(withoutId)
    check not isRequest(withoutId)
    check not isNotification(withoutId)

  test "Given JSON that is not an object, when classified, then it is nothing":
    for message in [%[1, 2], %"text", %42, newJNull()]:
      check not isRequest(message)
      check not isResponse(message)
      check not isNotification(message)
