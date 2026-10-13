## Verifies that HttpTransport / StreamableHttpTransport raise McpTransportError
## on non-2xx HTTP responses instead of silently discarding them.
##
## Repro for audit finding #6: previously `discard await client.post(...)`
## let 4xx/5xx server errors flow through as success.
##
## We use one shared mock server with path-based status codes so that
## asynchttpserver's asyncCheck'd serve loop does not get re-entered
## across tests (which previously surfaced as "Bad file descriptor").

import std/[unittest, asyncdispatch, asynchttpserver, json, strutils]
import std/net
import transport/transport
import transport/http
import protocol/types

proc pickFreePort(): Port =
  let s = newSocket()
  defer: s.close()
  s.bindAddr(Port(0))
  let (_, port) = s.getLocalAddr()
  port

let mockPort = pickFreePort()
let mockBase = "http://127.0.0.1:" & $mockPort.int

proc statusForPath(path: string): tuple[code: HttpCode, body: string] =
  case path
  of "/ok":      (Http200, "{}")
  of "/500":     (Http500, """{"error":"boom"}""")
  of "/404":     (Http404, """{"error":"not found"}""")
  of "/503":     (Http503, "")
  else:          (Http200, "{}")

proc startMockServer(): AsyncHttpServer =
  result = newAsyncHttpServer()
  let server = result
  proc cb(req: Request) {.async.} =
    let (code, body) = statusForPath(req.url.path)
    await req.respond(code, body)
  asyncCheck server.serve(mockPort, cb)

proc buildRequest(): JsonRpcRequest =
  newJsonRpcRequest("1", "ping", newJObject())

let server = startMockServer()

suite "HTTP transport error propagation":
  test "Given a server returning 500 When sendRequest is called Then McpTransportError is raised":
    let t = newHttpTransport(mockBase & "/500")
    var caught = false
    var msg = ""
    try:
      waitFor t.sendRequest(buildRequest())
    except McpTransportError as e:
      caught = true
      msg = e.msg
    waitFor t.close()
    check caught
    check "500" in msg

  test "Given a server returning 404 When sendNotification is called Then McpTransportError is raised":
    let t = newHttpTransport(mockBase & "/404")
    var caught = false
    try:
      let n = newJsonRpcNotification("tick", newJObject())
      waitFor t.sendNotification(n)
    except McpTransportError:
      caught = true
    waitFor t.close()
    check caught

  test "Given a server returning 200 When sendRequest is called Then no exception is raised":
    let t = newHttpTransport(mockBase & "/ok")
    var raised = false
    try:
      waitFor t.sendRequest(buildRequest())
    except McpTransportError:
      raised = true
    waitFor t.close()
    check not raised

  test "Given a streamable transport sendRequest with 503 Then McpTransportError is raised":
    let t = newStreamableHttpTransport(mockBase & "/503")
    var caught = false
    try:
      waitFor t.sendRequest(buildRequest())
    except McpTransportError:
      caught = true
    waitFor t.close()
    check caught

server.close()
