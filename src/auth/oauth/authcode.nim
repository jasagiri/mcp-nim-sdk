## The authorization code grant with PKCE (OAuth 2.1 4.1), the refresh
## grant, and the checks on what comes back from the user agent.

import std/[asyncdispatch, base64, json, options, strutils, times, uri]
import ./errors
import ./fetch
import ./jsonfield
import ./pkce
import ./registration
import ./tokens
import ./urls

type
  AuthorizationRequest* = object
    ## Everything the client has to remember between sending the user to the
    ## authorization endpoint and receiving the redirect. One per attempt;
    ## never reused, never persisted.
    authorizationUrl*: string
    clientId*: string
    redirectUri*: string
    state: string
    codeVerifier: string
    resource*: Option[string]
    scopes*: seq[string]
    expectedIssuer*: string
      ## Recorded from validated metadata before the redirect (RFC 9207).
    issuerParameterAdvertised*: bool
    checkIssuer*: bool

proc checkRedirectUri*(redirectUri: string) {.raises: [OAuthSecurityError].} =
  ## All redirect URIs MUST be localhost or HTTPS.
  let uri =
    try: parseUri(redirectUri)
    except CatchableError: raise newException(OAuthSecurityError, "redirect URI is not valid")
  if uri.hostname.len == 0 or uri.anchor.len > 0:
    raise newException(OAuthSecurityError,
      "redirect URI must be absolute and without a fragment: " & redirectUri)
  case uri.scheme.toLowerAscii()
  of "https":
    discard
  of "http":
    if not isLoopbackHost(uri.hostname):
      raise newException(OAuthSecurityError,
        "redirect URI must be https or a localhost URL: " & redirectUri)
  else:
    raise newException(OAuthSecurityError,
      "redirect URI must be https or a localhost URL: " & redirectUri)

proc newAuthorizationRequest*(authorizationEndpoint, clientId, redirectUri: string,
                              scopes: seq[string], resource: Option[string],
                              expectedIssuer: string, issuerParameterAdvertised: bool,
                              checkIssuer: bool): AuthorizationRequest
                             {.raises: [OAuthSecurityError, OAuthError].} =
  checkRedirectUri(redirectUri)
  result = AuthorizationRequest(
    clientId: clientId, redirectUri: redirectUri, scopes: scopes, resource: resource,
    expectedIssuer: expectedIssuer, issuerParameterAdvertised: issuerParameterAdvertised,
    checkIssuer: checkIssuer)
  try:
    result.state = randomUrlToken()
    result.codeVerifier = newCodeVerifier()
  except OSError as e:
    raise newException(OAuthError, "no source of randomness: " & e.msg)
  var fields = @[("response_type", "code"), ("client_id", clientId),
                 ("redirect_uri", redirectUri), ("state", result.state),
                 ("code_challenge", codeChallengeS256(result.codeVerifier)),
                 ("code_challenge_method", "S256")]
  if scopes.len > 0:
    fields.add ("scope", scopes.join(" "))
  if resource.isSome:
    fields.add ("resource", resource.get)
  result.authorizationUrl = authorizationEndpoint &
    (if '?' in authorizationEndpoint: "&" else: "?") & formEncode(fields)

func constantTimeEquals(a, b: string): bool {.raises: [].} =
  if a.len != b.len:
    return false
  var difference = 0
  for i in 0 ..< a.len:
    difference = difference or (a[i].ord xor b[i].ord)
  difference == 0

proc authorizationCode*(request: AuthorizationRequest,
                        response: openArray[(string, string)]): string
                       {.raises: [OAuthSecurityError, OAuthServerError, OAuthError].} =
  ## The code in the redirect's parameters, once the response has proved to
  ## answer this request. The order matters: `error` is neither acted on nor
  ## shown until `state` and `iss` have been checked, because they are what
  ## tells a genuine answer from a forged one (RFC 9207 2.4).
  var state, iss, code, error, description: Option[string]
  for (name, value) in response:
    case name
    of "state": state = some(value)
    of "iss": iss = some(value)
    of "code": code = some(value)
    of "error": error = some(value)
    of "error_description": description = some(value)
    else: discard
  if state.isNone or not constantTimeEquals(state.get, request.state):
    raise newException(OAuthSecurityError,
      "the authorization response has a missing or wrong state; it is discarded")
  if request.checkIssuer:
    # Simple string comparison: no case folding, no normalization.
    if iss.isSome:
      if iss.get != request.expectedIssuer:
        raise newException(OAuthSecurityError,
          "the authorization response names issuer " & iss.get &
          " but the request went to " & request.expectedIssuer)
    elif request.issuerParameterAdvertised:
      raise newException(OAuthSecurityError,
        "the authorization server advertises the iss parameter but the response has none")
  if error.isSome:
    var e = newException(OAuthServerError, "authorization was refused: " & error.get)
    e.error = error.get
    e.description = description.get("")
    raise e
  if code.isNone or code.get.len == 0:
    raise newException(OAuthError, "the authorization response has no code")
  code.get

type TokenEndpointClient* = object
  tokenEndpoint*: string
  credentials*: ClientCredentials
  policy*: FetchPolicy

func clientAuthentication(c: ClientCredentials): tuple[fields: seq[(string, string)],
                                                      headers: seq[(string, string)]]
                         {.raises: [].} =
  if c.clientSecret.isSome and c.authMethod == "client_secret_post":
    result.fields = @[("client_id", c.clientId), ("client_secret", c.clientSecret.get)]
  elif c.clientSecret.isSome:
    # RFC 6749 2.3.1: both parts are form-urlencoded before the base64.
    result.headers = @[("Authorization", "Basic " & base64.encode(
      encodeUrl(c.clientId) & ":" & encodeUrl(c.clientSecret.get)))]
  else:
    result.fields = @[("client_id", c.clientId)]

proc parseTokenResponse*(reply: HttpReply, issuer: string, requestedScopes: seq[string],
                        previousRefreshToken: Option[string], now: Time): TokenSet
                       {.raises: [OAuthError].} =
  if reply.code != 200:
    raise errorFrom(reply, "the token request")
  var body: JsonNode
  try:
    body = parseJson(reply.body)
  except CatchableError:
    raise newException(OAuthError, "the token response is not JSON")
  let access = body.strField("access_token")
  if access.isNone or access.get.len == 0:
    raise newException(OAuthError, "the token response has no access_token")
  if body.strField("token_type").get("").toLowerAscii() != "bearer":
    raise newException(OAuthError, "the token response is not of type Bearer")
  result.accessToken = access.get
  result.issuer = issuer
  result.refreshToken = body.strField("refresh_token")
  if result.refreshToken.isNone:
    result.refreshToken = previousRefreshToken
  let expiresIn = body.intField("expires_in")
  if expiresIn.isSome:
    result.expiresAt = some(now + initDuration(seconds = expiresIn.get))
  let granted = body.strField("scope")
  result.scopes = if granted.isSome: granted.get.splitWhitespace() else: requestedScopes

proc exchangeCode*(client: TokenEndpointClient, request: AuthorizationRequest, code: string,
                   now = getTime()): Future[TokenSet] {.async.} =
  let authentication = clientAuthentication(client.credentials)
  var fields = @[("grant_type", "authorization_code"), ("code", code),
                 ("redirect_uri", request.redirectUri),
                 ("code_verifier", request.codeVerifier)] & authentication.fields
  if request.resource.isSome:
    fields.add ("resource", request.resource.get)
  let reply = await postForm(client.tokenEndpoint, fields, client.policy,
                             "token endpoint", authentication.headers)
  return parseTokenResponse(reply, client.credentials.issuer, request.scopes,
                            none(string), now)

proc refreshTokens*(client: TokenEndpointClient, refreshToken: string,
                    scopes: seq[string], resource: Option[string],
                    now = getTime()): Future[TokenSet] {.async.} =
  let authentication = clientAuthentication(client.credentials)
  var fields = @[("grant_type", "refresh_token"),
                 ("refresh_token", refreshToken)] & authentication.fields
  if resource.isSome:
    fields.add ("resource", resource.get)
  let reply = await postForm(client.tokenEndpoint, fields, client.policy,
                             "token endpoint", authentication.headers)
  return parseTokenResponse(reply, client.credentials.issuer, scopes,
                            some(refreshToken), now)
