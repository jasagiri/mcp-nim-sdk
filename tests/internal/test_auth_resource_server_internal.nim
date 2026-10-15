## The resource-server side of MCP authorization: this SDK's
## HttpServerTransport with a token verifier, checked with a plain HTTP
## client, and then end to end with this SDK's client and an authorization
## server. Every version the build speaks is run with its own rules
## (docs/quality/auth-requirements.md).

import std/[unittest, asyncdispatch, httpclient, httpcore, json, options,
            strutils, tables, nativesockets, os]
import transport/http_server
import server/server
import protocol/types
import protocol/version
import protocol/features
import auth/resource_server
import bearer_challenge
import ../external/auth_fixtures

const authVersions = block:
  var vs: seq[McpProtocolVersion]
  for v in SupportedProtocolVersions:
    if v.has(ftAuthorization):
      vs.add v
  vs

type
  Seen = ref object
    ## What the verifier was asked.
    calls: seq[(string, string)]

  Env = object
    transport: HttpServerTransport
    url: string
    origin: string
    seen: Seen
    config: ResourceServerConfig

proc toolsServer(version: McpProtocolVersion): McpServer =
  result = newMcpServer(McpServerInfo(name: "ExampleServer", version: "1.0.0"),
    protocolVersion = version,
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      return @[%*{"name": "get_weather", "inputSchema": {"type": "object"}}]
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      return %*{"content": [{"type": "text", "text": name}], "isError": false}
  result.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))

proc verifierFor(seen: Seen, verdicts: TableRef[string, TokenVerdict]): TokenVerifier =
  result = proc(token, resource: string): Future[TokenVerdict] {.async.} =
    seen.calls.add (token, resource)
    if token in verdicts:
      return verdicts[token]
    return TokenVerdict(kind: tvInvalid)

proc startServer(v: McpProtocolVersion, verdicts: TableRef[string, TokenVerdict],
                 authServers = @["https://auth.example.com"],
                 challengeScopes: seq[string] = @[]): Env =
  let transport = newHttpServerTransport(port = 0, protocolVersion = v)
  transport.listen()
  asyncCheck transport.serve()
  waitFor toolsServer(v).attachTransport(transport)
  result.transport = transport
  result.origin = "http://127.0.0.1:" & $transport.port
  result.url = result.origin & "/mcp"
  result.seen = Seen()
  result.config = ResourceServerConfig(
    resource: result.url, authorizationServers: authServers,
    scopesSupported: @["files:read", "files:write"], challengeScopes: challengeScopes,
    verify: verifierFor(result.seen, verdicts), version: v)
  transport.auth = newResourceServerAuth(result.config)

proc issuedByVerifier(authServer: FakeAs, seen: Seen, v: McpProtocolVersion): TokenVerifier =
  ## Accepts what the authorization server issued, and, from the version
  ## that has the resource parameter, only for this resource (the audience).
  result = proc(token, resource: string): Future[TokenVerdict] {.async.} =
    seen.calls.add (token, resource)
    if token notin authServer.accessTokens:
      return TokenVerdict(kind: tvInvalid)
    if v.has(ftResourceIndicators) and authServer.accessTokens[token].resource != resource:
      return TokenVerdict(kind: tvInvalid)
    return TokenVerdict(kind: tvValid)

type Reply = tuple[code: HttpCode, headers: HttpHeaders, body: string]

proc send(url: string, httpMethod: HttpMethod, body = "",
          headers: openArray[(string, string)] = []): Reply =
  let http = newAsyncHttpClient()
  defer: http.close()
  let response = waitFor http.request(url, httpMethod, body, newHttpHeaders(headers))
  (response.code, response.headers, waitFor response.body)

proc wwwAuthenticate(reply: Reply): seq[string] =
  seq[string](reply.headers.getOrDefault("WWW-Authenticate"))

type BearerParams = object
  ## The `Bearer` challenge as the header line spells it: `name="value"`
  ## pairs after the scheme, read here without the SDK's own parser.
  scope, error, resourceMetadata: Option[string]

proc bearerParam(line, name: string): Option[string] =
  for lead in [" ", ", "]:
    let key = lead & name & "=\""
    let at = line.find(key)
    if at < 0: continue
    var i = at + key.len
    var value = ""
    while i < line.len and line[i] != '"':
      if line[i] == '\\' and i + 1 < line.len: inc i
      value.add line[i]
      inc i
    return some(value)
  none(string)

proc bearerOf(lines: seq[string]): Option[BearerParams] =
  for line in lines:
    if line.toLowerAscii().startsWith("bearer"):
      return some(BearerParams(scope: bearerParam(line, "scope"),
                               error: bearerParam(line, "error"),
                               resourceMetadata: bearerParam(line, "resource_metadata")))
  none(BearerParams)

proc validVerdicts(): TableRef[string, TokenVerdict] =
  result = newTable[string, TokenVerdict]()
  result["good"] = TokenVerdict(kind: tvValid)
  result["narrow"] = TokenVerdict(kind: tvInsufficientScope,
                                  requiredScopes: @["files:write", "files:read"])

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-auth-resource-server-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

const initializeBody = """{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}"""

suite "Resource server, every version of the build":
  for v in authVersions:


    test "Given a request without a token and version " & $v & ", when posted, then the challenge names no error: there was no credential to fault":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url, HttpPost, initializeBody)
      let bearer = bearerChallenge(reply.wwwAuthenticate).get
      check bearer.error.isNone
      check bearer.errorDescription.isNone
      check "error" notin reply.wwwAuthenticate[0]

    test "Given a token the verifier rejects and version " & $v & ", when posted, then the challenge explains the refusal":
      let env = startServer(v, validVerdicts())
      let reply = send(env.url, HttpPost, initializeBody, {"Authorization": "Bearer bogus"})
      let bearer = bearerChallenge(reply.wwwAuthenticate).get
      check bearer.errorDescription.isSome
      check bearer.errorDescription.get.len > 0


suite "The challenge a resource server writes, seen through the public entries":
  # RFC 9110 5.6.4: in a quoted string a quote and a backslash are written
  # as a backslash and the character; RFC 9110 5.5: a field value holds no
  # line break.
  let quoted = "scope=\"a\\\"b c\\\\d\""   # scope="a\"b c\\d"

