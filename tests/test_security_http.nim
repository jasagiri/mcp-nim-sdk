## Security of the HTTP server transport (build/SECURITY_FINDINGS.md: C1, M1,
## M2, M6, L5, L6), checked with plain HTTP clients against a transport that
## has a token verifier. Every test names the spec id it verifies
## (specs/security.feature, MCP-SEC-HTTP-*).

import std/[unittest, asyncdispatch, httpclient, httpcore, json, options,
            strutils, sequtils, tables]
import sse_reader
import transport/transport
import transport/http_server
import protocol/types
import protocol/version
import protocol/features
import auth/resource_server

const
  Spoken = SupportedProtocolVersions
  ServesLegacySse = Spoken.anyIt(it.has(ftHttpSse))
  ServesSessions = latestLegacyVersion(Spoken).isSome

type
  Script = ref object
    ## What the script server was handed, and the principal it came with.
    received: seq[McpIncoming]

  Env = object
    transport: HttpServerTransport
    base: string
    script: Script

proc runScript(t: HttpServerTransport, s: Script) {.async.} =
  ## `initialize` answers with the newest legacy version; `hang` is never
  ## answered; anything else answers at once.
  while true:
    let incoming = await t.receive()
    s.received.add incoming
    let message = incoming.message
    if not isRequest(message):
      continue
    let id = message["id"].getStr()
    case message["method"].getStr()
    of "initialize":
      await t.sendResponse(newJsonRpcResponse(id, %*{
        "protocolVersion": $latestLegacyVersion(Spoken).get(DefaultProtocolVersion),
        "capabilities": {}, "serverInfo": {"name": "script", "version": "0"}}))
    of "hang":
      discard
    else:
      await t.sendResponse(newJsonRpcResponse(id, %*{"principal":
        (if incoming.principal.isSome: incoming.principal.get else: "")}))

proc verdicts(): TokenVerifier =
  ## Tokens "alice" and "bob" stand for those principals; others are invalid.
  result = proc(token, resource: string): Future[TokenVerdict] {.async.} =
    if token in ["alice", "bob"]:
      return TokenVerdict(kind: tvValid, principal: some(token))
    return TokenVerdict(kind: tvInvalid)

proc startProtected(): Env =
  let version = if ServesSessions: latestLegacyVersion(Spoken).get else: DefaultProtocolVersion
  let transport = newHttpServerTransport(port = 0, protocolVersion = version)
  transport.listen()
  asyncCheck transport.serve()
  let script = Script()
  asyncCheck runScript(transport, script)
  let base = "http://127.0.0.1:" & $transport.port
  transport.auth = newResourceServerAuth(ResourceServerConfig(
    resource: base & "/mcp", authorizationServers: @["https://auth.example.com"],
    verify: verdicts(), version: version))
  Env(transport: transport, base: base, script: script)

proc bearer(token: string): seq[(string, string)] =
  @[("Authorization", "Bearer " & token)]

proc send(url: string, httpMethod: HttpMethod, body = "",
          headers: openArray[(string, string)] = []): tuple[code: HttpCode, headers: HttpHeaders, body: string] =
  let http = newAsyncHttpClient()
  defer: http.close()
  let all = newHttpHeaders({"Content-Type": "application/json",
                            "Accept": "application/json, text/event-stream"})
  for (name, value) in headers:
    all[name] = value
  let response = waitFor http.request(url, httpMethod, body, all)
  (response.code, response.headers, waitFor response.body)

proc rpc(id: int, name: string, params = newJObject()): string =
  $(%*{"jsonrpc": "2.0", "id": id, "method": name, "params": params})

proc initializeBody(): string =
  rpc(1, "initialize", %*{"protocolVersion": $latestLegacyVersion(Spoken).get(DefaultProtocolVersion),
                          "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})

proc openSession(env: Env, token: string): string =
  ## Initializes as `token` and returns the session id.
  let reply = send(env.base & "/mcp", HttpPost, initializeBody(), bearer(token))
  doAssert reply.code == Http200, "initialize answered " & $reply.code
  reply.headers["Mcp-Session-Id"]

suite "Authorization covers every endpoint the transport serves (MCP-SEC-HTTP-1)":
  if ServesLegacySse:
    test "Given an authorized transport, when GET /sse comes without a token, then the answer is 401 and no session is made":
      let env = startProtected()
      let stream = open(env.base & "/sse", HttpGet, "", @[("Accept", "text/event-stream")])
      check stream.code == Http401
      stream.close()
      check env.transport.sessionCount == 0

    test "Given an authorized transport, when POST /messages comes without a token, then the answer is 401 and nothing reaches the server":
      let env = startProtected()
      let reply = send(env.base & "/messages?sessionId=x", HttpPost, rpc(1, "tools/list"))
      check reply.code == Http401
      waitFor sleepAsync(30)
      check env.script.received.len == 0

    test "Given a token, when a client opens /sse and posts, then the request reaches the server as that principal":
      let env = startProtected()
      let stream = open(env.base & "/sse", HttpGet, "",
                        @[("Accept", "text/event-stream")] & bearer("alice"))
      check stream.code == Http200
      let endpoint = stream.next().get.data
      let reply = send(env.base & endpoint, HttpPost, rpc(7, "tools/list"), bearer("alice"))
      check reply.code == Http202
      let answer = parseJson(stream.next().get.data)
      check answer["result"]["principal"].getStr() == "alice"
      stream.close()

    test "Given an invalid token, when GET /sse comes, then the answer is 401":
      let env = startProtected()
      let stream = open(env.base & "/sse", HttpGet, "",
                        @[("Accept", "text/event-stream")] & bearer("nobody"))
      check stream.code == Http401
      stream.close()

  test "Given an authorized transport with documents, when a document and the metadata are read without a token, then both are served":
    let env = startProtected()
    env.transport.documents["/.well-known/server-card.json"] = HttpDocument(
      contentType: "application/json", body: """{"name":"card"}""")
    check send(env.base & "/.well-known/server-card.json", HttpGet).code == Http200
    check send(env.base & "/.well-known/oauth-protected-resource/mcp", HttpGet).code == Http200

  test "Given an authorized transport, when an unknown path is asked, then it is 404":
    let env = startProtected()
    check send(env.base & "/nothing", HttpGet).code == Http404
