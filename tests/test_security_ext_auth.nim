## Security property of the authorization extensions: the credentials of an
## extension are configured for one authorization server, and a resource
## server that names another gets nothing, not even the identity assertion.
## The resource server in these tests is the hostile one: its Protected
## Resource Metadata lists an authorization server it controls.

import std/[unittest, asyncdispatch, json, options, strutils]
import ext/auth_client_credentials
import ext/auth_enterprise_managed
import auth/oauth/errors
import ext_auth_fixtures

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

suite "client credentials: the credential belongs to one issuer":

  test "Given no issuer for the credential, when the auth is made, then it is refused and the message says how to fix it":
    let env = start()
    defer: env.stop()
    var config = newClientCredentialsConfig(env.rs.url, "svc", "")
    config.secret = some(Secret)
    var message = ""
    try:
      discard newClientCredentialsAuth(config)
      fail()
    except ValueError as e:
      message = e.msg
    check "issuer" in message
    check Secret notin message

  test "Given a client secret for one issuer, when the resource names another, then no request reaches that server and the error names both":
    let env = start()
    defer: env.stop()
    var config = newClientCredentialsConfig(env.rs.url, "svc", LegitIssuer)
    config.secret = some(Secret)
    let message = env.failureOf(newClientCredentialsAuth(config))
    check LegitIssuer in message
    check env.attacker.issuer in message
    check Secret notin message
    check env.attacker.log.len == 0

  test "Given a signing key for one issuer, when the resource names another, then no assertion is made out to that server":
    let env = start()
    defer: env.stop()
    var config = newClientCredentialsConfig(env.rs.url, "jwt-client", LegitIssuer)
    config.signer = some(hs256Signer(JwtKey))
    let message = env.failureOf(newClientCredentialsAuth(config))
    check LegitIssuer in message
    check env.attacker.issuer in message
    check env.attacker.log.len == 0

suite "enterprise-managed authorization: the grant is for one authorization server":

  proc idpAssertionConfig(env: Env, calls: ref int): EnterpriseManagedConfig =
    result = newEnterpriseManagedConfig(
      env.rs.url, LegitIdp, LegitIssuer, secretBasic("sso-client", Secret),
      secretPost("mcp-client", "ras-secret-value"),
      proc(): Future[IdentityAssertion] {.async.} =
        inc calls[]
        return IdentityAssertion(kind: iakIdToken, token: "id-token-of-the-user"))

  test "Given no authorization server for the resource client, when the auth is made, then it is refused and the message says how to fix it":
    let env = start()
    defer: env.stop()
    let calls = new(int)
    var config = idpAssertionConfig(env, calls)
    config.resourceIssuer = ""
    var message = ""
    try:
      discard newEnterpriseManagedAuth(config)
      fail()
    except ValueError as e:
      message = e.msg
    check "resourceIssuer" in message

  test "Given credentials for one authorization server, when the resource names another, then neither the IdP nor that server is contacted and the assertion is not read":
    let env = start()
    defer: env.stop()
    let calls = new(int)
    let message = env.failureOf(newEnterpriseManagedAuth(idpAssertionConfig(env, calls)))
    check LegitIssuer in message
    check env.attacker.issuer in message
    check Secret notin message
    check "ras-secret-value" notin message
    check env.attacker.log.len == 0
    check calls[] == 0
