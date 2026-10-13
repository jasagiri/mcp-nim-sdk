## The pieces of OAuth that need no network: PKCE, WWW-Authenticate,
## well-known URLs, URL policy, and metadata validation. Expected values are
## taken from RFC 7636 (appendix B), RFC 8414 (3.1), RFC 9728 (3.1, 5.1) and
## the MCP authorization specification.

import std/sequtils
import std/[unittest, json, options, strutils, asyncdispatch, asyncnet, asynchttpserver, httpcore, net,
            nativesockets, times, uri]
import protocol/version
import protocol/features
import auth/client
import auth/resource_server
import auth/oauth/[pkce, challenge, urls, metadata, discovery, errors, fetch, jsonfield, authcode, registration]
import ../external/auth_fixtures

type
  ScriptedServer = ref object
    ## A listener on 127.0.0.1 that reads one request head per connection,
    ## answers it with what `answer` makes of the request line, and closes.
    listener: AsyncSocket
    port: int
    origin: string
    requestLines: seq[string]
    closed: bool

  HoldingServer = ref object
    ## Reads one request head, sends `answer` (nothing when empty) and then
    ## waits for the client to close the connection.
    listener: AsyncSocket
    port: int
    peerClosed: bool

  Outcome = object
    kind: string  ## "none", "security", "server" (an OAuth error response) or "oauth"
    msg: string

proc requestHead(client: AsyncSocket): Future[string] {.async.} =
  while not result.endsWith("\c\L\c\L"):
    let chunk = await client.recv(1)
    if chunk.len == 0:
      break
    result.add chunk

proc jsonReply(code: int, reason, body: string, extra = ""): string =
  "HTTP/1.1 " & $code & " " & reason & "\c\LContent-Type: application/json\c\LContent-Length: " &
    $body.len & "\c\LConnection: close\c\L" & extra & "\c\L" & body

proc startScripted(answer: proc(origin, requestLine: string): string): ScriptedServer =
  let server = ScriptedServer(listener: newAsyncSocket(buffered = false))
  server.listener.setSockOpt(OptReuseAddr, true)
  server.listener.bindAddr(Port(0), "127.0.0.1")
  server.listener.listen()
  server.port = server.listener.getLocalAddr()[1].int
  server.origin = "http://127.0.0.1:" & $server.port
  proc serveOne(client: AsyncSocket) {.async.} =
    let line = (await requestHead(client)).splitLines()[0]
    server.requestLines.add line
    await client.send(answer(server.origin, line))
    client.close()
  proc acceptLoop() {.async.} =
    while not server.closed:
      let client =
        try:
          await server.listener.accept()
        except CatchableError:
          if server.closed:
            return
          raise
      asyncCheck serveOne(client)
  asyncCheck acceptLoop()
  server

proc stop(server: ScriptedServer) =
  server.closed = true
  server.listener.close()

proc startHolding(answer: string): HoldingServer =
  let server = HoldingServer(listener: newAsyncSocket(buffered = false))
  server.listener.setSockOpt(OptReuseAddr, true)
  server.listener.bindAddr(Port(0), "127.0.0.1")
  server.listener.listen()
  server.port = server.listener.getLocalAddr()[1].int
  proc serveOne() {.async.} =
    let client = await server.listener.accept()
    discard await requestHead(client)
    if answer.len > 0:
      await client.send(answer)
    try:
      # recv answers "" when the peer closed the connection.
      let rest = await client.recv(1)
      server.peerClosed = rest.len == 0
    except OSError:
      # a connection that is reset is a connection the peer is done with
      server.peerClosed = true
    client.close()
  asyncCheck serveOne()
  server

proc closedWithin(server: HoldingServer, ms: int): bool =
  var waited = 0
  while not server.peerClosed and waited < ms:
    waitFor sleepAsync(20)
    waited += 20
  server.peerClosed

proc plain(msg: string): string =
  ## A message of an exception that went through an async proc carries the
  ## async traceback after its own text.
  msg.split("\nAsync traceback:")[0]

proc outcomeOf[T](action: Future[T]): Outcome =
  try:
    discard waitFor action
  except OAuthSecurityError as e:
    return Outcome(kind: "security", msg: e.msg)
  except OAuthError as e:
    return Outcome(kind: "oauth", msg: e.msg)
  Outcome(kind: "none")

proc reportedBy[T](action: Future[T]): Outcome =
  ## Like `outcomeOf`, for what went through `OAuthClient`: an OAuth error
  ## response is its own kind, and the message has no async traceback.
  try:
    discard waitFor action
  except OAuthSecurityError as e:
    return Outcome(kind: "security", msg: plain(e.msg))
  except OAuthServerError as e:
    return Outcome(kind: "server", msg: plain(e.msg))
  except OAuthError as e:
    return Outcome(kind: "oauth", msg: plain(e.msg))
  Outcome(kind: "none")

proc resolvingTo(name, address: string): typeof(defaultFetchPolicy().resolver) =
  let parsed = parseIpAddress(address)
  result = proc(host: string): seq[IpAddress] {.closure, gcsafe, raises: [CatchableError].} =
    if host == name:
      return @[parsed]
    raise newException(OSError, "cannot resolve " & host)

proc everyHostIsLoopback(): typeof(defaultFetchPolicy().resolver) =
  ## A name resolves to the loopback address, so that a request a test expects
  ## to be refused can reach nothing but this machine if it is not.
  result = proc(host: string): seq[IpAddress] {.closure, gcsafe, raises: [CatchableError].} =
    @[parseIpAddress("127.0.0.1")]

proc asDocument(origin, issuer: string): string =
  $(%*{"issuer": issuer, "authorization_endpoint": origin & "/authorize",
       "token_endpoint": origin & "/token"})

proc prmDocument(origin, resource: string): string =
  $(%*{"resource": resource, "authorization_servers": [origin]})

proc prmNaming(origin, issuer: string): string =
  ## The protected resource metadata of `origin`/mcp that lists `issuer`.
  $(%*{"resource": origin & "/mcp", "authorization_servers": [issuer]})

proc stateOf(authorizationUrl: string): string =
  for (name, value) in decodeQuery(parseUri(authorizationUrl).query):
    if name == "state":
      return value

proc newRequest(redirectUri = "http://127.0.0.1:8080/cb"): AuthorizationRequest =
  newAuthorizationRequest("https://auth.example.com/authorize", "client", redirectUri,
    @[], none(string), "https://auth.example.com", false, false)

proc registeredWith(status: HttpCode, body: string): ClientCredentials =
  ## Runs a registration against a registration endpoint that answers `body`.
  let server = newAsyncHttpServer()
  server.listen(Port(0), "127.0.0.1")
  defer: server.close()
  proc handler(req: Request) {.async, gcsafe.} =
    await req.respond(status, body, newHttpHeaders({"Content-Type": "application/json"}))
  asyncCheck server.acceptRequest(handler)
  waitFor registerClient("http://127.0.0.1:" & $server.getPort.int & "/register",
    "https://auth.example.com",
    ClientRegistrationRequest(clientName: "t", redirectUris: @["http://127.0.0.1:1/cb"]),
    defaultFetchPolicy())

# The public door: an OAuthClient and the challenge the server answered with.

proc idleAuthorizer(): UserAuthorizer =
  result = proc(url: string): Future[seq[(string, string)]] {.async.} =
    doAssert false, "the user was sent to " & url

proc configOf(serverUrl: string, authorize: UserAuthorizer = idleAuthorizer(),
              version = DefaultProtocolVersion, fetchPolicy = defaultFetchPolicy()): OAuthClientConfig =
  result = newOAuthClientConfig(serverUrl, "http://127.0.0.1:8080/cb", authorize, version)
  result.fetchPolicy = fetchPolicy

proc clientOf(serverUrl: string, authorize: UserAuthorizer = idleAuthorizer(),
              version = DefaultProtocolVersion, fetchPolicy = defaultFetchPolicy()): OAuthClient =
  newOAuthClient(configOf(serverUrl, authorize, version, fetchPolicy))

proc loopbackOnlyClient(): OAuthClient =
  var policy = defaultFetchPolicy()
  policy.resolver = everyHostIsLoopback()
  clientOf("http://127.0.0.1:1/mcp", fetchPolicy = policy)

proc challengedWith(client: OAuthClient, metadataUrl: string): Future[bool] =
  ## A 401 whose challenge names `metadataUrl` as the resource metadata.
  client.handleChallenge(401, @["Bearer resource_metadata=\"" & metadataUrl & "\""])

proc unchallenged(client: OAuthClient): Future[bool] =
  client.handleChallenge(401, newSeq[string]())

proc answering(authServer: FakeAs, code: HttpCode, body: string) =
  ## What the authorization server answers on paths it has no behaviour for
  ## (point a metadata field at one).
  authServer.fallback = proc(req: Request): Future[void] {.closure, gcsafe.} =
    req.respond(code, body, newHttpHeaders({"Content-Type": "application/json"}))

proc pointAt(authServer: FakeAs, field, path: string) =
  authServer.metadata[field] = %("http://127.0.0.1:" & $authServer.port & path)

# The public door of the resource server.

proc acceptAll(token, resource: string): Future[TokenVerdict] {.async.} =
  return TokenVerdict(kind: tvValid)

proc serverConfig(resource: string, challengeScopes: seq[string] = @[]): ResourceServerConfig =
  ResourceServerConfig(resource: resource, authorizationServers: @["https://auth.example.com"],
                       challengeScopes: challengeScopes, verify: acceptAll,
                       version: DefaultProtocolVersion)

suite "PKCE":
  test "Given the RFC 7636 appendix B verifier, when challenged with S256, then it is the appendix B challenge":
    check codeChallengeS256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  test "Given a new verifier, when checked, then it is 43 unreserved characters and differs each time":
    let a = newCodeVerifier()
    let b = newCodeVerifier()
    check a.len == 43
    check isValidCodeVerifier(a)
    check a != b

  test "Given too short or reserved characters, when checked, then the verifier is invalid":
    check not isValidCodeVerifier("short")
    check not isValidCodeVerifier("a".repeat(42))
    check not isValidCodeVerifier("a".repeat(42) & "+")
    check not isValidCodeVerifier("a".repeat(129))
    check isValidCodeVerifier("a".repeat(128))

suite "WWW-Authenticate":
  test "Given the MCP 401 example, when parsed, then resource_metadata and scope are found":
    let header = "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\",\n" &
                 "                         scope=\"files:read\""
    let c = bearerChallenge([header]).get
    check c.resourceMetadata.get == "https://mcp.example.com/.well-known/oauth-protected-resource"
    check c.scope.get == "files:read"

  test "Given the MCP insufficient_scope example, when parsed, then every parameter is found":
    let header = "Bearer error=\"insufficient_scope\", scope=\"files:read files:write user:profile\", " &
                 "resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\", " &
                 "error_description=\"Additional file write permission required\""
    let c = bearerChallenge([header]).get
    check c.error.get == "insufficient_scope"
    check c.scope.get == "files:read files:write user:profile"
    check c.errorDescription.get == "Additional file write permission required"

  test "Given several challenges in one header, when parsed, then the Bearer one is selected":
    let c = bearerChallenge(["Basic realm=\"x\", Bearer realm=\"mcp\", error=\"invalid_token\""]).get
    check c.realm.get == "mcp"
    check c.error.get == "invalid_token"

  test "Given a quoted string with an escaped quote and a comma, when parsed, then it is unescaped whole":
    let c = bearerChallenge(["Bearer error_description=\"say \\\"hi\\\", please\", scope=\"a\""]).get
    check c.errorDescription.get == "say \"hi\", please"
    check c.scope.get == "a"

  test "Given an unquoted token value and mixed case, when parsed, then names are case-insensitive":
    let c = bearerChallenge(["bearer Scope=read"]).get
    check c.scope.get == "read"

  test "Given only a Basic challenge or nothing, when parsed, then there is no Bearer challenge":
    check bearerChallenge(["Basic realm=\"x\""]).isNone
    check bearerChallenge(newSeq[string]()).isNone
    check bearerChallenge([""]).isNone

  test "Given garbage, when parsed, then parsing terminates":
    discard parseChallenges("=,=,\"\"\"==")
    discard parseChallenges("Bearer a=\"unterminated")

  test "Given parameters, when formatted, then quotes and backslashes are escaped":
    check formatBearerChallenge({"error": "invalid_token", "error_description": "a \"b\" \\"}) ==
      "Bearer error=\"invalid_token\", error_description=\"a \\\"b\\\" \\\\\""

  test "Given a newline in a value, when formatted, then it is refused":
    expect ValueError:
      discard formatBearerChallenge({"error_description": "x\r\nSet-Cookie: a=b"})

suite "Well-known URLs":
  test "Given an issuer with a path, when building RFC 8414 URLs, then the suffix is inserted before the path":
    check wellKnownUrl("https://auth.example.com/tenant1", "oauth-authorization-server") ==
      "https://auth.example.com/.well-known/oauth-authorization-server/tenant1"

  test "Given a trailing slash, when building the URL, then it is removed first (RFC 8414 3.1)":
    check wellKnownUrl("https://auth.example.com/issuer1/", "oauth-authorization-server") ==
      "https://auth.example.com/.well-known/oauth-authorization-server/issuer1"
    check wellKnownUrl("https://auth.example.com/", "oauth-authorization-server") ==
      "https://auth.example.com/.well-known/oauth-authorization-server"

  test "Given the MCP 2025-11-25 example issuer with a path, when listing candidates, then the order is the specified one":
    check authorizationServerMetadataUrls("https://auth.example.com/tenant1", adsOAuthThenOidc) == @[
      "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
      "https://auth.example.com/.well-known/openid-configuration/tenant1",
      "https://auth.example.com/tenant1/.well-known/openid-configuration"]

  test "Given an issuer without a path, when listing candidates, then there are two":
    check authorizationServerMetadataUrls("https://auth.example.com", adsOAuthThenOidc) == @[
      "https://auth.example.com/.well-known/oauth-authorization-server",
      "https://auth.example.com/.well-known/openid-configuration"]

  test "Given the 2025-06-18 style, when listing candidates, then OpenID Connect is not tried":
    check authorizationServerMetadataUrls("https://auth.example.com/tenant1", adsOAuthOnly) == @[
      "https://auth.example.com/.well-known/oauth-authorization-server/tenant1"]

  test "Given the MCP example server path, when listing PRM URLs, then path-specific comes before root":
    check protectedResourceMetadataUrls("https://example.com/public/mcp") == @[
      "https://example.com/.well-known/oauth-protected-resource/public/mcp",
      "https://example.com/.well-known/oauth-protected-resource"]

  test "Given a server at the root, when listing PRM URLs, then only the root is probed":
    check protectedResourceMetadataUrls("https://example.com") ==
      @["https://example.com/.well-known/oauth-protected-resource"]
    check protectedResourceMetadataUrls("https://example.com/") ==
      @["https://example.com/.well-known/oauth-protected-resource"]

suite "Canonical resource":
  test "Given the valid examples of the specification, when canonicalized, then they are unchanged":
    for url in ["https://mcp.example.com/mcp", "https://mcp.example.com",
                "https://mcp.example.com:8443", "https://mcp.example.com/server/mcp"]:
      check canonicalResource(url) == url

  test "Given uppercase scheme and host and a bare trailing slash, when canonicalized, then they are lowercased and the slash dropped":
    check canonicalResource("HTTPS://MCP.Example.COM/") == "https://mcp.example.com"


  test "Given the resource, when form-encoded as the specification shows, then it matches &resource=https%3A%2F%2Fmcp.example.com":
    check formEncode({"resource": "https://mcp.example.com"}) ==
      "resource=https%3A%2F%2Fmcp.example.com"

suite "Fetch policy":
  let policy = defaultFetchPolicy()

  test "Given https to a public name, when checked, then it passes":
    checkFetchUrl("https://auth.example.com/x", policy, "t")


  test "Given plain http to loopback hosts, when checked, then it passes":
    for url in ["http://localhost:1/x", "http://127.0.0.1:8080/x", "http://[::1]:8080/x"]:
      checkFetchUrl(url, policy, "t")


  test "Given the cloud metadata address, when checked, then it is always refused":
    var open = policy
    open.allowPrivateNetworks = true
    expect OAuthSecurityError: checkFetchUrl("https://169.254.169.254/latest", policy, "t")
    expect OAuthSecurityError: checkFetchUrl("https://169.254.169.254/latest", open, "t")
    expect OAuthSecurityError: checkFetchUrl("https://[fe80::1]/x", open, "t")

  test "Given private ranges, when checked, then they are refused unless allowed":
    for url in ["https://10.0.0.5/x", "https://172.16.0.1/x", "https://172.31.255.255/x",
                "https://192.168.1.1/x", "https://[fd00::1]/x", "https://[::ffff:10.0.0.1]/x"]:
      expect OAuthSecurityError: checkFetchUrl(url, policy, "t")
    var open = policy
    open.allowPrivateNetworks = true
    checkFetchUrl("https://10.0.0.5/x", open, "t")
    # 172.32 is outside 172.16/12
    checkFetchUrl("https://172.32.0.1/x", policy, "t")


const goodAs = """{"issuer": "https://auth.example.com/tenant1",
  "authorization_endpoint": "https://auth.example.com/authorize",
  "token_endpoint": "https://auth.example.com/token",
  "registration_endpoint": "https://auth.example.com/register",
  "code_challenge_methods_supported": ["S256"],
  "client_id_metadata_document_supported": true,
  "authorization_response_iss_parameter_supported": true}"""

suite "Metadata validation":
  let policy = defaultFetchPolicy()

  test "Given a document naming the issuer it was fetched for, when parsed, then the fields are read":
    let m = parseAuthorizationServerMetadata(parseJson(goodAs), "https://auth.example.com/tenant1", policy)
    check m.tokenEndpoint == "https://auth.example.com/token"
    check m.registrationEndpoint.get == "https://auth.example.com/register"
    check m.codeChallengeMethodsSupported.get == @["S256"]
    check m.clientIdMetadataDocumentSupported
    check m.authorizationResponseIssParameterSupported

  test "Given the specification's example of an attacker serving another issuer, when parsed, then it is rejected":
    let doc = parseJson("""{"issuer": "https://honest.example",
      "authorization_endpoint": "https://attacker.example/authorize",
      "token_endpoint": "https://attacker.example/token"}""")
    expect OAuthSecurityError:
      discard parseAuthorizationServerMetadata(doc, "https://attacker.example", policy)

  test "Given an issuer differing only in a trailing slash, when parsed, then it is rejected":
    expect OAuthSecurityError:
      discard parseAuthorizationServerMetadata(parseJson(goodAs), "https://auth.example.com/tenant1/", policy)

  test "Given a plain http token endpoint on a remote host, when parsed, then it is rejected":
    let doc = parseJson(goodAs)
    doc["token_endpoint"] = %"http://auth.example.com/token"
    expect OAuthSecurityError:
      discard parseAuthorizationServerMetadata(doc, "https://auth.example.com/tenant1", policy)

  test "Given wrong types and missing fields, when parsed, then OAuthError names the field":
    for (key, value) in [("token_endpoint", newJInt(1)), ("code_challenge_methods_supported", %"S256"),
                         ("client_id_metadata_document_supported", %"yes"),
                         ("authorization_endpoint", newJNull())]:
      let doc = parseJson(goodAs)
      doc[key] = value
      expect OAuthError:
        discard parseAuthorizationServerMetadata(doc, "https://auth.example.com/tenant1", policy)
    expect OAuthError:
      discard parseAuthorizationServerMetadata(parseJson("[]"), "https://a", policy)

  test "Given no code_challenge_methods_supported, when parsed, then the field is absent rather than empty":
    let doc = parseJson(goodAs)
    doc.delete("code_challenge_methods_supported")
    let m = parseAuthorizationServerMetadata(doc, "https://auth.example.com/tenant1", policy)
    check m.codeChallengeMethodsSupported.isNone

  test "Given PRM for another resource, when parsed, then it is rejected (RFC 9728 3.3)":
    let doc = parseJson("""{"resource": "https://other.example/mcp",
      "authorization_servers": ["https://auth.example.com"]}""")
    expect OAuthSecurityError:
      discard parseProtectedResourceMetadata(doc, "https://mcp.example.com/mcp", policy)

  test "Given PRM whose resource differs only by case of host and a bare slash, when parsed, then it is accepted":
    let doc = parseJson("""{"resource": "https://MCP.example.com/",
      "authorization_servers": ["https://auth.example.com"], "scopes_supported": ["a", "b"]}""")
    let m = parseProtectedResourceMetadata(doc, "https://mcp.example.com", policy)
    check m.authorizationServers == @["https://auth.example.com"]
    check m.scopesSupported == @["a", "b"]

  test "Given PRM without authorization servers or with an insecure one, when parsed, then it is rejected":
    expect OAuthError:
      discard parseProtectedResourceMetadata(
        parseJson("""{"resource": "https://m.example", "authorization_servers": []}"""),
        "https://m.example", policy)
    expect OAuthError:
      discard parseProtectedResourceMetadata(
        parseJson("""{"resource": "https://m.example"}"""), "https://m.example", policy)
    expect OAuthSecurityError:
      discard parseProtectedResourceMetadata(
        parseJson("""{"resource": "https://m.example", "authorization_servers": ["http://a.example"]}"""),
        "https://m.example", policy)

  test "Given the 2025-03-26 defaults, when built for a server URL with a path, then they are on the origin":
    let m = defaultEndpointMetadata("https://api.example.com/v1/mcp")
    check m.authorizationEndpoint == "https://api.example.com/authorize"
    check m.tokenEndpoint == "https://api.example.com/token"
    check m.registrationEndpoint.get == "https://api.example.com/register"

suite "WWW-Authenticate edges (mutation review, g2f-oauth-a)":
  test "Given a Basic challenge with token68 padding before a Bearer one, when parsed, then the Bearer parameters are found":
    # RFC 9110 11.2: token68 may end in any number of "=".
    let header = "Basic YWJj==, Bearer resource_metadata=\"https://mcp.example.com/prm\", scope=\"read\""
    let challenges = parseChallenges(header)
    check challenges.len == 2
    check challenges[0].scheme == "Basic"
    check challenges[0].params.len == 0
    let bearer = bearerChallenge([header]).get
    check bearer.resourceMetadata == some("https://mcp.example.com/prm")
    check bearer.scope == some("read")

  test "Given a token68 whose padding ends the header, when parsed, then parsing ends with the challenge":
    let challenges = parseChallenges("Basic YWJj==")
    check challenges.len == 1
    check challenges[0].scheme == "Basic"
    check challenges[0].params.len == 0

  test "Given white space around the equals sign, when parsed, then the values are the same as without it (RFC 9110 11.2 BWS)":
    let bearer = bearerChallenge(["Bearer realm = \"a b\" , scope =  read"]).get
    check bearer.realm == some("a b")
    check bearer.scope == some("read")

  test "Given a parameter that ends the header, when parsed, then its value is empty":
    check bearerChallenge(["Bearer realm="]).get.realm == some("")
    check bearerChallenge(["Bearer realm=  "]).get.realm == some("")

  test "Given a quoted string that is cut off after a backslash, when parsed, then the backslash is kept":
    check bearerChallenge(["Bearer realm=\"a\\"]).get.realm == some("a\\")

  test "Given a header that starts with a parameter and no scheme, when parsed, then no challenge carries it":
    for c in parseChallenges("realm=\"x\""):
      check c.params.len == 0
    check bearerChallenge(["realm=\"x\", Bearer scope=\"s\""]).get.scope == some("s")

suite "Candidate URLs of an issuer with a trailing slash (mutation review, g2f-oauth-a)":
  test "Given an issuer path that ends in a slash, when listing candidates, then the slash is dropped from every URL":
    check authorizationServerMetadataUrls("https://auth.example.com/tenant1/", adsOAuthThenOidc) == @[
      "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
      "https://auth.example.com/.well-known/openid-configuration/tenant1",
      "https://auth.example.com/tenant1/.well-known/openid-configuration"]

suite "URL rules (mutation review, g2f-oauth-a)":


  test "Given a resource with a query, when canonicalized, then the query is kept (RFC 8707 2)":
    check canonicalResource("HTTPS://MCP.example.com/api?tenant=a%20b") ==
      "https://mcp.example.com/api?tenant=a%20b"

  test "Given a field with a space, when form-encoded, then the space is %20":
    check formEncode([("scope", "read write")]) == "scope=read%20write"

suite "Authorization server discovery over a scripted server (mutation review, g2f-oauth-a)":
  let policy = defaultFetchPolicy()
  const
    oauthPath = "/.well-known/oauth-authorization-server/tenant1"
    oidcPath = "/.well-known/openid-configuration/tenant1"
    appendedPath = "/tenant1/.well-known/openid-configuration"


  test "Given an issuer with a fragment, when discovering, then it is refused before any request is made":
    let server = startScripted(proc(origin, line: string): string = jsonReply(404, "Not Found", "{}"))
    defer: server.stop()
    let outcome = outcomeOf(discoverAuthorizationServer(server.origin & "/tenant1#frag", adsOAuthThenOidc, policy))
    check outcome.kind == "security"
    check "authorization server issuer has a fragment" in outcome.msg
    check server.requestLines.len == 0


suite "Requests of the OAuth client over a scripted server (mutation review, g2f-oauth-a)":
  let policy = defaultFetchPolicy()


  test "Given an endpoint that answers 304 to a conditional request, when requested, then the 304 is the reply":
    let server = startScripted(proc(origin, line: string): string =
      "HTTP/1.1 304 Not Modified\c\LConnection: close\c\L\c\L")
    defer: server.stop()
    let reply = waitFor httpExchange(HttpGet, server.origin & "/x", policy, "metadata",
                                     headers = @[("If-None-Match", "\"v1\"")])
    check reply.code == 304


  test "Given a keep-alive answer without a body, when the request is done, then the client has closed the connection":
    # A body that ends the connection closes it by itself; one that has no
    # body leaves it to the caller of the wire.
    for answer in ["HTTP/1.1 204 No Content\c\L\c\L",
                   "HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L"]:
      let server = startHolding(answer)
      let reply = waitFor httpExchange(HttpGet, "http://127.0.0.1:" & $server.port & "/x", policy, "metadata")
      check reply.body == ""
      check server.closedWithin(2000)


suite "OAuth parsers and checks (mutation review, g2f-oauth-b)":
  let policy = defaultFetchPolicy()


  test "Given a registration endpoint that is missing or null, when parsed, then the server offers no registration":
    let missing = parseJson(goodAs)
    missing.delete("registration_endpoint")
    check parseAuthorizationServerMetadata(missing, "https://auth.example.com/tenant1", policy)
      .registrationEndpoint.isNone
    let null = parseJson(goodAs)
    null["registration_endpoint"] = newJNull()
    check parseAuthorizationServerMetadata(null, "https://auth.example.com/tenant1", policy)
      .registrationEndpoint.isNone

  test "Given JSON that is absent, not an object, or has the key of another type, when a string is read, then there is none":
    check strField(nil, "a").isNone
    check strField(%*[1, 2], "a").isNone
    check strField(%*{"a": 1}, "a").isNone
    check strField(%*{"a": nil}, "a").isNone
    check strField(%*{"b": "x"}, "a").isNone
    check strField(%*{"a": "x"}, "a") == some("x")


  test "Given a plain http redirect URI to a remote host, when an authorization request is made, then no request is made":
    expect OAuthSecurityError:
      discard newRequest("http://app.example/cb")

  test "Given a response whose state has the length of the request's but differs, when the code is read, then it is refused":
    let request = newRequest()
    let state = stateOf(request.authorizationUrl)
    check state.len > 0
    var forged = state
    forged[0] = if state[0] == 'A': 'B' else: 'A'
    expect OAuthSecurityError:
      discard request.authorizationCode({"state": forged, "code": "c"})
    check request.authorizationCode({"state": state, "code": "c"}) == "c"

  test "Given a response with a matching state but no code or an empty one, when the code is read, then it is refused":
    let request = newRequest()
    let state = stateOf(request.authorizationUrl)
    expect OAuthError:
      discard request.authorizationCode({"state": state})
    expect OAuthError:
      discard request.authorizationCode({"state": state, "code": ""})

  test "Given a token response without an access token or with an empty one, when parsed, then it is refused":
    for body in ["""{"token_type": "Bearer"}""", """{"access_token": "", "token_type": "Bearer"}""",
                 """{"access_token": 7, "token_type": "Bearer"}"""]:
      checkpoint body
      expect OAuthError:
        discard parseTokenResponse(HttpReply(code: 200, body: body), "https://as.example", @[],
          none(string), fromUnix(1_800_000_000))


  test "Given a registration response with a client_id, when read, then the client is known by it":
    let credentials = registeredWith(Http201, """{"client_id": "abc"}""")
    check credentials.clientId == "abc"
    check credentials.authMethod == "none"

# The Bearer challenge and the authorization response, seen through the
# public entries: what the client reads from a challenge is what it goes to
# fetch (a resolver that names every host it is asked about and answers a
# link-local address, so that nothing is ever connected to) and what the
# user's authorization URL carries.

type ChallengeProbe = object
  hosts: seq[string]   ## every host name the client asked the resolver about
  outcome: Outcome

const
  ProbedVersion = block:
    ## The newest version of the build that reads the metadata URL of a
    ## challenge; none where the build speaks no such version.
    var found = none(McpProtocolVersion)
    for v in SupportedProtocolVersions:
      if v.has(ftProtectedResourceMetadata):
        found = some(v)
    found
  HasProbedVersion = ProbedVersion.isSome
  ProbedServer = "https://mcp.example.test/mcp"
  ProbedServerHost = "mcp.example.test"
  Named = "https://named.example.test/.well-known/oauth-protected-resource"

proc probed(headers: seq[string]): ChallengeProbe =
  ## The client of a remote server answers a 401 that carries `headers`.
  let seen = new(seq[string])
  var policy = defaultFetchPolicy()
  policy.resolver = proc(host: string): seq[IpAddress] {.closure, gcsafe, raises: [CatchableError].} =
    seen[].add host
    @[parseIpAddress("169.254.0.1")]
  let client = clientOf(ProbedServer, version = ProbedVersion.get, fetchPolicy = policy)
  let outcome = reportedBy(client.handleChallenge(401, headers))
  ChallengeProbe(hosts: seen[], outcome: outcome)

proc reachedOnly(probe: ChallengeProbe, host: string): bool =
  ## The client asked about `host` and about no host but the server's own.
  host in probe.hosts and probe.hosts.allIt(it in [host, ProbedServerHost])

proc readNothing(probe: ChallengeProbe): bool =
  ## The client took no host from the challenge: at most it asked about the
  ## server's own.
  probe.hosts.allIt(it == ProbedServerHost)

proc namedHostIsRefused(probe: ChallengeProbe, host: string): bool =
  probe.reachedOnly(host) and probe.outcome.kind == "security" and
    "link-local" in probe.outcome.msg

proc scopeInUrl(url: string): string =
  for (name, value) in decodeQuery(parseUri(url).query):
    if name == "scope":
      return value

proc consentedFor(version: McpProtocolVersion, headerTemplate: string
                 ): tuple[urls: seq[string], granted: bool] =
  ## A real authorization server and resource server on loopback: the client
  ## answers a 401 whose header is `headerTemplate`, "{prm}" standing for the
  ## URL of the resource's metadata. `urls` are the authorization URLs the
  ## user was sent to.
  let authServer = startFakeAs()
  let resourceServer = startFakeRs(authServer)
  defer:
    resourceServer.stop()
    authServer.stop()
  let seen = new(seq[string])
  let client = clientOf(resourceServer.url, authorizerFor(authServer, seen), version)
  let prm = "http://127.0.0.1:" & $resourceServer.port & "/.well-known/oauth-protected-resource/mcp"
  let granted = waitFor client.handleChallenge(401, @[headerTemplate.replace("{prm}", prm)])
  (seen[], granted)

proc scopeAsked(version: McpProtocolVersion, headerTemplate: string): string =
  let consent = consentedFor(version, headerTemplate)
  doAssert consent.granted
  doAssert consent.urls.len == 1
  scopeInUrl(consent.urls[0])

const scopeVersions = block:
  var versions: seq[McpProtocolVersion]
  for v in SupportedProtocolVersions:
    if v.has(ftProtectedResourceMetadata) and v.has(ftIncrementalScopeConsent):
      versions.add v
  versions


proc answeredWith(version: McpProtocolVersion,
                  tamper: proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.}
                 ): tuple[outcome: Outcome, tokenRequests: int] =
  ## The authorization response the user's browser brings back is what
  ## `tamper` makes of the one the authorization server's consent gives.
  let authServer = startFakeAs()
  let resourceServer = startFakeRs(authServer)
  defer:
    resourceServer.stop()
    authServer.stop()
  let authorize: UserAuthorizer = proc(url: string): Future[seq[(string, string)]] {.async.} =
    return tamper(authServer.consent(url))
  let client = clientOf(resourceServer.url, authorize, version)
  let prm = "http://127.0.0.1:" & $resourceServer.port & "/.well-known/oauth-protected-resource/mcp"
  let outcome = reportedBy(client.handleChallenge(401, @["Bearer resource_metadata=\"" & prm & "\""]))
  (outcome, authServer.log.requestsTo("/token").len)

