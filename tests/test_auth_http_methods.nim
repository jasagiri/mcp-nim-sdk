## A protected server wants the token on every HTTP request of a session:
## the POSTs, the GET that opens the stream for server-initiated messages,
## and the DELETE that ends the session.

import std/[unittest, asyncdispatch, asynchttpserver, json, options, tables,
            nativesockets, strutils]
import transport/http
import transport/auth_hook
import protocol/types

const SpeaksSessions = DefaultProtocolVersion >= mpv20250326

type Seen = ref object
  authorization: Table[string, seq[string]]  ## by HTTP method

proc startRecorder(seen: Seen): string =
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  let port = server.getPort.int
  proc handler(req: Request) {.async, gcsafe.} =
    let token = if req.headers.hasKey("Authorization"): $req.headers["Authorization"] else: ""
    {.cast(gcsafe).}:
      seen.authorization.mgetOrPut($req.reqMethod, @[]).add token
    case req.reqMethod
    of HttpPost:
      let message = parseJson(req.body)
      if message.hasKey("id"):
        await req.respond(Http200, $(%*{"jsonrpc": "2.0", "id": message["id"], "result": {}}),
          newHttpHeaders({"Content-Type": "application/json", "Mcp-Session-Id": "s-1"}))
      else:
        await req.respond(Http202, "")
    of HttpGet:
      await req.respond(Http405, "", newHttpHeaders({"Allow": "POST, DELETE"}))
    else:
      await req.respond(Http200, "")
  proc loop() {.async.} =
    while true:
      await server.acceptRequest(handler)
  asyncCheck loop()
  "http://127.0.0.1:" & $port & "/mcp"

proc bearer(token: string): HttpClientAuth =
  HttpClientAuth(
    authorization: proc(): Future[Option[string]] {.closure, gcsafe, async.} =
      return some("Bearer " & token),
    onChallenge: proc(status: int, wwwAuthenticate: seq[string]): Future[bool] {.closure, gcsafe, async.} =
      return false)

suite "authorization on every HTTP request":

  test "Given a transport with a token, when it posts, then every POST carries the token":
    let seen = Seen()
    let transport = newStreamableHttpTransport(startRecorder(seen))
    transport.auth = bearer("tok")
    waitFor transport.sendRequest(newJsonRpcRequest("1", "initialize", newJObject()))
    waitFor transport.sendRequest(newJsonRpcRequest("2", "tools/list", newJObject()))
    check seen.authorization["POST"] == @["Bearer tok", "Bearer tok"]
    waitFor transport.close()

  test "Given a transport without authorization, when it posts, then no Authorization header is sent":
    let seen = Seen()
    let transport = newStreamableHttpTransport(startRecorder(seen))
    waitFor transport.sendRequest(newJsonRpcRequest("1", "initialize", newJObject()))
    check seen.authorization["POST"] == @[""]
    waitFor transport.close()

  if SpeaksSessions:
    test "Given a session on a version with the GET stream, when the stream is opened and the session ended, then GET and DELETE carry the token too":
      let seen = Seen()
      let transport = newStreamableHttpTransport(startRecorder(seen))
      transport.auth = bearer("tok")
      waitFor transport.sendRequest(newJsonRpcRequest("1", "initialize", newJObject()))
      transport.protocolVersionNegotiated(mpv20250326)
      waitFor transport.sendNotification(
        newJsonRpcNotification("notifications/initialized", newJObject()))
      waitFor sleepAsync(100)
      waitFor transport.close()
      waitFor sleepAsync(50)
      check seen.authorization.getOrDefault("GET") == @["Bearer tok"]
      check seen.authorization.getOrDefault("DELETE") == @["Bearer tok"]
