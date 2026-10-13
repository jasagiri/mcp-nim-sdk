## What a server builds its tool definitions and results with, instead of
## writing the JSON out: `createToolInfo` and the schema procedures for an
## item of tools/list, `createToolResult` and the content procedures for the
## answer of a tools/call. `import mcp` exports them.

import json, options
import ../protocol/content
import ../protocol/types

proc createToolInfo*(name: string, description: string, inputSchema: JsonNode,
                     annotations: JsonNode = nil, title = "",
                     outputSchema: JsonNode = nil,
                     icons: seq[McpIcon] = @[]): JsonNode {.raises: [].} =
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
    let listed = newJArray()
    for icon in icons:
      listed.add icon.toJson
    result["icons"] = listed

proc createToolResult*(content: seq[JsonNode], isError: bool = false): JsonNode {.raises: [].} =
  result = %*{
    "content": content,
    "isError": isError
  }

proc createTextToolContent*(text: string): JsonNode {.raises: [].} =
  result = %*{
    "type": "text",
    "text": text
  }

proc createImageToolContent*(data: string, mimeType: string): JsonNode {.raises: [].} =
  result = %*{
    "type": "image",
    "data": data,
    "mimeType": mimeType
  }

proc createAudioToolContent*(data: string, mimeType: string): JsonNode {.raises: [].} =
  result = %*{
    "type": "audio",
    "data": data,
    "mimeType": mimeType
  }

proc createResourceToolContent*(resource: JsonNode): JsonNode {.raises: [].} =
  result = %*{
    "type": "resource",
    "resource": resource
  }

proc createResourceLinkToolContent*(uri, name: string, description = "",
    mimeType = "", title = "", size = none(int)): JsonNode {.raises: [].} =
  ## A link to a resource (2025-06-18 and later); a client may read it with
  ## resources/read. Only the fields that were given are sent.
  result = %*{"type": "resource_link", "uri": uri, "name": name}
  if description.len > 0: result["description"] = %description
  if mimeType.len > 0: result["mimeType"] = %mimeType
  if title.len > 0: result["title"] = %title
  if size.isSome: result["size"] = %size.get

proc createInputSchema*(properties: JsonNode, required: seq[string] = @[]): JsonNode {.raises: [].} =
  result = %*{
    "type": "object",
    "properties": properties
  }
  
  if required.len > 0:
    result["required"] = %required

proc createStringProperty*(description: string = ""): JsonNode {.raises: [].} =
  result = %*{
    "type": "string"
  }
  
  if description.len > 0:
    result["description"] = %description

proc createNumberProperty*(description: string = ""): JsonNode {.raises: [].} =
  result = %*{
    "type": "number"
  }
  
  if description.len > 0:
    result["description"] = %description

proc createBooleanProperty*(description: string = ""): JsonNode {.raises: [].} =
  result = %*{
    "type": "boolean"
  }
  
  if description.len > 0:
    result["description"] = %description

proc createArrayProperty*(items: JsonNode, description: string = ""): JsonNode {.raises: [].} =
  result = %*{
    "type": "array",
    "items": items
  }
  
  if description.len > 0:
    result["description"] = %description

proc createObjectProperty*(properties: JsonNode, required: seq[string] = @[], description: string = ""): JsonNode {.raises: [].} =
  result = %*{
    "type": "object",
    "properties": properties
  }
  
  if required.len > 0:
    result["required"] = %required
    
  if description.len > 0:
    result["description"] = %description

proc createEnumProperty*(values: seq[string], description: string = ""): JsonNode {.raises: [].} =
  result = %*{
    "type": "string",
    "enum": values
  }
  
  if description.len > 0:
    result["description"] = %description
