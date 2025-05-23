## MCP server prompt utilities

import asyncdispatch, json, options, sequtils

proc createPromptInfo*(name: string, description: string, arguments: seq[JsonNode] = @[]): JsonNode =
  result = %*{
    "name": name,
    "description": description
  }
  
  if arguments.len > 0:
    result["arguments"] = %arguments

proc createPromptArgument*(name: string, description: string = "", required: bool = false): JsonNode =
  result = %*{
    "name": name,
    "required": required
  }
  
  if description.len > 0:
    result["description"] = %description

proc createPromptResult*(messages: seq[JsonNode], description: string = ""): JsonNode =
  result = %*{
    "messages": messages
  }
  
  if description.len > 0:
    result["description"] = %description

proc createPromptMessage*(role: string, content: JsonNode): JsonNode =
  result = %*{
    "role": role,
    "content": content
  }

proc createTextContent*(text: string): JsonNode =
  result = %*{
    "type": "text",
    "text": text
  }

proc createImageContent*(data: string, mimeType: string): JsonNode =
  result = %*{
    "type": "image",
    "data": data,
    "mimeType": mimeType
  }

proc createAudioContent*(data: string, mimeType: string): JsonNode =
  result = %*{
    "type": "audio",
    "data": data,
    "mimeType": mimeType
  }

proc createResourceContent*(resource: JsonNode): JsonNode =
  result = %*{
    "type": "resource",
    "resource": resource
  }
