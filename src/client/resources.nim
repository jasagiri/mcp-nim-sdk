## MCP client resource operations

import asyncdispatch, json, options, sequtils
import ./client
import ../protocol/types

type
  McpResource* = object
    uri*: string
    name*: string
    description*: Option[string]
    mimeType*: Option[string]
    size*: Option[int]

  McpResourceContent* = object
    uri*: string
    mimeType*: string
    text*: Option[string]
    blob*: Option[string]
    
  McpResourceTemplate* = object
    uriTemplate*: string
    name*: string
    description*: Option[string]
    mimeType*: Option[string]
    arguments*: seq[McpTemplateArgument]
    
  McpTemplateArgument* = object
    name*: string
    description*: Option[string]
    required*: bool

proc listResources*(client: McpClient, cursor: Option[string] = none(string)): Future[tuple[resources: seq[McpResource], nextCursor: Option[string]]] {.async.} =
  if client.serverCapabilities.isNone or client.serverCapabilities.get.resources.isNone:
    raise newException(ValueError, "Server does not support resources")
    
  var params = newJObject()
  if cursor.isSome:
    params["cursor"] = %cursor.get
  
  let response = await client.sendRequest("resources/list", params)
  
  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Failed to list resources: " & error.message)
  
  let result = response.result.get
  
  var resources: seq[McpResource] = @[]
  var nextCursor: Option[string] = none(string)
  
  # Parse resources
  for item in result["resources"]:
    var resource = McpResource(
      uri: item["uri"].getStr(),
      name: item["name"].getStr()
    )
    
    if item.hasKey("description"):
      resource.description = some(item["description"].getStr())
    
    if item.hasKey("mimeType"):
      resource.mimeType = some(item["mimeType"].getStr())
      
    if item.hasKey("size"):
      resource.size = some(item["size"].getInt())
      
    resources.add(resource)
  
  # Check for pagination
  if result.hasKey("nextCursor"):
    nextCursor = some(result["nextCursor"].getStr())
    
  return (resources: resources, nextCursor: nextCursor)

proc readResource*(client: McpClient, uri: string): Future[McpResourceContent] {.async.} =
  if client.serverCapabilities.isNone or client.serverCapabilities.get.resources.isNone:
    raise newException(ValueError, "Server does not support resources")
    
  let params = %*{
    "uri": uri
  }
  
  let response = await client.sendRequest("resources/read", params)
  
  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Failed to read resource: " & error.message)
  
  let content = response.result.get["contents"][0]
  
  var resourceContent = McpResourceContent(
    uri: content["uri"].getStr(),
    mimeType: content["mimeType"].getStr()
  )
  
  if content.hasKey("text"):
    resourceContent.text = some(content["text"].getStr())
  elif content.hasKey("blob"):
    resourceContent.blob = some(content["blob"].getStr())
    
  return resourceContent

proc subscribeToResource*(client: McpClient, uri: string): Future[void] {.async.} =
  if client.serverCapabilities.isNone or client.serverCapabilities.get.resources.isNone:
    raise newException(ValueError, "Server does not support resources")
    
  let capabilities = client.serverCapabilities.get.resources.get
  if not capabilities.subscribe:
    raise newException(ValueError, "Server does not support resource subscriptions")
    
  let params = %*{
    "uri": uri
  }
  
  let response = await client.sendRequest("resources/subscribe", params)
  
  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Failed to subscribe to resource: " & error.message)

proc unsubscribeFromResource*(client: McpClient, uri: string): Future[void] {.async.} =
  if client.serverCapabilities.isNone or client.serverCapabilities.get.resources.isNone:
    raise newException(ValueError, "Server does not support resources")
    
  let capabilities = client.serverCapabilities.get.resources.get
  if not capabilities.subscribe:
    raise newException(ValueError, "Server does not support resource subscriptions")
    
  let params = %*{
    "uri": uri
  }
  
  let response = await client.sendRequest("resources/unsubscribe", params)
  
  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Failed to unsubscribe from resource: " & error.message)

proc listResourceTemplates*(client: McpClient): Future[seq[McpResourceTemplate]] {.async.} =
  if client.serverCapabilities.isNone or client.serverCapabilities.get.resources.isNone:
    raise newException(ValueError, "Server does not support resources")
    
  let response = await client.sendRequest("resources/templates/list", newJObject())
  
  if response.error.isSome:
    let error = response.error.get
    raise newException(ValueError, "Failed to list resource templates: " & error.message)
  
  let templates = response.result.get["resourceTemplates"]
  
  var resourceTemplates: seq[McpResourceTemplate] = @[]
  
  for item in templates:
    var template = McpResourceTemplate(
      uriTemplate: item["uriTemplate"].getStr(),
      name: item["name"].getStr()
    )
    
    if item.hasKey("description"):
      template.description = some(item["description"].getStr())
    
    if item.hasKey("mimeType"):
      template.mimeType = some(item["mimeType"].getStr())
      
    if item.hasKey("arguments"):
      for arg in item["arguments"]:
        var argument = McpTemplateArgument(
          name: arg["name"].getStr(),
          required: arg["required"].getBool(false)
        )
        
        if arg.hasKey("description"):
          argument.description = some(arg["description"].getStr())
          
        template.arguments.add(argument)
        
    resourceTemplates.add(template)
    
  return resourceTemplates
