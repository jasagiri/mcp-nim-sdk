## Token endpoint requests that are not the authorization code grant:
## client credentials (RFC 6749 4.4), token exchange (RFC 8693) and the JWT
## bearer grant (RFC 7523 2.1), and the client authentication that goes with
## them (RFC 6749 2.3.1, RFC 7523 2.2). Nothing here knows about MCP.
##
## Secrets (client secrets, assertions, subject tokens) go into the request
## and nowhere else: not into an error message, not into a log.

import std/[asyncdispatch, base64, json, options, strutils, times, uri]
import ./authcode
import ./errors
import ./fetch
import ./jsonfield
import ./jwt
import ./registration
import ./tokens
import ./urls

const
  GrantTypeClientCredentials* = "client_credentials"
  GrantTypeJwtBearer* = "urn:ietf:params:oauth:grant-type:jwt-bearer"
  GrantTypeTokenExchange* = "urn:ietf:params:oauth:grant-type:token-exchange"
  ClientAssertionTypeJwtBearer* = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  TokenTypeAccessToken* = "urn:ietf:params:oauth:token-type:access_token"
  TokenTypeRefreshToken* = "urn:ietf:params:oauth:token-type:refresh_token"
  TokenTypeIdToken* = "urn:ietf:params:oauth:token-type:id_token"
  TokenTypeSaml2* = "urn:ietf:params:oauth:token-type:saml2"

type
  ClientAuthMethod* = enum
    camNone = "none"
    camSecretBasic = "client_secret_basic"
    camSecretPost = "client_secret_post"
    camPrivateKeyJwt = "private_key_jwt"

  ClientAuthentication* = object
    ## How a client proves who it is at one token endpoint.
    clientId*: string
    case authMethod*: ClientAuthMethod
    of camSecretBasic, camSecretPost:
      secret*: string
    of camPrivateKeyJwt:
      signer*: JwtSigner
      audience*: string
        ## The `aud` of the assertion: the authorization server's issuer
        ## identifier or its token endpoint URL, as that server expects.
      lifetime*: Duration
    of camNone:
      discard

  TokenExchangeRequest* = object
    ## RFC 8693 2.1. Actor tokens are not supported.
    subjectToken*: string
    subjectTokenType*: string
    requestedTokenType*: Option[string]
    audience*: Option[string]
    resource*: Option[string]
    scopes*: seq[string]

  TokenExchangeResponse* = object
    accessToken*: string
      ## The issued token, whatever its type: RFC 8693 2.2.1 calls the field
      ## `access_token` even when the token is not one.
    issuedTokenType*: string
    tokenType*: string
    scopes*: Option[seq[string]]
    expiresAt*: Option[Time]

func secretBasic*(clientId, secret: string): ClientAuthentication {.raises: [].} =
  ClientAuthentication(clientId: clientId, authMethod: camSecretBasic, secret: secret)

func secretPost*(clientId, secret: string): ClientAuthentication {.raises: [].} =
  ClientAuthentication(clientId: clientId, authMethod: camSecretPost, secret: secret)

func publicClient*(clientId: string): ClientAuthentication {.raises: [].} =
  ClientAuthentication(clientId: clientId, authMethod: camNone)

func privateKeyJwt*(clientId: string, signer: JwtSigner, audience: string,
                    lifetime = initDuration(minutes = 1)): ClientAuthentication
                   {.raises: [].} =
  ClientAuthentication(clientId: clientId, authMethod: camPrivateKeyJwt, signer: signer,
                       audience: audience, lifetime: lifetime)

proc authenticate(auth: ClientAuthentication, now: Time): tuple[
    fields: seq[(string, string)], headers: seq[(string, string)]] {.raises: [OAuthError].} =
  if auth.clientId.len == 0:
    raise newException(OAuthError, "client authentication needs a client_id")
  case auth.authMethod
  of camNone:
    result.fields = @[("client_id", auth.clientId)]
  of camSecretPost:
    result.fields = @[("client_id", auth.clientId), ("client_secret", auth.secret)]
  of camSecretBasic:
    # RFC 6749 2.3.1: both parts are form-urlencoded before the base64.
    result.headers = @[("Authorization", "Basic " &
      base64.encode(encodeUrl(auth.clientId) & ":" & encodeUrl(auth.secret)))]
  of camPrivateKeyJwt:
    # RFC 7523 3: the client is identified by the assertion's `sub`, so
    # `client_id` stays out of the body.
    result.fields = @[("client_assertion_type", ClientAssertionTypeJwtBearer),
                      ("client_assertion", clientAssertion(
                        auth.signer, auth.clientId, auth.audience, now,
                        if auth.lifetime > DurationZero: auth.lifetime
                        else: initDuration(minutes = 1)))]

proc postGrant(tokenEndpoint: string, fields: seq[(string, string)],
               auth: ClientAuthentication, policy: FetchPolicy, now: Time): Future[HttpReply] =
  let authentication = authenticate(auth, now)
  postForm(tokenEndpoint, fields & authentication.fields, policy, "token endpoint",
           authentication.headers)

proc clientCredentialsGrant*(tokenEndpoint, issuer: string, auth: ClientAuthentication,
                             scopes: seq[string], resource: Option[string],
                             policy: FetchPolicy, now = getTime()): Future[TokenSet] {.async.} =
  ## RFC 6749 4.4.2. No refresh token is expected (4.4.3); one that comes
  ## anyway is kept like any other.
  var fields = @[("grant_type", GrantTypeClientCredentials)]
  if scopes.len > 0:
    fields.add ("scope", scopes.join(" "))
  if resource.isSome:
    fields.add ("resource", resource.get)
  let reply = await postGrant(tokenEndpoint, fields, auth, policy, now)
  return parseTokenResponse(reply, issuer, scopes, none(string), now)

proc jwtBearerGrant*(tokenEndpoint, issuer, assertion: string, auth: ClientAuthentication,
                     scopes: seq[string], policy: FetchPolicy,
                     now = getTime()): Future[TokenSet] {.async.} =
  ## RFC 7523 2.1: `assertion` is the grant.
  var fields = @[("grant_type", GrantTypeJwtBearer), ("assertion", assertion)]
  if scopes.len > 0:
    fields.add ("scope", scopes.join(" "))
  let reply = await postGrant(tokenEndpoint, fields, auth, policy, now)
  return parseTokenResponse(reply, issuer, scopes, none(string), now)

proc parseTokenExchangeResponse*(reply: HttpReply, now: Time): TokenExchangeResponse
                                {.raises: [OAuthError].} =
  if reply.code != 200:
    raise errorFrom(reply, "the token exchange")
  var body: JsonNode
  try:
    body = parseJson(reply.body)
  except CatchableError:
    raise newException(OAuthError, "the token exchange response is not JSON")
  if body.kind != JObject:
    raise newException(OAuthError, "the token exchange response is not a JSON object")
  let token = body.strField("access_token")
  if token.isNone or token.get.len == 0:
    raise newException(OAuthError, "the token exchange response has no access_token")
  let issued = body.strField("issued_token_type")
  if issued.isNone or issued.get.len == 0:
    raise newException(OAuthError, "the token exchange response has no issued_token_type")
  let tokenType = body.strField("token_type")
  if tokenType.isNone or tokenType.get.len == 0:
    raise newException(OAuthError, "the token exchange response has no token_type")
  result.accessToken = token.get
  result.issuedTokenType = issued.get
  result.tokenType = tokenType.get
  let scope = body.strField("scope")
  if scope.isSome:
    result.scopes = some(scope.get.splitWhitespace())
  result.expiresAt = tokenExpiry(body, "expires_in", now)

proc exchangeToken*(tokenEndpoint: string, request: TokenExchangeRequest,
                    auth: ClientAuthentication, policy: FetchPolicy,
                    now = getTime()): Future[TokenExchangeResponse] {.async.} =
  ## RFC 8693 2.1. The response is returned as it is; what its
  ## `issued_token_type` has to be is for the caller to check.
  if request.subjectToken.len == 0 or request.subjectTokenType.len == 0:
    raise newException(OAuthError, "a token exchange needs a subject token and its type")
  var fields = @[("grant_type", GrantTypeTokenExchange),
                 ("subject_token", request.subjectToken),
                 ("subject_token_type", request.subjectTokenType)]
  if request.requestedTokenType.isSome:
    fields.add ("requested_token_type", request.requestedTokenType.get)
  if request.audience.isSome:
    fields.add ("audience", request.audience.get)
  if request.resource.isSome:
    fields.add ("resource", request.resource.get)
  if request.scopes.len > 0:
    fields.add ("scope", request.scopes.join(" "))
  let reply = await postGrant(tokenEndpoint, fields, auth, policy, now)
  return parseTokenExchangeResponse(reply, now)
