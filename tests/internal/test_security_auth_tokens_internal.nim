## Security property of the token parsers: a number in a token response
## cannot overflow the clock, and a value that cannot be a lifetime is an
## error instead of a token that never expires.

import std/[unittest, options, strutils, times, asyncdispatch, asynchttpserver, httpcore, json]
import auth/client
import protocol/[version, features]
import auth/oauth/[errors, fetch, authcode, tokens]
import ../external/auth_fixtures

const
  RedirectUri = "http://127.0.0.1:53682/callback"
  ChallengeVersion = block:
    ## The newest version of the build that reads the metadata URL of a
    ## challenge: 2025-03-26 looks at the server's own origin instead and
    ## 2024-11-05 has no authorization. None where the build speaks no such
    ## version; the tests that need one are skipped there.
    var found = none(McpProtocolVersion)
    for v in SupportedProtocolVersions:
      if v.has(ftProtectedResourceMetadata):
        found = some(v)
    found
  HasChallengeVersion = ChallengeVersion.isSome

proc expiryAfter(body: string, now: Time): Option[Time] =
  ## What the client stores as the expiry after an authorization in which
  ## the token endpoint answered with this body.
  let authServer = startFakeAs()
  let resourceServer = startFakeRs(authServer)
  let tokenEndpoint = newAsyncHttpServer()
  tokenEndpoint.listen(Port(0), "127.0.0.1")
  defer:
    tokenEndpoint.close()
    resourceServer.stop()
    authServer.stop()
  authServer.metadata["token_endpoint"] =
    %("http://127.0.0.1:" & $tokenEndpoint.getPort.int & "/token")
  let answer = proc(req: Request) {.async, gcsafe.} =
    await req.respond(Http200, body, newHttpHeaders({"Content-Type": "application/json"}))
  asyncCheck tokenEndpoint.acceptRequest(answer)
  let stored = new(Option[TokenSet])
  let authorize = proc(url: string): Future[seq[(string, string)]] {.async.} =
    return authServer.consent(url)
  var config = newOAuthClientConfig(resourceServer.url, RedirectUri, authorize,
                                    ChallengeVersion.get)
  config.now = proc(): Time {.closure, gcsafe, raises: [].} = now
  config.tokenStore.save = proc(key: string, value: TokenSet) {.closure, gcsafe, raises: [].} =
    stored[] = some(value)
  let challenge = @["Bearer resource_metadata=\"http://127.0.0.1:" & $resourceServer.port &
                    "/.well-known/oauth-protected-resource/mcp\""]
  check waitFor newOAuthClient(config).handleChallenge(401, challenge)
  stored[].get.expiresAt

proc expiryOf(expiresIn: string, now: Time): Option[Time] =
  expiryAfter("""{"access_token":"a","token_type":"Bearer","expires_in":""" & expiresIn & "}", now)

suite "token responses: lifetimes":

  let now = fromUnix(1_800_000_000)


suite "token lifetimes and stores (mutation review, g2f-oauth-b)":

  let now = fromUnix(1_800_000_000)

  proc expiryOf(expiresIn: string): Option[Time] =
    let body = """{"access_token":"a","token_type":"Bearer","expires_in":""" & expiresIn & "}"
    parseTokenResponse(HttpReply(code: 200, body: body), "https://as.example", @[], none(string), now)
      .expiresAt


  test "Given an expires_in of zero, as an integer or a float, when the response is parsed, then the token expires at once":
    check expiryOf("0") == some(now)
    check expiryOf("0.0") == some(now)

  test "Given an expires_in of exactly the largest lifetime as a float, when the response is parsed, then it still counts":
    check expiryOf($MaxTokenLifetimeSeconds & ".0") ==
      some(now + initDuration(seconds = MaxTokenLifetimeSeconds))

  test "Given a digit string of eighteen characters with leading zeros, when the response is parsed, then it counts by its value":
    check expiryOf("\"000000000000003600\"") == some(now + initDuration(seconds = 3600))

  test "Given strings that are not a number of seconds in digits, when the response is parsed, then each is refused":
    for bad in ["\"+3600\"", "\"1_000\"", "\" 3600\"", "\"3600 \"", "\"0x10\""]:
      checkpoint bad
      expect OAuthError:
        discard expiryOf(bad)

  test "Given a lone minus sign, when the response is parsed, then it is refused as not a number rather than as a negative one":
    try:
      discard expiryOf("\"-\"")
      fail()
    except OAuthError as e:
      check "not a number" in e.msg
      check "negative" notin e.msg

  test "Given a negative digit string, when the response is parsed, then it is refused as negative":
    try:
      discard expiryOf("\"-5\"")
      fail()
    except OAuthError as e:
      check "negative" in e.msg

