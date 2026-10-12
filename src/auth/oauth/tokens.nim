## What a client keeps between requests: tokens, and the client credentials
## an authorization server issued. Where they live is the application's
## decision, so both go through a `Store` it can replace; the default keeps
## them in memory only.

import std/[json, math, options, strutils, tables, times]
import ./errors

const
  MaxTokenLifetimeSeconds* = 10 * 365 * 24 * 60 * 60
    ## The longest `expires_in` the client takes at its word: ten years. RFC
    ## 6749 5.1 sets no bound and servers that mean "does not expire" send
    ## values from 2^31 - 1 down to a decade, so a larger one is not refused;
    ## it is read as "no expiry given", which the client already handles (the
    ## server's 401 corrects it). The bound exists so that no number in a
    ## response, however large, reaches the arithmetic on `Time`.

type
  TokenSet* = object
    accessToken*: string
    refreshToken*: Option[string]
    expiresAt*: Option[Time]
    scopes*: seq[string]
      ## What the server granted, or what was requested when it did not say.
    issuer*: string
      ## The authorization server that issued the tokens.

  ClientCredentials* = object
    ## A client's identity at one authorization server (RFC 6749 2.2: client
    ## identifiers are unique to the server that issued them).
    issuer*: string
    clientId*: string
    clientSecret*: Option[string]
    authMethod*: string
      ## "none", "client_secret_basic" or "client_secret_post".
    redirectUris*: seq[string]

  Store*[T] = object
    ## Persistence the application supplies. Keys are chosen by the client.
    load*: proc(key: string): Option[T] {.closure, gcsafe, raises: [].}
    save*: proc(key: string, value: T) {.closure, gcsafe, raises: [].}
    remove*: proc(key: string) {.closure, gcsafe, raises: [].}

  TokenStore* = Store[TokenSet]
  CredentialStore* = Store[ClientCredentials]

proc newMemoryStore*[T](): Store[T] =
  let entries = new(Table[string, T])
  entries[] = initTable[string, T]()
  Store[T](
    load: proc(key: string): Option[T] {.closure, gcsafe, raises: [].} =
      if entries[].hasKey(key): some(entries[].getOrDefault(key)) else: none(T),
    save: proc(key: string, value: T) {.closure, gcsafe, raises: [].} =
      entries[][key] = value,
    remove: proc(key: string) {.closure, gcsafe, raises: [].} =
      entries[].del(key))

func isExpired*(tokens: TokenSet, now: Time, skew = initDuration(seconds = 30)): bool
               {.raises: [].} =
  ## Whether the access token should not be sent any more. A token without
  ## an expiry is assumed valid; the server's 401 corrects that.
  tokens.expiresAt.isSome and tokens.expiresAt.get - skew <= now

proc tokenExpiry*(body: JsonNode, field: string, now: Time): Option[Time]
                 {.raises: [OAuthError].} =
  ## When a token lasts until, from the lifetime in seconds at `field`
  ## (`expires_in`, RFC 6749 5.1; RFC 8693 2.2.1). RFC 6749 calls the value a
  ## number, and servers send it as an integer, as a float (`3599.9`: rounded
  ## down, the token is not kept past its life) and as a string of digits.
  ##  - missing or null: none, the lifetime is unknown;
  ##  - more than `MaxTokenLifetimeSeconds`, or too large for an integer: none;
  ##  - negative, not a number, or any other JSON type: OAuthError, because
  ##    the response cannot be read, and a token read as "never expires" for
  ##    that reason would be kept long after the server dropped it.
  if body.isNil or body.kind != JObject:
    return none(Time)
  let value = body{field}
  if value.isNil or value.kind == JNull:
    return none(Time)
  var seconds: BiggestInt
  case value.kind
  of JInt:
    if value.getBiggestInt() < 0:
      raise newException(OAuthError, field & " is negative: " & $value.getBiggestInt())
    seconds = value.getBiggestInt()
  of JFloat:
    let f = value.getFloat()
    if f != f:
      raise newException(OAuthError, field & " is not a number")
    if f < 0.0:
      raise newException(OAuthError, field & " is negative: " & $f)
    if f > float(MaxTokenLifetimeSeconds):
      return none(Time)
    seconds = BiggestInt(floor(f))
  of JString:
    # A digit string of 19 characters or more is taken as beyond the bound
    # without being converted (the JSON parser hands an integer too large for
    # 64 bits over as a string as well). Its value is not looked at, so
    # leading zeros do not shorten it: "0000000000000003600" is an unknown
    # lifetime, which a 401 corrects. It was not trimmed because no
    # authorization server sends such a string.
    let text = value.getStr()
    if text.len > 0 and text[0] == '-' and text.len > 1 and text[1 .. ^1].allCharsInSet(Digits):
      raise newException(OAuthError, field & " is negative")
    if text.len == 0 or not text.allCharsInSet(Digits):
      raise newException(OAuthError, field & " is not a number of seconds")
    if text.len > 18:
      return none(Time)
    try:
      seconds = parseBiggestInt(text)
    except ValueError:
      raise newException(OAuthError, field & " is not a number of seconds")
  else:
    raise newException(OAuthError, field & " is neither a number nor a string of digits")
  if seconds > MaxTokenLifetimeSeconds:
    return none(Time)
  some(now + initDuration(seconds = seconds))
