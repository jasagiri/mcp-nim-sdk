## What a server's handler may hand to a client: the checks of the results a
## handler builds itself (prompt messages, resource contents, the tool list,
## cache hints).
##
## A handler returns JSON and the server forwards it; a value the
## specification does not allow is the handler's defect, so each check
## returns the problems it found and the caller refuses to send the result
## (the client gets an internal error, the cause stays on the server's side).
## Nothing here is corrected: a value is accepted as it is or reported.

import std/[json, options, tables]
import ../jsonschema/json_schema
import ./base64_shape
import ./modern
import ./version

func isFilledString(node: JsonNode, key: string): bool {.raises: [].} =
  not node{key}.isNil and node{key}.kind == JString and node{key}.getStr().len > 0

func isBase64String(node: JsonNode, key: string): bool {.raises: [].} =
  not node{key}.isNil and node{key}.kind == JString and isPaddedBase64(node{key}.getStr())

func blobProblems(subject: string, content: JsonNode): seq[string] {.raises: [].} =
  if content.hasKey("blob") and not content.isBase64String("blob"):
    result.add subject & ": blob is not base64"

func resourceContentProblems(subject: string, content: JsonNode): seq[string] {.raises: [].} =
  ## The text or blob of one resource: a `uri`, a `mimeType`, and either
  ## `text` or a base64 `blob` (prompts, server/prompts: "MUST include").
  if content.isNil or content.kind != JObject:
    return @[subject & " is not an object"]
  if not content.isFilledString("uri"):
    result.add subject & ": no uri"
  if not content.isFilledString("mimeType"):
    result.add subject & ": no mimeType"
  let hasText = content.hasKey("text") and content{"text"}.kind == JString
  let hasBlob = content.hasKey("blob")
  if not hasText and not hasBlob:
    result.add subject & ": neither text nor blob"
  result.add blobProblems(subject, content)

func contentBlockProblems(subject: string, blk: JsonNode): seq[string] {.raises: [].} =
  if blk.isNil or blk.kind != JObject:
    return
  case blk{"type"}.getStr()
  of "image":
    if not blk.isBase64String("data"):
      result.add subject & ": image data is not base64"
    if not blk.isFilledString("mimeType"):
      result.add subject & ": image has no mimeType"
  of "resource":
    let resource = blk{"resource"}
    if resource.isNil:
      result.add subject & ": embedded resource without resource"
    else:
      result.add resourceContentProblems(subject & ".resource", resource)
  else:
    discard

func promptResultProblems*(prompt: JsonNode): seq[string] {.raises: [].} =
  ## What is wrong with the images and embedded resources of the messages of
  ## a GetPromptResult; empty when it is right.
  if prompt.isNil or prompt.kind != JObject or prompt{"messages"}.isNil or prompt{"messages"}.kind != JArray:
    return
  for i, message in prompt{"messages"}.getElems():
    if message.isNil or message.kind != JObject or message{"content"}.isNil:
      continue
    let subject = "messages[" & $i & "].content"
    let content = message{"content"}
    if content.kind == JArray:
      for j, blk in content.getElems():
        result.add contentBlockProblems(subject & "[" & $j & "]", blk)
    else:
      result.add contentBlockProblems(subject, content)

func resourceContentsProblems*(contents: openArray[JsonNode]): seq[string] {.raises: [].} =
  ## What is wrong with the `contents` of a resources/read result: the blob of
  ## each entry that has one is base64 (server/resources).
  for i, content in contents:
    if not content.isNil and content.kind == JObject:
      result.add blobProblems("contents[" & $i & "]", content)

func toolListingProblems*(version: McpProtocolVersion, tool: JsonNode): seq[string] {.raises: [].} =
  ## What is wrong with an entry of tools/list for `version`. From 2025-11-25
  ## the `inputSchema` "MUST be a valid JSON Schema object (not null)"; from
  ## 2026-07-28 its root is `type: "object"`. A tool without an `inputSchema`
  ## is not judged here.
  if tool.isNil or tool.kind != JObject or tool{"inputSchema"}.isNil:
    return
  let schema = tool{"inputSchema"}
  let subject = "tool '" & tool{"name"}.getStr() & "'"
  if version >= mpv20251125 and schema.kind != JObject:
    result.add subject & ": inputSchema is not a JSON Schema object"
  elif version >= mpv20260728 and schema{"type"} != %"object":
    result.add subject & ": the root of inputSchema is not type object"

func cacheHintProblem*(methodName: string, payload: JsonNode): Option[string] {.raises: [].} =
  ## Why the cache hints a handler put in a complete result of a cacheable
  ## method cannot be sent (caching): "Servers MUST provide a ttlMs value
  ## that is >= 0", and `cacheScope` is `public` or `private`. A hint that is
  ## absent is the server's own policy and is filled in by `completeResult`.
  if not isCacheable(methodName) or resultKind(payload) != rkComplete:
    return none(string)
  let ttl = payload{"ttlMs"}
  if not ttl.isNil and (ttl.kind != JInt or ttl.getInt() < 0):
    return some("ttlMs is not an integer of 0 or more")
  let scope = payload{"cacheScope"}
  if not scope.isNil and (scope.kind != JString or scope.getStr() notin ["public", "private"]):
    return some("cacheScope is not public or private")
  none(string)

func blocksOf(content: JsonNode): seq[JsonNode] {.raises: [].} =
  if content.kind == JArray: content.getElems() else: @[content]

proc samplingToolResultProblems*(params: JsonNode): seq[string] =
  ## A tool_result of a sampling/createMessage request whose
  ## `structuredContent` does not conform to the `outputSchema` of the tool it
  ## answers (schema, ToolResultContent). The tool is the one named by the
  ## tool_use the result answers; a tool the request does not list, or lists
  ## without an outputSchema, has nothing to check against. Whether the
  ## request is well formed is `createMessageParamsProblems`.
  if params.isNil or params.kind != JObject or
     params{"messages"}.isNil or params{"messages"}.kind != JArray or
     params{"tools"}.isNil or params{"tools"}.kind != JArray:
    return
  var nameOfUse = initTable[string, string]()
  for message in params{"messages"}:
    if message.kind == JObject and not message{"content"}.isNil:
      for blk in blocksOf(message{"content"}):
        if blk.kind == JObject and blk{"type"}.getStr() == "tool_use":
          nameOfUse[blk{"id"}.getStr()] = blk{"name"}.getStr()
  for i, message in params{"messages"}.getElems():
    if message.kind != JObject or message{"content"}.isNil:
      continue
    for j, blk in blocksOf(message{"content"}):
      if blk.kind != JObject or blk{"type"}.getStr() != "tool_result" or
         blk{"structuredContent"}.isNil:
        continue
      let name = nameOfUse.getOrDefault(blk{"toolUseId"}.getStr())
      for tool in params{"tools"}:
        if tool.kind != JObject or tool{"name"}.getStr() != name or
           tool{"outputSchema"}.isNil or tool{"outputSchema"}.kind != JObject:
          continue
        let subject = "messages[" & $i & "].content[" & $j &
                      "]: the structuredContent for tool '" & name & "'"
        try:
          for violation in validate(tool{"outputSchema"}, blk{"structuredContent"}):
            result.add subject & " breaks its outputSchema: " &
              (if violation.path.len == 0: "" else: violation.path & ": ") & violation.message
        except InvalidSchemaError as e:
          result.add subject & ": the outputSchema cannot be checked: " & e.msg
