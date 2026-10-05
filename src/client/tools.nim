## MCP client tool operations

import asyncdispatch, json, options, strutils, tables
import ./client
import ./content
import ../protocol/content as wire
import ../jsonschema/json_schema
export content
export wire.McpToolAnnotations, wire.isReadOnly, wire.isDestructive,
  wire.isIdempotent, wire.isOpenWorld

type
  McpToolContentKind* = McpContentKind
  McpToolContentItem* = McpContentItem

const
  mctkText* = mckText
  mctkImage* = mckImage
  mctkAudio* = mckAudio
  mctkResource* = mckResource
  mctkResourceLink* = mckResourceLink
  mctkUnknown* = mckUnknown

type
  McpToolContent* = object
    contentItems*: seq[McpToolContentItem]
    isError*: bool
      ## The tool ran and failed; a protocol failure raises instead.
    structuredContent*: Option[JsonNode]
      ## As received (2025-06-18 and later), after `callTool` has checked it
      ## against the outputSchema of the tool as listed.

  McpSchemaError* = object of McpError
    ## A tool's outputSchema cannot be checked (a dialect or keyword this
    ## library does not implement). Call the tool with `validateOutput = false`
    ## to read its result unchecked.

  McpTool* = object
    name*: string
    title*: Option[string]
    description*: string
    icons*: seq[McpIcon]
    inputSchema*: JsonNode
    outputSchema*: Option[JsonNode]
    annotations*: Option[JsonNode]
    execution*: Option[JsonNode]
      ## 2025-11-25: `{"taskSupport": ...}`, as received; see `taskSupport`
      ## in client/tasks.

proc annotationsOf*(tool: McpTool): McpToolAnnotations =
  ## The typed hints of `tool`; all unset when the server sent none. They are
  ## hints from the server: do not trust them more than the server.
  if tool.annotations.isNone:
    return McpToolAnnotations()
  try:
    parseToolAnnotations(tool.annotations.get)
  except McpShapeError as e:
    raise newException(McpProtocolError, "tool '" & tool.name & "': " & e.msg)

proc displayName*(tool: McpTool): string =
  ## What to show for the tool: `title`, else `annotations.title`, else
  ## `name` (2025-06-18, server/tools).
  if tool.title.isSome:
    return tool.title.get
  let annotated = tool.annotationsOf.title
  if annotated.isSome: annotated.get else: tool.name

proc requireTools(client: McpClient, operation: string) =
  if client.serverCapabilities.isNone:
    raise newException(McpConnectionClosedError, operation & ": the client is not connected")
  client.requireServerCapability(client.serverCapabilities.get.tools.isSome,
                                 operation, "tools")

proc parseTool(item: JsonNode): McpTool =
  McpTool(
    name: requiredString(item, "name", "tools/list"),
    title: optionalString(item, "title", "tools/list"),
    description: item{"description"}.getStr(),
    icons: iconsOf(item, "tools/list"),
    inputSchema: item{"inputSchema"},
    outputSchema: (if item.hasKey("outputSchema"): some(item["outputSchema"]) else: none(JsonNode)),
    annotations: (if item.hasKey("annotations"): some(item["annotations"]) else: none(JsonNode)),
    execution: (if item.hasKey("execution"): some(item["execution"]) else: none(JsonNode)))

proc listTools*(client: McpClient, cursor: Option[string] = none(string),
                options: McpRequestOptions = McpRequestOptions()
               ): Future[tuple[tools: seq[McpTool], nextCursor: Option[string]]] {.async.} =
  ## One page of tools; pass the returned nextCursor for the next page.
  client.requireTools("tools/list")
  let reply = await client.callMethod("tools/list", pageParams(cursor), options)
  var tools: seq[McpTool]
  for item in requiredArray(reply, "tools", "tools/list"):
    let tool = parseTool(item)
    tools.add tool
    if tool.outputSchema.isSome:
      client.toolOutputSchemas[tool.name] = tool.outputSchema.get
    else:
      client.toolOutputSchemas.del(tool.name)
  return (tools: tools, nextCursor: parseNextCursor(reply, "tools/list"))

proc listAllTools*(client: McpClient,
                   options: McpRequestOptions = McpRequestOptions()): Future[seq[McpTool]] =
  ## Every tool, following nextCursor to the last page.
  allPages("tools/list", proc(cursor: Option[string]): Future[tuple[items: seq[McpTool], next: Option[string]]] {.async.} =
    let page = await client.listTools(cursor, options)
    return (items: page.tools, next: page.nextCursor))

proc toolContentOf*(reply: JsonNode): McpToolContent =
  ## The CallToolResult of a tools/call answer, or of the result of a task
  ## that wraps one.
  result.isError = reply{"isError"}.getBool(false)
  for item in requiredArray(reply, "content", "tools/call"):
    result.contentItems.add parseContentItem(item, "tools/call")
  if reply.hasKey("structuredContent"):
    result.structuredContent = some(reply["structuredContent"])

proc callTool*(client: McpClient, name: string, arguments: JsonNode = newJObject(),
               options: McpRequestOptions = McpRequestOptions(),
               validateOutput = true): Future[McpToolContent] {.async.} =
  ## Call a tool. When the tool was listed with an outputSchema, the result
  ## is checked against it (2025-06-18: clients SHOULD validate) and a result
  ## that does not conform raises McpProtocolError; `validateOutput = false`
  ## turns that off for the call.
  client.requireTools("tools/call")
  let reply = await client.callMethod("tools/call",
    %*{"name": name, "arguments": arguments}, options)
  if validateOutput and name in client.toolOutputSchemas and client.negotiatedVersion.isSome:
    var problems: seq[string]
    try:
      problems = outputProblems(client.negotiatedVersion.get,
                                client.toolOutputSchemas[name], reply)
    except InvalidSchemaError as e:
      raise newException(McpSchemaError,
        "tools/call: the outputSchema of tool '" & name & "' cannot be checked: " & e.msg)
    if problems.len > 0:
      raise newException(McpProtocolError,
        "tools/call: the result of tool '" & name & "' does not conform to its outputSchema: " &
        problems.join("; "))
  return toolContentOf(reply)
