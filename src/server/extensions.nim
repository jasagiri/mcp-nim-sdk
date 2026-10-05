## Extensions on the server (2026-07-28): declare an extension, register the
## methods and result types it defines, and read what the client declared.
##
## An extension is a separate specification; this module is only the place
## it plugs into. A request for one of its methods from a client that did not
## declare it is answered with the missing-capability error.
##
##   server.registerExtension("com.example/widgets", %*{"flavours": ["a"]},
##                            resultTypes = ["widget_job"])
##   server.registerExtensionMethod("com.example/widgets", "widgets/make",
##     proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} =
##       return %*{"made": params{"kind"}})

import std/[json, options, tables]
import ./server
import ../protocol/types
import ../protocol/extensions
import ../protocol/modern

export extensions

proc registerExtension*(server: McpServer, id: string, settings: JsonNode = nil,
                        resultTypes: openArray[string] = []) =
  ## Declare extension `id` in the server's capabilities, with `settings` (an
  ## object; none means empty). `resultTypes` are the `resultType` values the
  ## extension defines, which its handlers may return. Raises ValueError for
  ## an identifier that breaks the naming rules, a settings value that is not
  ## an object, or a result type that is a core one or another extension's.
  let problem = validateExtensionId(id)
  if problem.isSome:
    raise newException(ValueError, problem.get)
  if not settings.isNil and settings.kind != JObject:
    raise newException(ValueError, "the settings of " & id & " must be a JSON object")
  for resultType in resultTypes:
    if resultType in CoreResultTypes:
      raise newException(ValueError, "'" & resultType & "' is a core result type")
    let owner = server.extensionResultTypes.getOrDefault(resultType)
    if owner.len > 0 and owner != id:
      raise newException(ValueError, "result type '" & resultType &
        "' already belongs to " & owner)
  var declared =
    if server.capabilities.extensions.isSome: server.capabilities.extensions.get
    else: newJObject()
  declared[id] = if settings.isNil: newJObject() else: settings
  server.capabilities.extensions = some(declared)
  for resultType in resultTypes:
    server.extensionResultTypes[resultType] = id

proc registerExtensionMethod*(server: McpServer, extensionId, methodName: string,
                              handler: ExtensionMethodHandler) =
  ## Serve `methodName` for extension `extensionId` (declared with
  ## `registerExtension`). Only a client that declared the extension may call
  ## it. Raises ValueError for an undeclared extension, a method of the core
  ## protocol, or a method already registered.
  if server.capabilities.extensions.isNone or
     not server.capabilities.extensions.get.hasKey(extensionId):
    raise newException(ValueError, "extension " & extensionId &
      " is not declared; call registerExtension first")
  if methodName in server.extensionMethods or methodName in server.requestHandlers or
     isCoreMethod(methodName):
    raise newException(ValueError, "method " & methodName & " is already defined")
  server.extensionMethods[methodName] = ExtensionMethod(
    extensionId: extensionId, handler: handler)

proc clientExtension*(ctx: McpRequestContext, id: string): Option[JsonNode] =
  ## The settings the client of this request declared for extension `id`;
  ## none when it declared none, and always none before 2026-07-28.
  settingsOf(ctx.clientCapabilities, id)

proc requireClientExtension*(ctx: McpRequestContext, id: string) =
  ## For a handler whose work needs extension `id`: raises the request error
  ## the specification asks for when the client did not declare it.
  if ctx.clientExtension(id).isNone:
    let error = missingCapabilityError(
      "This request needs the extension " & id, requiredExtension(id))
    raise newRequestError(error.code, error.message, error.data)
