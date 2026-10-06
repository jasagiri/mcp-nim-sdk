## Security property of the authorization client (core flow): credentials
## configured for one authorization server are never sent to the one an MCP
## server points at. The resource server and the authorization server in
## these tests are the hostile ones: the MCP server names an authorization
## server it controls in its Protected Resource Metadata.

import std/[unittest, asyncdispatch, json, options, strutils, tables, times]
import transport/transport
import transport/http
import protocol/types
import protocol/version
import protocol/features
import auth/client
import auth_fixtures

const
  RedirectUri = "http://127.0.0.1:53682/callback"
  LegitIssuer = "https://as.legit.example"
  Secret = "s3cret-value-for-legit-as-Qx81"

const authVersions = block:
  var vs: seq[McpProtocolVersion]
  for v in SupportedProtocolVersions:
    if v.has(ftAuthorization):
      vs.add v
  vs

type Env = object
  attacker: FakeAs
  rs: FakeRs
  config: OAuthClientConfig
  consents: ref seq[string]

proc start(v: McpProtocolVersion): Env =
  ## A resource server whose metadata names `attacker` as the authorization
  ## server. 2025-03-26 has no resource metadata and keeps both on one origin.
  result.attacker = startFakeAs()
  result.rs = startFakeRs(result.attacker, sharedOrigin = v == mpv20250326)
  if v == mpv20250326:
    result.rs.advertiseInChallenge = false
  result.consents = new(seq[string])
  let (attacker, consents) = (result.attacker, result.consents)
  let authorize: UserAuthorizer = proc(url: string): Future[seq[(string, string)]] {.async.} =
    consents[].add url
    return attacker.consent(url)
  result.config = newOAuthClientConfig(result.rs.url, RedirectUri, authorize, v)

proc stop(e: Env) =
  e.rs.stop()
  e.attacker.stop()

proc challengeOf(e: Env): seq[string] =
  if e.rs.advertiseInChallenge:
    @["Bearer resource_metadata=\"http://127.0.0.1:" & $e.rs.port &
      "/.well-known/oauth-protected-resource/mcp\""]
  else:
    @["Bearer"]

proc failureOf(e: Env, client: OAuthClient): string =
  try:
    discard waitFor client.handleChallenge(401, e.challengeOf)
    fail()
  except OAuthError as ex:
    result = ex.msg

proc reachedAttacker(e: Env): seq[string] =
  ## Paths the attacker's servers were asked for other than the metadata.
  for l in e.attacker.log:
    if not l.path.startsWith("/.well-known/"):
      result.add l.path

proc refreshAfterHalfFailedChallenge(v: McpProtocolVersion) =
  ## The first server is honest; then the resource names a second one that is
  ## refused for lacking PKCE metadata, which leaves the client holding the
  ## second server's metadata and the first one's tokens. A proc: a closure
  ## over a module-level variable is not gcsafe.
  let honest = startFakeAs()
  defer: honest.stop()
  let rs = startFakeRs(honest)
  defer: rs.stop()
  let other = startFakeAs()
  defer: other.stop()
  other.metadata.delete("code_challenge_methods_supported")
  let clock = new(Time)
  clock[] = getTime()
  var config = newOAuthClientConfig(rs.url, RedirectUri, authorizerFor(honest), v)
  config.now = proc(): Time {.closure, gcsafe, raises: [].} = clock[]
  let transport = newStreamableHttpTransport(rs.url)
  transport.auth = newOAuthClient(config).asHttpAuth()
  proc ping() =
    waitFor transport.sendRequest(newJsonRpcRequest("1", "ping", newJObject()))
    discard waitFor transport.receiveMessage()
  ping()
  check honest.refreshTokens.len == 1
  rs.resourceMetadata["authorization_servers"] = %[other.issuer]
  honest.accessTokens.clear()
  expect McpTransportError:
    ping()
  clock[] = clock[] + initDuration(hours = 2)
  expect McpTransportError:
    ping()
  for l in other.log:
    check l.path.startsWith("/.well-known/")

suite "authorization client: credentials belong to one issuer":

  for v in authVersions:
    test "Given a client secret without an issuer and version " & $v &
         ", when the client is made, then it is refused and the message says how to fix it":
      var env = start(v)
      defer: env.stop()
      env.config.preRegistered = some(PreRegisteredClient(
        clientId: "confidential", clientSecret: some(Secret), issuer: none(string)))
      var message = ""
      try:
        discard newOAuthClient(env.config)
        fail()
      except ValueError as e:
        message = e.msg
      check "issuer" in message
      check Secret notin message
      check env.attacker.log.len == 0

    test "Given a client secret for one issuer and version " & $v &
         ", when the resource names another, then nothing but metadata reaches it and the error names both":
      var env = start(v)
      defer: env.stop()
      env.config.preRegistered = some(PreRegisteredClient(
        clientId: "confidential", clientSecret: some(Secret), issuer: some(LegitIssuer)))
      let message = env.failureOf(newOAuthClient(env.config))
      check LegitIssuer in message
      check env.attacker.issuer in message
      check Secret notin message
      check env.reachedAttacker == newSeq[string]()
      check env.consents[].len == 0

    test "Given a public pre-registered client for one issuer and version " & $v &
         ", when the resource names another, then the user is not sent there":
      var env = start(v)
      defer: env.stop()
      env.config.preRegistered = some(PreRegisteredClient(
        clientId: "public", clientSecret: none(string), issuer: some(LegitIssuer)))
      let message = env.failureOf(newOAuthClient(env.config))
      check LegitIssuer in message
      check env.consents[].len == 0
      check env.reachedAttacker == newSeq[string]()

  for v in authVersions:
    if v.has(ftIncrementalScopeConsent):
      test "Given tokens of one issuer and a later challenge that met another and failed, when the tokens have expired, then the refresh token is not sent to the other server (version " & $v & ")":
        refreshAfterHalfFailedChallenge(v)
