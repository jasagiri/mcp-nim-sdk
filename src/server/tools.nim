## MCP server tool utilities

import json, options
import ../protocol/content
import ../protocol/types

proc createToolInfo*(name: string, description: string, inputSchema: JsonNode,
                     annotations: JsonNode = nil, title = "",
                     outputSchema: JsonNode = nil,
                     icons: seq[McpIcon] = @[]): JsonNode =
  ## A tool definition for tools/list. Fields the client's protocol version
  ## does not have (annotations, title, outputSchema, icons) are left out
  ## when the server answers, so they can be set whatever the version.
  result = %*{
    "name": name,
    "description": description,
    "inputSchema": inputSchema
  }

  if not annotations.isNil:
    result["annotations"] = annotations
  if title.len > 0:
    result["title"] = %title
  if not outputSchema.isNil:
    result["outputSchema"] = outputSchema
  if icons.len > 0:
    result["icons"] = newJArray()
    for icon in icons:
      result["icons"].add icon.toJson

proc createToolResult*(content: seq[JsonNode], isError: bool = false): JsonNode =
  result = %*{
    "content": content,
    "isError": isError
  }

proc createTextToolContent*(text: string): JsonNode =
  result = %*{
    "type": "text",
    "text": text
  }

proc createImageToolContent*(data: string, mimeType: string): JsonNode =
  result = %*{
    "type": "image",
    "data": data,
    "mimeType": mimeType
  }

proc createAudioToolContent*(data: string, mimeType: string): JsonNode =
  result = %*{
    "type": "audio",
    "data": data,
    "mimeType": mimeType
  }

proc createResourceToolContent*(resource: JsonNode): JsonNode =
  result = %*{
    "type": "resource",
    "resource": resource
  }

proc createResourceLinkToolContent*(uri, name: string, description = "",
    mimeType = "", title = "", size = none(int)): JsonNode =
  ## A link to a resource (2025-06-18 and later); a client may read it with
  ## resources/read. Only the fields that were given are sent.
  result = %*{"type": "resource_link", "uri": uri, "name": name}
  if description.len > 0: result["description"] = %description
  if mimeType.len > 0: result["mimeType"] = %mimeType
  if title.len > 0: result["title"] = %title
  if size.isSome: result["size"] = %size.get

proc createInputSchema*(properties: JsonNode, required: seq[string] = @[]): JsonNode =
  result = %*{
    "type": "object",
    "properties": properties
  }
  
  if required.len > 0:
    result["required"] = %required

proc createStringProperty*(description: string = ""): JsonNode =
  result = %*{
    "type": "string"
  }
  
  if description.len > 0:
    result["description"] = %description

proc createNumberProperty*(description: string = ""): JsonNode =
  result = %*{
    "type": "number"
  }
  
  if description.len > 0:
    result["description"] = %description

proc createBooleanProperty*(description: string = ""): JsonNode =
  result = %*{
    "type": "boolean"
  }
  
  if description.len > 0:
    result["description"] = %description

proc createArrayProperty*(items: JsonNode, description: string = ""): JsonNode =
  result = %*{
    "type": "array",
    "items": items
  }
  
  if description.len > 0:
    result["description"] = %description

proc createObjectProperty*(properties: JsonNode, required: seq[string] = @[], description: string = ""): JsonNode =
  result = %*{
    "type": "object",
    "properties": properties
  }
  
  if required.len > 0:
    result["required"] = %required
    
  if description.len > 0:
    result["description"] = %description

proc createEnumProperty*(values: seq[string], description: string = ""): JsonNode =
  result = %*{
    "type": "string",
    "enum": values
  }
  
  if description.len > 0:
    result["description"] = %description
