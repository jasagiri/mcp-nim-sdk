## The pieces of OAuth that need no network: PKCE, WWW-Authenticate,
## well-known URLs, URL policy, and metadata validation. Expected values are
## taken from RFC 7636 (appendix B), RFC 8414 (3.1), RFC 9728 (3.1, 5.1) and
## the MCP authorization specification.

import std/sequtils
import std/[unittest, json, options, strutils, asyncdispatch, asyncnet, asynchttpserver, httpcore, net,
            nativesockets, uri]
import protocol/version
import protocol/features
import auth/client
import auth/resource_server
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


suite "Canonical resource":


  test "Given the invalid examples of the specification, when canonicalized, then they are refused":
    # The version of the build without authorization has no client or resource server.
    if not (DefaultProtocolVersion.has(ftAuthorization)):
      skip()
    else:
      expect OAuthError: discard newResourceServerAuth(serverConfig("mcp.example.com"))
      expect OAuthError: discard newResourceServerAuth(serverConfig("https://mcp.example.com#fragment"))


suite "Fetch policy":
  let policy = defaultFetchPolicy()


  test "Given plain http to a remote host, when checked, then it is refused":
    # Before protected resource metadata the client ignores the resource_metadata of a challenge.
    if not (DefaultProtocolVersion.has(ftProtectedResourceMetadata)):
      skip()
    else:
      let client = loopbackOnlyClient()
      expect OAuthSecurityError: discard waitFor client.challengedWith("http://auth.example.com/x")


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

suite "A Bearer challenge seen through the public entries":

  test "Given the MCP 401 example, when the client answers it, then it goes for the resource metadata the Bearer challenge names":
    when HasProbedVersion:
      let probe = probed(@["Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\", scope=\"files:read\""])
      check probe.namedHostIsRefused("mcp.example.com")
    else:
      skip()

  test "Given several challenges, when the client answers them, then it takes the metadata of the Bearer one, whatever the order, lines or case":
    when HasProbedVersion:
      let bearer = "Bearer resource_metadata=\"https://bearer.example.test/x\""
      check probed(@["Basic realm=\"x\", " & bearer]).namedHostIsRefused("bearer.example.test")
      check probed(@[bearer & ", Basic realm=\"x\""]).namedHostIsRefused("bearer.example.test")
      check probed(@["Basic realm=\"x\"", bearer]).namedHostIsRefused("bearer.example.test")
      check probed(@["bEaReR rEsOuRcE_mEtAdAtA=\"https://bearer.example.test/x\""]).namedHostIsRefused("bearer.example.test")
      check probed(@["Other resource_metadata=\"https://other.example.test/x\", " & bearer]
                  ).namedHostIsRefused("bearer.example.test")
      check probed(@[bearer & ", Other resource_metadata=\"https://other.example.test/x\""]
                  ).namedHostIsRefused("bearer.example.test")
    else:
      skip()

  test "Given a quoted string with an escaped quote and a comma that holds another resource_metadata, when the client answers, then the string is read whole and the inner one is not taken":
    when HasProbedVersion:
      let probe = probed(@["Bearer error_description=\"see \\\"x\\\", resource_metadata=\\\"https://trap.example.test/x\\\"\", resource_metadata=\"https://bearer.example.test/x\""])
      check probe.namedHostIsRefused("bearer.example.test")
      check "trap.example.test" notin probe.hosts
    else:
      skip()

  test "Given only a Basic challenge or no challenge, when the client answers, then it takes no metadata from the header":
    when HasProbedVersion:
      check probed(@["Basic realm=\"x\""]).readNothing()
      check probed(@["Basic realm=\"x\", resource_metadata=\"https://other.example.test/x\""]).readNothing()
      check probed(newSeq[string]()).readNothing()
    else:
      skip()

  for v in scopeVersions:
    test "Given the scope of a challenge with white space and a comma inside the quotes and version " & $v &
         ", when the client asks the user, then the authorization URL carries the scope whole":
      let header = "Bearer error_description=\"a, \\\"b\\\"\", scope=\"files:read files:write\", resource_metadata=\"{prm}\""
      check scopeAsked(v, header) == "files:read files:write"

suite "A Bearer challenge's surroundings seen through the public entries":

  test "Given token68 padding before a Bearer challenge, when the client answers, then it takes the Bearer metadata":
    when HasProbedVersion:
      check probed(@["Basic YWJj==, Bearer resource_metadata=\"https://bearer.example.test/x\""]
                  ).namedHostIsRefused("bearer.example.test")
      check probed(@["Basic YWJj=, Bearer resource_metadata=\"https://bearer.example.test/x\""]
                  ).namedHostIsRefused("bearer.example.test")
    else:
      skip()

  test "Given a token68 whose padding ends a header line, when the client answers, then the next line is read on its own":
    when HasProbedVersion:
      check probed(@["Basic YWJj==", "Bearer resource_metadata=\"https://bearer.example.test/x\""]
                  ).namedHostIsRefused("bearer.example.test")
      check probed(@["Basic YWJj=="]).readNothing()
    else:
      skip()

  test "Given white space around the equals sign, when the client answers, then it reads what it reads without":
    when HasProbedVersion:
      check probed(@["Bearer resource_metadata = \"https://bearer.example.test/x\""]
                  ).namedHostIsRefused("bearer.example.test")
      check probed(@["Bearer resource_metadata\t=\t\"https://bearer.example.test/x\" , scope = read"]
                  ).namedHostIsRefused("bearer.example.test")
    else:
      skip()

  test "Given a resource_metadata that ends the header with no value, when the client answers, then the value is empty: nothing named is fetched and the answer is no refusal of an address":
    when HasProbedVersion:
      let probe = probed(@["Bearer realm=\"r\", resource_metadata="])
      check probe.readNothing()
      check probe.outcome.kind != "none"
      check "link-local" notin probe.outcome.msg
    else:
      skip()

  test "Given a parameter before any scheme, when the client answers, then it belongs to no challenge and is not taken":
    when HasProbedVersion:
      check probed(@["resource_metadata=\"https://trap.example.test/x\""]).readNothing()
      check probed(@["resource_metadata=\"https://trap.example.test/x\", Bearer realm=\"r\""]).readNothing()
      check probed(@["resource_metadata=\"https://trap.example.test/x\", Bearer resource_metadata=\"https://bearer.example.test/x\""]
                  ).namedHostIsRefused("bearer.example.test")
    else:
      skip()

  for v in scopeVersions:
    test "Given white space around the equals sign of an unquoted scope and version " & $v &
         ", when the client asks the user, then the authorization URL carries the scope":
      check scopeAsked(v, "Bearer resource_metadata = \"{prm}\" , scope =  read") == "read"

    test "Given a scope that ends the header with no value and version " & $v &
         ", when the client asks the user, then the scope is empty and the authorization URL has none":
      check scopeAsked(v, "Bearer resource_metadata=\"{prm}\", scope=") == ""

    test "Given a scope cut off after a backslash and version " & $v &
         ", when the client asks the user, then the backslash is kept in the scope":
      check scopeAsked(v, "Bearer resource_metadata=\"{prm}\", scope=\"files:read\\") == "files:read\\"

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

suite "An authorization response seen through the public entries":
  for v in SupportedProtocolVersions:
    if v.has(ftProtectedResourceMetadata):
      test "Given a response whose state differs from the request's in one character and version " & $v &
           ", when the client receives it, then it is refused for its state and no token is requested":
        let answered = answeredWith(v, proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
          for (name, value) in params:
            if name == "state":
              result.add (name, value[0 ..< value.high] & (if value[^1] == 'x': "y" else: "x"))
            else:
              result.add (name, value))
        check answered.outcome.kind in ["oauth", "security"]
        check "state" in answered.outcome.msg.toLowerAscii()
        check answered.tokenRequests == 0

      test "Given a response with a matching state and no code and version " & $v &
           ", when the client receives it, then it is refused for its code and no token is requested":
        let answered = answeredWith(v, proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
          for (name, value) in params:
            if name != "code":
              result.add (name, value))
        check answered.outcome.kind in ["oauth", "security"]
        check "code" in answered.outcome.msg.toLowerAscii()
        check "state" notin answered.outcome.msg.toLowerAscii()
        check answered.tokenRequests == 0

      test "Given a response with a matching state and an empty code and version " & $v &
           ", when the client receives it, then it is refused for its code and no token is requested":
        let answered = answeredWith(v, proc(params: seq[(string, string)]): seq[(string, string)] {.closure, gcsafe.} =
          for (name, value) in params:
            result.add (name, if name == "code": "" else: value))
        check answered.outcome.kind in ["oauth", "security"]
        check "code" in answered.outcome.msg.toLowerAscii()
        check "state" notin answered.outcome.msg.toLowerAscii()
        check answered.tokenRequests == 0
