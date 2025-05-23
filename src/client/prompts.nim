## MCP client prompt operations

import asyncdispatch, json, options, sequtils
import ./client
import ../protocol/types

type
  McpPrompt* = object
    name*: string
    description*: string
    arguments*: seq[McpPromptArgument]
    
  McpPromptArgument* = object
    name*: string
    description*: Option[string]
    required*: bool
    
  McpPromptResult* = object
    description*: Option[string]
    messages*: seq[McpPromptMessage]
    
  McpPromptMessage* = object
    role*: string  # "user" or "assistant"
    content*: McpPromptMessageContent
    
  McpPromptMessageContent* = object
    case kind*: McpPromptContentKind
    of mpckText:
      text*: string
    of mpckImage:
      imageData*: string
      imageMimeType*: string
    of mpckAudio:
      audioData*: string
      audioMimeType*: string
    of mpckResource:
      resource*: McpEmbeddedResource
      
  McpPromptContentKind* = enum
    mpckText, mpckImage, mpckAudio, mpckResource
    
  McpEmbeddedResource* = object
    uri*: string
    mimeType*: string
    text*: Option[string]
    blob*: Option[string]

proc listPrompts*(client: McpClient, cursor: Option[string] = none(string)): Future[tuple[prompts: seq[McpPrompt], nextCursor: Option[string]]] {.async.} =
  if client.serverCapabilities.isNone or client.serverCapabilities.get.prompts.isNone:
    raise newException(ValueError, "Server does not support prompts")
    
  var params = newJObject()
  if cursor.isSome:
    params["cursor"] = %cursor.get
  
  let response = await client.sendRequest("prompts/list", params)
  
  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Failed to list prompts: " & error.message)
  
  let result = response.result.get
  
  var prompts: seq[McpPrompt] = @[]
  var nextCursor: Option[string] = none(string)
  
  # Parse prompts
  for item in result["prompts"]:
    var prompt = McpPrompt(
      name: item["name"].getStr(),
      description: item["description"].getStr(),
      arguments: @[]
    )
    
    if item.hasKey("arguments"):
      for arg in item["arguments"]:
        var argument = McpPromptArgument(
          name: arg["name"].getStr(),
          required: arg["required"].getBool(false)
        )
        
        if arg.hasKey("description"):
          argument.description = some(arg["description"].getStr())
          
        prompt.arguments.add(argument)
        
    prompts.add(prompt)
  
  # Check for pagination
  if result.hasKey("nextCursor"):
    nextCursor = some(result["nextCursor"].getStr())
    
  return (prompts: prompts, nextCursor: nextCursor)

proc getPrompt*(client: McpClient, name: string, arguments: JsonNode): Future[McpPromptResult] {.async.} =
  if client.serverCapabilities.isNone or client.serverCapabilities.get.prompts.isNone:
    raise newException(ValueError, "Server does not support prompts")
    
  let params = %*{
    "name": name,
    "arguments": arguments
  }
  
  let response = await client.sendRequest("prompts/get", params)
  
  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Failed to get prompt: " & error.message)
  
  let result = response.result.get
  
  var promptResult = McpPromptResult(
    messages: @[]
  )
  
  if result.hasKey("description"):
    promptResult.description = some(result["description"].getStr())
  
  # Parse messages
  for item in result["messages"]:
    let contentJson = item["content"]
    let contentType = contentJson["type"].getStr()
    
    var content: McpPromptMessageContent
    
    if contentType == "text":
      content = McpPromptMessageContent(
        kind: mpckText,
        text: contentJson["text"].getStr()
      )
    elif contentType == "image":
      content = McpPromptMessageContent(
        kind: mpckImage,
        imageData: contentJson["data"].getStr(),
        imageMimeType: contentJson["mimeType"].getStr()
      )
    elif contentType == "audio":
      content = McpPromptMessageContent(
        kind: mpckAudio,
        audioData: contentJson["data"].getStr(),
        audioMimeType: contentJson["mimeType"].getStr()
      )
    elif contentType == "resource":
      let resourceJson = contentJson["resource"]
      var resource = McpEmbeddedResource(
        uri: resourceJson["uri"].getStr(),
        mimeType: resourceJson["mimeType"].getStr()
      )
      
      if resourceJson.hasKey("text"):
        resource.text = some(resourceJson["text"].getStr())
      elif resourceJson.hasKey("blob"):
        resource.blob = some(resourceJson["blob"].getStr())
        
      content = McpPromptMessageContent(
        kind: mpckResource,
        resource: resource
      )
    
    promptResult.messages.add(McpPromptMessage(
      role: item["role"].getStr(),
      content: content
    ))
    
  return promptResult
