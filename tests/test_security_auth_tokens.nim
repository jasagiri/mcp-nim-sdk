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
