## An authorization server and a resource server on 127.0.0.1 for the
## authorization tests. The authorization server does what RFC 6749, 7591,
## 7636, 8707 and 9207 say a server does, and records every request so a
## test can check what the client sent. It is deliberately strict: a wrong
## verifier, redirect URI or resource is answered with an OAuth error.

import std/[asyncdispatch, asynchttpserver, httpcore, json, options, strutils,
            tables, uri, base64, nativesockets, sets, osproc]
import auth/client

proc formDecode(query: string): seq[(string, string)] =
  for (k, v) in decodeQuery(query):
    result.add (k, v)

proc queryOf(url: string): seq[(string, string)] =
  formDecode(parseUri(url).query)

proc codeChallengeS256(verifier: string): string =
  ## RFC 7636 4.2. Nim's std has no SHA-256, so the digest comes from the
  ## openssl command, which the TLS tests already rely on. The hex form is
  ## read because execCmdEx splits its output into lines and is not
  ## binary-safe.
  let (output, code) = execCmdEx("openssl dgst -sha256 -r", input = verifier)
  let hex = output.splitWhitespace()
  doAssert code == 0 and hex.len > 0 and hex[0].len == 64,
    "openssl dgst failed: exit " & $code & ": " & output
  var digest = newString(32)
  for i in 0 ..< 32:
    digest[i] = char(parseHexInt(hex[0][2 * i .. 2 * i + 1]))
  base64.encode(digest, safe = true).strip(leading = false, chars = {'='})

type
  Logged* = object
    httpMethod*: string
    path*: string
    query*: string
    headers*: HttpHeaders
    body*: string
    form*: seq[(string, string)]

  PendingCode = object
    challenge: string
    redirectUri: string
    clientId: string
    resource: string
    scope: string

  IssuedToken* = object
    scope*: string
    resource*: string
    clientId*: string
    refresh*: bool

  FakeAs* = ref object
    server: AsyncHttpServer
    closed: bool
    port*: int
    issuer*: string
    metadata*: JsonNode
    metadataPaths*: HashSet[string]
      ## Paths (without query) that answer with `metadata`; others are 404.
    registrationEnabled*: bool
    log*: seq[Logged]
    registered*: seq[JsonNode]
    codes: Table[string, PendingCode]
    accessTokens*: Table[string, IssuedToken]
    refreshTokens*: Table[string, IssuedToken]
    counter: int
    accessTokenLifetime*: int
      ## expires_in of issued tokens; 0 omits it.
    rotateRefreshTokens*: bool
    grantScopes*: Option[string]
      ## When set, the token response grants this instead of what was asked.
    redirectMetadataTo*: string
      ## When set, the metadata paths answer 302 to this URL.
    fallback*: proc(req: Request): Future[void] {.closure, gcsafe.}
      ## Receives what is not an authorization server path: the resource
      ## server of the 2025-03-26 layout, where both share an origin.

  FakeRs* = ref object
    server: AsyncHttpServer
    closed: bool
    port*: int
    url*: string
    authorizationServer*: FakeAs
    log*: seq[Logged]
    resourceMetadata*: JsonNode
    resourceMetadataPaths*: HashSet[string]
    advertiseInChallenge*: bool
    challengeScope*: string
    requiredScope*: string
      ## A request needs a token granted this scope; otherwise 403.
    insufficientScopeChallenge*: string
      ## The scope in the 403 challenge; defaults to `requiredScope`.

proc jsonResponse(req: Request, code: HttpCode, body: JsonNode,
                  extra: openArray[(string, string)] = []): Future[void] =
  let headers = newHttpHeaders({"Content-Type": "application/json"})
  for (k, v) in extra:
    headers[k] = v
  req.respond(code, $body, headers)

proc record(req: Request): Logged =
  let contentType = $req.headers.getOrDefault("Content-Type")
  # The server reuses its header table for the next request: keep a copy.
  var copied = newHttpHeaders()
  for k, v in req.headers.pairs:
    copied.add(k, v)
  Logged(httpMethod: $req.reqMethod, path: req.url.path, query: req.url.query,
         headers: copied, body: req.body,
         form: if "x-www-form-urlencoded" in contentType.toLowerAscii(): formDecode(req.body) else: @[])

func field*(l: Logged, name: string): Option[string] =
  for (k, v) in l.form:
    if k == name:
      return some(v)
  none(string)

func queryField*(l: Logged, name: string): Option[string] =
  for (k, v) in formDecode(l.query):
    if k == name:
      return some(v)
  none(string)

proc requestsTo*(log: seq[Logged], path: string): seq[Logged] =
  for l in log:
    if l.path == path:
      result.add l

proc nextId(a: FakeAs, prefix: string): string =
  inc a.counter
  prefix & $a.counter

proc oauthError(req: Request, error: string, description = ""): Future[void] =
  jsonResponse(req, Http400, %*{"error": error, "error_description": description})

proc clientIdOf(l: Logged): string =
  let basic = $l.headers.getOrDefault("Authorization")
  if basic.startsWith("Basic "):
    let decoded = base64.decode(basic["Basic ".len .. ^1])
    return decodeUrl(decoded.split(':')[0], decodePlus = true)
  l.field("client_id").get("")

proc issue(a: FakeAs, grant: IssuedToken, withRefresh: bool): JsonNode =
  let access = a.nextId("at-")
  a.accessTokens[access] = grant
  result = %*{"access_token": access, "token_type": "Bearer",
              "scope": a.grantScopes.get(grant.scope)}
  if a.grantScopes.isSome:
    a.accessTokens[access].scope = a.grantScopes.get
  if a.accessTokenLifetime > 0:
    result["expires_in"] = %a.accessTokenLifetime
  if withRefresh:
    let refresh = a.nextId("rt-")
    a.refreshTokens[refresh] = grant
    result["refresh_token"] = %refresh

proc handleToken(a: FakeAs, req: Request, logged: Logged) {.async.} =
  let grantType = logged.field("grant_type").get("")
  case grantType
  of "authorization_code":
    let code = logged.field("code").get("")
    if code notin a.codes:
      await req.oauthError("invalid_grant", "unknown code")
      return
    let pending = a.codes[code]
    a.codes.del(code)  # single use
    if logged.field("redirect_uri").get("") != pending.redirectUri:
      await req.oauthError("invalid_grant", "redirect_uri mismatch")
    elif codeChallengeS256(logged.field("code_verifier").get("")) != pending.challenge:
      await req.oauthError("invalid_grant", "PKCE verification failed")
    elif clientIdOf(logged) != pending.clientId:
      await req.oauthError("invalid_client")
    elif logged.field("resource").get("") != pending.resource:
      await req.oauthError("invalid_target", "resource mismatch")
    else:
      await req.jsonResponse(Http200, a.issue(
        IssuedToken(scope: pending.scope, resource: pending.resource,
                    clientId: pending.clientId), true))
  of "refresh_token":
    let refresh = logged.field("refresh_token").get("")
    if refresh notin a.refreshTokens:
      await req.oauthError("invalid_grant", "unknown refresh token")
      return
    let grant = a.refreshTokens[refresh]
    if a.rotateRefreshTokens:
      a.refreshTokens.del(refresh)
    if clientIdOf(logged) != grant.clientId:
      await req.oauthError("invalid_client")
    else:
      # Without rotation the old refresh token stays valid and is not repeated.
      await req.jsonResponse(Http200, a.issue(grant, a.rotateRefreshTokens))
  else:
    await req.oauthError("unsupported_grant_type")

proc handle(a: FakeAs, req: Request) {.async.} =
  let logged = record(req)
  a.log.add logged
  let path = req.url.path
  if path in a.metadataPaths and req.reqMethod == HttpGet:
    if a.redirectMetadataTo.len > 0:
      await req.respond(Http302, "", newHttpHeaders({"Location": a.redirectMetadataTo}))
    else:
      await req.jsonResponse(Http200, a.metadata)
  elif path == "/register" and req.reqMethod == HttpPost and a.registrationEnabled:
    let doc = parseJson(req.body)
    let id = a.nextId("client-")
    doc["client_id"] = %id
    a.registered.add doc
    await req.jsonResponse(Http201, doc)
  elif path == "/token" and req.reqMethod == HttpPost:
    await a.handleToken(req, logged)
  elif not a.fallback.isNil:
    await a.fallback(req)
  else:
    await req.respond(Http404, "")

proc serveLoop(server: AsyncHttpServer, isClosed: proc(): bool {.closure, gcsafe.},
               handler: proc(req: Request): Future[void] {.closure, gcsafe.}) {.async.} =
  while not isClosed():
    if server.shouldAcceptRequest():
      try:
        await server.acceptRequest(handler)
      except CatchableError:
        if not isClosed():
          raise
    else:
      await sleepAsync(10)

proc startFakeAs*(issuerPath = "", metadataPaths: seq[string] = @[],
                  registration = true): FakeAs =
  ## Metadata is served at `metadataPaths` (default: the RFC 8414 location
  ## for the issuer).
  result = FakeAs(server: newAsyncHttpServer(), registrationEnabled: registration,
                  codes: initTable[string, PendingCode](),
                  accessTokens: initTable[string, IssuedToken](),
                  refreshTokens: initTable[string, IssuedToken](),
                  metadataPaths: initHashSet[string](),
                  accessTokenLifetime: 3600)
  result.server.listen(Port(0), "127.0.0.1")
  result.port = result.server.getPort.int
  let base = "http://127.0.0.1:" & $result.port
  result.issuer = base & issuerPath
  result.metadata = %*{
    "issuer": result.issuer,
    "authorization_endpoint": base & "/authorize",
    "token_endpoint": base & "/token",
    "code_challenge_methods_supported": ["S256"]}
  if registration:
    result.metadata["registration_endpoint"] = %(base & "/register")
  if metadataPaths.len == 0:
    result.metadataPaths.incl "/.well-known/oauth-authorization-server" & issuerPath
  for p in metadataPaths:
    result.metadataPaths.incl p
  let self = result
  proc handler(req: Request) {.async, gcsafe.} =
    await self.handle(req)
  asyncCheck serveLoop(result.server, proc(): bool {.closure, gcsafe.} = self.closed, handler)

proc stop*(a: FakeAs) =
  a.closed = true
  a.server.close()

proc consent*(a: FakeAs, authorizationUrl: string, sendIss = true): seq[(string, string)] =
  ## What the authorization endpoint and the user do: validate the request,
  ## remember it under a fresh code, and return the redirect's parameters.
  let query = queryOf(authorizationUrl)
  var q = initTable[string, string]()
  for (k, v) in query:
    q[k] = v
  doAssert parseUri(authorizationUrl).path == "/authorize", "request went to the wrong endpoint"
  doAssert q.getOrDefault("response_type") == "code"
  doAssert q.getOrDefault("code_challenge_method") == "S256"
  doAssert q.getOrDefault("code_challenge").len == 43
  doAssert q.getOrDefault("state").len >= 43, "state must be unguessable"
  let code = a.nextId("code-")
  a.codes[code] = PendingCode(
    challenge: q["code_challenge"], redirectUri: q["redirect_uri"],
    clientId: q["client_id"], resource: q.getOrDefault("resource"),
    scope: q.getOrDefault("scope"))
  result = @[("code", code), ("state", q["state"])]
  if sendIss:
    result.add ("iss", a.issuer)

proc handleRs(r: FakeRs, req: Request) {.async.} =
  let logged = record(req)
  r.log.add logged
  let path = req.url.path
  if path in r.resourceMetadataPaths and req.reqMethod == HttpGet:
    await req.jsonResponse(Http200, r.resourceMetadata)
    return
  if path != "/mcp":
    await req.respond(Http404, "")
    return
  let authorization = $req.headers.getOrDefault("Authorization")
  var challenge = "Bearer"
  var params: seq[string]
  if r.advertiseInChallenge:
    params.add "resource_metadata=\"http://127.0.0.1:" & $r.port &
               "/.well-known/oauth-protected-resource/mcp\""
  if r.challengeScope.len > 0:
    params.add "scope=\"" & r.challengeScope & "\""
  let token = if authorization.startsWith("Bearer "): authorization["Bearer ".len .. ^1] else: ""
  if token.len == 0 or token notin r.authorizationServer.accessTokens:
    if token.len > 0:
      params.add "error=\"invalid_token\""
    if params.len > 0:
      challenge.add " " & params.join(", ")
    await req.respond(Http401, "", newHttpHeaders({"WWW-Authenticate": challenge}))
    return
  let grant = r.authorizationServer.accessTokens[token]
  if r.requiredScope.len > 0 and r.requiredScope notin grant.scope.split(' '):
    let needed =
      if r.insufficientScopeChallenge.len > 0: r.insufficientScopeChallenge
      else: r.requiredScope
    var forbidden = @["error=\"insufficient_scope\"", "scope=\"" & needed & "\""]
    if r.advertiseInChallenge:
      forbidden.add params[0]
    await req.respond(Http403, "", newHttpHeaders({
      "WWW-Authenticate": "Bearer " & forbidden.join(", ")}))
    return
  let rpc = parseJson(req.body)
  await req.jsonResponse(Http200, %*{"jsonrpc": "2.0", "id": rpc{"id"},
                                      "result": {"served": true}})

proc startFakeRs*(authorizationServer: FakeAs, path = "/mcp",
                  sharedOrigin = false): FakeRs =
  ## Serves PRM at the RFC 9728 location for `/mcp`, and an MCP endpoint
  ## that answers every request that carries a token the AS issued. With
  ## `sharedOrigin` it is mounted on the authorization server's own port.
  result = FakeRs(server: newAsyncHttpServer(), authorizationServer: authorizationServer,
                  resourceMetadataPaths: initHashSet[string](), advertiseInChallenge: true)
  if sharedOrigin:
    result.port = authorizationServer.port
  else:
    result.server.listen(Port(0), "127.0.0.1")
    result.port = result.server.getPort.int
  result.url = "http://127.0.0.1:" & $result.port & path
  result.resourceMetadata = %*{"resource": result.url,
                               "authorization_servers": [authorizationServer.issuer]}
  result.resourceMetadataPaths.incl "/.well-known/oauth-protected-resource" & path
  let self = result
  proc handler(req: Request) {.async, gcsafe.} =
    await self.handleRs(req)
  if sharedOrigin:
    authorizationServer.fallback = handler
  else:
    asyncCheck serveLoop(result.server, proc(): bool {.closure, gcsafe.} = self.closed, handler)

proc stop*(r: FakeRs) =
  r.closed = true
  if r.port != r.authorizationServer.port:
    r.server.close()

proc authorizerFor*(authServer: FakeAs, seen: ref seq[string] = nil): UserAuthorizer =
  ## The user's side of consent. Test bodies run at module level, where a
  ## local is a global and a closure over it is not gcsafe; a proc's
  ## parameters are captured fine, so tests build the callback here.
  result = proc(url: string): Future[seq[(string, string)]] {.async.} =
    if not seen.isNil:
      seen[].add url
    return authServer.consent(url)
