## The pieces of OAuth that need no network: PKCE, WWW-Authenticate,
## well-known URLs, URL policy, and metadata validation. Expected values are
## taken from RFC 7636 (appendix B), RFC 8414 (3.1), RFC 9728 (3.1, 5.1) and
## the MCP authorization specification.

import std/[unittest, json, options, strutils, asyncdispatch, asyncnet, asynchttpserver, httpcore, net,
            nativesockets, times, uri]
import protocol/version
import protocol/features
import auth/client
import auth/resource_server
import auth/oauth/[pkce, challenge, urls, metadata, discovery, errors, fetch, jsonfield, authcode, registration]
import auth_fixtures

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

  test "Given the invalid examples of the specification, when canonicalized, then they are refused":
    # The version of the build without authorization has no client or resource server.
    if not (DefaultProtocolVersion.has(ftAuthorization)):
      skip()
    else:
      expect OAuthError: discard newResourceServerAuth(serverConfig("mcp.example.com"))
      expect OAuthError: discard newResourceServerAuth(serverConfig("https://mcp.example.com#fragment"))

  test "Given the resource, when form-encoded as the specification shows, then it matches &resource=https%3A%2F%2Fmcp.example.com":
    check formEncode({"resource": "https://mcp.example.com"}) ==
      "resource=https%3A%2F%2Fmcp.example.com"

suite "Fetch policy":
  let policy = defaultFetchPolicy()

  test "Given https to a public name, when checked, then it passes":
    checkFetchUrl("https://auth.example.com/x", policy, "t")

  test "Given plain http to a remote host, when checked, then it is refused":
    # Before protected resource metadata the client ignores the resource_metadata of a challenge.
    if not (DefaultProtocolVersion.has(ftProtectedResourceMetadata)):
      skip()
    else:
      let client = loopbackOnlyClient()
      expect OAuthSecurityError: discard waitFor client.challengedWith("http://auth.example.com/x")

  test "Given plain http to loopback hosts, when checked, then it passes":
    for url in ["http://localhost:1/x", "http://127.0.0.1:8080/x", "http://[::1]:8080/x"]:
      checkFetchUrl(url, policy, "t")

  test "Given loopback disallowed, when checking loopback, then it is refused":
    # Before protected resource metadata the client ignores the resource_metadata of a challenge.
    if not (DefaultProtocolVersion.has(ftProtectedResourceMetadata)):
      skip()
    else:
      var strict = policy
      strict.allowLoopback = false
      let client = clientOf("http://127.0.0.1:1/mcp", fetchPolicy = strict)
      expect OAuthSecurityError: discard waitFor client.challengedWith("http://127.0.0.1/x")
      expect OAuthSecurityError: discard waitFor client.challengedWith("https://localhost/x")

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

  test "Given other schemes, fragments or credentials, when checked, then they are refused":
    # Before protected resource metadata the client ignores the resource_metadata of a challenge.
    if not (DefaultProtocolVersion.has(ftProtectedResourceMetadata)):
      skip()
    else:
      let client = loopbackOnlyClient()
      for url in ["ftp://auth.example.com/x", "file:///etc/passwd", "https://auth.example.com/x#a",
                  "https://user:pw@auth.example.com/x", "/relative"]:
        checkpoint url
        expect OAuthSecurityError: discard waitFor client.challengedWith(url)

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
  test "Given URLs that name no host or no scheme, when checked, then they are refused":
    # Before protected resource metadata the client ignores the resource_metadata of a challenge.
    if not (DefaultProtocolVersion.has(ftProtectedResourceMetadata)):
      skip()
    else:
      let client = loopbackOnlyClient()
      expect OAuthSecurityError: discard waitFor client.challengedWith("https:///x")
      expect OAuthSecurityError: discard waitFor client.challengedWith("//auth.example.com/x")

  test "Given a user name alone or a password alone, when checked, then the URL is refused for its credentials":
    # Before protected resource metadata the client ignores the resource_metadata of a challenge.
    if not (DefaultProtocolVersion.has(ftProtectedResourceMetadata)):
      skip()
    else:
      let client = loopbackOnlyClient()
      expect OAuthSecurityError: discard waitFor client.challengedWith("https://user@auth.example.com/x")
      expect OAuthSecurityError: discard waitFor client.challengedWith("https://:secret@auth.example.com/x")

  test "Given a resource without a host or without a scheme, when canonicalized, then it is refused":
    # The version of the build without authorization has no client or resource server.
    if not (DefaultProtocolVersion.has(ftAuthorization)):
      skip()
    else:
      expect OAuthError: discard newResourceServerAuth(serverConfig("https:///mcp"))
      expect OAuthError: discard newResourceServerAuth(serverConfig("//mcp.example.com/mcp"))

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

  test "Given a 201 with a valid document, when discovering, then it is not used and every URL tried is named with its status":
    # The client probes the well-known URLs without a resource_metadata, and tries the OpenID Connect URLs, only from the version with both.
    if not (DefaultProtocolVersion.has(ftIncrementalScopeConsent) and DefaultProtocolVersion.has(ftOidcDiscovery)):
      skip()
    else:
      # RFC 8414 3.2: a successful response uses 200.
      let server = startScripted(proc(origin, line: string): string =
        if "oauth-protected-resource" in line: jsonReply(200, "OK", prmNaming(origin, origin & "/tenant1"))
        elif oauthPath in line: jsonReply(201, "Created", asDocument(origin, origin & "/tenant1"))
        else: jsonReply(404, "Not Found", "{}"))
      defer: server.stop()
      let outcome = reportedBy(clientOf(server.origin & "/mcp").unchallenged())
      check outcome.kind == "oauth"
      check (server.origin & oauthPath & ": HTTP 201") in outcome.msg
      check (server.origin & oidcPath & ": HTTP 404") in outcome.msg
      check (server.origin & appendedPath & ": HTTP 404") in outcome.msg

  test "Given a 200 whose body is not a JSON object, when discovering, then it is a failure of that URL":
    # The client probes the well-known URLs without a resource_metadata only from the version with incremental scope consent.
    if not (DefaultProtocolVersion.has(ftIncrementalScopeConsent)):
      skip()
    else:
      let server = startScripted(proc(origin, line: string): string =
        if "oauth-protected-resource" in line: jsonReply(200, "OK", prmNaming(origin, origin & "/tenant1"))
        else: jsonReply(200, "OK", "[1]"))
      defer: server.stop()
      let outcome = reportedBy(clientOf(server.origin & "/mcp").unchallenged())
      check outcome.kind == "oauth"
      check (server.origin & oauthPath & ": HTTP 200") in outcome.msg

  test "Given a document that names another issuer, when discovering, then the failure is a security failure that says why":
    # The client probes the well-known URLs without a resource_metadata, and tries the OpenID Connect URLs, only from the version with both.
    if not (DefaultProtocolVersion.has(ftIncrementalScopeConsent) and DefaultProtocolVersion.has(ftOidcDiscovery)):
      skip()
    else:
      let server = startScripted(proc(origin, line: string): string =
        if "oauth-protected-resource" in line: jsonReply(200, "OK", prmNaming(origin, origin & "/tenant1"))
        elif oauthPath in line: jsonReply(200, "OK", asDocument(origin, "https://elsewhere.example"))
        else: jsonReply(404, "Not Found", "{}"))
      defer: server.stop()
      let outcome = reportedBy(clientOf(server.origin & "/mcp").unchallenged())
      check outcome.kind == "security"
      check (server.origin & oauthPath & ": authorization server metadata names issuer https://elsewhere.example") in
        outcome.msg
      check (server.origin & oidcPath & ": HTTP 404") in outcome.msg

  test "Given a document without a token endpoint, when discovering, then the failure names the field and is not a security failure":
    # The client probes the well-known URLs without a resource_metadata only from the version with incremental scope consent.
    if not (DefaultProtocolVersion.has(ftIncrementalScopeConsent)):
      skip()
    else:
      let server = startScripted(proc(origin, line: string): string =
        if "oauth-protected-resource" in line: jsonReply(200, "OK", prmNaming(origin, origin & "/tenant1"))
        elif oauthPath in line: jsonReply(200, "OK", $(%*{"issuer": origin & "/tenant1",
                                                         "authorization_endpoint": origin & "/authorize"}))
        else: jsonReply(404, "Not Found", "{}"))
      defer: server.stop()
      let outcome = reportedBy(clientOf(server.origin & "/mcp").unchallenged())
      check outcome.kind == "oauth"
      check (server.origin & oauthPath & ": metadata field token_endpoint is missing") in outcome.msg

  test "Given an issuer with a fragment, when discovering, then it is refused before any request is made":
    let server = startScripted(proc(origin, line: string): string = jsonReply(404, "Not Found", "{}"))
    defer: server.stop()
    let outcome = outcomeOf(discoverAuthorizationServer(server.origin & "/tenant1#frag", adsOAuthThenOidc, policy))
    check outcome.kind == "security"
    check "authorization server issuer has a fragment" in outcome.msg
    check server.requestLines.len == 0

  test "Given a server URL on plain http to a remote host, when discovering with the 2025-03-26 rules, then the error names the authorization base URL":
    # The build has to speak 2025-03-26 for the client to follow its rules.
    if not (mpv20250326.isSupported):
      skip()
    else:
      var named = defaultFetchPolicy()
      named.resolver = everyHostIsLoopback()
      let outcome = reportedBy(clientOf("http://remote.example.test/mcp", version = mpv20250326,
                                        fetchPolicy = named).unchallenged())
      check outcome.kind == "security"
      check "authorization base URL must be https" in outcome.msg

  test "Given the root of an origin that answers 201 or a non-object 200, when discovering with the 2025-03-26 rules, then it fails without defaults":
    # The build has to speak 2025-03-26 for the client to follow its rules.
    if not (mpv20250326.isSupported):
      skip()
    else:
      for (code, reason, body) in [(201, "Created", ""), (200, "OK", "[1]")]:
        let server = startScripted(proc(origin, line: string): string =
          jsonReply(code, reason, if body.len > 0: body else: asDocument(origin, origin)))
        defer: server.stop()
        let outcome = reportedBy(clientOf(server.origin & "/mcp", version = mpv20250326).unchallenged())
        check outcome.kind == "oauth"
        check ("(HTTP " & $code & ")") in outcome.msg

suite "Protected resource metadata over a scripted server (mutation review, g2f-oauth-a)":
  test "Given a 201 with a valid document or a non-object 200, when fetching, then it is refused":
    # Before protected resource metadata the client ignores the resource_metadata of a challenge.
    if not (DefaultProtocolVersion.has(ftProtectedResourceMetadata)):
      skip()
    else:
      for (code, reason, useDocument) in [(201, "Created", true), (200, "OK", false)]:
        let server = startScripted(proc(origin, line: string): string =
          jsonReply(code, reason, if useDocument: prmDocument(origin, origin & "/mcp") else: "[1]"))
        defer: server.stop()
        let outcome = reportedBy(clientOf(server.origin & "/mcp").challengedWith(server.origin & "/x"))
        check outcome.kind == "oauth"
        check ("(HTTP " & $code & ")") in outcome.msg

  test "Given no document at either well-known URL, when probing, then the failure lists both with their status":
    # The client probes the well-known URLs without a resource_metadata only from the version with incremental scope consent.
    if not (DefaultProtocolVersion.has(ftIncrementalScopeConsent)):
      skip()
    else:
      let server = startScripted(proc(origin, line: string): string = jsonReply(404, "Not Found", "{}"))
      defer: server.stop()
      let outcome = reportedBy(clientOf(server.origin & "/mcp").unchallenged())
      check outcome.kind == "oauth"
      check outcome.msg.startsWith("no protected resource metadata: ")
      check (server.origin & "/.well-known/oauth-protected-resource/mcp is not a JSON object (HTTP 404)") in
        outcome.msg
      check (server.origin & "/.well-known/oauth-protected-resource is not a JSON object (HTTP 404)") in
        outcome.msg

  test "Given a document for another resource at the first URL, when probing, then the failure is a security failure that says why":
    # The client probes the well-known URLs without a resource_metadata only from the version with incremental scope consent.
    if not (DefaultProtocolVersion.has(ftIncrementalScopeConsent)):
      skip()
    else:
      let server = startScripted(proc(origin, line: string): string =
        if "/oauth-protected-resource/mcp" in line:
          jsonReply(200, "OK", prmDocument(origin, "https://other.example/mcp"))
        else: jsonReply(404, "Not Found", "{}"))
      defer: server.stop()
      let outcome = reportedBy(clientOf(server.origin & "/mcp").unchallenged())
      check outcome.kind == "security"
      check outcome.msg.startsWith("no usable protected resource metadata: ")
      check "describes https://other.example/mcp, not " & server.origin & "/mcp" in outcome.msg

suite "Requests of the OAuth client over a scripted server (mutation review, g2f-oauth-a)":
  let policy = defaultFetchPolicy()

  test "Given an endpoint that answers 302, when requested, then the redirect is reported and its target is never requested":
    # Before protected resource metadata the client ignores the resource_metadata of a challenge.
    if not (DefaultProtocolVersion.has(ftProtectedResourceMetadata)):
      skip()
    else:
      let server = startScripted(proc(origin, line: string): string =
        if "/moved" in line: jsonReply(302, "Found", "", "Location: " & origin & "/target\c\L")
        else: jsonReply(200, "OK", "{}"))
      defer: server.stop()
      let outcome = reportedBy(clientOf(server.origin & "/mcp").challengedWith(server.origin & "/moved"))
      check outcome.kind == "oauth"
      check "redirected (HTTP 302)" in outcome.msg
      check server.requestLines.len == 1

  test "Given an endpoint that answers 304 to a conditional request, when requested, then the 304 is the reply":
    let server = startScripted(proc(origin, line: string): string =
      "HTTP/1.1 304 Not Modified\c\LConnection: close\c\L\c\L")
    defer: server.stop()
    let reply = waitFor httpExchange(HttpGet, server.origin & "/x", policy, "metadata",
                                     headers = @[("If-None-Match", "\"v1\"")])
    check reply.code == 304

  test "Given plain http to a host name that resolves to loopback, when requested, then it is refused and nothing is sent":
    # Before protected resource metadata the client ignores the resource_metadata of a challenge.
    if not (DefaultProtocolVersion.has(ftProtectedResourceMetadata)):
      skip()
    else:
      # The text of the URL decides the scheme rule: a name is not "loopback".
      let server = startScripted(proc(origin, line: string): string = jsonReply(200, "OK", "{}"))
      defer: server.stop()
      var named = policy
      named.resolver = resolvingTo("auth.example.test", "127.0.0.1")
      let outcome = reportedBy(clientOf(server.origin & "/mcp", fetchPolicy = named).challengedWith(
        "http://auth.example.test:" & $server.port & "/x"))
      check outcome.kind == "security"
      check "must be https" in outcome.msg
      check server.requestLines.len == 0

  test "Given a keep-alive answer without a body, when the request is done, then the client has closed the connection":
    # A body that ends the connection closes it by itself; one that has no
    # body leaves it to the caller of the wire.
    for answer in ["HTTP/1.1 204 No Content\c\L\c\L",
                   "HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L"]:
      let server = startHolding(answer)
      let reply = waitFor httpExchange(HttpGet, "http://127.0.0.1:" & $server.port & "/x", policy, "metadata")
      check reply.body == ""
      check server.closedWithin(2000)

  test "Given an endpoint that never answers, when the time runs out, then the connection is closed as well as reported":
    # Before protected resource metadata the client ignores the resource_metadata of a challenge.
    if not (DefaultProtocolVersion.has(ftProtectedResourceMetadata)):
      skip()
    else:
      let server = startHolding("")
      var quick = policy
      quick.timeoutMs = 300
      let origin = "http://127.0.0.1:" & $server.port
      let outcome = reportedBy(clientOf(origin & "/mcp", fetchPolicy = quick).challengedWith(origin & "/x"))
      check outcome.kind == "oauth"
      check "timed out after 300 ms" in outcome.msg
      check server.closedWithin(2000)

suite "OAuth parsers and checks (mutation review, g2f-oauth-b)":
  let policy = defaultFetchPolicy()

  test "Given metadata with a plain http authorization or registration endpoint on a remote host, when parsed, then it is rejected":
    # The client probes the well-known URLs without a resource_metadata only from the version with incremental scope consent.
    if not (DefaultProtocolVersion.has(ftIncrementalScopeConsent)):
      skip()
    else:
      for key in ["authorization_endpoint", "registration_endpoint"]:
        checkpoint key
        let authServer = startFakeAs()
        let resourceServer = startFakeRs(authServer)
        defer:
          resourceServer.stop()
          authServer.stop()
        authServer.metadata[key] = %"http://auth.example.com/endpoint"
        var named = defaultFetchPolicy()
        named.resolver = everyHostIsLoopback()
        expect OAuthSecurityError:
          discard waitFor clientOf(resourceServer.url, fetchPolicy = named).unchallenged()

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

  test "Given an error answer that is not JSON, when the error is built, then it names the HTTP status and is no OAuth error response":
    # The client probes the well-known URLs without a resource_metadata only from the version with incremental scope consent.
    if not (DefaultProtocolVersion.has(ftIncrementalScopeConsent)):
      skip()
    else:
      let authServer = startFakeAs()
      let resourceServer = startFakeRs(authServer)
      defer:
        resourceServer.stop()
        authServer.stop()
      authServer.pointAt("token_endpoint", "/oauth/token")
      authServer.answering(Http502, "<html>bad gateway</html>")
      let outcome = reportedBy(clientOf(resourceServer.url, authorizerFor(authServer)).unchallenged())
      check outcome.kind == "oauth"
      check outcome.msg == "the token request failed with HTTP 502"

  test "Given an OAuth error answer, when the error is built, then the description follows only when there is one":
    # The client probes the well-known URLs without a resource_metadata only from the version with incremental scope consent.
    if not (DefaultProtocolVersion.has(ftIncrementalScopeConsent)):
      skip()
    else:
      let authServer = startFakeAs(registration = false)
      let resourceServer = startFakeRs(authServer)
      defer:
        resourceServer.stop()
        authServer.stop()
      authServer.pointAt("registration_endpoint", "/register")
      for (body, message) in [
          ("""{"error": "invalid_redirect_uri"}""",
           "client registration was refused: invalid_redirect_uri"),
          ("""{"error": "invalid_redirect_uri", "error_description": ""}""",
           "client registration was refused: invalid_redirect_uri"),
          ("""{"error": "invalid_redirect_uri", "error_description": "no fragments"}""",
           "client registration was refused: invalid_redirect_uri (no fragments)")]:
        checkpoint body
        authServer.answering(Http400, body)
        let outcome = reportedBy(clientOf(resourceServer.url).unchallenged())
        check outcome.msg == message

  test "Given redirect URIs with a fragment, no host, plain http to a remote host or another scheme, when checked, then they are refused":
    # The version of the build without authorization has no client or resource server.
    if not (DefaultProtocolVersion.has(ftAuthorization)):
      skip()
    else:
      for bad in ["https://app.example/cb#frag", "https:///cb", "/cb", "http://app.example/cb",
                  "ftp://app.example/cb"]:
        checkpoint bad
        var config = configOf("https://mcp.example.com/mcp")
        config.redirectUri = bad
        expect OAuthSecurityError:
          discard newOAuthClient(config)
      for good in ["https://app.example/cb", "http://127.0.0.1:8080/cb", "http://localhost/cb"]:
        checkpoint good
        var config = configOf("https://mcp.example.com/mcp")
        config.redirectUri = good
        discard newOAuthClient(config)

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

  test "Given a registration response without a client_id or with an empty one, when read, then registration fails":
    # The client probes the well-known URLs without a resource_metadata only from the version with incremental scope consent.
    if not (DefaultProtocolVersion.has(ftIncrementalScopeConsent)):
      skip()
    else:
      let authServer = startFakeAs(registration = false)
      let resourceServer = startFakeRs(authServer)
      defer:
        resourceServer.stop()
        authServer.stop()
      authServer.pointAt("registration_endpoint", "/register")
      for body in ["""{"client_secret": "s"}""", """{"client_id": ""}""", """{"client_id": 5}"""]:
        checkpoint body
        authServer.answering(Http201, body)
        expect OAuthError:
          discard waitFor clientOf(resourceServer.url).unchallenged()

  test "Given a registration response with a client_id, when read, then the client is known by it":
    let credentials = registeredWith(Http201, """{"client_id": "abc"}""")
    check credentials.clientId == "abc"
    check credentials.authMethod == "none"
