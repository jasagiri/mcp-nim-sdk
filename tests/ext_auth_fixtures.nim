## What the tests of the authorization extensions need on top of
## `auth_fixtures`: token endpoints for the grants the core flow does not
## use, a registry that authenticates clients the way RFC 6749 2.3.1 and
## RFC 7523 2.2 say, and an HMAC-SHA256 signer.
##
## The signer is HS256 because the standard library and this SDK have no
## asymmetric signature. The SDK itself asks the application for a signing
## function (`JwtSigner`); in the tests that function is a symmetric one, and
## the fake servers verify it with the same key.

import std/[asyncdispatch, asynchttpserver, base64, httpcore, json, options,
            sets, strutils, tables, times, uri]
import auth/oauth/[jwt, sha256, urls]
import auth_fixtures

export auth_fixtures

proc hmacSha256*(key, message: string): string =
  const Block = 64
  var k = key
  if k.len > Block:
    let digest = sha256(k)
    k = newString(32)
    for i in 0 ..< 32:
      k[i] = char(digest[i])
  while k.len < Block:
    k.add '\0'
  var inner, outer = newString(Block)
  for i in 0 ..< Block:
    inner[i] = char(k[i].ord xor 0x36)
    outer[i] = char(k[i].ord xor 0x5c)
  let innerDigest = sha256(inner & message)
  var innerBytes = newString(32)
  for i in 0 ..< 32:
    innerBytes[i] = char(innerDigest[i])
  let digest = sha256(outer & innerBytes)
  result = newString(32)
  for i in 0 ..< 32:
    result[i] = char(digest[i])

proc hs256Signer*(key: string, keyId = none(string)): JwtSigner =
  newJwtSigner("HS256", proc(input: string): string {.closure, gcsafe, raises: [].} =
    hmacSha256(key, input), keyId)

proc hs256Valid*(jwt: DecodedJwt, key: string): bool =
  jwt.header{"alg"}.getStr() == "HS256" and jwt.signature == hmacSha256(key, jwt.signingInput)

type
  GrantRequest* = object
    form*: seq[(string, string)]
    authorization*: string

  GrantAnswer* = object
    code*: HttpCode
    body*: JsonNode

  GrantHandler* = proc(req: GrantRequest): GrantAnswer {.closure, gcsafe.}

  ClientRegistry* = ref object
    ## Who may authenticate at a fake token endpoint, and how.
    secrets*: Table[string, string]
    jwtKeys*: Table[string, string]
    publicClients*: HashSet[string]
    audiences*: seq[string]
      ## What the `aud` of a client assertion may be.
    seenJti: HashSet[string]

func field*(r: GrantRequest, name: string): Option[string] =
  for (k, v) in r.form:
    if k == name:
      return some(v)
  none(string)

func newRegistry*(audiences: seq[string]): ClientRegistry =
  ClientRegistry(audiences: audiences)

proc oauthFailure*(error: string, description = ""): GrantAnswer =
  GrantAnswer(code: Http400, body: %*{"error": error, "error_description": description})

proc authenticate*(reg: ClientRegistry, req: GrantRequest, now: Time): Option[string] =
  ## The client that proved who it is, or none. A request that tries two
  ## methods at once is refused (RFC 6749 2.3: not more than one).
  let hasBasic = req.authorization.startsWith("Basic ")
  let assertion = req.field("client_assertion")
  let bodySecret = req.field("client_secret")
  if (hasBasic.int + assertion.isSome.int + bodySecret.isSome.int) > 1:
    return none(string)
  if hasBasic:
    let decoded = base64.decode(req.authorization["Basic ".len .. ^1])
    let parts = decoded.split(':', 1)
    if parts.len != 2:
      return none(string)
    let id = decodeUrl(parts[0], decodePlus = true)
    let secret = decodeUrl(parts[1], decodePlus = true)
    if reg.secrets.getOrDefault(id, "\0no") == secret:
      return some(id)
  elif assertion.isSome:
    if req.field("client_assertion_type").get("") !=
       "urn:ietf:params:oauth:client-assertion-type:jwt-bearer":
      return none(string)
    if req.field("client_id").isSome:
      return none(string)  # RFC 7523 3: identified by `sub`
    let jwt =
      try: decodeJwtUnverified(assertion.get)
      except CatchableError: return none(string)
    let id = jwt.claims{"sub"}.getStr()
    if jwt.claims{"iss"}.getStr() != id or id notin reg.jwtKeys:
      return none(string)
    if not jwt.hs256Valid(reg.jwtKeys[id]):
      return none(string)
    if jwt.claims{"aud"}.getStr() notin reg.audiences:
      return none(string)
    let exp = jwt.claims{"exp"}.getBiggestInt()
    if exp <= now.toUnix or exp - now.toUnix > 600:
      return none(string)
    let jti = jwt.claims{"jti"}.getStr()
    if jti.len == 0 or jti in reg.seenJti:
      return none(string)
    reg.seenJti.incl jti
    return some(id)
  elif bodySecret.isSome:
    let id = req.field("client_id").get("")
    if reg.secrets.getOrDefault(id, "\0no") == bodySecret.get:
      return some(id)
  else:
    let id = req.field("client_id").get("")
    if id in reg.publicClients:
      return some(id)
  none(string)

proc serveGrants*(a: FakeAs, handler: GrantHandler, path = "/oauth2/token") =
  ## Moves the token endpoint of `a` to `path`, which `FakeAs` forwards to its
  ## fallback, and answers there with `handler`.
  a.metadata["token_endpoint"] = %("http://127.0.0.1:" & $a.port & path)
  a.fallback = proc(req: Request): Future[void] {.closure, gcsafe.} =
    if req.url.path == path and req.reqMethod == HttpPost:
      let answer = handler(GrantRequest(
        form: formDecode(req.body),
        authorization: $req.headers.getOrDefault("Authorization")))
      req.respond(answer.code, $answer.body,
                  newHttpHeaders({"Content-Type": "application/json",
                                  "Cache-Control": "no-store"}))
    else:
      req.respond(Http404, "")

proc issueAccessToken*(a: FakeAs, scope, resource, clientId: string,
                       lifetime = 3600): JsonNode =
  ## A token response; the token is known to the resource server fixture.
  let token = "at-ext-" & $(a.accessTokens.len + 1)
  a.accessTokens[token] = IssuedToken(scope: scope, resource: resource, clientId: clientId)
  %*{"access_token": token, "token_type": "Bearer", "scope": scope, "expires_in": lifetime}
