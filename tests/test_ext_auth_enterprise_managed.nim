## Enterprise-Managed Authorization (ext-auth, specification/stable/
## enterprise-managed-authorization.mdx): a real StreamableHttpTransport
## against an MCP server that answers 401, an enterprise IdP that exchanges
## the identity assertion for an ID-JAG, and an authorization server that
## validates the ID-JAG the way draft-ietf-oauth-identity-assertion-authz-grant
## 4.4.1 says. The user is never sent anywhere: there is no authorize
## callback to call.

import protocol/version
import protocol/features

when DefaultProtocolVersion.has(ftProtectedResourceMetadata):
  import std/[unittest, asyncdispatch, httpcore, json, options, strutils, times, tables, sets]
  import transport/transport
  import transport/http
  import protocol/types
  import client/client
  import server/server
  import ext/auth_enterprise_managed
  import auth/oauth/[errors, grants, jwt, tokens, urls]
  import ./server_harness
  import ./client_peer
  import ext_auth_fixtures

  const
    ScopeChallenges = DefaultProtocolVersion.has(ftIncrementalScopeConsent)
      ## Scope in a challenge and step-up on 403 exist from 2025-11-25.
    Secret = "sso-client-secret-value"
    IdpKey = "idp-signing-key-do-not-leak"
    IdToken = "idtoken-alice-SECRET"
    McpClientId = "mcp-client-at-ras"

  type
    IdpBehavior = ref object
      ## What the fake IdP does wrong, when a test wants it to.
      typ: string
      audience: Option[JsonNode]
      clientId: Option[string]
      resource: Option[JsonNode]
      dropResource: bool
      drop: seq[string]
      lifetime: int
      issuedTokenType: string
      tokenType: string
      grantScope: Option[string]
      refuse: bool
      issuer: Option[string]

    Env = object
      idp, ras: FakeAs
      rs: FakeRs
      idpRegistry, rasRegistry: ClientRegistry
      idpRequests, rasRequests: ref seq[GrantRequest]
      clock: ref Time
      behavior: IdpBehavior
      providerCalls: ref int
      assertion: ref IdentityAssertion
      rasRefresh: ref bool

  proc startEnv(grantProfiles = @[GrantProfileIdJag],
                rasGrantTypes = @[GrantTypeJwtBearer],
                idpTokenTypes = @[TokenTypeIdJag]): Env =
    result.idpRequests = new(seq[GrantRequest])
    result.rasRequests = new(seq[GrantRequest])
    result.clock = new(Time)
    result.clock[] = fromUnix(1_800_000_000)
    result.providerCalls = new(int)
    result.assertion = new(IdentityAssertion)
    result.assertion[] = IdentityAssertion(kind: iakIdToken, token: IdToken)
    result.rasRefresh = new(bool)
    result.behavior = IdpBehavior(typ: IdJagJwtType, lifetime: 300,
                                  issuedTokenType: TokenTypeIdJag, tokenType: "N_A")
    result.idp = startFakeAs(registration = false)
    result.ras = startFakeAs(registration = false)
    result.rs = startFakeRs(result.ras)
    result.idpRegistry = newRegistry(@[])
    result.idpRegistry.secrets["sso-client"] = Secret
    result.idpRegistry.jwtKeys["sso-jwt-client"] = "sso-jwt-key"
    result.rasRegistry = newRegistry(@[])
    result.rasRegistry.secrets[McpClientId] = "ras-secret-value"
    result.rasRegistry.publicClients.incl "https://client.example/client.json"
    let (idp, ras) = (result.idp, result.ras)
    let (idpReg, rasReg) = (result.idpRegistry, result.rasRegistry)
    let (idpRequests, rasRequests, clock) = (result.idpRequests, result.rasRequests, result.clock)
    let (behavior, rasRefresh) = (result.behavior, result.rasRefresh)
    idpReg.audiences = @[idp.issuer, idp.metadata["token_endpoint"].getStr()]
    if idpTokenTypes.len > 0:
      idp.metadata["identity_chaining_requested_token_types_supported"] = %idpTokenTypes
    if grantProfiles.len > 0:
      ras.metadata["authorization_grant_profiles_supported"] = %grantProfiles
    if rasGrantTypes.len > 0:
      ras.metadata["grant_types_supported"] = %rasGrantTypes

    serveGrants(idp, proc(req: GrantRequest): GrantAnswer {.closure, gcsafe.} =
      idpRequests[].add req
      let client = idpReg.authenticate(req, clock[])
      if client.isNone:
        return oauthFailure("invalid_client")
      if req.field("grant_type").get("") != GrantTypeTokenExchange:
        return oauthFailure("unsupported_grant_type")
      if behavior.refuse:
        return oauthFailure("invalid_grant", "enterprise policy denies this client the server")
      let subjects = {"idtoken-alice-SECRET": (TokenTypeIdToken, "alice"),
                      "saml-alice-SECRET": (TokenTypeSaml2, "alice"),
                      "refresh-alice-SECRET": (TokenTypeRefreshToken, "alice")}.toTable
      let subject = req.field("subject_token").get("")
      if subject notin subjects or subjects[subject][0] != req.field("subject_token_type").get(""):
        return oauthFailure("invalid_grant", "unknown subject token")
      if req.field("requested_token_type").get("") != TokenTypeIdJag:
        return oauthFailure("invalid_request", "requested_token_type")
      if req.field("audience").get("") != ras.issuer:
        return oauthFailure("invalid_target", "unknown audience")
      let requested = req.field("scope").get("")
      let granted = behavior.grantScope.get(requested)
      let issued = clock[].toUnix
      var claims = %*{
        "jti": "jti-" & $idpRequests[].len, "iss": behavior.issuer.get(idp.issuer),
        "sub": subjects[subject][1], "email": "alice@example.com",
        "aud": ras.issuer, "client_id": behavior.clientId.get(McpClientId),
        "exp": issued + behavior.lifetime, "iat": issued}
      if granted.len > 0:
        claims["scope"] = %granted
      if req.field("resource").isSome and not behavior.dropResource:
        claims["resource"] = %req.field("resource").get
      if behavior.audience.isSome:
        claims["aud"] = behavior.audience.get
      if behavior.resource.isSome:
        claims["resource"] = behavior.resource.get
      for name in behavior.drop:
        claims.delete(name)
      let jag = hs256Signer(IdpKey).signJwt(claims, typ = some(behavior.typ))
      var body = %*{"issued_token_type": behavior.issuedTokenType, "access_token": jag,
                    "token_type": behavior.tokenType, "expires_in": max(behavior.lifetime, 0)}
      if granted.len > 0:
        body["scope"] = %granted
      GrantAnswer(code: Http200, body: body))

    serveGrants(ras, proc(req: GrantRequest): GrantAnswer {.closure, gcsafe.} =
      rasRequests[].add req
      let client = rasReg.authenticate(req, clock[])
      if client.isNone:
        return oauthFailure("invalid_client")
      if req.field("grant_type").get("") != GrantTypeJwtBearer:
        return oauthFailure("unsupported_grant_type")
      let jwt =
        try: decodeJwtUnverified(req.field("assertion").get(""))
        except CatchableError: return oauthFailure("invalid_grant", "assertion is not a JWT")
      if not jwt.hs256Valid(IdpKey):
        return oauthFailure("invalid_grant", "bad signature")
      if jwt.header{"typ"}.getStr() != IdJagJwtType:
        return oauthFailure("invalid_grant", "typ")
      if jwt.claims{"iss"}.getStr() != idp.issuer:
        return oauthFailure("invalid_grant", "iss")
      let aud = jwt.claims{"aud"}
      let audOk = (aud.kind == JString and aud.getStr() == ras.issuer) or
                  (aud.kind == JArray and aud.len == 1 and aud[0].getStr() == ras.issuer)
      if not audOk:
        return oauthFailure("invalid_grant", "aud")
      if jwt.claims{"client_id"}.getStr() != client.get:
        return oauthFailure("invalid_grant", "client_id")
      if jwt.claims{"exp"}.getBiggestInt() <= clock[].toUnix:
        return oauthFailure("invalid_grant", "expired")
      let resource = jwt.claims{"resource"}.getStr()
      var answer = ras.issueAccessToken(jwt.claims{"scope"}.getStr(), resource, client.get)
      if rasRefresh[]:
        answer["refresh_token"] = %"rt-from-ras"
      GrantAnswer(code: Http200, body: answer))
    ras.metadata["token_endpoint_auth_methods_supported"] =
      %*["client_secret_basic", "client_secret_post", "none"]
    result.rasRegistry.audiences = @[ras.issuer]

  proc stop(e: Env) =
    e.rs.stop()
    e.ras.stop()
    e.idp.stop()

  proc config(e: Env, idpClient: ClientAuthentication = secretBasic("sso-client", Secret),
              rasClient: ClientAuthentication = secretPost(McpClientId, "ras-secret-value")
             ): EnterpriseManagedConfig =
    let (calls, assertion, clock) = (e.providerCalls, e.assertion, e.clock)
    result = newEnterpriseManagedConfig(
      e.rs.url, e.idp.issuer, e.ras.issuer, idpClient, rasClient,
      proc(): Future[IdentityAssertion] {.async.} =
        inc calls[]
        return assertion[])
    result.now = proc(): Time {.closure, gcsafe, raises: [].} = clock[]

  proc transportFor(auth: EnterpriseManagedAuth, url: string): StreamableHttpTransport =
    result = newStreamableHttpTransport(url)
    result.auth = auth.asHttpAuth()

  proc ping(t: StreamableHttpTransport): JsonNode =
    waitFor t.sendRequest(newJsonRpcRequest("1", "ping", newJObject()))
    waitFor t.receiveMessage()

  proc bearerOf(l: Logged): string = $l.headers.getOrDefault("Authorization")

  proc connect(e: Env, config: EnterpriseManagedConfig): StreamableHttpTransport =
    transportFor(newEnterpriseManagedAuth(config), e.rs.url)

  proc failureOf(t: StreamableHttpTransport): string =
    try:
      discard t.ping()
      fail()
    except McpTransportError as e:
      result = e.msg

  suite "enterprise-managed authorization: the flow":

    test "Given a 401 and an ID token, when a request is sent, then the IdP exchanges it for an ID-JAG for this authorization server and resource, the server turns that into an access token, and the user is never sent anywhere":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "chat.read chat.history"
      let t = env.connect(env.config())
      check t.ping(){"result", "served"}.getBool()
      check env.idpRequests[].len == 1
      let x = env.idpRequests[][0]
      check x.field("grant_type") == some(GrantTypeTokenExchange)
      check x.field("requested_token_type") == some(TokenTypeIdJag)
      check x.field("audience") == some(env.ras.issuer)
      check x.field("resource") == some(env.rs.url)
      # A challenge names a scope from 2025-11-25 on; before that it is ignored.
      check x.field("scope") ==
        (if ScopeChallenges: some("chat.read chat.history") else: none(string))
      check x.field("subject_token") == some(IdToken)
      check x.field("subject_token_type") == some(TokenTypeIdToken)
      check env.rasRequests[].len == 1
      let g = env.rasRequests[][0]
      check g.field("grant_type") == some(GrantTypeJwtBearer)
      check g.field("assertion").isSome
      check g.field("resource").isNone
      check g.field("subject_token").isNone
      let posts = env.rs.log.requestsTo("/mcp")
      check posts.len == 2
      check posts[0].bearerOf == ""
      check posts[1].bearerOf.startsWith("Bearer at-ext-")
      for l in env.idp.log & env.ras.log:
        check l.path != "/authorize"

    test "Given the access token the server issued, when it is looked up, then it is restricted to the MCP server named by the ID-JAG's resource":
      let env = startEnv()
      defer: env.stop()
      discard env.connect(env.config()).ping()
      let token = env.rs.log.requestsTo("/mcp")[1].bearerOf["Bearer ".len .. ^1]
      check env.ras.accessTokens[token].resource == env.rs.url

    test "Given a SAML assertion or a refresh token instead of an ID token, when a request is sent, then subject_token_type says which":
      for (kind, token, urn) in [(iakSaml2, "saml-alice-SECRET", TokenTypeSaml2),
                                 (iakRefreshToken, "refresh-alice-SECRET", TokenTypeRefreshToken)]:
        let env = startEnv()
        defer: env.stop()
        env.assertion[] = IdentityAssertion(kind: kind, token: token)
        check env.connect(env.config()).ping(){"result", "served"}.getBool()
        check env.idpRequests[][0].field("subject_token_type") == some(urn)

    test "Given a signing key at the IdP and a public client with a metadata document URL at the authorization server, when a request is sent, then both authenticate as the draft says":
      let env = startEnv()
      defer: env.stop()
      env.idpRegistry.audiences = @[env.idp.issuer]
      let cimd = "https://client.example/client.json"
      env.behavior.clientId = some(cimd)
      let config = env.config(
        idpClient = privateKeyJwt("sso-jwt-client", hs256Signer("sso-jwt-key"), ""),
        rasClient = publicClient(cimd))
      check env.connect(config).ping(){"result", "served"}.getBool()
      check env.idpRequests[][0].field("client_assertion_type").isSome
      check env.idpRequests[][0].field("client_id").isNone
      check env.rasRequests[][0].field("client_id") == some(cimd)

    test "Given a stored token, when more requests are sent, then no second exchange happens":
      let env = startEnv()
      defer: env.stop()
      let t = env.connect(env.config())
      discard t.ping()
      discard t.ping()
      check env.idpRequests[].len == 1
      check env.rasRequests[].len == 1
      check env.providerCalls[] == 1

    test "Given an access token and an ID-JAG that both outlive a clock step, when the access token expires first, then the ID-JAG is reused":
      let env = startEnv()
      defer: env.stop()
      env.behavior.lifetime = 7200            # the ID-JAG outlives the access token (3600 s)
      let t = env.connect(env.config())
      discard t.ping()
      env.clock[] = env.clock[] + initDuration(seconds = 3700)
      check t.ping(){"result", "served"}.getBool()
      check env.idpRequests[].len == 1
      check env.rasRequests[].len == 2
      check env.rasRequests[][0].field("assertion") == env.rasRequests[][1].field("assertion")
      check env.providerCalls[] == 1
      let posts = env.rs.log.requestsTo("/mcp")
      check posts.len == 3                     # no 401 in between
      check posts[2].bearerOf != posts[1].bearerOf

    test "Given an access token and an ID-JAG that have both expired, when the next request is sent, then the identity assertion is asked for again and the IdP issues a new ID-JAG":
      let env = startEnv()
      defer: env.stop()
      let t = env.connect(env.config())
      discard t.ping()
      env.clock[] = env.clock[] + initDuration(seconds = 3700)   # ID-JAG lifetime is 300 s
      check t.ping(){"result", "served"}.getBool()
      check env.idpRequests[].len == 2
      check env.providerCalls[] == 2
      check env.rasRequests[][0].field("assertion") != env.rasRequests[][1].field("assertion")

    test "Given a refresh token from the authorization server, when the access token is stored, then it is not kept (the ID-JAG renews access)":
      let env = startEnv()
      defer: env.stop()
      env.rasRefresh[] = true
      let config = env.config()
      discard env.connect(config).ping()
      check config.tokenStore.load(canonicalResource(env.rs.url)).get.refreshToken.isNone

    test "Given a config without a resource, when a request is sent, then the exchange carries none":
      let env = startEnv()
      defer: env.stop()
      var config = env.config()
      config.omitResource = true
      check env.connect(config).ping(){"result", "served"}.getBool()
      check env.idpRequests[][0].field("resource").isNone

  suite "enterprise-managed authorization: scopes":

    test "Given scopes in the config, when the exchange is made, then they replace the challenge's":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "chat.read"
      var config = env.config()
      config.scopes = some(@["other.scope"])
      discard env.connect(config).ping()
      check env.idpRequests[][0].field("scope") == some("other.scope")

    test "Given no scope in the challenge but scopes_supported, when the exchange is made, then it asks for those":
      let env = startEnv()
      defer: env.stop()
      env.rs.resourceMetadata["scopes_supported"] = %*["a", "b"]
      discard env.connect(env.config()).ping()
      check env.idpRequests[][0].field("scope") == some("a b")

    test "Given a 403 insufficient_scope, when the request is sent, then a new ID-JAG for the union is requested and the request succeeds":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "chat.read"
      env.rs.requiredScope = "chat.write"
      if ScopeChallenges:
        check env.connect(env.config()).ping(){"result", "served"}.getBool()
        check env.idpRequests[].len == 2
        check env.idpRequests[][1].field("scope") == some("chat.read chat.write")
      else:
        # Step-up is 2025-11-25 on: a 403 is the end of it.
        let t = env.connect(env.config())
        expect McpTransportError:
          discard t.ping()
        check env.idpRequests[].len == 1

    test "Given a 403 that names a scope already asked for, when it repeats, then the client does not ask again":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "chat.read"
      env.rs.requiredScope = "chat.admin"
      env.rs.insufficientScopeChallenge = "chat.read"
      let t = env.connect(env.config())
      expect McpTransportError:
        discard t.ping()
      check env.idpRequests[].len == 1

  suite "enterprise-managed authorization: what is advertised":

    proc refusedBeforeAnyExchange(env: Env, config: EnterpriseManagedConfig): string =
      ## The identity assertion is not even asked for, and nothing reaches the IdP
      ## or the authorization server's token endpoint.
      result = env.connect(config).failureOf()
      check env.providerCalls[] == 0
      check env.idpRequests[].len == 0
      check env.rasRequests[].len == 0

    test "Given an authorization server that does not list the ID-JAG profile, when a request is sent, then no identity assertion is used":
      let env = startEnv(grantProfiles = @[])
      defer: env.stop()
      check "authorization_grant_profiles_supported" in env.refusedBeforeAnyExchange(env.config())

    test "Given an authorization server that lists other profiles only, when a request is sent, then no identity assertion is used":
      let env = startEnv(grantProfiles = @["urn:example:other"])
      defer: env.stop()
      check GrantProfileIdJag in env.refusedBeforeAnyExchange(env.config())

    test "Given an authorization server that lists the profile but not the jwt-bearer grant, when a request is sent, then no identity assertion is used":
      let env = startEnv(rasGrantTypes = @["authorization_code"])
      defer: env.stop()
      check GrantTypeJwtBearer in env.refusedBeforeAnyExchange(env.config())

    test "Given an IdP that lists identity chaining token types without id-jag, when a request is sent, then the identity assertion is not sent to it":
      let env = startEnv(idpTokenTypes = @["urn:ietf:params:oauth:token-type:access_token"])
      defer: env.stop()
      let message = env.connect(env.config()).failureOf()
      check TokenTypeIdJag in message
      check env.idpRequests[].len == 0
      check env.providerCalls[] == 0

    test "Given an IdP that does not advertise identity chaining token types, when a request is sent, then the exchange is tried (the draft says SHOULD)":
      let env = startEnv(idpTokenTypes = @[])
      defer: env.stop()
      check env.connect(env.config()).ping(){"result", "served"}.getBool()

  suite "enterprise-managed authorization: what the client checks in the ID-JAG":

    proc refusedGrant(env: Env): string =
      ## The IdP answered, the client looked at the ID-JAG and did not send it on.
      result = env.connect(env.config()).failureOf()
      check env.idpRequests[].len == 1
      check env.rasRequests[].len == 0

    test "Given an ID-JAG whose typ is not oauth-id-jag+jwt, when it arrives, then it is not sent to the authorization server":
      let env = startEnv()
      defer: env.stop()
      env.behavior.typ = "JWT"
      check "typ" in env.refusedGrant()

    test "Given an ID-JAG issued by someone other than the IdP, when it arrives, then it is not sent on":
      let env = startEnv()
      defer: env.stop()
      env.behavior.issuer = some("https://evil.example")
      check "issued by" in env.refusedGrant()

    test "Given an ID-JAG for another audience, when it arrives, then it is not sent on":
      let env = startEnv()
      defer: env.stop()
      env.behavior.audience = some(%"https://other-as.example")
      check "not issued for" in env.refusedGrant()

    test "Given an ID-JAG whose aud is an array with another entry too, when it arrives, then it is not sent on":
      let env = startEnv()
      defer: env.stop()
      env.behavior.audience = some(%*[env.ras.issuer, "https://other-as.example"])
      check "not issued for" in env.refusedGrant()

    test "Given an ID-JAG whose aud is an array of exactly this authorization server, when it arrives, then it is accepted":
      let env = startEnv()
      defer: env.stop()
      env.behavior.audience = some(%*[env.ras.issuer])
      check env.connect(env.config()).ping(){"result", "served"}.getBool()

    test "Given an ID-JAG for another client, when it arrives, then it is not sent on":
      let env = startEnv()
      defer: env.stop()
      env.behavior.clientId = some("someone-else")
      check "client_id" in env.refusedGrant()

    test "Given an ID-JAG without the resource that was asked for, when it arrives, then it is not sent on":
      let env = startEnv()
      defer: env.stop()
      env.behavior.dropResource = true
      check "resource" in env.refusedGrant()

    test "Given an ID-JAG for another resource, when it arrives, then it is not sent on":
      let env = startEnv()
      defer: env.stop()
      env.behavior.resource = some(%"https://other-mcp.example/mcp")
      check "resource" in env.refusedGrant()

    test "Given an ID-JAG whose resource is an array that includes this server, when it arrives, then it is accepted":
      let env = startEnv()
      defer: env.stop()
      env.behavior.resource = some(%*["https://other-mcp.example/mcp", env.rs.url])
      check env.connect(env.config()).ping(){"result", "served"}.getBool()

    test "Given an ID-JAG that has already expired, when it arrives, then it is not sent on":
      let env = startEnv()
      defer: env.stop()
      env.behavior.lifetime = -10
      check "expired" in env.refusedGrant()

    test "Given an ID-JAG without sub, jti, iat or exp, when it arrives, then it is not sent on":
      for missing in ["sub", "jti", "iat", "exp"]:
        let env = startEnv()
        defer: env.stop()
        env.behavior.drop = @[missing]
        check missing in env.refusedGrant()

    test "Given an exchange response that is not an ID-JAG by its issued_token_type or token_type, when it arrives, then it is not sent on":
      let env = startEnv()
      defer: env.stop()
      env.behavior.issuedTokenType = "urn:ietf:params:oauth:token-type:access_token"
      check "issued a token of type" in env.refusedGrant()
      let other = startEnv()
      defer: other.stop()
      other.behavior.tokenType = "Bearer"
      check "token_type" in other.refusedGrant()

    test "Given a granted scope narrower than the request, when the ID-JAG arrives, then the exchange still succeeds":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "chat.read chat.history"
      env.behavior.grantScope = some("chat.read")
      check env.connect(env.config()).ping(){"result", "served"}.getBool()

  suite "enterprise-managed authorization: refusals and secrets":

    test "Given an IdP that refuses by policy, when a request is sent, then the failure names the error, nothing reaches the authorization server, and no token or secret is in the message":
      let env = startEnv()
      defer: env.stop()
      env.behavior.refuse = true
      let message = env.connect(env.config()).failureOf()
      check "invalid_grant" in message
      check IdToken notin message
      check Secret notin message
      check env.rasRequests[].len == 0

    test "Given a wrong client secret at the IdP, when a request is sent, then the failure does not contain the secret":
      let env = startEnv()
      defer: env.stop()
      let message = env.connect(env.config(idpClient = secretBasic("sso-client", "not-" & Secret))).failureOf()
      check "invalid_client" in message
      check Secret notin message
      check env.rasRequests[].len == 0

    test "Given an authorization server that refuses the ID-JAG, when a request is sent, then the failure contains neither the ID-JAG nor the identity assertion":
      let env = startEnv()
      defer: env.stop()
      let message = env.connect(env.config(
        rasClient = secretPost(McpClientId, "wrong-ras-secret"))).failureOf()
      check "invalid_client" in message
      let jag = env.rasRequests[][0].field("assertion").get
      check jag notin message
      check IdToken notin message
      check "wrong-ras-secret" notin message

    test "Given single sign-on that has to be repeated, when the provider raises, then the request fails with that reason and nothing is sent to the IdP":
      let env = startEnv()
      defer: env.stop()
      var config = env.config()
      config.identityAssertion = proc(): Future[IdentityAssertion] {.async.} =
        raise newException(ValueError, "the session ended; sign in again")
      let message = env.connect(config).failureOf()
      check "sign in again" in message
      check env.idpRequests[].len == 0
      check env.rasRequests[].len == 0

    test "Given an empty identity assertion, when a request is sent, then nothing is sent to the IdP":
      let env = startEnv()
      defer: env.stop()
      env.assertion[] = IdentityAssertion(kind: iakIdToken, token: "")
      discard env.connect(env.config()).failureOf()
      check env.idpRequests[].len == 0

    test "Given a whole flow, when the logs are read, then the identity assertion went to the IdP only and the ID-JAG to the authorization server only":
      let env = startEnv()
      defer: env.stop()
      let t = env.connect(env.config())
      discard t.ping()
      discard t.ping()
      let jag = env.rasRequests[][0].field("assertion").get
      for l in env.rs.log & env.ras.log:
        check IdToken notin l.body & l.path & l.query
        check IdToken notin $l.headers
      for l in env.rs.log & env.idp.log:
        check jag notin l.body & l.path & l.query
        check jag notin $l.headers
      for l in env.rs.log:
        check "ras-secret-value" notin l.body & $l.headers

    test "Given an IdP issuer that is plain http on a public host, when the auth is made, then it is refused":
      let env = startEnv()
      defer: env.stop()
      var config = env.config()
      config.idpIssuer = "http://idp.example.com"
      expect OAuthSecurityError:
        discard newEnterpriseManagedAuth(config)

    test "Given IdP metadata that names another issuer, when a request is sent, then the identity assertion is not sent":
      let env = startEnv()
      defer: env.stop()
      env.idp.metadata["issuer"] = %"https://other-idp.example"
      discard env.connect(env.config()).failureOf()
      check env.providerCalls[] == 0
      check env.idpRequests[].len == 0

    test "Given IdP metadata with a plain-http token endpoint on a public host, when a request is sent, then the identity assertion is not sent":
      let env = startEnv()
      defer: env.stop()
      env.idp.metadata["token_endpoint"] = %"http://idp.example.com/token"
      discard env.connect(env.config()).failureOf()
      check env.providerCalls[] == 0

  suite "enterprise-managed authorization: off unless used":

    test "Given a transport without the extension's auth, when the server answers 401, then the request fails and neither the IdP nor the authorization server is contacted":
      let env = startEnv()
      defer: env.stop()
      let t = newStreamableHttpTransport(env.rs.url)
      expect McpTransportError:
        discard t.ping()
      check env.idp.log.len == 0
      check env.ras.log.len == 0
      check env.providerCalls[] == 0

    test "Given a config that could never succeed, when the auth is made, then ValueError says why":
      let env = startEnv()
      defer: env.stop()
      var noProvider = env.config()
      noProvider.identityAssertion = nil
      expect ValueError: discard newEnterpriseManagedAuth(noProvider)
      expect ValueError: discard newEnterpriseManagedAuth(env.config(idpClient = publicClient("")))
      expect ValueError: discard newEnterpriseManagedAuth(env.config(rasClient = publicClient("")))
      var old = env.config()
      old.version = mpv20250326
      expect ValueError: discard newEnterpriseManagedAuth(old)
      var none = env.config()
      none.version = mpv20241105
      expect ValueError: discard newEnterpriseManagedAuth(none)

  suite "enterprise-managed authorization: checkIdentityAssertionGrant":

    proc jag(claims: JsonNode, typ = IdJagJwtType): string =
      hs256Signer("k").signJwt(claims, typ = some(typ))

    let now = fromUnix(1_800_000_000)
    let good = %*{"jti": "j", "iss": "https://idp.example", "sub": "u", "aud": "https://as.example",
                  "client_id": "c", "exp": 1_800_000_100, "iat": 1_799_999_900,
                  "resource": "https://mcp.example/mcp"}

    test "Given a well-formed ID-JAG, when checked, then the claims come back":
      let decoded = checkIdentityAssertionGrant(jag(good), "https://idp.example", "https://as.example",
                                                some("https://mcp.example/mcp"), "c", now)
      check decoded.claims{"sub"}.getStr() == "u"

    test "Given a resource written with a trailing slash on a bare origin, when checked, then it matches the canonical resource":
      var claims = good.copy()
      claims["resource"] = %"https://mcp.example/"
      discard checkIdentityAssertionGrant(jag(claims), "https://idp.example", "https://as.example",
                                          some("https://mcp.example"), "c", now)

    test "Given no resource expected, when the ID-JAG has none, then it is accepted":
      var claims = good.copy()
      claims.delete("resource")
      discard checkIdentityAssertionGrant(jag(claims), "https://idp.example", "https://as.example",
                                          none(string), "c", now)

    test "Given an ID-JAG that is not a JWT or has the wrong typ, when checked, then it is refused":
      expect OAuthError:
        discard checkIdentityAssertionGrant("not-a-jwt", "https://idp.example", "https://as.example",
                                            none(string), "c", now)
      expect OAuthSecurityError:
        discard checkIdentityAssertionGrant(jag(good, "at+jwt"), "https://idp.example",
                                            "https://as.example", none(string), "c", now)
      expect OAuthSecurityError:
        discard checkIdentityAssertionGrant(hs256Signer("k").signJwt(good), "https://idp.example",
                                            "https://as.example", none(string), "c", now)

    test "Given claims of the wrong JSON type, when checked, then they are refused":
      for (name, value) in [("aud", %5), ("aud", %*[1]), ("resource", %true), ("iss", %1),
                            ("client_id", %1), ("exp", %"soon"), ("sub", %""), ("jti", %3)]:
        var claims = good.copy()
        claims[name] = value
        var refused = false
        try:
          discard checkIdentityAssertionGrant(jag(claims), "https://idp.example",
                                              "https://as.example", some("https://mcp.example/mcp"),
                                              "c", now)
        except OAuthError:
          refused = true
        check refused

    test "Given an ID-JAG that expires at this very second, when checked, then it has expired":
      var claims = good.copy()
      claims["exp"] = %1_800_000_000
      try:
        discard checkIdentityAssertionGrant(jag(claims), "https://idp.example", "https://as.example",
                                            none(string), "c", now)
        fail()
      except OAuthError as e:
        check "expired" in e.msg

    test "Given an ID-JAG without iss or without client_id, when checked, then it is refused as not from the IdP or not for the client":
      for name in ["iss", "client_id"]:
        var claims = good.copy()
        claims.delete(name)
        expect OAuthSecurityError:
          discard checkIdentityAssertionGrant(jag(claims), "https://idp.example",
                                              "https://as.example", none(string), "c", now)

  suite "enterprise-managed authorization: how a challenge is answered":

    test "Given a 403 that is no insufficient_scope challenge, or a status that is no challenge, when handled, then the answer is no and nothing is exchanged":
      let env = startEnv()
      defer: env.stop()
      let auth = newEnterpriseManagedAuth(env.config())
      check not (waitFor auth.handleChallenge(403, @[]))
      check not (waitFor auth.handleChallenge(403, @["Bearer"]))
      check not (waitFor auth.handleChallenge(403, @["Bearer error=\"invalid_token\""]))
      check not (waitFor auth.handleChallenge(500, @["Bearer"]))
      check env.providerCalls[] == 0
      check env.idpRequests[].len == 0
      check env.rasRequests[].len == 0
      check env.rs.log.len == 0

    test "Given a 401 without any challenge header, when handled, then the exchange asks for the scopes the resource supports":
      let env = startEnv()
      defer: env.stop()
      env.rs.resourceMetadata["scopes_supported"] = %*["a"]
      let auth = newEnterpriseManagedAuth(env.config())
      if ScopeChallenges:
        check (waitFor auth.handleChallenge(401, @[]))
        check env.idpRequests[].len == 1
        check env.idpRequests[][0].field("scope") == some("a")
      else:
        # Before 2025-11-25 the metadata is found only through the challenge.
        expect OAuthError:
          discard waitFor auth.handleChallenge(401, @[])
        check env.idpRequests[].len == 0

    test "Given a 403 that names a scope already requested, when handled, then the answer is no and no second exchange is made":
      let env = startEnv()
      defer: env.stop()
      let auth = newEnterpriseManagedAuth(env.config())
      let metadata = "http://127.0.0.1:" & $env.rs.port & "/.well-known/oauth-protected-resource/mcp"
      check (waitFor auth.handleChallenge(401,
        @["Bearer resource_metadata=\"" & metadata & "\", scope=\"chat.read\""]))
      check env.idpRequests[].len == 1
      check not (waitFor auth.handleChallenge(403,
        @["Bearer error=\"insufficient_scope\", scope=\"chat.read\""]))
      check env.idpRequests[].len == 1
      check env.rasRequests[].len == 1

  suite "enterprise-managed authorization: the clock, the ID-JAG's reuse and a refused renewal":

    test "Given the default clock, when a request is sent, then the ID-JAG is judged against now and accepted":
      let env = startEnv()
      defer: env.stop()
      env.clock[] = getTime()
      let config = newEnterpriseManagedConfig(
        env.rs.url, env.idp.issuer, env.ras.issuer,
        secretBasic("sso-client", Secret), secretPost(McpClientId, "ras-secret-value"),
        proc(): Future[IdentityAssertion] {.async.} =
          return IdentityAssertion(kind: iakIdToken, token: IdToken))
      check env.connect(config).ping(){"result", "served"}.getBool()

    test "Given an access token that expires when the ID-JAG has 31 or 30 seconds left, when the next request is sent, then the first reuses the ID-JAG and the second asks the IdP for a new one":
      for (left, exchanges) in [(31, 1), (30, 2)]:
        let env = startEnv()
        defer: env.stop()
        env.behavior.lifetime = 7200            # the ID-JAG outlives the access token (3600 s)
        let t = env.connect(env.config())
        discard t.ping()
        env.clock[] = env.clock[] + initDuration(seconds = 7200 - left)
        check t.ping(){"result", "served"}.getBool()
        check env.idpRequests[].len == exchanges

    test "Given an expired access token and an IdP that now refuses, when requests fail, then the stale token is dropped and the next request exchanges once":
      let env = startEnv()
      defer: env.stop()
      let t = env.connect(env.config())
      discard t.ping()
      env.clock[] = env.clock[] + initDuration(seconds = 3700)
      env.behavior.refuse = true
      discard t.failureOf()
      let asked = env.idpRequests[].len
      discard t.failureOf()
      check env.idpRequests[].len == asked + 1

    test "Given an authorization server that grants a narrower scope than was asked, when the access token is stored, then its scopes are the granted ones":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "chat.read chat.history"
      env.behavior.grantScope = some("chat.read")
      let config = env.config()
      discard env.connect(config).ping()
      check config.tokenStore.load(canonicalResource(env.rs.url)).get.scopes == @["chat.read"]

    test "Given an authorization server that names no scope in its answer, when the access token is stored, then its scopes are the ones asked for":
      let env = startEnv()
      defer: env.stop()
      env.rs.challengeScope = "chat.read"
      env.behavior.grantScope = some("")
      let config = env.config()
      discard env.connect(config).ping()
      check config.tokenStore.load(canonicalResource(env.rs.url)).get.scopes ==
            (if ScopeChallenges: @["chat.read"] else: @[])

  suite "enterprise-managed authorization: the extensions capability":

    test "Given a client that declares the extension, when it sends a 2026-07-28 request, then clientCapabilities carries the identifier with empty settings":
      for v in versionsWith(ftExtensions):
        let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
          if message{"method"}.getStr() == "tools/list":
            peer.reply(message["id"], %*{"resultType": "complete", "tools": []}), modern = true)
        let client = peer.connectedClient(v, proc(c: McpClient) = c.declareEnterpriseManaged())
        discard waitFor client.callMethod("tools/list", newJObject())
        let caps = peer.requestsFor("tools/list")[0]["params"]["_meta"][
          "io.modelcontextprotocol/clientCapabilities"]
        check caps["extensions"][EnterpriseManagedExtensionId] == newJObject()

    test "Given a client that did not declare the extension, when it sends a request, then clientCapabilities has no extensions":
      for v in versionsWith(ftExtensions):
        let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
          if message{"method"}.getStr() == "tools/list":
            peer.reply(message["id"], %*{"resultType": "complete", "tools": []}), modern = true)
        let client = peer.connectedClient(v)
        discard waitFor client.callMethod("tools/list", newJObject())
        let caps = peer.requestsFor("tools/list")[0]["params"]["_meta"][
          "io.modelcontextprotocol/clientCapabilities"]
        check not caps.hasKey("extensions")

    test "Given a server that advertises the extension, when a 2026-07-28 client discovers it, then the capabilities list the identifier":
      for v in versionsWith(ftExtensions):
        let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
        server.advertiseEnterpriseManaged()
        let peer = server.connect(server.attach(), v)
        let answer = peer.ask("server/discover")
        check answer["result"]["capabilities"]["extensions"][EnterpriseManagedExtensionId] ==
              newJObject()

    test "Given a build that speaks no version with the extensions capability, when the extension is declared or advertised, then ValueError names the limit and nothing is registered":
      if not DefaultProtocolVersion.has(ftExtensions):
        let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
        expect ValueError: server.advertiseEnterpriseManaged()
        check server.capabilities.extensions.isNone
        let client = newMcpClient(McpClientInfo(name: "test-client", version: "0"),
                                  DefaultProtocolVersion)
        expect ValueError: client.declareEnterpriseManaged()
        check client.capabilities.extensions.isNone

    test "Given enableEnterpriseManaged, when called, then the transport authorizes with it and the extension is declared":
      if DefaultProtocolVersion.has(ftExtensions):
        let env = startEnv()
        defer: env.stop()
        let client = newMcpClient(McpClientInfo(name: "test-client", version: "0"),
                                  DefaultProtocolVersion)
        let t = newStreamableHttpTransport(env.rs.url)
        let auth = enableEnterpriseManaged(client, t, env.config())
        check not auth.isNil
        check not t.auth.isNil
        check client.capabilities.extensions.get.hasKey(EnterpriseManagedExtensionId)
        check t.ping(){"result", "served"}.getBool()

else:
  import std/[unittest, asyncdispatch]
  import auth/oauth/grants
  import ext/auth_enterprise_managed

  suite "enterprise-managed authorization: versions without Protected Resource Metadata":
    test "Given a version before Protected Resource Metadata, when the auth is made, then ValueError says the extension needs it":
      let config = newEnterpriseManagedConfig(
        "https://mcp.example/mcp", "https://idp.example", "https://as.example",
        secretBasic("sso", "a-secret"), secretPost("mcp", "another-secret"),
        proc(): Future[IdentityAssertion] {.async.} =
          return IdentityAssertion(kind: iakIdToken, token: "t"),
        DefaultProtocolVersion)
      expect ValueError:
        discard newEnterpriseManagedAuth(config)
