## What the authorization specification asks of an implementation, per
## protocol version. The generic OAuth modules (`auth/oauth/*`) know nothing
## about MCP versions; this is where the table in
## docs/quality/auth-requirements.md turns into switches.

import ../protocol/version
import ../protocol/features
import ./oauth/discovery

type
  AuthPolicy* = object
    version*: McpProtocolVersion
    defaultEndpoints*: bool
      ## 2025-03-26: no PRM; metadata at the server's origin, default
      ## endpoints when it is missing; MCP-Protocol-Version on discovery.
    protectedResourceMetadata*: bool
    wellKnownResourceFallback*: bool
    asDiscovery*: AsDiscoveryStyle
    resourceIndicator*: bool
    requirePkceMetadata*: bool
      ## Refuse an authorization server that does not advertise PKCE.
    scopeFromChallenge*: bool
    stepUp*: bool
    clientIdMetadataDocuments*: bool
    unionScopesOnStepUp*: bool
    validateIssuer*: bool
    issuerBoundCredentials*: bool
    applicationType*: bool

func authPolicy*(version: McpProtocolVersion): AuthPolicy {.raises: [ValueError].} =
  ## Raises for a version without authorization (2024-11-05).
  if not version.has(ftAuthorization):
    raise newException(ValueError,
      "protocol version " & $version & " has no authorization")
  AuthPolicy(
    version: version,
    defaultEndpoints: version.has(ftAuthDefaultEndpoints),
    protectedResourceMetadata: version.has(ftProtectedResourceMetadata),
    wellKnownResourceFallback: version.has(ftIncrementalScopeConsent),
    asDiscovery: if version.has(ftOidcDiscovery): adsOAuthThenOidc else: adsOAuthOnly,
    resourceIndicator: version.has(ftResourceIndicators),
    requirePkceMetadata: version.has(ftIncrementalScopeConsent),
    scopeFromChallenge: version.has(ftIncrementalScopeConsent),
    stepUp: version.has(ftIncrementalScopeConsent),
    clientIdMetadataDocuments: version.has(ftClientIdMetadataDocuments),
    unionScopesOnStepUp: version.has(ftIssuerParameter),
    validateIssuer: version.has(ftIssuerParameter),
    issuerBoundCredentials: version.has(ftIssuerParameter),
    applicationType: version.has(ftIssuerParameter))
