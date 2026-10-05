## Dynamic Client Registration (RFC 7591), with the OpenID Connect
## `application_type` (OpenID Connect Dynamic Client Registration 1.0 2).

import std/[asyncdispatch, json, options, strutils]
import ./errors
import ./fetch
import ./jsonfield
import ./tokens
import ./urls

type
  ClientRegistrationRequest* = object
    clientName*: string
    redirectUris*: seq[string]
    scope*: Option[string]
    applicationType*: Option[string]
      ## "native" or "web". An OpenID Connect server treats a missing value
      ## as "web" and then refuses localhost redirect URIs.
    refreshTokens*: bool
      ## Ask for the `refresh_token` grant as well.

func registrationDocument*(request: ClientRegistrationRequest): JsonNode {.raises: [].} =
  ## A public client: authorization code grant, no client authentication.
  var grants = @["authorization_code"]
  if request.refreshTokens:
    grants.add "refresh_token"
  result = %*{
    "client_name": request.clientName,
    "redirect_uris": request.redirectUris,
    "grant_types": grants,
    "response_types": ["code"],
    "token_endpoint_auth_method": "none"}
  if request.scope.isSome:
    result["scope"] = %request.scope.get
  if request.applicationType.isSome:
    result["application_type"] = %request.applicationType.get

proc errorFrom*(reply: HttpReply, doing: string): ref OAuthError {.raises: [].} =
  ## The exception for a non-success answer: an OAuth error response when
  ## the body is one, otherwise just the status.
  var body: JsonNode = nil
  try:
    body = parseJson(reply.body)
  except CatchableError:
    body = nil  # not JSON: reported by status below
  let error = body.strField("error")
  if error.isSome:
    let description = body.strField("error_description").get("")
    var e = (ref OAuthServerError)()
    e.error = error.get
    e.description = description
    e.msg = doing & " was refused: " & error.get &
            (if description.len > 0: " (" & description & ")" else: "")
    return e
  result = (ref OAuthError)()
  result.msg = doing & " failed with HTTP " & $reply.code

proc registerClient*(endpoint: string, issuer: string, request: ClientRegistrationRequest,
                     policy: FetchPolicy): Future[ClientCredentials] {.async.} =
  let reply = await postJson(endpoint, registrationDocument(request), policy,
                             "registration endpoint")
  if reply.code notin {200, 201}:
    raise errorFrom(reply, "client registration")
  var body: JsonNode
  try:
    body = parseJson(reply.body)
  except CatchableError:
    raise newException(OAuthError, "the registration response is not JSON")
  let clientId = body.strField("client_id")
  if clientId.isNone or clientId.get.len == 0:
    raise newException(OAuthError, "the registration response has no client_id")
  let secret = body.strField("client_secret")
  let authMethod = body.strField("token_endpoint_auth_method").get(
    if secret.isSome: "client_secret_basic" else: "none")
  return ClientCredentials(
    issuer: issuer, clientId: clientId.get, clientSecret: secret,
    authMethod: authMethod, redirectUris: request.redirectUris)
