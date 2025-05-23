## Tool implementation for the Model Context Protocol (MCP).
##
## This module provides utilities for working with MCP tools.

import std/[json, options, tables, asyncdispatch]

type
  ToolHandler* = proc(args: JsonNode): Future[JsonNode] {.async, gcsafe.}
    ## Handler procedure for a tool

  ToolConfig* = object
    ## Configuration for a tool
    name*: string
    description*: string
    inputSchema*: JsonNode
    handler*: ToolHandler

  ToolResponse* = object
    ## Response from a tool invocation
    isError*: bool
    content*: seq[ToolResponseContent]

  ToolResponseContentType* = enum
    ## Types of content in a tool response
    TextContent,  ## Text content
    ImageContent  ## Image content (base64 encoded)

  ToolResponseContent* = object
    ## Content item in a tool response
    case contentType*: ToolResponseContentType
    of TextContent:
      text*: string
    of ImageContent:
      data*: string  # Base64 encoded image data
      mimeType*: string  # Image MIME type

proc newToolConfig*(name, description: string, inputSchema: JsonNode): ToolConfig =
  ## Create a new tool configuration
  result = ToolConfig(
    name: name,
    description: description,
    inputSchema: inputSchema
  )

proc newToolResponseWithText*(text: string, isError = false): ToolResponse =
  ## Create a new tool response with text content
  result = ToolResponse(
    isError: isError,
    content: @[
      ToolResponseContent(
        contentType: TextContent,
        text: text
      )
    ]
  )

proc newToolResponseWithImage*(data, mimeType: string, isError = false): ToolResponse =
  ## Create a new tool response with image content
  result = ToolResponse(
    isError: isError,
    content: @[
      ToolResponseContent(
        contentType: ImageContent,
        data: data,
        mimeType: mimeType
      )
    ]
  )

proc addTextContent*(response: var ToolResponse, text: string) =
  ## Add text content to a tool response
  response.content.add(ToolResponseContent(
    contentType: TextContent,
    text: text
  ))

proc addImageContent*(response: var ToolResponse, data, mimeType: string) =
  ## Add image content to a tool response
  response.content.add(ToolResponseContent(
    contentType: ImageContent,
    data: data,
    mimeType: mimeType
  ))

proc toInfoJson*(config: ToolConfig): JsonNode =
  ## Convert a tool configuration to its info JSON representation
  result = %{
    "name": %config.name,
    "inputSchema": config.inputSchema
  }
  
  if config.description.len > 0:
    result["description"] = %config.description

proc toResultJson*(response: ToolResponse): JsonNode =
  ## Convert a tool response to its JSON representation
  var contentArray = newJArray()
  
  for item in response.content:
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
    "content": contentArray
  }
  
  if response.isError:
    result["isError"] = %true

proc validateToolArguments*(schema: JsonNode, args: JsonNode): bool =
  ## Validate tool arguments against a JSON schema
  ## This is a basic implementation that should be extended with a proper JSON schema validator
  
  if schema["type"].getStr() != "object":
    return false
    
  let properties = schema["properties"]
  let required = if schema.hasKey("required"): schema["required"] else: newJArray()
  
  # Check required properties
  for reqProp in required:
    let propName = reqProp.getStr()
    if not args.hasKey(propName):
      return false
  
  # Check property types
  for propName, propSchema in properties:
    if args.hasKey(propName):
      let propType = propSchema["type"].getStr()
      let value = args[propName]
      
      case propType
      of "string":
        if value.kind != JString:
          return false
      of "number":
        if value.kind != JFloat and value.kind != JInt:
          return false
      of "integer":
        if value.kind != JInt:
          return false
      of "boolean":
        if value.kind != JBool:
          return false
      of "array":
        if value.kind != JArray:
          return false
      of "object":
        if value.kind != JObject:
          return false
      of "null":
        if value.kind != JNull:
          return false
  
  return true

proc createBasicSchemaForStringParam*(paramName, description: string, required = true): JsonNode =
  ## Create a basic JSON schema for a string parameter
  var propSchema = %{
    "type": %"object",
    "properties": %{
      paramName: %{
        "type": %"string",
        "description": %description
      }
    }
  }
  
  if required:
    propSchema["required"] = %[%paramName]
    
  return propSchema

proc createBasicSchemaForNumberParam*(paramName, description: string, required = true): JsonNode =
  ## Create a basic JSON schema for a number parameter
  var propSchema = %{
    "type": %"object",
    "properties": %{
      paramName: %{
        "type": %"number",
        "description": %description
      }
    }
  }
  
  if required:
    propSchema["required"] = %[%paramName]
    
  return propSchema

proc createBasicSchemaForObjectParam*(paramName, description: string, properties: JsonNode, required = true): JsonNode =
  ## Create a basic JSON schema for an object parameter
  var propSchema = %{
    "type": %"object",
    "properties": %{
      paramName: %{
        "type": %"object",
        "description": %description,
        "properties": properties
      }
    }
  }
  
  if required:
    propSchema["required"] = %[%paramName]
    
  return propSchema

type
  ToolRegistry* = ref object
    ## Registry for available tools
    tools*: Table[string, ToolConfig]

proc newToolRegistry*(): ToolRegistry =
  ## Create a new empty tool registry
  result = ToolRegistry(tools: initTable[string, ToolConfig]())

proc registerTool*(registry: ToolRegistry, name, description: string,
                 inputSchema: JsonNode, handler: ToolHandler) =
  ## Register a tool in the registry
  let tool = ToolConfig(
    name: name,
    description: description,
    inputSchema: inputSchema,
    handler: handler
  )
  registry.tools[name] = tool

proc registerTool*(registry: ToolRegistry, tool: ToolConfig) =
  ## Register a tool in the registry
  registry.tools[tool.name] = tool

proc getToolDefinitions*(registry: ToolRegistry): seq[JsonNode] =
  ## Get all registered tool definitions as JSON objects
  result = @[]
  for name, tool in registry.tools:
    result.add(toInfoJson(tool))

proc executeTool*(registry: ToolRegistry, name: string, args: JsonNode): Future[Option[JsonNode]] {.async.} =
  ## Execute a tool by name with the provided arguments
  if name notin registry.tools:
    return none(JsonNode)

  let tool = registry.tools[name]

  if not validateToolArguments(tool.inputSchema, args):
    return none(JsonNode)

  try:
    let result = await tool.handler(args)
    return some(result)
  except:
    return none(JsonNode)

proc newToolSuccess*(text: string): JsonNode =
  ## Create a successful tool response with a single text item
  result = %*{
    "isError": false,
    "content": [{
      "type": "text",
      "text": text
    }]
  }

proc newToolSuccess*(content: seq[JsonNode]): JsonNode =
  ## Create a successful tool response with multiple content items
  result = %*{
    "isError": false,
    "content": content
  }

proc newToolError*(message: string): JsonNode =
  ## Create an error tool response
  result = %*{
    "isError": true,
    "content": [{
      "type": "text",
      "text": message
    }]
  }

proc createBasicSchemaForArrayParam*(paramName, description: string, itemType: string, required = true): JsonNode =
  ## Create a basic JSON schema for an array parameter
  var propSchema = %{
    "type": %"object",
    "properties": %{
      paramName: %{
        "type": %"array",
        "description": %description,
        "items": %{
          "type": %itemType
        }
      }
    }
  }
  
  if required:
    propSchema["required"] = %[%paramName]
    
  return propSchema
