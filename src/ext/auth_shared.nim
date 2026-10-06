## What the two authorization extensions (`auth_client_credentials`,
## `auth_enterprise_managed`) have in common: finding the authorization
## server of an MCP server, choosing scopes from a challenge, and the one
## rule about declaring an extension in a build.
##
## Based on the ext-auth repository at
## fb374c7db2b34f18ca9183882e0beecdf661892b (see docs/quality/ext-auth.md).

import std/[asyncdispatch, options, strutils]
import ../protocol/version
import ../protocol/features
import ../auth/policy
import ../auth/oauth/[discovery, errors, metadata, urls]

type
  ResourceAuthorization* = object
    ## What a client learns about an MCP server's authorization before it
    ## asks for a token.
    resource*: string
      ## The canonical URI of the MCP server (RFC 8707).
    issuer*: string
    metadata*: AuthorizationServerMetadata
    resourceScopes*: seq[string]
      ## `scopes_supported` of the protected resource metadata.

  AuthorizationServerChooser* = proc(servers: seq[string]): string {.closure, gcsafe.}

proc requireExtensionsCapability*(id: string) {.raises: [ValueError].} =
  ## Declaring `id` goes through the `extensions` capability, which exists
  ## from 2026-07-28. A build that speaks nothing newer cannot honor the
  ## declaration, so it is refused instead of ignored.
  if not DefaultProtocolVersion.has(ftExtensions):
    raise newException(ValueError,
      "cannot declare " & id & ": the extensions capability exists from 2026-07-28 " &
      "and this build speaks up to " & $DefaultProtocolVersion)

func firstAuthorizationServer*(servers: seq[string]): string {.raises: [].} =
  servers[0]

proc requireIssuer*(expected, found: string, what: string) {.raises: [OAuthSecurityError].} =
  ## The MCP server decides which authorization server a client meets, so a
  ## credential is used only at the one it was configured for. The message
  ## names both and, because it ends up in logs, nothing secret.
  if found != expected:
    raise newException(OAuthSecurityError,
      what & " belong to the authorization server " & expected &
      " but the resource server names " & found & "; nothing is sent to it. If the " &
      "resource lists several, choose the right one with selectAuthorizationServer")

proc discoverResourceAuthorization*(
    serverUrl: string, advertised: Option[string], policy: AuthPolicy,
    choose: AuthorizationServerChooser, fetchPolicy: FetchPolicy,
    expectedIssuer: string, credentials: string
  ): Future[ResourceAuthorization] {.async.} =
  ## Protected Resource Metadata (RFC 9728), the choice among its
  ## authorization servers (which has to be one the resource lists, and the
  ## one `credentials` are configured for: `expectedIssuer`), and that
  ## server's metadata. The two documents are validated the way the core
  ## flow validates them. A server that is not `expectedIssuer` is not asked
  ## for anything.
  let prm = await discoverProtectedResource(serverUrl, advertised,
                                            policy.wellKnownResourceFallback, fetchPolicy)
  let issuer = if choose.isNil: firstAuthorizationServer(prm.authorizationServers)
               else: choose(prm.authorizationServers)
  if issuer notin prm.authorizationServers:
    raise newException(OAuthSecurityError,
      "the chosen authorization server " & issuer & " is not one the resource lists")
  requireIssuer(expectedIssuer, issuer, credentials)
  let md = await discoverAuthorizationServer(issuer, policy.asDiscovery, fetchPolicy)
  return ResourceAuthorization(resource: canonicalResource(serverUrl), issuer: issuer,
                               metadata: md, resourceScopes: prm.scopesSupported)

func unionOf*(a, b: seq[string]): seq[string] {.raises: [].} =
  result = a
  for item in b:
    if item notin result:
      result.add item
