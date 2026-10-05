## What tool definitions, tool results and the descriptive fields of the
## lists look like on the wire in each protocol version.
##
## A server builds these as JSON and a handler may fill in any field its
## author knows; what leaves the server is what the negotiated version
## defines (`toolFor`, `toolResultFor`, ...): a field the version does not
## have is not sent.

import std/[json, options]
import ./features
import ./json_schema
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
  if not version.has(ftStructuredToolOutput):
    result.dropKey("outputSchema")

proc textBlock(text: string): JsonNode =
  %*{"type": "text", "text": text}

proc contentBlockFor*(version: McpProtocolVersion, blk: JsonNode): JsonNode =
  ## A content block (of a tool result or a prompt message) as `version`
  ## defines it. A block of a type the version does not have is replaced by a
  ## text block that says what it was, so that the reader is told and no
  ## client meets a type it cannot parse.
  if not blk.objectOnly:
    return blk
  case blk{"type"}.getStr()
  of "audio":
    if version.has(ftAudioContent):
      return blk
    textBlock("[audio content (" & blk{"mimeType"}.getStr() &
              ") omitted: protocol version " & $version & " has no audio content]")
  of "resource_link":
    if version.has(ftResourceLinks):
      return blk
    textBlock(blk{"name"}.getStr() & ": " & blk{"uri"}.getStr())
  else:
    blk

proc toolResultFor*(version: McpProtocolVersion, callResult: JsonNode): JsonNode =
  ## A CallToolResult as `version` defines it.
  if not callResult.objectOnly:
    return callResult
  result = callResult.copy()
  if result.hasKey("content") and result["content"].kind == JArray:
    var blocks = newJArray()
    for item in result["content"]:
      blocks.add version.contentBlockFor(item)
    result["content"] = blocks
  if not version.has(ftStructuredToolOutput) and result.hasKey("structuredContent"):
    # The data still reaches a client that has no field for it: as the text
    # block the specification asks structured results to come with.
    let structured = result["structuredContent"]
    result.dropKey("structuredContent")
    if not result.hasKey("content") or result["content"].kind != JArray or
       result["content"].len == 0:
      result["content"] = %*[textBlock($structured)]

proc promptResultFor*(version: McpProtocolVersion, prompt: JsonNode): JsonNode =
  ## A GetPromptResult as `version` defines it.
  if not prompt.objectOnly:
    return prompt
  result = prompt.copy()
  if result.hasKey("messages") and result["messages"].kind == JArray:
    for message in result["messages"]:
      if message.objectOnly and message.hasKey("content"):
        message["content"] = version.contentBlockFor(message["content"])

proc withSerializedText*(callResult: JsonNode): JsonNode =
  ## A result that has `structuredContent` and no content gains the
  ## serialized JSON as a text block: "a tool that returns structured content
  ## SHOULD also return the serialized JSON in a TextContent block"
  ## (2025-06-18, server/tools).
  if not callResult.objectOnly or not callResult.hasKey("structuredContent"):
    return callResult
  let content = callResult{"content"}
  if not content.isNil and content.kind == JArray and content.len > 0:
    return callResult
  result = callResult.copy()
  result["content"] = %*[textBlock($callResult["structuredContent"])]

proc outputProblems*(version: McpProtocolVersion, outputSchema, callResult: JsonNode): seq[string] =
  ## What is wrong with the `structuredContent` of `callResult` for a tool
  ## whose `outputSchema` is given; empty when it is right. Raises
  ## InvalidSchemaError (or a subclass, UnsupportedDialectError among them)
  ## when the schema cannot be checked.
  ##
  ## Nothing is wrong when the version has no structured output, or when the
  ## result reports a tool failure (`isError`): that is not a structured
  ## result. Before 2026-07-28 `structuredContent` is a JSON object; from
  ## then on it is any JSON value.
  if not version.has(ftStructuredToolOutput) or not callResult.objectOnly or
     callResult{"isError"}.getBool(false):
    return
  if not callResult.hasKey("structuredContent"):
    return @["the tool has an outputSchema but the result has no structuredContent"]
  let structured = callResult["structuredContent"]
  if structured.kind != JObject and version < mpv20260728:
    return @["structuredContent must be a JSON object in protocol version " & $version]
  for violation in validate(outputSchema, structured):
    result.add (if violation.path.len == 0: "" else: violation.path & ": ") & violation.message
