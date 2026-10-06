## An authorization that cannot be obtained is reported as that: the
## transport raises `McpAuthorizationError`, and a client that is finding out
## which era the server speaks does not take it for a legacy server's refusal.

import std/[unittest, asyncdispatch, asynchttpserver, json, options, nativesockets, strutils]
import transport/http
import transport/auth_hook
import transport/transport
import client/client
import protocol/types
import protocol/version

type Refuser = ref object
  url: string
  methods: seq[string]  ## the JSON-RPC methods that were posted

proc startRefuser(): Refuser =
  ## A server that answers every request 403 `insufficient_scope`.
  let refuser = Refuser()
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  refuser.url = "http://127.0.0.1:" & $server.getPort.int & "/mcp"
  proc handler(req: Request) {.async, gcsafe.} =
    if req.reqMethod == HttpPost:
      {.cast(gcsafe).}:
        refuser.methods.add parseJson(req.body){"method"}.getStr()
    await req.respond(Http403, "", newHttpHeaders({
      "WWW-Authenticate": "Bearer error=\"insufficient_scope\", scope=\"files:read\""}))
  proc loop() {.async.} =
    while true:
      await server.acceptRequest(handler)
  asyncCheck loop()
  refuser

proc answering(onChallenge: proc(status: int, wwwAuthenticate: seq[string]): Future[bool]
                              {.closure, gcsafe.}): HttpClientAuth =
  HttpClientAuth(
    authorization: proc(): Future[Option[string]] {.closure, gcsafe, async.} =
      return some("Bearer tok"),
    onChallenge: onChallenge)

proc failureOf(sending: Future[void]): ref McpAuthorizationError =
  try:
    waitFor sending
  except McpAuthorizationError as e:
    result = e

suite "an authorization that cannot be obtained":

  test "Given a hook that can do nothing about a 403, when a request is sent, then McpAuthorizationError carries the status":
    let refuser = startRefuser()
    let transport = newStreamableHttpTransport(refuser.url)
    transport.auth = answering(proc(status: int, wwwAuthenticate: seq[string]): Future[bool]
                                   {.closure, gcsafe, async.} = return false)
    let failure = failureOf(transport.sendRequest(newJsonRpcRequest("1", "tools/list", newJObject())))
    check not failure.isNil
    if not failure.isNil:
      check failure.status == 403
    waitFor transport.close()

  test "Given a hook that fails, when a request is sent, then McpAuthorizationError says why and keeps the hook's error":
    let refuser = startRefuser()
    let transport = newStreamableHttpTransport(refuser.url)
    transport.auth = answering(proc(status: int, wwwAuthenticate: seq[string]): Future[bool]
                                   {.closure, gcsafe, async.} =
      raise newException(ValueError, "the user denied consent"))
    let failure = failureOf(transport.sendRequest(newJsonRpcRequest("1", "tools/list", newJObject())))
    check not failure.isNil
    if not failure.isNil:
      check failure.status == 403
      check "the user denied consent" in failure.msg
      check failure.parent of ValueError
    waitFor transport.close()

  test "Given a hook that always says it improved things, when the server keeps refusing, then McpAuthorizationError ends the attempts":
    let refuser = startRefuser()
    let transport = newStreamableHttpTransport(refuser.url)
    transport.auth = answering(proc(status: int, wwwAuthenticate: seq[string]): Future[bool]
                                   {.closure, gcsafe, async.} = return true)
    let failure = failureOf(transport.sendRequest(newJsonRpcRequest("1", "tools/list", newJObject())))
    check not failure.isNil
    if not failure.isNil:
      check failure.status == 403
    check refuser.methods.len < 10
    waitFor transport.close()

  test "Given a transport without authorization, when the server answers 403, then McpAuthorizationError carries the status":
    let refuser = startRefuser()
    let transport = newStreamableHttpTransport(refuser.url)
    let failure = failureOf(transport.sendRequest(newJsonRpcRequest("1", "tools/list", newJObject())))
    check not failure.isNil
    if not failure.isNil:
      check failure.status == 403
    waitFor transport.close()

  test "Given a server that refuses the authorization for good, when a client connects, then it fails with McpAuthorizationError":
    let refuser = startRefuser()
    let transport = newStreamableHttpTransport(refuser.url)
    transport.auth = answering(proc(status: int, wwwAuthenticate: seq[string]): Future[bool]
                                   {.closure, gcsafe, async.} = return false)
    let client = newMcpClient(McpClientInfo(name: "c", version: "1"))
    let failure = failureOf(client.connect(transport))
    check not failure.isNil
    if not failure.isNil:
      check failure.status == 403
    if DefaultProtocolVersion.isModern:
      # The refusal of the probe is not a legacy server's: no handshake follows.
      check refuser.methods == @["server/discover"]
    waitFor client.close()
