## MCP client sampling operations

import asyncdispatch, json, options, sequtils
import ./client
import ../protocol/types

type
  McpMessage* = object
    role*: string  # "user" or "assistant"
    content*: McpMessageContent
    
  McpMessageContent* = object
    case kind*: McpContentKind
    of mckText:
      text*: string
    of mckImage:
      imageData*: string
      imageMimeType*: string
    of mckAudio:
      audioData*: string
      audioMimeType*: string
      
  McpContentKind* = enum
    mckText, mckImage, mckAudio
    
  McpModelPreferences* = object
    hints*: seq[McpModelHint]
    costPriority*: Option[float]
    speedPriority*: Option[float]
    intelligencePriority*: Option[float]
    
  McpModelHint* = object
    name*: string
    
  McpSamplingResult* = object
    role*: string
    content*: McpMessageContent
    model*: Option[string]
    stopReason*: Option[string]

proc createMessage*(
  client: McpClient, 
  messages: seq[McpMessage],
  modelPreferences: McpModelPreferences = McpModelPreferences(),
  systemPrompt: Option[string] = none(string),
  maxTokens: Option[int] = none(int)
): Future[McpSamplingResult] {.async.} =
  if client.serverCapabilities.isNone or client.serverCapabilities.get.sampling.isNone:
    raise newException(ValueError, "Server does not support sampling")
    
  # Convert messages to JSON
  var messagesJson = newJArray()
  for msg in messages:
    var contentJson: JsonNode
    
    case msg.content.kind
    of mckText:
      contentJson = %*{
        "type": "text",
        "text": msg.content.text
      }
    of mckImage:
      contentJson = %*{
        "type": "image",
        "data": msg.content.imageData,
        "mimeType": msg.content.imageMimeType
      }
    of mckAudio:
      contentJson = %*{
        "type": "audio",
        "data": msg.content.audioData,
        "mimeType": msg.content.audioMimeType
      }
    
    messagesJson.add(%*{
      "role": msg.role,
      "content": contentJson
    })
  
  # Build model preferences
  var modelPreferencesJson = newJObject()
  
  if modelPreferences.hints.len > 0:
    var hintsJson = newJArray()
    for hint in modelPreferences.hints:
      hintsJson.add(%*{"name": hint.name})
    modelPreferencesJson["hints"] = hintsJson
  
  if modelPreferences.costPriority.isSome:
    modelPreferencesJson["costPriority"] = %modelPreferences.costPriority.get
    
  if modelPreferences.speedPriority.isSome:
    modelPreferencesJson["speedPriority"] = %modelPreferences.speedPriority.get
    
  if modelPreferences.intelligencePriority.isSome:
    modelPreferencesJson["intelligencePriority"] = %modelPreferences.intelligencePriority.get
  
  # Build request params
  var params = %*{
    "messages": messagesJson,
    "modelPreferences": modelPreferencesJson
  }
  
  if systemPrompt.isSome:
    params["systemPrompt"] = %systemPrompt.get
    
  if maxTokens.isSome:
    params["maxTokens"] = %maxTokens.get
  
  let response = await client.sendRequest("sampling/createMessage", params)
  
  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Failed to create message: " & error.message)
  
  let result = response.result.get
  
  # Parse result
  var samplingResult = McpSamplingResult(
    role: result["role"].getStr()
  )
  
  if result.hasKey("model"):
    samplingResult.model = some(result["model"].getStr())
    
  if result.hasKey("stopReason"):
    samplingResult.stopReason = some(result["stopReason"].getStr())
  
  # Parse content
  let contentJson = result["content"]
  let contentType = contentJson["type"].getStr()
  
  if contentType == "text":
    samplingResult.content = McpMessageContent(
      kind: mckText,
      text: contentJson["text"].getStr()
    )
  elif contentType == "image":
    samplingResult.content = McpMessageContent(
      kind: mckImage,
      imageData: contentJson["data"].getStr(),
      imageMimeType: contentJson["mimeType"].getStr()
    )
  elif contentType == "audio":
    samplingResult.content = McpMessageContent(
      kind: mckAudio,
      audioData: contentJson["data"].getStr(),
      audioMimeType: contentJson["mimeType"].getStr()
    )
    
  return samplingResult
