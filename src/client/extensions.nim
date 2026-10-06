## Extensions on the client (2026-07-28): declare the extensions this client
## supports, read which ones the server declared, and call the methods an
## extension defines. An extension is a separate specification; this module
## is only the place it plugs into.
##
##   client.declareExtension("com.example/widgets", %*{"flavour": "blue"},
##                           resultTypes = ["widget_job"])   # before connect()
##   await client.connect(transport)
##   let answer = await client.callExtension("com.example/widgets", "widgets/make",
##                                           %*{"kind": "gear"})

import std/[asyncdispatch, json, options]
import ./client
import ../protocol/features
import ../protocol/types
import ../protocol/extensions

export extensions

proc declareExtension*(client: McpClient, id: string, settings: JsonNode = nil,
                       resultTypes: openArray[string] = [],
                       onLegacyHandshake = false) =
  ## Declare support for extension `id`, with `settings` (an object; none
  ## means empty), in the capabilities of every 2026-07-28 request.
  ## `resultTypes` are the `resultType` values the extension defines, which
  ## this client then accepts instead of treating them as unknown.
  ## `onLegacyHandshake` also sends the declaration in the `initialize`
  ## request of the versions before 2026-07-28, which otherwise carry no
  ## `extensions` (for an extension whose specification declares itself
  ## there); other extensions are left out of it as before. Call
  ## before connect(). Raises ValueError for a malformed identifier or
  ## settings.
  client.requireNotConnected("the extension " & id)
  let problem = validateExtensionId(id)
  if problem.isSome:
    raise newException(ValueError, problem.get)
  if not settings.isNil and settings.kind != JObject:
    raise newException(ValueError, "the settings of " & id & " must be a JSON object")
  var declared =
    if client.capabilities.extensions.isSome: client.capabilities.extensions.get
    else: newJObject()
  declared[id] = if settings.isNil: newJObject() else: settings
  client.capabilities.extensions = some(declared)
  if onLegacyHandshake and id notin client.legacyExtensions:
    client.legacyExtensions.add id
  for resultType in resultTypes:
    if resultType in CoreResultTypes:
      raise newException(ValueError, "'" & resultType & "' is a core result type")
    client.extensionResultTypes.add resultType

proc serverExtension*(client: McpClient, id: string): Option[JsonNode] =
  ## The settings the server declared for extension `id`; none when it did
  ## not, or before the client has connected.
  if client.serverCapabilities.isNone or client.serverCapabilities.get.extensions.isNone:
    return none(JsonNode)
  let declared = client.serverCapabilities.get.extensions.get
  let settings = declared{id}
  if settings.isNil or settings.kind != JObject: none(JsonNode) else: some(settings)

proc serverCapability*(client: McpClient, name: string): Option[JsonNode] =
  ## The settings of a top-level capability the core does not define, as the
  ## server declared it; none when it did not, before the client has
  ## connected. Whether it means anything depends on the specification that
  ## defines the capability; check the version it needs.
  if client.serverCapabilities.isNone or client.serverCapabilities.get.additional.isNone:
    return none(JsonNode)
  let settings = client.serverCapabilities.get.additional.get{name}
  if settings.isNil or settings.kind != JObject: none(JsonNode) else: some(settings)

proc callExtension*(client: McpClient, extensionId, methodName: string,
                    params: JsonNode = nil,
                    options: McpRequestOptions = McpRequestOptions(),
                    clientDeclares = true): Future[JsonNode] {.async.} =
  ## Call `methodName`, a method of extension `extensionId`, and return the
  ## result object, which may carry a `resultType` the extension defines.
  ## Raises McpUnsupportedError, sending nothing, when the connection is not
  ## 2026-07-28, this client did not declare the extension, or the server did
  ## not; the server's errors raise McpRequestError. `clientDeclares = false`
  ## is for an extension the server alone declares: the client's own
  ## declaration is then not asked for.
  client.requireFeature(ftExtensions, methodName)
  if clientDeclares and (client.capabilities.extensions.isNone or
     not client.capabilities.extensions.get.hasKey(extensionId)):
    raise newException(McpUnsupportedError,
      methodName & ": this client did not declare the extension " & extensionId)
  if client.serverExtension(extensionId).isNone:
    raise newException(McpUnsupportedError,
      methodName & ": the server does not declare the extension " & extensionId)
  return await client.callMethod(methodName, params, options)
