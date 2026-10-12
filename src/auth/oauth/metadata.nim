## The two metadata documents of OAuth discovery: Protected Resource
## Metadata (RFC 9728) and Authorization Server Metadata (RFC 8414 / OpenID
## Connect Discovery). Both come from the network, so parsing checks types
## and the identity of the document, not just its shape.

import std/[json, options]
import ./errors
import ./urls

type
  ProtectedResourceMetadata* = object
    resource*: string
    authorizationServers*: seq[string]
    scopesSupported*: seq[string]

  AuthorizationServerMetadata* = object
    issuer*: string
    authorizationEndpoint*: string
    tokenEndpoint*: string
    registrationEndpoint*: Option[string]
    scopesSupported*: seq[string]
    codeChallengeMethodsSupported*: Option[seq[string]]
      ## `none` when the document has no such field, which means the server
      ## does not support PKCE.
    clientIdMetadataDocumentSupported*: bool
    authorizationResponseIssParameterSupported*: bool
    document*: JsonNode
      ## The validated document as received, for the fields an extension
      ## reads that this module does not model (RFC 8414 allows any number).

func optString(doc: JsonNode, key: string): Option[string] {.raises: [OAuthError].} =
  let node = doc{key}
  if node.isNil or node.kind == JNull:
    return none(string)
  if node.kind != JString:
    raise newException(OAuthError, "metadata field " & key & " is not a string")
  some(node.getStr())

func requiredString(doc: JsonNode, key: string): string {.raises: [OAuthError].} =
  let value = doc.optString(key)
  if value.isNone or value.get.len == 0:
    raise newException(OAuthError, "metadata field " & key & " is missing")
  value.get

func optStrings(doc: JsonNode, key: string): Option[seq[string]] {.raises: [OAuthError].} =
  let node = doc{key}
  if node.isNil or node.kind == JNull:
    return none(seq[string])
  if node.kind != JArray:
    raise newException(OAuthError, "metadata field " & key & " is not an array")
  var values: seq[string]
  for item in node:
    if item.kind != JString:
      raise newException(OAuthError, "metadata field " & key & " has a non-string entry")
    values.add item.getStr()
  some(values)

func optBool(doc: JsonNode, key: string): bool {.raises: [OAuthError].} =
  let node = doc{key}
  if node.isNil or node.kind == JNull:
    return false
  if node.kind != JBool:
    raise newException(OAuthError, "metadata field " & key & " is not a boolean")
  node.getBool()

proc parseProtectedResourceMetadata*(doc: JsonNode, requestedResource: string,
                                     policy: FetchPolicy,
                                     alsoAccepted: openArray[string] = []
                                    ): ProtectedResourceMetadata
                                    {.raises: [OAuthError].} =
  ## RFC 9728 3.3: the `resource` of the document must be the resource the
  ## client asked about, or a server could vouch for another one; a document
  ## that names another resource raises OAuthSecurityError, an OAuthError.
  ## `alsoAccepted` are other identifiers the document may name, for a
  ## document fetched from a URL that was not built from `requestedResource`.
  ## MCP additionally requires at least one authorization server.
  if doc.kind != JObject:
    raise newException(OAuthError, "protected resource metadata is not a JSON object")
  result.resource = doc.requiredString("resource")
  var named = canonicalResource(result.resource) == canonicalResource(requestedResource)
  for identifier in alsoAccepted:
    named = named or canonicalResource(result.resource) == canonicalResource(identifier)
  if not named:
    raise newException(OAuthSecurityError,
      "protected resource metadata describes " & result.resource &
      ", not " & requestedResource)
  result.authorizationServers = doc.optStrings("authorization_servers").get(@[])
  if result.authorizationServers.len == 0:
    raise newException(OAuthError,
      "protected resource metadata lists no authorization_servers")
  for server in result.authorizationServers:
    checkFetchUrl(server, policy, "authorization server")
  result.scopesSupported = doc.optStrings("scopes_supported").get(@[])

proc parseAuthorizationServerMetadata*(doc: JsonNode, expectedIssuer: string,
                                       policy: FetchPolicy): AuthorizationServerMetadata
                                      {.raises: [OAuthError].} =
  ## RFC 8414 3.3: the `issuer` must be identical to the identifier the
  ## well-known URL was built from, or the document may belong to someone
  ## else (the mix-up the specification names); another issuer raises
  ## OAuthSecurityError, an OAuthError.
  if doc.kind != JObject:
    raise newException(OAuthError, "authorization server metadata is not a JSON object")
  result.issuer = doc.requiredString("issuer")
  if result.issuer != expectedIssuer:
    raise newException(OAuthSecurityError,
      "authorization server metadata names issuer " & result.issuer &
      " but was fetched for " & expectedIssuer)
  result.authorizationEndpoint = doc.requiredString("authorization_endpoint")
  result.tokenEndpoint = doc.requiredString("token_endpoint")
  checkFetchUrl(result.authorizationEndpoint, policy, "authorization endpoint")
  checkFetchUrl(result.tokenEndpoint, policy, "token endpoint")
  result.registrationEndpoint = doc.optString("registration_endpoint")
  if result.registrationEndpoint.isSome:
    checkFetchUrl(result.registrationEndpoint.get, policy, "registration endpoint")
  result.scopesSupported = doc.optStrings("scopes_supported").get(@[])
  result.codeChallengeMethodsSupported = doc.optStrings("code_challenge_methods_supported")
  result.clientIdMetadataDocumentSupported = doc.optBool("client_id_metadata_document_supported")
  result.authorizationResponseIssParameterSupported =
    doc.optBool("authorization_response_iss_parameter_supported")
  result.document = doc

func defaultEndpointMetadata*(serverUrl: string): AuthorizationServerMetadata {.raises: [].} =
  ## Version 2025-03-26 for a server without metadata: `/authorize`,
  ## `/token` and `/register` on the server's origin.
  let base = originOf(serverUrl)
  AuthorizationServerMetadata(
    issuer: base,
    authorizationEndpoint: base & "/authorize",
    tokenEndpoint: base & "/token",
    registrationEndpoint: some(base & "/register"))
