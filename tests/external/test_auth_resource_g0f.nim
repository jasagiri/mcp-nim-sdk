## What a resource server does with the access token it receives, and with
## the challenge it answers a token that lacks scope with. Checked with a
## plain HTTP client against this SDK's HttpServerTransport and, for what a
## handler sees, with this SDK's client. Everything is on 127.0.0.1.

import std/[unittest, asyncdispatch, httpclient, httpcore, json, options,
            strutils, tables, nativesockets, os]
import transport/http
import transport/http_server
import server/server
import client/client
import protocol/types
import protocol/version
import protocol/features
import auth/resource_server

const
  Secret = "tok-7f3a91c2-secret-access-token"
  authVersions = block:
    var vs: seq[McpProtocolVersion]
    for v in SupportedProtocolVersions:
      if v.has(ftAuthorization):
        vs.add v
    vs

type
  Verdicts = TableRef[string, TokenVerdict]

  Env = object
    transport: HttpServerTransport
    url: string
    origin: string

proc verifierFor(verdicts: Verdicts): TokenVerifier =
  result = proc(token, resource: string): Future[TokenVerdict] {.async.} =
    if token == "explode":
      raise newException(ValueError, "introspection said: " & token)
    if token in verdicts:
      return verdicts[token]
    return TokenVerdict(kind: tvInvalid)

proc verdicts(): Verdicts =
  result = newTable[string, TokenVerdict]()
  result[Secret] = TokenVerdict(kind: tvValid, principal: some("alice"))
  result["narrow-" & Secret] = TokenVerdict(kind: tvInsufficientScope,
                                            requiredScopes: @["files:write"])

proc startServer(v: McpProtocolVersion, server: McpServer): Env =
  let transport = newHttpServerTransport(port = 0, protocolVersion = v)
  transport.listen()
  asyncCheck transport.serve()
  waitFor server.attachTransport(transport)
  result.transport = transport
  result.origin = "http://127.0.0.1:" & $transport.port
  result.url = result.origin & "/mcp"
  transport.auth = newResourceServerAuth(ResourceServerConfig(
    resource: result.url, authorizationServers: @["https://auth.example.com"],
    verify: verifierFor(verdicts()), version: v))

proc plainServer(v: McpProtocolVersion): McpServer =
  result = newMcpServer(McpServerInfo(name: "ExampleServer", version: "1.0.0"),
    protocolVersion = v,
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"name": "who", "inputSchema": {"type": "object"}}]))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    ## Reports everything the context offers a handler.
    return %*{"content": [{"type": "text", "text": $(%*{
      "principal": ctx.principal.get("none"), "session": ctx.session,
      "requestId": ctx.requestId, "version": $ctx.version,
      "meta": (if ctx.meta.isNil: newJNull() else: ctx.meta),
      "clientCapabilities": (if ctx.clientCapabilities.isNil: newJNull() else: ctx.clientCapabilities)})}]})

proc post(url: string, headers: openArray[(string, string)] = []): (HttpCode, HttpHeaders, string) =
  let http = newAsyncHttpClient()
  defer: http.close()
  let response = waitFor http.request(url, HttpPost,
    """{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}""", newHttpHeaders(headers))
  (response.code, response.headers, waitFor response.body)

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-auth-resource-g0f-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

func bearerHeader(lines: seq[string]): string =
  for line in lines:
    if line.toLowerAscii().startsWith("bearer"):
      return line

func parameter(line, name: string): Option[string] =
  ## The quoted value of `name="..."` in a Bearer challenge line.
  let key = name & "=\""
  let at = line.find(key)
  if at < 0:
    return none(string)
  let start = at + key.len
  let stop = line.find('"', start)
  some(line[start ..< stop])

suite "A token the resource server receives, and no more of it":
  for v in authVersions:
    test "Given tokens that are good, rejected, short of scope and one that makes the verifier fail, and version " & $v &
         ", when each is posted, then no answer and nothing on stderr repeats the token":
      let env = startServer(v, plainServer(v))
      var replies: seq[(HttpCode, HttpHeaders, string)]
      let tokens = [Secret, "bogus-" & Secret, "narrow-" & Secret, "explode"]
      let logged = loggedWhile(proc() =
        for token in tokens:
          replies.add post(env.url, {"Authorization": "Bearer " & token}))
      check replies[0][0] notin {Http401, Http403, Http500}
      check replies[1][0] == Http401
      check replies[2][0] == Http403
      check replies[3][0] == Http500
      for i, token in tokens:
        check token notin replies[i][2]
        check token notin $replies[i][1]
        check token notin logged

suite "What a handler is told about the token":
  for v in authVersions:
    test "Given a token the verifier accepts for a subject and version " & $v &
         ", when a handler runs, then it is told the subject and nothing it can read holds the token":
      let env = startServer(v, plainServer(v))
      let transport = newStreamableHttpTransport(env.url)
      transport.auth = HttpClientAuth(
        authorization: proc(): Future[Option[string]] {.closure, gcsafe, async.} =
          return some("Bearer " & Secret),
        onChallenge: proc(status: int, wwwAuthenticate: seq[string]): Future[bool]
                         {.closure, gcsafe, async.} =
          return false)
      let client = newMcpClient(McpClientInfo(name: "ExampleClient", version: "1.0.0"))
      waitFor client.connect(transport)
      let response = waitFor client.sendRequest("tools/call", %*{"name": "who", "arguments": {}})
      check response.error.isNone
      let seen = parseJson(response.result.get["content"][0]["text"].getStr())
      check seen["principal"].getStr() == "alice"
      check Secret notin $seen
      check Secret notin $response.result.get
      waitFor client.close()

suite "The challenge of a token that lacks scope":
  for v in authVersions:
    test "Given a token that lacks scope and version " & $v &
         ", when posted, then the 403 challenge names the same resource metadata as the 401 one, where the version has it":
      let env = startServer(v, plainServer(v))
      let unauthorized = post(env.url)
      let forbidden = post(env.url, {"Authorization": "Bearer narrow-" & Secret})
      check unauthorized[0] == Http401
      check forbidden[0] == Http403
      let first = bearerHeader(seq[string](unauthorized[1].getOrDefault("WWW-Authenticate"))).parameter("resource_metadata")
      let second = bearerHeader(seq[string](forbidden[1].getOrDefault("WWW-Authenticate"))).parameter("resource_metadata")
      check first.isSome == v.has(ftProtectedResourceMetadata)
      check second == first
      if v.has(ftProtectedResourceMetadata):
        check second.get == env.origin & "/.well-known/oauth-protected-resource/mcp"
