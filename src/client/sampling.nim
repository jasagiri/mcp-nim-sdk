## Sampling: a server asks the client to run an LLM completion
## (sampling/createMessage, before 2026-07-28). The application supplies
## the model; this module declares the capability and does the wire work.

import asyncdispatch, json, options
import ./client
import ./content
import ../protocol/types
import ../protocol/sampling_tools

type
  McpModelHint* = object
    name*: string

  McpModelPreferences* = object
    hints*: seq[McpModelHint]
    costPriority*: Option[float]
    speedPriority*: Option[float]
    intelligencePriority*: Option[float]

  McpSamplingMessage* = object
    role*: string  ## "user" or "assistant"
    content*: McpContentItem
      ## The first content block.
    blocks*: seq[McpContentItem]
      ## Every content block (2025-11-25 allows an array). tool_use and
      ## tool_result blocks are `mckUnknown`, kept as received in `raw`.

  McpSamplingRequest* = object
    messages*: seq[McpSamplingMessage]
    modelPreferences*: Option[McpModelPreferences]
    systemPrompt*: Option[string]
    includeContext*: Option[string]
    temperature*: Option[float]
    maxTokens*: int
    stopSequences*: seq[string]
    metadata*: Option[JsonNode]
    tools*: seq[JsonNode]
      ## 2025-11-25: the tools the model may use, as received.
    toolChoice*: Option[string]
      ## 2025-11-25: toolChoice.mode ("auto", "required" or "none").
    raw*: JsonNode
      ## The params as received, for fields this type does not model.

  McpSamplingResult* = object
    role*: string
    content*: McpContentItem
    blocks*: seq[McpContentItem]
      ## When not empty, sent as the content array in place of `content`: a
      ## model that wants tools returns `toolUseContent` blocks here with
      ## stopReason "toolUse" (2025-11-25).
    model*: string
    stopReason*: Option[string]

  McpSamplingHandler* = proc(request: McpSamplingRequest): Future[McpSamplingResult] {.closure.}

proc toolUseContent*(id, name: string, input: JsonNode): McpContentItem =
  ## A tool_use block for `McpSamplingResult.blocks`.
  McpContentItem(kind: mckUnknown, raw: toolUseBlock(id, name, input))

proc parseSamplingRequest*(params: JsonNode): McpSamplingRequest =
  if params.isNil or params.kind != JObject:
    raise newException(McpProtocolError, "sampling/createMessage: params is not an object")
  result = McpSamplingRequest(raw: params, maxTokens: params{"maxTokens"}.getInt())
  for message in requiredArray(params, "messages", "sampling/createMessage"):
    let content = message{"content"}
    var blocks: seq[McpContentItem]
    if not content.isNil and content.kind == JArray:
      for block0 in content:
        blocks.add parseContentItem(block0, "sampling/createMessage")
      if blocks.len == 0:
        raise newException(McpProtocolError, "sampling/createMessage: a message has no content")
    else:
      blocks.add parseContentItem(content, "sampling/createMessage")
    result.messages.add McpSamplingMessage(
      role: requiredString(message, "role", "sampling/createMessage"),
      content: blocks[0], blocks: blocks)
  let prefs = params{"modelPreferences"}
  if not prefs.isNil and prefs.kind == JObject:
    var parsed = McpModelPreferences()
    let hints = prefs{"hints"}
    if not hints.isNil and hints.kind == JArray:
      for hint in hints:
        parsed.hints.add McpModelHint(name: hint{"name"}.getStr())
    proc priority(key: string): Option[float] =
      if prefs.hasKey(key): some(prefs[key].getFloat()) else: none(float)
    parsed.costPriority = priority("costPriority")
    parsed.speedPriority = priority("speedPriority")
    parsed.intelligencePriority = priority("intelligencePriority")
    result.modelPreferences = some(parsed)
  result.systemPrompt = optionalString(params, "systemPrompt")
  result.includeContext = optionalString(params, "includeContext")
  if params.hasKey("temperature"):
    result.temperature = some(params["temperature"].getFloat())
  let stops = params{"stopSequences"}
  if not stops.isNil and stops.kind == JArray:
    for stop in stops: result.stopSequences.add stop.getStr()
  if params.hasKey("metadata"):
    result.metadata = some(params["metadata"])
  let tools = params{"tools"}
  if not tools.isNil and tools.kind == JArray:
    result.tools = tools.getElems()
  let choice = params{"toolChoice"}
  if not choice.isNil and choice.kind == JObject:
    result.toolChoice = some(choice{"mode"}.getStr("auto"))

proc toJson*(response: McpSamplingResult): JsonNode =
  result = %*{"role": response.role, "content": response.content.toJson(),
              "model": response.model}
  if response.blocks.len > 0:
    let blocks = newJArray()
    for block0 in response.blocks:
      blocks.add block0.toJson()
    result["content"] = blocks
  if response.stopReason.isSome:
    result["stopReason"] = %response.stopReason.get

proc contentOfAnswerForVersion(answer: JsonNode, version: McpProtocolVersion): JsonNode =
  ## The one place where the content blocks of a sampling answer are fitted
  ## to the negotiated version (for example audio before 2025-03-26).
  ## TODO: this passes `answer` through unchanged. At integration, call
  ## `contentBlockFor` of `src/protocol/content.nim` here for each block, so
  ## a block the version lacks becomes text.
  answer

proc setSamplingHandler*(client: McpClient, handler: McpSamplingHandler,
                         tools = false) =
  ## Declare the sampling capability and answer sampling/createMessage from
  ## `handler`. To refuse a request, raise McpRequestError (the
  ## specification suggests code -1 for a user rejection). `tools` declares
  ## sampling.tools: the handler then gets requests with `tools` and
  ## `toolChoice` and may answer with tool uses (2025-11-25). A request that
  ## uses tools without the declaration, or whose messages break the rules,
  ## is answered with invalid params; an answer to a request with tools that
  ## breaks the rules is the handler's defect and the server is told
  ## "Internal error". Call before connect().
  client.requireNotConnected("the sampling handler")
  client.capabilities.sampling = some(McpSamplingCapability(tools: tools))
  client.registerRequestHandler("sampling/createMessage",
    proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
      let version = client.negotiatedVersion.get
      let unavailable = samplingToolsUnavailable(request.params, version,
                                                 client.capabilities.sampling.get)
      if unavailable.isSome:
        return newJsonRpcErrorResponse(request.id, -32602,
          "sampling/createMessage: " & unavailable.get)
      let problems = createMessageParamsProblems(request.params, version)
      if problems.len > 0:
        return newJsonRpcErrorResponse(request.id, -32602,
          "sampling/createMessage: " & problems[0])
      let parsed =
        try: parseSamplingRequest(request.params)
        except McpProtocolError as e:
          return newJsonRpcErrorResponse(request.id, -32602, e.msg)
      let answer = contentOfAnswerForVersion((await handler(parsed)).toJson(), version)
      if request.params.usesTools:
        let faults = createMessageResultProblems(answer, request.params, version)
        if faults.len > 0:
          stderr.writeLine("[mcp-client] the sampling handler's answer was not sent: " & faults[0])
          return newJsonRpcErrorResponse(request.id, -32603,
            "the sampling handler answered with something that does not match the request")
      return newJsonRpcResponse(request.id, answer))
