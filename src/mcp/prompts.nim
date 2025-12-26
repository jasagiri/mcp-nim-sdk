# Model Context Protocol (MCP) Server SDK for Nim
#
# Prompts implementation for MCP

import std/[json, tables, options, strutils, strformat]
import types

type
  PromptType* = object
    name*: string
    description*: string
    paramsSchema*: JsonNode

  PromptRegistry* = ref object
    promptTypes*: Table[string, PromptType]

proc newPromptRegistry*(): PromptRegistry =
  ## Creates a new prompt registry
  result = PromptRegistry(
    promptTypes: initTable[string, PromptType]()
  )

proc registerPromptType*(registry: PromptRegistry, name: string,
                         description: string, paramsSchema: JsonNode) =
  ## Registers a prompt type with the registry
  registry.promptTypes[name] = PromptType(
    name: name,
    description: description,
    paramsSchema: paramsSchema
  )

proc getPromptTypeDefinitions*(registry: PromptRegistry): seq[JsonNode] =
  ## Gets all prompt type definitions as JSON
  result = @[]
  for name, promptType in registry.promptTypes:
    result.add(%*{
      "name": promptType.name,
      "description": promptType.description,
      "paramsSchema": promptType.paramsSchema
    })

proc validatePromptParams*(schema: JsonNode, params: JsonNode): tuple[valid: bool, errors: seq[string]] =
  ## Validates prompt parameters against a schema
  var errors: seq[string] = @[]

  # Check required fields
  if schema.hasKey("required"):
    for req in schema["required"]:
      let fieldName = req.getStr()
      if not params.hasKey(fieldName):
        errors.add(fmt"Missing required parameter: {fieldName}")

  # Check types
  if schema.hasKey("properties") and params.kind == JObject:
    for key, propSchema in schema["properties"]:
      if params.hasKey(key):
        let value = params[key]
        if propSchema.hasKey("type"):
          let expectedType = propSchema["type"].getStr()
          var typeMatch = false

          case expectedType:
          of "string":
            typeMatch = value.kind == JString
          of "integer":
            typeMatch = value.kind == JInt
          of "number":
            typeMatch = value.kind == JFloat or value.kind == JInt
          of "boolean":
            typeMatch = value.kind == JBool
          of "object":
            typeMatch = value.kind == JObject
          of "array":
            typeMatch = value.kind == JArray
          else:
            typeMatch = true  # Unknown type, skip validation

          if not typeMatch:
            errors.add(fmt"Parameter '{key}' should be of type {expectedType}")

  result = (errors.len == 0, errors)

proc createPromptMessages*(promptType: string, params: JsonNode): seq[JsonNode] =
  ## Creates prompt messages from a prompt type and parameters
  var textContent = fmt"Prompt type: {promptType}"

  if params.kind == JObject:
    for key, value in params:
      textContent &= fmt"\n{key}: {value}"

  result = @[%*{
    "role": "user",
    "content": {
      "type": "text",
      "text": textContent
    }
  }]
