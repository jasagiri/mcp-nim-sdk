## The token endpoint requests the authorization extensions are built from,
## and the JWTs they carry (src/auth/oauth/jwt.nim and grants.nim). Nothing
## here is MCP: a fake token endpoint that authenticates clients strictly.

import std/[unittest, asyncdispatch, base64, httpcore, json, options, strutils, times, tables, sets]
import auth/oauth/[errors, fetch, grants, jwt, tokens, urls]
import ext_auth_fixtures

const Secret = "s3cret-value-7Fjfp0ZB"

proc grantServer(registry: ClientRegistry, seen: ref seq[GrantRequest],
                 now: Time): FakeAs =
  result = startFakeAs()
  let a = result
  serveGrants(a, proc(req: GrantRequest): GrantAnswer {.closure, gcsafe.} =
    seen[].add req
    let client = registry.authenticate(req, now)
    if client.isNone:
      return oauthFailure("invalid_client")
    case req.field("grant_type").get("")
    of GrantTypeClientCredentials:
      GrantAnswer(code: Http200, body: a.issueAccessToken(
        req.field("scope").get(""), req.field("resource").get(""), client.get))
    of GrantTypeJwtBearer:
      GrantAnswer(code: Http200, body: a.issueAccessToken(
        req.field("scope").get(""), "", client.get))
    of GrantTypeTokenExchange:
      GrantAnswer(code: Http200, body: %*{
        "issued_token_type": req.field("requested_token_type").get(TokenTypeAccessToken),
        "access_token": "exchanged-" & req.field("subject_token").get(""),
        "token_type": "N_A", "expires_in": 300,
        "scope": req.field("scope").get("")})
    else:
      oauthFailure("unsupported_grant_type"))

proc endpointOf(a: FakeAs): string = a.metadata["token_endpoint"].getStr()

let policy = defaultFetchPolicy()

suite "JWTs":

  test "Given RFC 4231 test case 1, when HMAC-SHA256 of the fixtures is computed, then it matches (the signer the other tests rely on is right)":
    var digest = ""
    for c in hmacSha256(repeat('\x0b', 20), "Hi There"):
      digest.add toHex(c.ord, 2).toLowerAscii()
    check digest == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"

  test "Given claims and a signer, when signed and decoded, then header, claims and signature come back and verify":
    let signer = hs256Signer("key-1", some("kid-1"))
    let token = signer.signJwt(%*{"sub": "abc"}, typ = some("test+jwt"))
    let decoded = decodeJwtUnverified(token)
    check decoded.header{"alg"}.getStr() == "HS256"
    check decoded.header{"typ"}.getStr() == "test+jwt"
    check decoded.header{"kid"}.getStr() == "kid-1"
    check decoded.claims{"sub"}.getStr() == "abc"
    check decoded.hs256Valid("key-1")
    check not decoded.hs256Valid("key-2")

  test "Given the algorithm none or an empty signer, when a signer is made, then it is refused":
    let nothing = proc(input: string): string {.closure, gcsafe, raises: [].} = "x"
    expect ValueError:
      discard newJwtSigner("none", nothing)
    expect ValueError:
      discard newJwtSigner("NoNe", nothing)
    expect ValueError:
      discard newJwtSigner("", nothing)
    expect ValueError:
      discard newJwtSigner("RS256", nil)

  test "Given a signer that raises or returns nothing, when signing, then OAuthError names neither the key nor the message":
    let failing = newJwtSigner("RS256", proc(input: string): string {.closure, gcsafe.} =
      raise newException(IOError, "cannot read /keys/private-" & Secret & ".pem"))
    try:
      discard failing.signJwt(%*{"a": 1})
      fail()
    except OAuthError as e:
      check Secret notin e.msg
      check "private" notin e.msg
    let empty = newJwtSigner("RS256", proc(input: string): string {.closure, gcsafe.} = "")
    expect OAuthError:
      discard empty.signJwt(%*{"a": 1})

  test "Given malformed JWTs, when decoded, then each is refused":
    let good = hs256Signer("k").signJwt(%*{"a": 1})
    let parts = good.split('.')
    for bad in ["", "a.b", "a.b.c.d", parts[0] & "." & parts[1], "!!." & parts[1] & "." & parts[2],
                parts[0] & ".bm90LWpzb24." & parts[2],  # payload is not JSON
                parts[0] & ".WzFd." & parts[2],         # payload is an array
                "e30." & parts[1] & "." & parts[2],     # header {} has no alg
                good & repeat('A', MaxJwtLength)]:
      expect OAuthError:
        discard decodeJwtUnverified(bad)

  test "Given a client assertion, when decoded, then iss and sub are the client, aud the server, and every one is fresh":
    let now = fromUnix(1_700_000_000)
    let signer = hs256Signer("k")
    let a = decodeJwtUnverified(signer.clientAssertion("client-1", "https://as.example", now))
    let b = decodeJwtUnverified(signer.clientAssertion("client-1", "https://as.example", now))
    check a.claims{"iss"}.getStr() == "client-1"
    check a.claims{"sub"}.getStr() == "client-1"
    check a.claims{"aud"}.getStr() == "https://as.example"
    check a.claims{"iat"}.getInt() == 1_700_000_000
    check a.claims{"exp"}.getInt() == 1_700_000_060
    check a.claims{"jti"}.getStr().len >= 20
    check a.claims{"jti"}.getStr() != b.claims{"jti"}.getStr()

  test "Given a signer with no signing function or no algorithm, when signing, then OAuthError says it is not set up":
    expect OAuthError:
      discard JwtSigner(alg: "HS256").signJwt(%*{"a": 1})
    let noAlgorithm = JwtSigner(sign: proc(input: string): string {.closure, gcsafe.} = "x")
    expect OAuthError:
      discard noAlgorithm.signJwt(%*{"a": 1})

  test "Given a JWT whose signature is empty or not base64url, when decoded, then it is refused":
    let parts = hs256Signer("k").signJwt(%*{"a": 1}).split('.')
    for signature in ["", "ab+d", "ab=="]:
      expect OAuthError:
        discard decodeJwtUnverified(parts[0] & "." & parts[1] & "." & signature)

  test "Given payloads and signatures of every length modulo three, when decoded, then the bytes come back from segments without padding":
    proc b64(text: string): string =
      base64.encode(text, safe = true).strip(leading = false, chars = {'='})
    for width in 0 .. 5:
      let claims = %*{"k": repeat('x', width)}
      let signature = repeat('s', width + 1)
      let token = b64("""{"alg":"HS256"}""") & "." & b64($claims) & "." & b64(signature)
      checkpoint token
      let decoded = decodeJwtUnverified(token)
      check decoded.claims == claims
      check decoded.signature == signature

  test "Given a segment with one character more than whole groups, when decoded, then the character that makes no byte is left out":
    let parts = hs256Signer("k").signJwt(%*{"a": 1}).split('.')
    check decodeJwtUnverified(parts[0] & "." & parts[1] & ".YWJjZ").signature == "abc"
    expect OAuthError:
      discard decodeJwtUnverified("YWJjZ." & parts[1] & "." & parts[2])

  test "Given a header whose alg is missing, not a string or empty, when decoded, then it is refused":
    proc b64(text: string): string =
      base64.encode(text, safe = true).strip(leading = false, chars = {'='})
    for header in ["""{"typ":"JWT"}""", """{"alg":5}""", """{"alg":""}""", """{"alg":null}"""]:
      expect OAuthError:
        discard decodeJwtUnverified(b64(header) & "." & b64("{}") & "." & "c2ln")

  test "Given a JWT of exactly the largest accepted length and one a byte longer, when decoded, then the first is read and the second refused":
    let signer = hs256Signer("k")
    var token = ""
    for filler in 0 .. 8:
      let parts = signer.signJwt(%*{"p": repeat('x', filler)}).split('.')
      let rest = MaxJwtLength - parts[0].len - parts[1].len - 2
      if rest mod 4 != 1:  # a base64 text cannot be 1 mod 4 characters long
        token = parts[0] & "." & parts[1] & "." & repeat('A', rest)
        break
    check token.len == MaxJwtLength
    check decodeJwtUnverified(token).header{"alg"}.getStr() == "HS256"
    try:
      discard decodeJwtUnverified(token & "A")
      fail()
    except OAuthError as e:
      check "longer than" in e.msg

  test "Given a client assertion without a client_id or without an audience, when made, then OAuthError refuses either":
    let signer = hs256Signer("k")
    expect OAuthError:
      discard signer.clientAssertion("", "https://as.example", fromUnix(1_700_000_000))
    expect OAuthError:
      discard signer.clientAssertion("client-1", "", fromUnix(1_700_000_000))

suite "grants at a token endpoint":

  proc setup(): (ClientRegistry, ref seq[GrantRequest], FakeAs) =
    let seen = new(seq[GrantRequest])
    let a = block:
      let registry = newRegistry(@[])
      registry.secrets["svc"] = Secret
      registry.secrets["we ird:id"] = "p@ss word"
      registry.publicClients.incl "public-app"
      registry.jwtKeys["jwt-client"] = "jwt-key"
      let server = grantServer(registry, seen, getTime())
      registry.audiences = @[server.issuer, server.endpointOf]
      (registry, server)
    (a[0], seen, a[1])

  test "Given a client secret sent with HTTP Basic, when client credentials are requested, then the secret is in the header only and a token comes back":
    let (_, seen, a) = setup()
    defer: a.stop()
    let t = waitFor clientCredentialsGrant(a.endpointOf, a.issuer, secretBasic("svc", Secret),
                                           @["mcp:read", "mcp:write"], some("https://mcp.example"),
                                           policy)
    check t.accessToken.startsWith("at-ext-")
    check t.issuer == a.issuer
    check t.scopes == @["mcp:read", "mcp:write"]
    check t.refreshToken.isNone
    check seen[][0].field("grant_type") == some("client_credentials")
    check seen[][0].field("scope") == some("mcp:read mcp:write")
    check seen[][0].field("resource") == some("https://mcp.example")
    check seen[][0].field("client_secret").isNone
    check seen[][0].field("client_id").isNone
    check seen[][0].authorization.startsWith("Basic ")

  test "Given a client id and secret with characters that need form encoding, when sent with Basic, then the server decodes them as RFC 6749 2.3.1 says":
    let (_, _, a) = setup()
    defer: a.stop()
    let t = waitFor clientCredentialsGrant(a.endpointOf, a.issuer,
                                           secretBasic("we ird:id", "p@ss word"), @[], none(string), policy)
    check t.accessToken.len > 0

  test "Given a client secret sent in the body, when client credentials are requested, then client_id and client_secret are form fields and there is no Authorization header":
    let (_, seen, a) = setup()
    defer: a.stop()
    discard waitFor clientCredentialsGrant(a.endpointOf, a.issuer, secretPost("svc", Secret),
                                           @[], none(string), policy)
    check seen[][0].field("client_id") == some("svc")
    check seen[][0].field("client_secret") == some(Secret)
    check seen[][0].authorization == ""
    check seen[][0].field("scope").isNone

  test "Given a signing key, when client credentials are requested with private_key_jwt, then the assertion authenticates and client_id is not sent":
    let (_, seen, a) = setup()
    defer: a.stop()
    let auth = privateKeyJwt("jwt-client", hs256Signer("jwt-key"), a.issuer)
    let t = waitFor clientCredentialsGrant(a.endpointOf, a.issuer, auth, @["s"], none(string), policy)
    check t.accessToken.len > 0
    check seen[][0].field("client_assertion_type").isSome
    check seen[][0].field("client_id").isNone
    check seen[][0].field("client_secret").isNone

  test "Given an assertion signed with another key, when client credentials are requested, then the server refuses and the error shows no secret":
    let (_, _, a) = setup()
    defer: a.stop()
    let auth = privateKeyJwt("jwt-client", hs256Signer("wrong-key"), a.issuer)
    try:
      discard waitFor clientCredentialsGrant(a.endpointOf, a.issuer, auth, @[], none(string), policy)
      fail()
    except OAuthServerError as e:
      check e.error == "invalid_client"
      check "wrong-key" notin e.msg

  test "Given a wrong client secret, when requested, then OAuthServerError carries the error and not the secret":
    let (_, _, a) = setup()
    defer: a.stop()
    try:
      discard waitFor clientCredentialsGrant(a.endpointOf, a.issuer,
                                             secretBasic("svc", "not-" & Secret), @[], none(string), policy)
      fail()
    except OAuthServerError as e:
      check e.error == "invalid_client"
      check Secret notin e.msg

  test "Given an ID-JAG like assertion, when the JWT bearer grant is requested, then grant_type and assertion are sent and the client authenticates separately":
    let (_, seen, a) = setup()
    defer: a.stop()
    let t = waitFor jwtBearerGrant(a.endpointOf, a.issuer, "the.assertion.here",
                                   secretPost("svc", Secret), @[], policy)
    check t.accessToken.len > 0
    check seen[][0].field("grant_type") == some("urn:ietf:params:oauth:grant-type:jwt-bearer")
    check seen[][0].field("assertion") == some("the.assertion.here")
    check seen[][0].field("scope").isNone

  test "Given scopes, when the JWT bearer grant is requested, then they are sent as one scope parameter":
    let (_, seen, a) = setup()
    defer: a.stop()
    discard waitFor jwtBearerGrant(a.endpointOf, a.issuer, "the.assertion.here",
                                   secretPost("svc", Secret), @["a", "b"], policy)
    check seen[][0].field("scope") == some("a b")

  test "Given a private_key_jwt client without a lifetime, when client credentials are requested, then the assertion lives one minute":
    let (_, seen, a) = setup()
    defer: a.stop()
    let auth = privateKeyJwt("jwt-client", hs256Signer("jwt-key"), a.issuer, DurationZero)
    discard waitFor clientCredentialsGrant(a.endpointOf, a.issuer, auth, @["s"], none(string),
                                           policy, getTime())
    let claims = decodeJwtUnverified(seen[][0].field("client_assertion").get).claims
    check claims{"exp"}.getInt() - claims{"iat"}.getInt() == 60

  test "Given a subject token, when exchanged, then every RFC 8693 parameter is sent and the issued token is returned with its type and lifetime":
    let (_, seen, a) = setup()
    defer: a.stop()
    let now = fromUnix(1_700_000_000)
    let r = waitFor exchangeToken(a.endpointOf, TokenExchangeRequest(
      subjectToken: "id-token-1", subjectTokenType: TokenTypeIdToken,
      requestedTokenType: some("urn:ietf:params:oauth:token-type:id-jag"),
      audience: some("https://as.example/"), resource: some("https://mcp.example/"),
      scopes: @["a", "b"]), secretPost("svc", Secret), policy, now)
    check r.accessToken == "exchanged-id-token-1"
    check r.issuedTokenType == "urn:ietf:params:oauth:token-type:id-jag"
    check r.tokenType == "N_A"
    check r.scopes == some(@["a", "b"])
    check r.expiresAt == some(now + initDuration(seconds = 300))
    let f = seen[][0]
    check f.field("grant_type") == some("urn:ietf:params:oauth:grant-type:token-exchange")
    check f.field("subject_token_type") == some(TokenTypeIdToken)
    check f.field("audience") == some("https://as.example/")
    check f.field("resource") == some("https://mcp.example/")
    check f.field("scope") == some("a b")

  test "Given a subject token and no scopes, when exchanged, then no scope parameter is sent":
    let (_, seen, a) = setup()
    defer: a.stop()
    discard waitFor exchangeToken(a.endpointOf, TokenExchangeRequest(
      subjectToken: "id-token-1", subjectTokenType: TokenTypeIdToken), secretPost("svc", Secret), policy)
    check seen[][0].field("scope").isNone

  test "Given an empty subject token, when exchanged, then nothing is sent":
    let (_, seen, a) = setup()
    defer: a.stop()
    expect OAuthError:
      discard waitFor exchangeToken(a.endpointOf, TokenExchangeRequest(
        subjectToken: "", subjectTokenType: TokenTypeIdToken), publicClient("public-app"), policy)
    check seen[].len == 0

  test "Given token exchange responses with a missing field, when parsed, then each is refused":
    let ok = %*{"access_token": "t", "issued_token_type": "x", "token_type": "N_A"}
    for missing in ["access_token", "issued_token_type", "token_type"]:
      var doc = ok.copy()
      doc.delete(missing)
      expect OAuthError:
        discard parseTokenExchangeResponse(HttpReply(code: 200, body: $doc), getTime())
    expect OAuthError:
      discard parseTokenExchangeResponse(HttpReply(code: 200, body: "[]"), getTime())
    expect OAuthError:
      discard parseTokenExchangeResponse(HttpReply(code: 200, body: "not json"), getTime())
    expect OAuthServerError:
      discard parseTokenExchangeResponse(HttpReply(code: 400, body: """{"error":"invalid_grant"}"""), getTime())
