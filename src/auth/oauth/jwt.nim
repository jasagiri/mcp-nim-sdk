## Compact JWTs (RFC 7519, RFC 7515) as the OAuth extensions use them: a
## client assertion (RFC 7523 2.2) that the client signs, and an assertion
## from someone else that the client only reads.
##
## Signing is the application's: the standard library has no RSA or ECDSA and
## this SDK does not implement them. `JwtSigner` wraps the proc the
## application supplies (usually a binding to its crypto library or a call to
## a KMS). Reading does not verify anything: `decodeJwtUnverified` says so in
## its name, and whoever needs a verified claim has to verify the signature
## with the issuer's key first.
##
## Nothing here puts a token, key or signature into an exception message.

import std/[base64, json, options, strutils, times]
import ./errors
import ./pkce

const MaxJwtLength* = 16 * 1024
  ## A JWT longer than this is refused unread: assertions are a few hundred
  ## bytes, and what arrives from the network is bounded.

type
  JwtSigner* = object
    ## The algorithm, the key identifier a verifier looks the key up by, and
    ## the signing function.
    alg*: string
    keyId*: Option[string]
    sign*: proc(signingInput: string): string {.closure, gcsafe, raises: [CatchableError].}
      ## The raw signature (not base64) of `signingInput`, the ASCII
      ## `base64url(header) "." base64url(payload)`. May raise.

  DecodedJwt* = object
    ## The parts of a JWT that parsed. NOT verified.
    header*: JsonNode
    claims*: JsonNode
    signingInput*: string
    signature*: string

proc newJwtSigner*(alg: string, sign: proc(signingInput: string): string {.closure, gcsafe, raises: [CatchableError].},
                   keyId = none(string)): JwtSigner {.raises: [ValueError].} =
  ## Raises for the algorithm "none", which would make the assertion a
  ## claim nobody signed, and for a missing algorithm or function.
  if alg.len == 0:
    raise newException(ValueError, "a JWT signer needs an algorithm")
  if alg.toLowerAscii() == "none":
    raise newException(ValueError, "the JWT algorithm 'none' is not a signature")
  if sign.isNil:
    raise newException(ValueError, "a JWT signer needs a signing function")
  JwtSigner(alg: alg, keyId: keyId, sign: sign)

func b64(text: string): string {.raises: [].} =
  base64UrlNoPad(toOpenArrayByte(text, 0, text.high))

proc signJwt*(signer: JwtSigner, claims: JsonNode, typ = none(string)): string
             {.raises: [OAuthError].} =
  ## The compact serialization of `claims` signed by `signer`.
  if signer.sign.isNil or signer.alg.len == 0:
    raise newException(OAuthError, "the JWT signer is not set up")
  var header = %*{"alg": signer.alg}
  if typ.isSome:
    header["typ"] = %typ.get
  if signer.keyId.isSome:
    header["kid"] = %signer.keyId.get
  let signingInput = b64($header) & "." & b64($claims)
  var signature: string
  try:
    signature = signer.sign(signingInput)
  except CatchableError as e:
    # The message is the signer's own and may name a key or a path.
    raise newException(OAuthError, "the JWT signer failed (" & $e.name & ")")
  if signature.len == 0:
    raise newException(OAuthError, "the JWT signer returned no signature")
  signingInput & "." & b64(signature)

func decodeSegment(segment, what: string): string {.raises: [OAuthError].} =
  if segment.len == 0 or not segment.allCharsInSet(
       {'A'..'Z', 'a'..'z', '0'..'9', '-', '_'}):
    raise newException(OAuthError, "the JWT " & what & " is not base64url")
  var standard = segment.replace('-', '+').replace('_', '/')
  while standard.len mod 4 != 0:
    standard.add '='
  try:
    base64.decode(standard)
  except ValueError:
    raise newException(OAuthError, "the JWT " & what & " is not base64url")

proc decodeJwtUnverified*(token: string): DecodedJwt {.raises: [OAuthError].} =
  ## Splits and parses a compact JWT: three base64url segments, a header and
  ## a payload that are JSON objects, and an `alg` in the header. The
  ## signature is NOT checked.
  if token.len > MaxJwtLength:
    raise newException(OAuthError, "the JWT is longer than " & $MaxJwtLength & " bytes")
  let parts = token.split('.')
  if parts.len != 3:
    raise newException(OAuthError, "a JWT has three dot-separated parts")
  var header, claims: JsonNode
  try:
    header = parseJson(decodeSegment(parts[0], "header"))
    claims = parseJson(decodeSegment(parts[1], "payload"))
  except OAuthError:
    raise
  except CatchableError:
    raise newException(OAuthError, "the JWT header or payload is not JSON")
  if header.kind != JObject or claims.kind != JObject:
    raise newException(OAuthError, "the JWT header and payload must be JSON objects")
  if header{"alg"}.isNil or header{"alg"}.kind != JString or header{"alg"}.getStr().len == 0:
    raise newException(OAuthError, "the JWT header has no alg")
  DecodedJwt(header: header, claims: claims, signingInput: parts[0] & "." & parts[1],
             signature: decodeSegment(parts[2], "signature"))

proc clientAssertion*(signer: JwtSigner, clientId, audience: string, now: Time,
                      lifetime = initDuration(minutes = 1)): string
                     {.raises: [OAuthError].} =
  ## The `client_assertion` of RFC 7523 2.2 / OpenID Connect Core 9
  ## (`private_key_jwt`): `iss` and `sub` are the client, `aud` the
  ## authorization server, `jti` is fresh so a server can refuse a replay.
  if clientId.len == 0 or audience.len == 0:
    raise newException(OAuthError, "a client assertion needs a client_id and an audience")
  let issued = now.toUnix
  var jti: string
  try:
    jti = randomUrlToken(16)
  except OSError:
    raise newException(OAuthError, "no source of randomness for the assertion's jti")
  signer.signJwt(%*{"iss": clientId, "sub": clientId, "aud": audience, "jti": jti,
                    "iat": issued, "exp": issued + lifetime.inSeconds})
