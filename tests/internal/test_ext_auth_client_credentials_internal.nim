## The OAuth Client Credentials extension (ext-auth draft, specification/draft/
## oauth-client-credentials.mdx): a real StreamableHttpTransport against a
## resource server that answers 401 and an authorization server that
## authenticates clients strictly and checks `resource`, `scope` and the
## assertion. Plus what the extension is not: off unless used.

import protocol/version
import protocol/features

when DefaultProtocolVersion.has(ftProtectedResourceMetadata):
  import std/[unittest, asyncdispatch, httpcore, json, options, tables, times]
  import transport/transport
  import transport/http
  import protocol/types
  import ext/auth_client_credentials
  import auth/oauth/jwt
  import ../external/server_harness
  import ../external/ext_auth_fixtures except DecodedJwt, decodeJwtUnverified, signJwt,
      GrantTypeClientCredentials, GrantTypeJwtBearer, GrantTypeTokenExchange

  const
    ScopeChallenges = DefaultProtocolVersion.has(ftIncrementalScopeConsent)
      ## Scope in a challenge and step-up on 403 exist from 2025-11-25.
    Secret = "s3cret-value-7Fjfp0ZB"
    JwtKey = "jwt-signing-key-do-not-leak"

  type Env = object
    authServer: FakeAs
    rs: FakeRs
    registry: ClientRegistry
    requests: ref seq[GrantRequest]
    clock: ref Time
    lifetime: ref int

  proc startEnv(authMethods = @["private_key_jwt", "client_secret_basic", "client_secret_post"],
                algs = @["HS256"], grantTypes: seq[string] = @[]): Env =
    result.requests = new(seq[GrantRequest])
    result.clock = new(Time)
    result.clock[] = fromUnix(1_800_000_000)
    result.lifetime = new(int)
    result.lifetime[] = 3600
    result.authServer = startFakeAs(registration = false)
    result.rs = startFakeRs(result.authServer)
    result.registry = newRegistry(@[])
    result.registry.secrets["svc"] = Secret
    result.registry.jwtKeys["jwt-client"] = JwtKey
    let a = result.authServer
    let rsUrl = result.rs.url
    let (registry, requests, clock, lifetime) = (result.registry, result.requests, result.clock,
                                                 result.lifetime)
    if authMethods.len > 0:
      a.metadata["token_endpoint_auth_methods_supported"] = %authMethods
    if algs.len > 0:
      a.metadata["token_endpoint_auth_signing_alg_values_supported"] = %algs
    if grantTypes.len > 0:
      a.metadata["grant_types_supported"] = %grantTypes
    serveGrants(a, proc(req: GrantRequest): GrantAnswer {.closure, gcsafe.} =
      requests[].add req
      if req.field("grant_type").get("") != "client_credentials":
        return oauthFailure("unsupported_grant_type")
      let client = registry.authenticate(req, clock[])
      if client.isNone:
        return oauthFailure("invalid_client")
      if req.field("resource").get("") != rsUrl:
        return oauthFailure("invalid_target", "resource mismatch")
      GrantAnswer(code: Http200, body: a.issueAccessToken(
        req.field("scope").get(""), rsUrl, client.get, lifetime[])))
    result.registry.audiences = @[a.issuer, a.metadata["token_endpoint"].getStr()]

  proc stop(e: Env) =
    e.rs.stop()
    e.authServer.stop()

  proc configFor(e: Env, clientId: string): ClientCredentialsConfig =
    result = newClientCredentialsConfig(e.rs.url, clientId, e.authServer.issuer)
    let clock = e.clock
    result.now = proc(): Time {.closure, gcsafe, raises: [].} = clock[]

  proc withSecret(e: Env, secret = Secret): ClientCredentialsConfig =
    result = e.configFor("svc")
    result.secret = some(secret)

  proc withKey(e: Env, key = JwtKey): ClientCredentialsConfig =
    result = e.configFor("jwt-client")
    result.signer = some(hs256Signer(key))

  proc transportFor(auth: ClientCredentialsAuth, url: string): StreamableHttpTransport =
    result = newStreamableHttpTransport(url)
    result.auth = auth.asHttpAuth()

  proc ping(t: StreamableHttpTransport): JsonNode =
    waitFor t.sendRequest(newJsonRpcRequest("1", "ping", newJObject()))
    waitFor t.receiveMessage()

  proc bearerOf(l: Logged): string = $l.headers.getOrDefault("Authorization")

  suite "client credentials: the flow":


    test "Given a signing key, when a request is sent, then the assertion names the issuer as audience, client_id is not in the body, and the retry succeeds":
      let env = startEnv()
      defer: env.stop()
      let t = transportFor(newClientCredentialsAuth(env.withKey()), env.rs.url)
      check t.ping(){"result", "served"}.getBool()
      let r = env.requests[][0]
      check r.field("client_assertion_type").isSome
      check r.field("client_id").isNone
      check decodeJwtUnverified(r.field("client_assertion").get).claims{"aud"}.getStr() ==
            env.authServer.issuer

    test "Given a server that expects the token endpoint as audience, when the config asks for it, then the assertion carries the token endpoint URL":
      let env = startEnv()
      defer: env.stop()
      env.registry.audiences = @[env.authServer.metadata["token_endpoint"].getStr()]
      var config = env.withKey()
      config.assertionAudience = aaTokenEndpoint
      let t = transportFor(newClientCredentialsAuth(config), env.rs.url)
      check t.ping(){"result", "served"}.getBool()
      check decodeJwtUnverified(env.requests[][0].field("client_assertion").get).claims{"aud"}.getStr() ==
            env.authServer.metadata["token_endpoint"].getStr()


  suite "client credentials: what the authorization server must advertise":

    proc refused(env: Env, config: ClientCredentialsConfig): string =
      ## The message of the failure; the token endpoint must not have been called.
      let t = transportFor(newClientCredentialsAuth(config), env.rs.url)
      try:
        discard t.ping()
        fail()
      except McpTransportError as e:
        result = e.msg
      check env.requests[].len == 0
