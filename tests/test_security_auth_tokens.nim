## Security property of the token parsers: a number in a token response
## cannot overflow the clock, and a value that cannot be a lifetime is an
## error instead of a token that never expires.

import std/[unittest, options, strutils, times]
import auth/oauth/[errors, fetch, authcode, tokens]

suite "token responses: lifetimes":

  let now = fromUnix(1_800_000_000)

  func reply(body: string): HttpReply =
    HttpReply(code: 200, body: body)

  proc expiryOf(expiresIn: string): Option[Time] =
    let body = """{"access_token":"a","token_type":"Bearer","expires_in":""" & expiresIn & "}"
    parseTokenResponse(reply(body), "https://as.example", @[], none(string), now).expiresAt

  test "Given expires_in as an integer, when the response is parsed, then the token expires that many seconds from now":
    check expiryOf("3600") == some(now + initDuration(seconds = 3600))

  test "Given no expires_in or null, when the response is parsed, then the expiry is unknown":
    let body = """{"access_token":"a","token_type":"Bearer"}"""
    check parseTokenResponse(reply(body), "https://as.example", @[], none(string), now)
      .expiresAt.isNone
    check expiryOf("null").isNone

  test "Given expires_in as a decimal string, which some servers send, when the response is parsed, then it counts":
    check expiryOf("\"3600\"") == some(now + initDuration(seconds = 3600))

  test "Given expires_in as a float, when the response is parsed, then it is rounded down to whole seconds":
    check expiryOf("3599.9") == some(now + initDuration(seconds = 3599))

  test "Given an expires_in beyond the largest lifetime the client believes, when the response is parsed, then the expiry is unknown and nothing overflows":
    for huge in ["9223372036854775807", "99999999999999999999", "1e300", "315360001",
                 "\"9223372036854775807\"", "\"99999999999999999999999999\""]:
      checkpoint huge
      check expiryOf(huge).isNone

  test "Given expires_in at the largest lifetime, when the response is parsed, then it still counts":
    check expiryOf($MaxTokenLifetimeSeconds) ==
      some(now + initDuration(seconds = MaxTokenLifetimeSeconds))

  test "Given a negative or non-numeric expires_in, when the response is parsed, then the response is refused":
    for bad in ["-1", "-9223372036854775808", "-0.5", "\"-5\"", "\"soon\"", "\"\"", "\"1e3\"",
                "true", "[3600]", "{}"]:
      checkpoint bad
      expect OAuthError:
        discard expiryOf(bad)

  test "Given a refused expires_in, when the error is read, then it does not contain the token":
    try:
      discard expiryOf("-1")
      fail()
    except OAuthError as e:
      check "-1" in e.msg
      check "\"a\"" notin e.msg

import std/json

suite "token lifetimes and stores (mutation review, g2f-oauth-b)":

  let now = fromUnix(1_800_000_000)

  proc expiryOf(expiresIn: string): Option[Time] =
    let body = """{"access_token":"a","token_type":"Bearer","expires_in":""" & expiresIn & "}"
    parseTokenResponse(HttpReply(code: 200, body: body), "https://as.example", @[], none(string), now)
      .expiresAt

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

  test "Given no JSON object at all, when a lifetime is read, then it is unknown":
    check tokenExpiry(nil, "expires_in", now).isNone
    check tokenExpiry(%*[3600], "expires_in", now).isNone
