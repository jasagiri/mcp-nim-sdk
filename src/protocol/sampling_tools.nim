## The payloads of sampling/createMessage that are about tools (2025-11-25
## onward): `tools` and `toolChoice` in the request, tool_use and tool_result
## blocks in messages, and a result that stops for a tool.
##
## Like `elicitation` this takes and returns JSON and knows nothing of how it
## travels. A check returns the problems it found; a caller that cannot go
## on raises `McpPayloadError` (see `payload`). The rules follow
## `schema/2025-11-25/schema.ts` and `client/sampling.mdx`.
##
## The checks of the messages hold for every request, with or without
## `tools`, because a message can carry tool blocks without the request
## listing tools (a follow-up to an earlier turn).

import std/[json, options, sets, strutils]
import ./version
import ./features
import ./payload
import ./types

export payload

const
  ContentTypes = ["text", "image", "audio"]
  ToolChoiceModes = ["auto", "required", "none"]

func isString(node: JsonNode, key: string): bool =
  not node{key}.isNil and node{key}.kind == JString

func has(node: JsonNode, key: string): bool =
  not node{key}.isNil

func usesTools*(params: JsonNode): bool =
  ## Whether a createMessage request asks for tool use: it carries `tools` or
  ## `toolChoice`.
  not params.isNil and params.kind == JObject and (params.has("tools") or params.has("toolChoice"))

func blocksOf(content: JsonNode): seq[JsonNode] =
  if content.kind == JArray: content.getElems() else: @[content]

func typeOf(block0: JsonNode): string =
  if block0.kind == JObject and block0.isString("type"): block0["type"].getStr() else: ""

func toolUseBlock*(id, name: string, input: JsonNode): JsonNode =
  ## A tool_use content block: the model's request to call `name`.
  %*{"type": "tool_use", "id": id, "name": name, "input": input}

func toolResultBlock*(toolUseId: string, content: seq[JsonNode], isError = false,
                      structuredContent: JsonNode = nil): JsonNode =
  ## A tool_result content block answering the tool_use with `toolUseId`.
  result = %*{"type": "tool_result", "toolUseId": toolUseId, "content": content}
  if not structuredContent.isNil:
    result["structuredContent"] = structuredContent
  if isError:
    result["isError"] = %true

func toolUsesOf*(answer: JsonNode): seq[JsonNode] =
  ## The tool_use blocks of a createMessage result, in order.
  if answer.isNil or answer.kind != JObject or answer{"content"}.isNil:
    return
  for block0 in blocksOf(answer["content"]):
    if block0.typeOf == "tool_use":
      result.add block0

func blockProblems(subject: string, block0: JsonNode,
                   version: McpProtocolVersion): seq[string] =
  if block0.kind != JObject or not block0.isString("type"):
    return @[subject & " is not a content block with a type"]
  let kind = block0["type"].getStr()
  case kind
  of "text":
    if not block0.isString("text"):
      result.add subject & ": text block without text"
  of "image", "audio":
    if not block0.isString("data") or not block0.isString("mimeType"):
      result.add subject & ": " & kind & " block without data and mimeType"
  of "tool_use", "tool_result":
    if not version.has(ftSamplingTools):
      return @[subject & ": " & kind & " is not part of protocol version " & $version]
    if kind == "tool_use":
      if not block0.isString("id") or block0["id"].getStr().len == 0:
        result.add subject & ": tool_use without an id"
      if not block0.isString("name"):
        result.add subject & ": tool_use without a name"
      if block0{"input"}.isNil or block0["input"].kind != JObject:
        result.add subject & ": tool_use without an input object"
    else:
      if not block0.isString("toolUseId"):
        result.add subject & ": tool_result without a toolUseId"
      if block0{"content"}.isNil or block0["content"].kind != JArray:
        result.add subject & ": tool_result without a content array"
      else:
        for entry in block0["content"]:
          if entry.kind != JObject or not entry.isString("type"):
            result.add subject & ": tool_result content holds something that is not a content block"
            break
      if block0.has("structuredContent") and block0["structuredContent"].kind != JObject:
        result.add subject & ": structuredContent is not an object"
      if block0.has("isError") and block0["isError"].kind != JBool:
        result.add subject & ": isError is not a boolean"
  else:
    result.add subject & ": content type '" & kind & "' is not a sampling content type"

func idsOf(blocks: seq[JsonNode], kind, key: string): seq[string] =
  for b in blocks:
    if b.typeOf == kind:
      result.add b{key}.getStr()

func messageProblems(index: int, message: JsonNode,
                     version: McpProtocolVersion): seq[string] =
  let subject = "messages[" & $index & "]"
  if message.kind != JObject:
    return @[subject & " is not an object"]
  if not message.isString("role") or message["role"].getStr() notin ["user", "assistant"]:
    result.add subject & ": role is not user or assistant"
  let content = message{"content"}
  if content.isNil or content.kind notin {JObject, JArray}:
    return result & (subject & ": content is not a content block or an array of them")
  if content.kind == JArray:
    if not version.has(ftSamplingTools):
      return result & (subject & ": array content is not part of protocol version " & $version)
    if content.len == 0:
      return result & (subject & ": content is an empty array")
  for i, block0 in blocksOf(content):
    result.add blockProblems(subject & ".content[" & $i & "]", block0, version)

func samplingMessagesProblems*(messages: JsonNode,
                               version: McpProtocolVersion): seq[string] =
  ## What is wrong with the `messages` of a createMessage request: each
  ## message is well formed, and tool uses and tool results pair up. An
  ## assistant message with tool_use blocks must be followed by a user
  ## message of exactly their tool_result blocks and nothing else; a
  ## tool_result answers a tool_use of the message before it.
  if messages.isNil or messages.kind != JArray:
    return @["messages is not an array"]
  var pending: seq[string]  # tool use ids the next message must answer
  var pendingFrom = -1
  for i, message in messages.getElems():
    let found = messageProblems(i, message, version)
    result.add found
    if found.len > 0:
      return  # pairing makes no sense on a malformed message
    let subject = "messages[" & $i & "]"
    let blocks = blocksOf(message["content"])
    let role = message["role"].getStr()
    let uses = idsOf(blocks, "tool_use", "id")
    let results = idsOf(blocks, "tool_result", "toolUseId")
    if uses.len > 0 and role != "assistant":
      result.add subject & ": tool_use belongs in an assistant message"
    if results.len > 0 and role != "user":
      result.add subject & ": tool_result belongs in a user message"
    if results.len > 0 and results.len != blocks.len:
      result.add subject & ": a message with tool results holds only tool results"
    if pending.len > 0 and results.len == 0:
      result.add subject & ": must answer the tool uses of messages[" & $pendingFrom &
                 "] with tool results"
    if results.len > 0:
      let expected = pending.toHashSet
      var seen = initHashSet[string]()
      for id in results:
        if id in seen:
          result.add subject & ": two tool results for '" & id & "'"
        elif id notin expected:
          result.add subject & ": tool result for '" & id & "', which no tool use of the message before asked for"
        seen.incl id
      for id in pending:
        if id notin seen:
          result.add subject & ": no tool result for the tool use '" & id & "'"
    var usedIds = initHashSet[string]()
    for id in uses:
      if id in usedIds:
        result.add subject & ": two tool uses with the id '" & id & "'"
      usedIds.incl id
    pending = uses
    pendingFrom = i
  if pending.len > 0:
    result.add "messages[" & $pendingFrom & "]: its tool uses are not answered by a following message"

func toolsProblems(tools: JsonNode): seq[string] =
  if tools.kind != JArray:
    return @["tools is not an array"]
  var names = initHashSet[string]()
  for i, tool in tools.getElems():
    let subject = "tools[" & $i & "]"
    if tool.kind != JObject or not tool.isString("name") or tool["name"].getStr().len == 0:
      result.add subject & " has no name"
    elif tool["name"].getStr() in names:
      result.add subject & ": the tool name '" & tool["name"].getStr() & "' is used twice"
    else:
      names.incl tool["name"].getStr()
    if tool.kind == JObject and
       (tool{"inputSchema"}.isNil or tool["inputSchema"].kind != JObject or
        tool["inputSchema"]{"type"} != %"object"):
      result.add subject & " has no inputSchema of type object"

func createMessageParamsProblems*(params: JsonNode,
                                  version: McpProtocolVersion): seq[string] =
  ## What is wrong with the params of a sampling/createMessage request:
  ## messages, maxTokens, and when present tools and toolChoice. Whether the
  ## client may be sent tools at all is `samplingToolsUnavailable`.
  if params.isNil or params.kind != JObject:
    return @["params is not an object"]
  result.add samplingMessagesProblems(params{"messages"}, version)
  if params{"maxTokens"}.isNil or params["maxTokens"].kind != JInt:
    result.add "maxTokens is not an integer"
  if params.has("tools"):
    if not version.has(ftSamplingTools):
      result.add "tools is not part of protocol version " & $version
    else:
      result.add toolsProblems(params["tools"])
  if params.has("toolChoice"):
    if not version.has(ftSamplingTools):
      result.add "toolChoice is not part of protocol version " & $version
    else:
      let choice = params["toolChoice"]
      if choice.kind != JObject:
        result.add "toolChoice is not an object"
      elif choice.has("mode") and (choice["mode"].kind != JString or
                                   choice["mode"].getStr() notin ToolChoiceModes):
        result.add "toolChoice.mode is not one of " & ToolChoiceModes.join(", ")

func samplingToolsUnavailable*(params: JsonNode, version: McpProtocolVersion,
                               capability: McpSamplingCapability): Option[string] =
  ## Why a request that uses tools cannot go to this client, or none: the
  ## version must have sampling tools and the client must have declared
  ## `sampling.tools`. Servers MUST NOT send tools otherwise, and a client
  ## MUST answer such a request with an error.
  if not params.usesTools:
    return none(string)
  if not version.has(ftSamplingTools):
    return some("tools in sampling are not part of protocol version " & $version)
  if not capability.tools:
    return some("the client did not declare the sampling.tools capability")
  none(string)

func createMessageResultProblems*(answer, params: JsonNode,
                                  version: McpProtocolVersion): seq[string] =
  ## What is wrong with `answer`, the result of a request with `params`: it
  ## is a message with a model, it stops for tool use exactly when it holds
  ## tool_use blocks, and it asks for tools only as the request allowed.
  if answer.isNil or answer.kind != JObject:
    return @["the result is not an object"]
  if not answer.isString("role") or answer["role"].getStr() notin ["user", "assistant"]:
    result.add "role is not user or assistant"
  if not answer.isString("model"):
    result.add "model is missing"
  let content = answer{"content"}
  if content.isNil or content.kind notin {JObject, JArray}:
    return result & "content is not a content block or an array of them"
  if content.kind == JArray and not version.has(ftSamplingTools):
    return result & ("array content is not part of protocol version " & $version)
  for i, block0 in blocksOf(content):
    result.add blockProblems("content[" & $i & "]", block0, version)
  let uses = toolUsesOf(answer)
  let stop = answer{"stopReason"}
  if not stop.isNil and stop.kind == JString and stop.getStr() == "toolUse" and uses.len == 0:
    result.add "stopReason is toolUse but the content has no tool_use block"
  var usedIds = initHashSet[string]()
  for use in uses:
    if use{"id"}.getStr() in usedIds:
      result.add "two tool uses with the id '" & use{"id"}.getStr() & "'"
    usedIds.incl use{"id"}.getStr()
  let mode =
    if params.isNil or params{"toolChoice"}.isNil: "auto"
    else: params["toolChoice"]{"mode"}.getStr("auto")
  if uses.len > 0:
    if params.isNil or params{"tools"}.isNil:
      result.add "the content has tool_use blocks but the request offered no tools"
    elif mode == "none":
      result.add "the content has tool_use blocks but toolChoice.mode is none"
  elif mode == "required" and not params.isNil and params{"messages"}.kind == JArray:
    var used = false
    for message in params["messages"]:
      if message.kind == JObject and not message{"content"}.isNil and
         idsOf(blocksOf(message["content"]), "tool_use", "id").len > 0:
        used = true
    if not used:
      result.add "toolChoice.mode is required but no tool was used"
