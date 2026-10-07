## Finding the metadata documents: the candidate URLs, in the order a
## client has to try them, and the fetch-and-validate loop around them.

import std/[asyncdispatch, options, strutils, uri]
import ./errors
import ./fetch
import ./metadata
import ./urls

type
  AsDiscoveryStyle* = enum
    adsOAuthOnly      ## RFC 8414 only
    adsOAuthThenOidc  ## RFC 8414, then OpenID Connect Discovery

func authorizationServerMetadataUrls*(issuer: string, style: AsDiscoveryStyle): seq[string]
                                     {.raises: [].} =
  ## RFC 8414 3.1 path insertion; with `adsOAuthThenOidc` also OpenID
  ## Connect Discovery by path insertion and, for an issuer with a path, by
  ## path appending (RFC 8414 5).
  result.add wellKnownUrl(issuer, "oauth-authorization-server")
  if style == adsOAuthThenOidc:
    result.add wellKnownUrl(issuer, "openid-configuration")
    var path = parseUri(issuer).path
    while path.len > 0 and path[^1] == '/':
      path.setLen(path.len - 1)
    if path.len > 0:
      result.add originOf(issuer) & path & "/.well-known/openid-configuration"

func protectedResourceMetadataUrls*(resourceUrl: string): seq[string] {.raises: [].} =
  ## RFC 9728 3.1: at the path of the resource, then at the root. A resource
  ## without a path has only the root.
  let specific = wellKnownUrl(resourceUrl, "oauth-protected-resource")
  let root = originOf(resourceUrl) & "/.well-known/oauth-protected-resource"
  if specific != root:
    result.add specific
  result.add root

proc fetchProtectedResourceMetadata*(url, requestedResource: string,
                                     policy: FetchPolicy,
                                     alsoAccepted: seq[string] = @[]
                                    ): Future[ProtectedResourceMetadata] {.async.} =
  let reply = await getJson(url, policy, "protected resource metadata")
  if reply.code != 200 or reply.document.isNone:
    raise newException(OAuthError, "protected resource metadata at " & url &
      " is not a JSON object (HTTP " & $reply.code & ")")
  return parseProtectedResourceMetadata(reply.document.get, requestedResource, policy,
                                        alsoAccepted)

proc discoverProtectedResource*(resourceUrl: string, advertisedUrl: Option[string],
                                wellKnownFallback: bool,
                                policy: FetchPolicy): Future[ProtectedResourceMetadata] {.async.} =
  ## The URL the server advertised in its challenge is used when there is
  ## one, and a failure there is a failure. Without it, versions that allow
  ## it probe the well-known URIs.
  if advertisedUrl.isSome:
    return await fetchProtectedResourceMetadata(advertisedUrl.get, resourceUrl, policy)
  if not wellKnownFallback:
    raise newException(OAuthError,
      "the server's challenge has no resource_metadata, and this protocol " &
      "version does not define another way to find it")
  var failures: seq[string]
  var security: ref OAuthSecurityError = nil
  let root = originOf(resourceUrl) & "/.well-known/oauth-protected-resource"
  for url in protectedResourceMetadataUrls(resourceUrl):
    try:
      # RFC 9728 3.3: the resource is the identifier the well-known URL was
      # built from, which for the root URL is the origin.
      let builtFromOrigin = if url == root: @[originOf(resourceUrl)] else: @[]
      return await fetchProtectedResourceMetadata(url, resourceUrl, policy, builtFromOrigin)
    except OAuthSecurityError as e:
      security = e
      failures.add e.plainMessage
    except OAuthError as e:
      failures.add e.plainMessage
  if not security.isNil:
    raise newException(OAuthSecurityError,
      "no usable protected resource metadata: " & failures.join("; "))
  raise newException(OAuthError, "no protected resource metadata: " & failures.join("; "))

proc discoverAuthorizationServer*(issuer: string, style: AsDiscoveryStyle, policy: FetchPolicy,
                                  headers: seq[(string, string)] = @[]
                                 ): Future[AuthorizationServerMetadata] {.async.} =
  ## The first candidate URL that yields a document naming `issuer`. A
  ## document that names another issuer is never used, whichever URL it
  ## came from.
  checkFetchUrl(issuer, policy, "authorization server issuer")
  var failures: seq[string]
  var sawSecurityFailure = false
  for url in authorizationServerMetadataUrls(issuer, style):
    try:
      let reply = await getJson(url, policy, "authorization server metadata", headers)
      if reply.code != 200 or reply.document.isNone:
        failures.add url & ": HTTP " & $reply.code
        continue
      return parseAuthorizationServerMetadata(reply.document.get, issuer, policy)
    except OAuthSecurityError as e:
      sawSecurityFailure = true
      failures.add url & ": " & e.plainMessage
    except OAuthError as e:
      failures.add url & ": " & e.plainMessage
  let message = "no authorization server metadata for " & issuer & ": " & failures.join("; ")
  if sawSecurityFailure:
    raise newException(OAuthSecurityError, message)
  raise newException(OAuthError, message)

proc discoverOrDefault*(serverUrl: string, policy: FetchPolicy,
                        headers: seq[(string, string)]
                       ): Future[AuthorizationServerMetadata] {.async.} =
  ## Version 2025-03-26: metadata at the root of the server's origin, and
  ## the default endpoints when that answers 404. Any other failure is not
  ## "no metadata", and does not fall back.
  let issuer = originOf(serverUrl)
  checkFetchUrl(issuer, policy, "authorization base URL")
  let url = issuer & "/.well-known/oauth-authorization-server"
  let reply = await getJson(url, policy, "authorization server metadata", headers)
  if reply.code == 404:
    return defaultEndpointMetadata(serverUrl)
  if reply.code != 200 or reply.document.isNone:
    raise newException(OAuthError, "authorization server metadata at " & url &
      " is not a JSON object (HTTP " & $reply.code & ")")
  return parseAuthorizationServerMetadata(reply.document.get, issuer, policy)
