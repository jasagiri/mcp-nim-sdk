## Security property of the token parsers: a number in a token response
## cannot overflow the clock, and a value that cannot be a lifetime is an
## error instead of a token that never expires.

import std/[unittest, options, strutils, times, asyncdispatch, asynchttpserver, httpcore, json]
import auth/client
import protocol/[version, features]
import auth_fixtures

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

  test "Given expires_in as an integer, when the response is parsed, then the token expires that many seconds from now":
    when HasChallengeVersion:
      check expiryOf("3600", now) == some(now + initDuration(seconds = 3600))
    else:
      skip()

  test "Given no expires_in or null, when the response is parsed, then the expiry is unknown":
    when HasChallengeVersion:
      let body = """{"access_token":"a","token_type":"Bearer"}"""
      check expiryAfter(body, now).isNone
      check expiryOf("null", now).isNone
    else:
      skip()

  test "Given expires_in as a decimal string, which some servers send, when the response is parsed, then it counts":
    when HasChallengeVersion:
      check expiryOf("\"3600\"", now) == some(now + initDuration(seconds = 3600))
    else:
      skip()

  test "Given expires_in as a float, when the response is parsed, then it is rounded down to whole seconds":
    when HasChallengeVersion:
      check expiryOf("3599.9", now) == some(now + initDuration(seconds = 3599))
    else:
      skip()

  test "Given an expires_in beyond the largest lifetime the client believes, when the response is parsed, then the expiry is unknown and nothing overflows":
    when HasChallengeVersion:
      for huge in ["9223372036854775807", "99999999999999999999", "1e300", "315360001",
                   "\"9223372036854775807\"", "\"99999999999999999999999999\""]:
        checkpoint huge
        check expiryOf(huge, now).isNone
    else:
      skip()

  test "Given expires_in at the largest lifetime, when the response is parsed, then it still counts":
    when HasChallengeVersion:
      check expiryOf($MaxTokenLifetimeSeconds, now) ==
        some(now + initDuration(seconds = MaxTokenLifetimeSeconds))
    else:
      skip()

  test "Given a negative or non-numeric expires_in, when the response is parsed, then the response is refused":
    when HasChallengeVersion:
      for bad in ["-1", "-9223372036854775808", "-0.5", "\"-5\"", "\"soon\"", "\"\"", "\"1e3\"",
                  "true", "[3600]", "{}"]:
        checkpoint bad
        expect OAuthError:
          discard expiryOf(bad, now)
    else:
      skip()

  test "Given a refused expires_in, when the error is read, then it does not contain the token":
    when HasChallengeVersion:
      try:
        discard expiryOf("-1", now)
        fail()
      except OAuthError as e:
        check "-1" in e.msg
        check "\"a\"" notin e.msg
    else:
      skip()
suite "token lifetimes and stores (mutation review, g2f-oauth-b)":

  let now = fromUnix(1_800_000_000)

  test "Given a token that has been removed from a memory store, when loaded, then there is none, and the others stay":
    let store = newMemoryStore[TokenSet]()
    store.save("one", TokenSet(accessToken: "a"))
    store.save("two", TokenSet(accessToken: "b"))
    check store.load("one").isSome
    store.remove("one")
    check store.load("one").isNone
    check store.load("two").get.accessToken == "b"

  test "Given an expiry inside the default skew, at its edge, outside it, or past, when asked if the token is expired, then only the outside is not":
    proc expiring(seconds: int): TokenSet =
      TokenSet(accessToken: "a", expiresAt: some(now + initDuration(seconds = seconds)))
    check expiring(10).isExpired(now)
    check expiring(30).isExpired(now)
    check not expiring(31).isExpired(now)
    check not expiring(3600).isExpired(now)
    check expiring(-10).isExpired(now)
    check expiring(-3600).isExpired(now)
    check not TokenSet(accessToken: "a").isExpired(now)

  test "Given a skew of zero, when asked at the very second of the expiry, then the token is expired, and a second earlier it is not":
    let tokens = TokenSet(accessToken: "a", expiresAt: some(now))
    check tokens.isExpired(now, skew = initDuration())
    check not tokens.isExpired(now - initDuration(seconds = 1), skew = initDuration())


  test "Given no JSON object at all, when a lifetime is read, then it is unknown":
    check tokenExpiry(nil, "expires_in", now).isNone
    check tokenExpiry(%*[3600], "expires_in", now).isNone
