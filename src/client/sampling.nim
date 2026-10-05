## Sampling: a server asks the client to run an LLM completion
## (sampling/createMessage, before 2026-07-28). The application supplies
## the model; this module declares the capability and does the wire work.

import asyncdispatch, json, options
import ./client
import ./content
import ../protocol/types

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

  McpSamplingRequest* = object
    messages*: seq[McpSamplingMessage]
    modelPreferences*: Option[McpModelPreferences]
    systemPrompt*: Option[string]
    includeContext*: Option[string]
    temperature*: Option[float]
    maxTokens*: int
    stopSequences*: seq[string]
    metadata*: Option[JsonNode]
    raw*: JsonNode
      ## The params as received, for fields this type does not model.

  McpSamplingResult* = object
    role*: string
    content*: McpContentItem
    model*: string
    stopReason*: Option[string]

  McpSamplingHandler* = proc(request: McpSamplingRequest): Future[McpSamplingResult] {.closure.}

proc parseSamplingRequest*(params: JsonNode): McpSamplingRequest =
  if params.isNil or params.kind != JObject:
    raise newException(McpProtocolError, "sampling/createMessage: params is not an object")
  result = McpSamplingRequest(raw: params, maxTokens: params{"maxTokens"}.getInt())
  for message in requiredArray(params, "messages", "sampling/createMessage"):
    result.messages.add McpSamplingMessage(
      role: requiredString(message, "role", "sampling/createMessage"),
      content: parseContentItem(message{"content"}, "sampling/createMessage"))
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

proc toJson*(response: McpSamplingResult): JsonNode =
  result = %*{"role": response.role, "content": response.content.toJson(),
              "model": response.model}
  if response.stopReason.isSome:
    result["stopReason"] = %response.stopReason.get

proc setSamplingHandler*(client: McpClient, handler: McpSamplingHandler) =
  ## Declare the sampling capability and answer sampling/createMessage from
  ## `handler`. To refuse a request, raise McpRequestError (the
  ## specification suggests code -1 for a user rejection). Call before
  ## connect().
  client.requireNotConnected("the sampling handler")
  client.capabilities.sampling = some(McpSamplingCapability())
  client.registerRequestHandler("sampling/createMessage",
    proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
      let parsed =
        try: parseSamplingRequest(request.params)
        except McpProtocolError as e:
          return newJsonRpcErrorResponse(request.id, -32602, e.msg)
      let answer = await handler(parsed)
      return newJsonRpcResponse(request.id, answer.toJson()))
