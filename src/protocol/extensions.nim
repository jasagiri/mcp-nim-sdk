## Extensions (2026-07-28): optional features beyond the core protocol,
## advertised in the `extensions` field of client and server capabilities as
## a map from an extension identifier to that extension's settings object.
##
## Pure functions over JSON, shared by the server and the client.

import std/[json, options, strutils]

const
  ## Result types the core protocol defines; extensions may add more.
  CoreResultTypes* = ["complete", "input_required"]

  ## Every request method any version of the core protocol defines; an
  ## extension cannot take one over.
  CoreMethods* = [
    "initialize", "ping", "server/discover", "subscriptions/listen",
    "tools/list", "tools/call", "resources/list", "resources/templates/list",
    "resources/read", "resources/subscribe", "resources/unsubscribe",
    "prompts/list", "prompts/get", "completion/complete", "logging/setLevel",
    "sampling/createMessage", "elicitation/create", "roots/list",
    "tasks/get", "tasks/result", "tasks/cancel", "tasks/list"
  ]

func isCoreMethod*(methodName: string): bool {.raises: [].} =
  methodName in CoreMethods

func isLabel(label: string): bool {.raises: [].} =
  ## A letter first, a letter or digit last, letters, digits and hyphens
  ## between.
  label.len > 0 and label[0] in Letters and label[^1] in Letters + Digits and
    label.allCharsInSet(Letters + Digits + {'-'})

func validateExtensionId*(id: string): Option[string] {.raises: [].} =
  ## Why `id` is not an extension identifier, or none when it is. An
  ## identifier follows the `_meta` key naming rules with a mandatory
  ## prefix: reverse-DNS labels, a slash, then a name.
  let slash = id.find('/')
  if slash < 0:
    return some("an extension identifier needs a prefix such as 'com.example/'")
  for label in id[0 ..< slash].split('.'):
    if not isLabel(label):
      return some("prefix label '" & label & "' of '" & id & "' must start with a " &
                  "letter, end with a letter or digit and hold letters, digits and hyphens")
  let name = id[slash + 1 .. ^1]
  if name.len == 0 or name[0] notin Letters + Digits or name[^1] notin Letters + Digits or
     not name.allCharsInSet(Letters + Digits + {'-', '_', '.'}):
    return some("the name of '" & id & "' must start and end with a letter or digit and " &
                "hold letters, digits, hyphens, underscores and dots")
  none(string)

func extensionsOf*(capabilities: JsonNode): JsonNode {.raises: [].} =
  ## The `extensions` object of a capabilities object; JSON null when the
  ## peer declared none (or declared something that is not an object).
  if capabilities.isNil or capabilities.kind != JObject:
    return newJNull()
  let node = capabilities{"extensions"}
  if node.isNil or node.kind != JObject: newJNull() else: node

func settingsOf*(capabilities: JsonNode, id: string): Option[JsonNode] {.raises: [].} =
  ## The settings the peer declared for extension `id`, if it declared it.
  ## A declaration whose settings are not an object is not a declaration.
  let declared = extensionsOf(capabilities)
  if declared.kind != JObject:
    return none(JsonNode)
  let settings = declared{id}
  if settings.isNil or settings.kind != JObject: none(JsonNode) else: some(settings)

func requiredExtension*(id: string): JsonNode {.raises: [].} =
  ## The `requiredCapabilities` of a missing-capability error for `id`.
  %*{"extensions": {id: {}}}
