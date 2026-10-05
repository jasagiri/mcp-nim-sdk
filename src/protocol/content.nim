## What tool definitions, tool results and the descriptive fields of the
## lists look like on the wire in each protocol version.
##
## A server builds these as JSON and a handler may fill in any field its
## author knows; what leaves the server is what the negotiated version
## defines (`toolFor`, `toolResultFor`, ...): a field the version does not
## have is not sent.

import std/[json, options]
import ./features
import ./version

type
  McpShapeError* = object of ValueError
    ## A field of a message has the wrong JSON type.

  McpToolAnnotations* = object
    ## Hints about a tool (2025-03-26 and later). They are hints: a client
    ## MUST treat them as untrusted unless the server is trusted, and this
    ## library never acts on them itself.
    title*: Option[string]
    readOnlyHint*: Option[bool]
    destructiveHint*: Option[bool]
    idempotentHint*: Option[bool]
    openWorldHint*: Option[bool]

func isReadOnly*(a: McpToolAnnotations): bool {.raises: [].} =
  ## Default: false.
  a.readOnlyHint.get(false)

func isDestructive*(a: McpToolAnnotations): bool {.raises: [].} =
  ## `destructiveHint` (default: true) means something only for a tool that
  ## is not read-only.
  not a.isReadOnly and a.destructiveHint.get(true)

func isIdempotent*(a: McpToolAnnotations): bool {.raises: [].} =
  ## `idempotentHint` (default: false) means something only for a tool that
  ## is not read-only.
  not a.isReadOnly and a.idempotentHint.get(false)

func isOpenWorld*(a: McpToolAnnotations): bool {.raises: [].} =
  ## Default: true.
  a.openWorldHint.get(true)

proc optionalField[T](node: JsonNode, key: string, kind: JsonNodeKind,
                      read: proc(n: JsonNode): T {.noSideEffect.}): Option[T] =
  let value = node{key}
  if value.isNil:
    return none(T)
  if value.kind != kind:
    raise newException(McpShapeError, "'" & key & "' must be a JSON " &
      (case kind
       of JString: "string"
       of JBool: "boolean"
       else: $kind))
  some(read(value))

proc optionalStringField*(node: JsonNode, key: string): Option[string] =
  ## A string field that may be absent; present with another type raises
  ## McpShapeError.
  optionalField(node, key, JString, proc(n: JsonNode): string = n.getStr())

proc optionalBoolField*(node: JsonNode, key: string): Option[bool] =
  optionalField(node, key, JBool, proc(n: JsonNode): bool = n.getBool())

proc parseToolAnnotations*(node: JsonNode): McpToolAnnotations =
  ## Raises McpShapeError when `node` is not an object or a hint has the
  ## wrong type.
  if node.isNil or node.kind != JObject:
    raise newException(McpShapeError, "annotations must be a JSON object")
  McpToolAnnotations(
    title: optionalStringField(node, "title"),
    readOnlyHint: optionalBoolField(node, "readOnlyHint"),
    destructiveHint: optionalBoolField(node, "destructiveHint"),
    idempotentHint: optionalBoolField(node, "idempotentHint"),
    openWorldHint: optionalBoolField(node, "openWorldHint"))

func toJson*(a: McpToolAnnotations): JsonNode {.raises: [].} =
  ## Only the hints that are set.
  result = newJObject()
  if a.title.isSome: result["title"] = %a.title.get
  if a.readOnlyHint.isSome: result["readOnlyHint"] = %a.readOnlyHint.get
  if a.destructiveHint.isSome: result["destructiveHint"] = %a.destructiveHint.get
  if a.idempotentHint.isSome: result["idempotentHint"] = %a.idempotentHint.get
  if a.openWorldHint.isSome: result["openWorldHint"] = %a.openWorldHint.get

# What a version sends

proc dropKey(node: JsonNode, key: string) =
  if node.hasKey(key):
    node.delete(key)

func objectOnly(node: JsonNode): bool =
  not node.isNil and node.kind == JObject

proc toolFor*(version: McpProtocolVersion, tool: JsonNode): JsonNode =
  ## `tool` (an entry of tools/list) as `version` defines it.
  if not tool.objectOnly:
    return tool
  result = tool.copy()
  if not version.has(ftToolAnnotations):
    result.dropKey("annotations")
