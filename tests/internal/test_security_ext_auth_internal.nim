## Security property of the authorization extensions: the credentials of an
## extension are configured for one authorization server, and a resource
## server that names another gets nothing, not even the identity assertion.
## The resource server in these tests is the hostile one: its Protected
## Resource Metadata lists an authorization server it controls.

import protocol/version
import protocol/features

when DefaultProtocolVersion.has(ftProtectedResourceMetadata):
  import std/[unittest, asyncdispatch, json, options, strutils, times]
  import ext/auth_client_credentials
  import ext/auth_enterprise_managed
  import auth/oauth/[errors, fetch, grants, tokens, jwt]
  import ../external/ext_auth_fixtures except DecodedJwt, decodeJwtUnverified, signJwt,
      GrantTypeClientCredentials, GrantTypeJwtBearer, GrantTypeTokenExchange

  const
    LegitIssuer = "https://as.legit.example"
    LegitIdp = "https://idp.legit.example"
    Secret = "s3cret-value-for-legit-as-Qx81"
    JwtKey = "jwt-signing-key-do-not-leak"

  type Env = object
    attacker: FakeAs
    rs: FakeRs

  proc start(): Env =
    result.attacker = startFakeAs(registration = false)
    result.rs = startFakeRs(result.attacker)
    result.attacker.metadata["token_endpoint_auth_methods_supported"] =
      %*["private_key_jwt", "client_secret_basic", "client_secret_post"]
    result.attacker.metadata["token_endpoint_auth_signing_alg_values_supported"] = %*["HS256"]

  proc stop(e: Env) =
    e.rs.stop()
    e.attacker.stop()

  proc challengeOf(e: Env): seq[string] =
    @["Bearer resource_metadata=\"http://127.0.0.1:" & $e.rs.port &
      "/.well-known/oauth-protected-resource/mcp\""]

  proc failureOf[T](e: Env, auth: T): string =
    try:
      discard waitFor auth.handleChallenge(401, e.challengeOf)
      fail()
    except OAuthError as ex:
      result = ex.msg


  suite "enterprise-managed authorization: the grant is for one authorization server":

    proc idpAssertionConfig(env: Env, calls: ref int): EnterpriseManagedConfig =
      result = newEnterpriseManagedConfig(
        env.rs.url, LegitIdp, LegitIssuer, secretBasic("sso-client", Secret),
        secretPost("mcp-client", "ras-secret-value"),
        proc(): Future[IdentityAssertion] {.async.} =
          inc calls[]
          return IdentityAssertion(kind: iakIdToken, token: "id-token-of-the-user"))


  suite "the authorization extensions fetch loopback only for a server the user chose":
    const LoopbackChallenge =
      @["Bearer resource_metadata=\"http://127.0.0.1:1/.well-known/oauth-protected-resource\""]

    proc refusal[T](auth: T): string =
      try:
        discard waitFor auth.handleChallenge(401, LoopbackChallenge)
      except OAuthSecurityError as e:
        result = e.msg

    proc remoteServerConfig(calls: ref int): EnterpriseManagedConfig =
      result = newEnterpriseManagedConfig(
        "https://mcp.example.test/mcp", LegitIdp, LegitIssuer,
        secretBasic("sso-client", Secret), secretPost("mcp-client", "ras-secret-value"),
        proc(): Future[IdentityAssertion] {.async.} =
          inc calls[]
          return IdentityAssertion(kind: iakIdToken, token: "id-token-of-the-user"))


  suite "enterprise-managed authorization: numbers in an ID-JAG and in an exchange response":

    proc jag(claims: JsonNode): string =
      hs256Signer("k").signJwt(claims, typ = some(IdJagJwtType))

    proc claimsWith(exp: JsonNode): JsonNode =
      %*{"jti": "j", "iss": "https://idp.example", "sub": "u", "aud": "https://as.example",
         "client_id": "c", "exp": exp, "iat": 1_799_999_900}

    let now = fromUnix(1_800_000_000)

    proc grantChecked(claims: JsonNode): DecodedJwt =
      checkIdentityAssertionGrant(jag(claims), "https://idp.example", "https://as.example",
                                  none(string), "c", now)

    test "Given an exp or iat that is a fractional number, which a NumericDate may be, when checked, then it is accepted":
      discard grantChecked(claimsWith(%1_800_000_100.5))
      var claims = claimsWith(%1_800_000_100)
      claims["iat"] = %1_799_999_900.25
      discard grantChecked(claims)

    test "Given a fractional exp that has passed, when checked, then the ID-JAG has expired":
      expect OAuthError:
        discard grantChecked(claimsWith(%1_799_999_999.5))

    test "Given an exp beyond what a grant can plausibly live, when checked, then it is refused and nothing overflows":
      for far in [%9_223_372_036_854_775_807, %1e300, %1e18, %(1_800_000_000 + MaxTokenLifetimeSeconds + 1)]:
        checkpoint $far
        expect OAuthError:
          discard grantChecked(claimsWith(far))

    test "Given an exp at the largest lifetime or a negative one, when checked, then the first is accepted and the second has expired":
      discard grantChecked(claimsWith(%(1_800_000_000 + MaxTokenLifetimeSeconds)))
      for past in [%(-9_223_372_036_854_775_807 - 1), %(-1), %(-1e300)]:
        checkpoint $past
        expect OAuthError:
          discard grantChecked(past.claimsWith)

    test "Given an expires_in that is huge, negative or not a number in a token exchange response, when parsed, then it is no expiry, an error, an error":
      func body(expiresIn: string): HttpReply =
        HttpReply(code: 200, body: """{"access_token":"jag","issued_token_type":"urn:ietf:params:oauth:token-type:id-jag","token_type":"N_A","expires_in":""" & expiresIn & "}")
      check parseTokenExchangeResponse(body("9223372036854775807"), now).expiresAt.isNone
      check parseTokenExchangeResponse(body("\"3600\""), now).expiresAt ==
        some(now + initDuration(seconds = 3600))
      for bad in ["-1", "\"soon\"", "[1]"]:
        checkpoint bad
        expect OAuthError:
          discard parseTokenExchangeResponse(body(bad), now)
