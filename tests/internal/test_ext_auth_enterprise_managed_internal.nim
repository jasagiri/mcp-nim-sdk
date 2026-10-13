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
  import ext/auth_enterprise_managed
  import auth/oauth/[errors, grants, jwt, tokens, urls]
  import ../external/server_harness
  import ../external/ext_auth_fixtures except DecodedJwt, decodeJwtUnverified, signJwt,
      GrantTypeClientCredentials, GrantTypeJwtBearer, GrantTypeTokenExchange,
    TokenTypeAccessToken, TokenTypeRefreshToken, TokenTypeIdToken, TokenTypeSaml2

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


    test "Given a SAML assertion or a refresh token instead of an ID token, when a request is sent, then subject_token_type says which":
      for (kind, token, urn) in [(iakSaml2, "saml-alice-SECRET", TokenTypeSaml2),
                                 (iakRefreshToken, "refresh-alice-SECRET", TokenTypeRefreshToken)]:
        let env = startEnv()
        defer: env.stop()
        env.assertion[] = IdentityAssertion(kind: kind, token: token)
        check env.connect(env.config()).ping(){"result", "served"}.getBool()
        check env.idpRequests[][0].field("subject_token_type") == some(urn)


    test "Given a refresh token from the authorization server, when the access token is stored, then it is not kept (the ID-JAG renews access)":
      let env = startEnv()
      defer: env.stop()
      env.rasRefresh[] = true
      let config = env.config()
      discard env.connect(config).ping()
      check config.tokenStore.load(canonicalResource(env.rs.url)).get.refreshToken.isNone


  suite "enterprise-managed authorization: what is advertised":

    proc refusedBeforeAnyExchange(env: Env, config: EnterpriseManagedConfig): string =
      ## The identity assertion is not even asked for, and nothing reaches the IdP
      ## or the authorization server's token endpoint.
      result = env.connect(config).failureOf()
      check env.providerCalls[] == 0
      check env.idpRequests[].len == 0
      check env.rasRequests[].len == 0


    test "Given an authorization server that lists the profile but not the jwt-bearer grant, when a request is sent, then no identity assertion is used":
      let env = startEnv(rasGrantTypes = @["authorization_code"])
      defer: env.stop()
      check GrantTypeJwtBearer in env.refusedBeforeAnyExchange(env.config())


  suite "enterprise-managed authorization: what the client checks in the ID-JAG":

    proc refusedGrant(env: Env): string =
      ## The IdP answered, the client looked at the ID-JAG and did not send it on.
      result = env.connect(env.config()).failureOf()
      check env.idpRequests[].len == 1
      check env.rasRequests[].len == 0


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


  suite "enterprise-managed authorization: the clock, the ID-JAG's reuse and a refused renewal":


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
