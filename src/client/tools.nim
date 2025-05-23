## MCP client tool operations

import asyncdispatch, json, options, sequtils
import ./client
import ../protocol/types

type
  McpTool* = object
    name*: string
    description*: string
    inputSchema*: JsonNode
    annotations*: Option[JsonNode]
    
  McpToolContent* = object
    contentItems*: seq[McpToolContentItem]
    isError*: bool
    
  McpToolContentItem* = object
    case kind*: McpToolContentKind
    of mctkText:
      text*: string
    of mctkImage:
      imageData*: string
      imageMimeType*: string
    of mctkAudio:
      audioData*: string
      audioMimeType*: string
    of mctkResource:
      resource*: McpEmbeddedResource
      
  McpToolContentKind* = enum
    mctkText, mctkImage, mctkAudio, mctkResource
    
  McpEmbeddedResource* = object
    uri*: string
    mimeType*: string
    text*: Option[string]
    blob*: Option[string]

proc listTools*(client: McpClient, cursor: Option[string] = none(string)): Future[tuple[tools: seq[McpTool], nextCursor: Option[string]]] {.async.} =
  if client.serverCapabilities.isNone or client.serverCapabilities.get.tools.isNone:
    raise newException(ValueError, "Server does not support tools")
    
  var params = newJObject()
  if cursor.isSome:
    params["cursor"] = %cursor.get
  
  let response = await client.sendRequest("tools/list", params)
  
  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Failed to list tools: " & error.message)
  
  let result = response.result.get
  
  var tools: seq[McpTool] = @[]
  var nextCursor: Option[string] = none(string)
  
  # Parse tools
  for item in result["tools"]:
    var tool = McpTool(
      name: item["name"].getStr(),
      description: item["description"].getStr(),
      inputSchema: item["inputSchema"]
    )
    
    if item.hasKey("annotations"):
      tool.annotations = some(item["annotations"])
      
    tools.add(tool)
  
  # Check for pagination
  if result.hasKey("nextCursor"):
    nextCursor = some(result["nextCursor"].getStr())
    
  return (tools: tools, nextCursor: nextCursor)

proc callTool*(client: McpClient, name: string, arguments: JsonNode): Future[McpToolContent] {.async.} =
  if client.serverCapabilities.isNone or client.serverCapabilities.get.tools.isNone:
    raise newException(ValueError, "Server does not support tools")
    
  let params = %*{
    "name": name,
    "arguments": arguments
  }
  
  let response = await client.sendRequest("tools/call", params)
  
  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Failed to call tool: " & error.message)
  
  let result = response.result.get
  
  var content = McpToolContent(
    isError: result["isError"].getBool(false),
    contentItems: @[]
  )
  
  # Parse content items
  for item in result["content"]:
    let contentType = item["type"].getStr()
    
    if contentType == "text":
      content.contentItems.add(McpToolContentItem(
        kind: mctkText,
        text: item["text"].getStr()
      ))
    elif contentType == "image":
      content.contentItems.add(McpToolContentItem(
        kind: mctkImage,
        imageData: item["data"].getStr(),
        imageMimeType: item["mimeType"].getStr()
      ))
    elif contentType == "audio":
      content.contentItems.add(McpToolContentItem(
        kind: mctkAudio,
        audioData: item["data"].getStr(),
        audioMimeType: item["mimeType"].getStr()
      ))
    elif contentType == "resource":
      let resourceJson = item["resource"]
      var resource = McpEmbeddedResource(
        uri: resourceJson["uri"].getStr(),
        mimeType: resourceJson["mimeType"].getStr()
      )
      
      if resourceJson.hasKey("text"):
        resource.text = some(resourceJson["text"].getStr())
      elif resourceJson.hasKey("blob"):
        resource.blob = some(resourceJson["blob"].getStr())
        
      content.contentItems.add(McpToolContentItem(
        kind: mctkResource,
        resource: resource
      ))
    
  return content
