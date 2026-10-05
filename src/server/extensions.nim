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
                        resultTypes: openArray[string] = [],
                        onLegacyHandshake = false) =
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
  if onLegacyHandshake and id notin server.legacyExtensions:
    server.legacyExtensions.add id
  for resultType in resultTypes:
    server.extensionResultTypes[resultType] = id

proc registerExtensionMethod*(server: McpServer, extensionId, methodName: string,
                              handler: ExtensionMethodHandler) =
  ## Serve `methodName` for extension `extensionId` (declared with
  ## `registerExtension`). Only a client that declared the extension may call
  ## it. Raises ValueError for an undeclared extension, a method of the core
  ## protocol (but for the ones an official extension takes over, see
  ## `takesOver`), or a method already registered.
  if server.capabilities.extensions.isNone or
     not server.capabilities.extensions.get.hasKey(extensionId):
    raise newException(ValueError, "extension " & extensionId &
      " is not declared; call registerExtension first")
  if methodName in server.extensionMethods or methodName in server.requestHandlers or
     (isCoreMethod(methodName) and not takesOver(extensionId, methodName)):
    raise newException(ValueError, "method " & methodName & " is already defined")
  server.extensionMethods[methodName] = ExtensionMethod(
    extensionId: extensionId, handler: handler)

proc registerTopLevelCapability*(server: McpServer, name: string, settings: JsonNode = nil) =
  ## Declare a top-level capability the core does not define, for a
  ## specification that names its own (to 2026-07-28 clients only). Raises
  ## ValueError for a name the core defines or `extensions`, or settings that
  ## are not an object.
  if name in ["prompts", "resources", "tools", "logging", "completions", "tasks",
              "experimental", "extensions", "roots", "sampling", "elicitation"]:
    raise newException(ValueError, "'" & name & "' is a capability of the core")
  if not settings.isNil and settings.kind != JObject:
    raise newException(ValueError, "the settings of " & name & " must be a JSON object")
  var declared =
    if server.capabilities.additional.isSome: server.capabilities.additional.get
    else: newJObject()
  declared[name] = if settings.isNil: newJObject() else: settings
  server.capabilities.additional = some(declared)

proc registerOpenMethod*(server: McpServer, methodName: string,
                         handler: ExtensionMethodHandler) =
  ## Serve `methodName` of a specification that does not ask the client to
  ## declare anything (its server-side capability, see
  ## `registerTopLevelCapability`, is what a client looks at). 2026-07-28
  ## only. Raises ValueError for a method of the core or one already defined.
  if methodName in server.extensionMethods or methodName in server.requestHandlers or
     isCoreMethod(methodName):
    raise newException(ValueError, "method " & methodName & " is already defined")
  server.extensionMethods[methodName] = ExtensionMethod(extensionId: "", handler: handler)

proc clientExtension*(ctx: McpRequestContext, id: string): Option[JsonNode] =
  ## The settings the client of this request declared for extension `id`;
  ## none when it declared none. Before 2026-07-28 only what the `initialize`
  ## request carried counts, which a client sends only for an extension
  ## declared for the legacy handshake.
  settingsOf(ctx.declaredCapabilities, id)

proc requireClientExtension*(ctx: McpRequestContext, id: string) =
  ## For a handler whose work needs extension `id`: raises the request error
  ## the specification asks for when the client did not declare it.
  if ctx.clientExtension(id).isNone:
    let error = missingCapabilityError(
      "This request needs the extension " & id, requiredExtension(id))
    raise newRequestError(error.code, error.message, error.data)
