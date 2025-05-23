## Sampling implementation for the Model Context Protocol (MCP).
##
## This module provides functionality for servers to request LLM completions
## using the MCP sampling capability.

import json
import uuids
import strutils
import options
import sequtils
import asyncdispatch
import protocol

type
  MessageRole* = enum
    ## Roles for message participants
    User = "user",
    Assistant = "assistant"

  MessageContentType* = enum
    ## Types of message content
    TextContent = "text",
    ImageContent = "image"

  MessageContent* = object
    ## Content of a message
    case contentType*: MessageContentType
    of TextContent:
      text*: string
    of ImageContent:
      data*: string        # Base64 encoded
      mimeType*: string

  Message* = object
    ## A message in a sampling request
    role*: MessageRole
    content*: seq[MessageContent]

  ContextInclusion* = enum
    ## Options for including context
    None = "none",
    ThisServer = "thisServer",
    AllServers = "allServers"

  ModelPreferences* = object
    ## Preferences for model selection
    hints*: seq[string]
    costPriority*: Option[float]
    speedPriority*: Option[float]
    intelligencePriority*: Option[float]

  SamplingRequest* = object
    ## Request for sampling from an LLM
    messages*: seq[Message]
    modelPreferences*: Option[ModelPreferences]
    systemPrompt*: Option[string]
    includeContext*: ContextInclusion
    temperature*: Option[float]
    maxTokens*: int
    stopSequences*: seq[string]
    metadata*: JsonNode

  SamplingStopReason* = enum
    ## Reasons why sampling stopped
    EndTurn = "endTurn",
    StopSequence = "stopSequence",
    MaxTokens = "maxTokens",
    Other = ""

  SamplingResponse* = object
    ## Response from sampling
    model*: string
    stopReason*: Option[SamplingStopReason]
    role*: MessageRole
    content*: seq[MessageContent]

proc newTextMessage*(role: MessageRole, text: string): Message =
  ## Create a new message with text content
  result = Message(
    role: role,
    content: @[
      MessageContent(
        contentType: TextContent,
        text: text
      )
    ]
  )

proc newImageMessage*(role: MessageRole, data, mimeType: string): Message =
  ## Create a new message with image content
  result = Message(
    role: role,
    content: @[
      MessageContent(
        contentType: ImageContent,
        data: data,
        mimeType: mimeType
      )
    ]
  )

proc addTextContent*(msg: var Message, text: string) =
  ## Add text content to a message
  msg.content.add(MessageContent(
    contentType: TextContent,
    text: text
  ))

proc addImageContent*(msg: var Message, data, mimeType: string) =
  ## Add image content to a message
  msg.content.add(MessageContent(
    contentType: ImageContent,
    data: data,
    mimeType: mimeType
  ))

proc newModelPreferences*(hints: seq[string] = @[], 
                         costPriority = none(float), 
                         speedPriority = none(float), 
                         intelligencePriority = none(float)): ModelPreferences =
  ## Create new model preferences
  result = ModelPreferences(
    hints: hints,
    costPriority: costPriority,
    speedPriority: speedPriority,
    intelligencePriority: intelligencePriority
  )

proc newSamplingRequest*(messages: seq[Message], 
                        maxTokens: int, 
                        modelPreferences = none(ModelPreferences),
                        systemPrompt = none(string),
                        includeContext = None,
                        temperature = none(float),
                        stopSequences: seq[string] = @[],
                        metadata = newJObject()): SamplingRequest =
  ## Create a new sampling request
  result = SamplingRequest(
    messages: messages,
    modelPreferences: modelPreferences,
    systemPrompt: systemPrompt,
    includeContext: includeContext,
    temperature: temperature,
    maxTokens: maxTokens,
    stopSequences: stopSequences,
    metadata: metadata
  )

proc messageToJson*(msg: Message): JsonNode =
  ## Convert a message to its JSON representation
  var contentArray = newJArray()
  
  for item in msg.content:
    var contentItem: JsonNode
    
    case item.contentType
    of TextContent:
      contentItem = %{
        "type": %"text",
        "text": %item.text
      }
    of ImageContent:
      contentItem = %{
        "type": %"image",
        "data": %item.data,
        "mimeType": %item.mimeType
      }
      
    contentArray.add(contentItem)
  
  result = %{
    "role": %($msg.role),
    "content": contentArray
  }

proc modelPreferencesToJson*(prefs: ModelPreferences): JsonNode =
  ## Convert model preferences to JSON
  result = newJObject()
  
  if prefs.hints.len > 0:
    var hintsArray = newJArray()
    for hint in prefs.hints:
      hintsArray.add(%{"name": %hint})
    result["hints"] = hintsArray
  
  if prefs.costPriority.isSome:
    result["costPriority"] = %prefs.costPriority.get()
    
  if prefs.speedPriority.isSome:
    result["speedPriority"] = %prefs.speedPriority.get()
    
  if prefs.intelligencePriority.isSome:
    result["intelligencePriority"] = %prefs.intelligencePriority.get()

proc samplingRequestToJson*(req: SamplingRequest): JsonNode =
  ## Convert a sampling request to its JSON representation
  var messagesArray = newJArray()
  for msg in req.messages:
    messagesArray.add(messageToJson(msg))
  
  result = %{
    "messages": messagesArray,
    "maxTokens": %req.maxTokens,
    "includeContext": %($req.includeContext)
  }
  
  if req.modelPreferences.isSome:
    result["modelPreferences"] = modelPreferencesToJson(req.modelPreferences.get())
    
  if req.systemPrompt.isSome:
    result["systemPrompt"] = %req.systemPrompt.get()
    
  if req.temperature.isSome:
    result["temperature"] = %req.temperature.get()
    
  if req.stopSequences.len > 0:
    var stopArray = newJArray()
    for stop in req.stopSequences:
      stopArray.add(%stop)
    result["stopSequences"] = stopArray
    
  if req.metadata.len > 0:
    result["metadata"] = req.metadata

proc parseMessageContent*(content: JsonNode): MessageContent =
  ## Parse message content from JSON
  var contentType: MessageContentType = TextContent  # Default

  # Determine content type
  if content.hasKey("type") and not content["type"].isNil() and content["type"].kind == JString:
    let typeStr = content["type"].getStr().toLowerAscii()
    # Try to match with enum directly first
    try:
      contentType = parseEnum[MessageContentType](typeStr)
    except:
      # Fall back to case matching
      case typeStr
      of "text": contentType = TextContent
      of "image": contentType = ImageContent
      # Otherwise keep the default (TextContent)

  # Create appropriate content object based on type
  case contentType
  of TextContent:
    if content.hasKey("text") and not content["text"].isNil():
      result = MessageContent(
        contentType: TextContent,
        text: content["text"].getStr()
      )
    else:
      # If no text field, create empty text content
      result = MessageContent(
        contentType: TextContent,
        text: ""
      )
  of ImageContent:
    if content.hasKey("data") and not content["data"].isNil() and
        content.hasKey("mimeType") and not content["mimeType"].isNil():
      result = MessageContent(
        contentType: ImageContent,
        data: content["data"].getStr(),
        mimeType: content["mimeType"].getStr()
      )
    else:
      # If missing required fields, fall back to text content
      var textContent = ""
      if content.hasKey("text") and not content["text"].isNil():
        textContent = content["text"].getStr()

      result = MessageContent(
        contentType: TextContent,
        text: textContent
      )

proc parseMessage*(msgJson: JsonNode): Message =
  ## Parse a message from JSON
  var role: MessageRole = User  # Default to user if missing/invalid

  if msgJson.hasKey("role") and not msgJson["role"].isNil() and msgJson["role"].kind == JString:
    let roleStr = msgJson["role"].getStr().toLowerAscii()
    # Try to match with enum directly first
    try:
      role = parseEnum[MessageRole](roleStr)
    except:
      # Fall back to case matching
      case roleStr
      of "user": role = User
      of "assistant": role = Assistant
      # Otherwise keep the default (User)

  var content: seq[MessageContent] = @[]

  # Handle both single content and array of content
  if msgJson["content"].kind == JArray:
    for item in msgJson["content"]:
      content.add(parseMessageContent(item))
  else:
    content.add(parseMessageContent(msgJson["content"]))

  result = Message(
    role: role,
    content: content
  )

proc parseSamplingResponse*(respJson: JsonNode): SamplingResponse =
  ## Parse a sampling response from JSON
  var content: seq[MessageContent] = @[]

  # Handle both single content and array of content
  if respJson["content"].kind == JArray:
    for item in respJson["content"]:
      content.add(parseMessageContent(item))
  else:
    content.add(parseMessageContent(respJson["content"]))

  # Parse stop reason if present
  var stopReason: Option[SamplingStopReason]
  if respJson.hasKey("stopReason") and not respJson["stopReason"].isNil() and respJson["stopReason"].kind == JString:
    let stopReasonStr = respJson["stopReason"].getStr().toLowerAscii()
    # Try to match with enum directly first
    try:
      let enumValue = parseEnum[SamplingStopReason](stopReasonStr)
      stopReason = some(enumValue)
    except:
      # Fall back to case matching for common variants with different casing/format
      case stopReasonStr
      of "endturn", "end_turn": stopReason = some(EndTurn)
      of "stopsequence", "stop_sequence": stopReason = some(StopSequence)
      of "maxtokens", "max_tokens": stopReason = some(MaxTokens)
      else: stopReason = some(Other)
  else:
    stopReason = none(SamplingStopReason)

  # Parse role
  var role: MessageRole = Assistant  # Default to assistant if missing/invalid

  if respJson.hasKey("role") and not respJson["role"].isNil() and respJson["role"].kind == JString:
    let roleStr = respJson["role"].getStr().toLowerAscii()
    # Try to match with enum directly first
    try:
      role = parseEnum[MessageRole](roleStr)
    except:
      # Fall back to case matching
      case roleStr
      of "user": role = User
      of "assistant": role = Assistant
      # Otherwise keep the default (Assistant)

  result = SamplingResponse(
    model: respJson["model"].getStr(),
    stopReason: stopReason,
    role: role,
    content: content
  )

proc createSamplingRequest*(messages: seq[Message], maxTokens: int): RequestMessage =
  ## Create a sampling request message
  let params = samplingRequestToJson(newSamplingRequest(
    messages = messages,
    maxTokens = maxTokens
  ))
  
  result = createRequest(
    methodName = "sampling/createMessage",
    params = params,
    id = $genUUID()
  )

proc extractTextFromContent*(content: seq[MessageContent]): string =
  ## Extract text from message content
  for item in content:
    if item.contentType == TextContent:
      return item.text
  return ""

type
  CreateMessageFn* = proc(request: JsonNode): Future[JsonNode] {.async.}

  SamplingManager* = ref object
    ## Manager for sampling requests
    createMessageFn*: CreateMessageFn

proc newSamplingManager*(): SamplingManager =
  ## Create a new sampling manager
  result = SamplingManager(
    createMessageFn: nil
  )

proc createMessage*(manager: SamplingManager, messages: seq[JsonNode],
                  systemPrompt = none(string), temperature = none(float),
                  maxTokens = 100, stopSequences: seq[string] = @[],
                  includeContext = none(ContextInclusion),
                  modelPreferences = none(JsonNode)): Future[JsonNode] {.async.} =
  ## Create a message using the sampling manager
  if manager.createMessageFn.isNil:
    raise newException(ValueError, "createMessageFn not set")

  # Convert JsonNode messages to Message objects
  var messageObjs: seq[Message] = @[]
  for msg in messages:
    # Parse the message directly using our existing function
    var parsedMsg: Message
    try:
      parsedMsg = parseMessage(msg)
      messageObjs.add(parsedMsg)
    except Exception:
      # Fallback to direct conversion for simple messages
      let roleStr = msg["role"].getStr().toLowerAscii()
      var role: MessageRole
      case roleStr
      of "user": role = User
      of "assistant": role = Assistant
      else: role = User  # Default

      let content = msg["content"]
      if content.kind == JObject:
        # Check if it has a type field (proper content object)
        if content.hasKey("type"):
          messageObjs.add(Message(
            role: role,
            content: @[parseMessageContent(content)]
          ))
        else:
          # Simple text content without type field
          messageObjs.add(Message(
            role: role,
            content: @[MessageContent(
              contentType: TextContent,
              text: content["text"].getStr()
            )]
          ))
      else:
        # Multiple content items
        var contentSeq: seq[MessageContent] = @[]
        for item in content:
          if item.hasKey("type"):
            contentSeq.add(parseMessageContent(item))
          else:
            contentSeq.add(MessageContent(
              contentType: TextContent,
              text: item["text"].getStr()
            ))
        messageObjs.add(Message(role: role, content: contentSeq))

  # Build the request
  var reqParams = %*{
    "messages": messageObjs.mapIt(messageToJson(it)),
    "maxTokens": maxTokens
  }

  if systemPrompt.isSome:
    reqParams["systemPrompt"] = %systemPrompt.get()

  if temperature.isSome:
    reqParams["temperature"] = %temperature.get()

  if stopSequences.len > 0:
    var stopArray = newJArray()
    for stop in stopSequences:
      stopArray.add(%stop)
    reqParams["stopSequences"] = stopArray

  if includeContext.isSome:
    reqParams["includeContext"] = %($includeContext.get())

  if modelPreferences.isSome:
    reqParams["modelPreferences"] = modelPreferences.get()

  # Call the create message function
  return await manager.createMessageFn(reqParams)
