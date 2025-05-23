## MCP server tool utilities

import asyncdispatch, json, options, sequtils

proc createToolInfo*(name: string, description: string, inputSchema: JsonNode, annotations: JsonNode = nil): JsonNode =
  result = %*{
    "name": name,
    "description": description,
    "inputSchema": inputSchema
  }
  
  if not annotations.isNil:
    result["annotations"] = annotations

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
