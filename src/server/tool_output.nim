## Checking what a tool returns against the tool's `outputSchema`.
##
## "Servers MUST provide structured results that conform to this schema"
## (2025-06-18, server/tools). A result that does not conform is a defect of
## the server, so the client is told so with an internal error instead of
## receiving data its schema disowns.

import std/[asyncdispatch, json, options, strutils]
import ../protocol/content
import ../protocol/json_schema
import ../protocol/modern
import ./errors
import ./server

type
  OutputSchemaOf* = proc(name: string): Option[JsonNode]
    ## The `outputSchema` of the tool called `name`, if it has one.

proc outputSchemasOf*(tools: seq[JsonNode]): OutputSchemaOf =
  ## Look up in the tool definitions `tools` (entries of tools/list).
  var schemas: seq[(string, JsonNode)]
  for tool in tools:
    if tool.kind == JObject and tool.hasKey("outputSchema"):
      schemas.add (tool{"name"}.getStr(), tool["outputSchema"])
  result = proc(name: string): Option[JsonNode] =
    for (toolName, schema) in schemas:
      if toolName == name:
        return some(schema)
    none(JsonNode)

proc outputChecked*(call: ToolCallHandler, schemaOf: OutputSchemaOf): ToolCallHandler =
  ## `call`, except that the result of a tool with an outputSchema is checked
  ## when the client's version has structured output: it needs a conforming
  ## `structuredContent`, unless it reports a failure (`isError`). A result
  ## with `structuredContent` and no content gets the serialized JSON as text.
  result = proc(ctx: McpRequestContext, name: string,
                arguments: JsonNode): Future[JsonNode] {.async.} =
    let answer = withSerializedText(await call(ctx, name, arguments))
    let schema = schemaOf(name)
    if schema.isNone:
      return answer
    var problems: seq[string]
    try:
      problems = outputProblems(ctx.version, schema.get, answer)
    except InvalidSchemaError as e:
      raise newRequestError(ErrInternal,
        "tools/call: the outputSchema of tool '" & name & "' cannot be checked: " & e.msg)
    if problems.len > 0:
      raise newRequestError(ErrInternal,
        "tools/call: the result of tool '" & name & "' does not conform to its outputSchema: " &
        problems.join("; "))
    return answer

proc outputChecked*(call: ToolCallHandler, tools: seq[JsonNode]): ToolCallHandler =
  ## `outputChecked` against the outputSchemas of the tool definitions `tools`.
  outputChecked(call, outputSchemasOf(tools))
