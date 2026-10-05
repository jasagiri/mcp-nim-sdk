## Authorization for an MCP server of an HTTP transport (versions
## 2025-03-26 and later): the server acts as an OAuth resource server.
##
## `newResourceServerAuth` makes the hook `HttpServerTransport.auth` takes.
## For every HTTP request the hook
##   * serves the Protected Resource Metadata document (RFC 9728) at its
##     well-known URI (2025-06-18 and later);
##   * answers a request to the MCP endpoint that carries no acceptable
##     token with 401 and a `WWW-Authenticate` challenge, which names the
##     metadata document (`resource_metadata`) from 2025-06-18 on;
##   * answers a token that lacks scope with 403 `insufficient_scope`;
##   * lets everything else through to the MCP server.
##
## Judging the token is the application's: `TokenVerifier`.

import std/[asyncdispatch, json, options, strutils]
import ../protocol/version
import ../protocol/features
import ../transport/auth_hook
import ./oauth/[challenge, errors, urls]

const MaxTokenLength = 8192
  ## A bearer token longer than this is refused without being handed to the
  ## verifier.

type
  TokenVerdictKind* = enum
    tvValid
    tvInvalid            ## unknown, expired, malformed, wrong audience
    tvInsufficientScope  ## a good token that may not do this

  TokenVerdict* = object
    case kind*: TokenVerdictKind
    of tvInsufficientScope:
      requiredScopes*: seq[string]
        ## Everything the operation needs, in one challenge.
    of tvValid:
      principal*: Option[string]
        ## Who the token stands for (its subject, or the client id of a
        ## client-credentials token). Handlers read it as `ctx.principal`, and
        ## tasks are bound to it (2025-11-25 tasks, Security). None when the
        ## verifier cannot name one: tasks then belong to the session.
    else:
      discard

  TokenVerifier* = proc(token, resource: string): Future[TokenVerdict] {.closure, gcsafe.}
    ## Decides whether `token` may be used at this server. `resource` is the
    ## canonical URI of the MCP server.
    ##
    ## MUST (2025-06-18 and later; OAuth 2.1 5.2 before): the verifier
    ## validates the token itself (signature or introspection, expiry) and
    ## that it was issued for this server as its audience (RFC 8707 2, the
    ## `aud` claim of RFC 9068). A token for another resource is `tvInvalid`.
    ## An MCP server MUST NOT accept tokens meant for others, and MUST NOT
    ## pass the token it received on to an upstream API; where it calls one
    ## it uses a token of its own.
    ##
    ## From 2026-07-28 a verifier also has to account for scope hierarchies:
    ## a broader scope implies narrower ones.
    ##
    ## An exception from the verifier answers the request with 500 and is
    ## written to stderr (without the token); it never lets the request
    ## through.

  ResourceServerConfig* = object
    resource*: string
      ## Canonical URI of this MCP server, e.g. "https://mcp.example.com/mcp".
    authorizationServers*: seq[string]
      ## Issuers of the authorization servers that issue tokens for it; at
      ## least one.
    scopesSupported*: seq[string]
      ## The minimal set for basic functionality. Not `offline_access`:
      ## refresh tokens are not a resource requirement (2026-07-28).
    challengeScopes*: seq[string]
      ## Put in the `scope` of a 401 challenge (2025-11-25 and later).
    verify*: TokenVerifier
    version*: McpProtocolVersion

func resourcePath(resource: string): string {.raises: [OAuthError].} =
  let canonical = canonicalResource(resource)
  canonical[originOf(canonical).len .. ^1]

func metadataUrl*(config: ResourceServerConfig): string {.raises: [].} =
  ## Where this server's Protected Resource Metadata lives (RFC 9728 3.1).
  wellKnownUrl(config.resource, "oauth-protected-resource")

func resourceMetadataDocument*(config: ResourceServerConfig): JsonNode {.raises: [].} =
  result = %*{
    "resource": config.resource,
    "authorization_servers": config.authorizationServers,
    "bearer_methods_supported": ["header"]}
  if config.scopesSupported.len > 0:
    result["scopes_supported"] = %config.scopesSupported

proc challenge(config: ResourceServerConfig, error = "", scopes: seq[string] = @[],
               description = ""): string {.raises: [ValueError].} =
  var params: seq[(string, string)]
  if error.len > 0:
    params.add ("error", error)
  if description.len > 0:
    params.add ("error_description", description)
  if scopes.len > 0:
    params.add ("scope", scopes.join(" "))
  if config.version.has(ftProtectedResourceMetadata):
    params.add ("resource_metadata", config.metadataUrl)
  formatBearerChallenge(params)

proc bearerToken(authorization: Option[string]): Option[string] {.raises: [].} =
  ## The token of an `Authorization: Bearer <token>` header (the scheme is
  ## case-insensitive); none for anything else.
  if authorization.isNone:
    return none(string)
  let value = authorization.get
  if value.len <= 7 or value[0 ..< 6].toLowerAscii() != "bearer" or value[6] != ' ':
    return none(string)
  let token = value[7 .. ^1].strip()
  if token.len == 0 or token.len > MaxTokenLength or ' ' in token:
    return none(string)
  some(token)

func answered(response: HttpServerAuthResponse): HttpServerAuthOutcome {.raises: [].} =
  HttpServerAuthOutcome(answer: some(response))

proc newResourceServerAuth*(config: ResourceServerConfig, mcpPath: string): HttpServerAuth
                           {.raises: [ValueError, OAuthError].} =
  ## `mcpPath` is the path the HTTP transport serves MCP on. Raises for a
  ## configuration that could never work.
  if not config.version.has(ftAuthorization):
    raise newException(ValueError, "protocol version " & $config.version & " has no authorization")
  if config.verify.isNil:
    raise newException(ValueError, "a token verifier is required")
  if config.authorizationServers.len == 0 and config.version.has(ftProtectedResourceMetadata):
    raise newException(ValueError,
      "resource metadata must list at least one authorization server")
  let canonical = canonicalResource(config.resource)
  if canonical != config.resource:
    raise newException(ValueError,
      "resource must be in canonical form (" & canonical & "), not " & config.resource)
  let metadataPath =
    if config.version.has(ftProtectedResourceMetadata):
      some("/.well-known/oauth-protected-resource" & resourcePath(config.resource))
    else:
      none(string)
  let document = $resourceMetadataDocument(config)
  # Fail now, not on the first request, if the configured challenge cannot
  # be written.
  discard config.challenge(scopes = config.challengeScopes)
  let check = proc(httpMethod, path: string, authorization: Option[string]):
                  Future[HttpServerAuthOutcome] {.closure, gcsafe, async.} =
      if metadataPath.isSome and path == metadataPath.get and httpMethod == "GET":
        return answered(HttpServerAuthResponse(
          code: 200, headers: @[("Content-Type", "application/json")], body: document))
      if path != mcpPath:
        return HttpServerAuthOutcome()
      let token = bearerToken(authorization)
      if token.isNone:
        return answered(HttpServerAuthResponse(
          code: 401, headers: @[("WWW-Authenticate",
            config.challenge(scopes = if config.version.has(ftIncrementalScopeConsent):
                                        config.challengeScopes else: @[]))]))
      var verdict: TokenVerdict
      try:
        verdict = await config.verify(token.get, config.resource)
      except CatchableError as e:
        stderr.writeLine("[mcp-auth] token verifier failed: " & $e.name)
        return answered(HttpServerAuthResponse(code: 500))
      case verdict.kind
      of tvValid:
        return HttpServerAuthOutcome(principal: verdict.principal)
      of tvInvalid:
        return answered(HttpServerAuthResponse(
          code: 401, headers: @[("WWW-Authenticate",
            config.challenge(error = "invalid_token",
                             description = "The access token is invalid or expired"))]))
      of tvInsufficientScope:
        try:
          return answered(HttpServerAuthResponse(
            code: 403, headers: @[("WWW-Authenticate",
              config.challenge(error = "insufficient_scope",
                               scopes = verdict.requiredScopes))]))
        except ValueError:
          # The verifier named a scope that cannot go in a header.
          stderr.writeLine("[mcp-auth] required scopes cannot be written as a challenge")
          return answered(HttpServerAuthResponse(code: 500))
  HttpServerAuth(
    check: check,
    intercept: proc(httpMethod, path: string, authorization: Option[string]):
                   Future[Option[HttpServerAuthResponse]] {.closure, gcsafe, async.} =
      return (await check(httpMethod, path, authorization)).answer)
