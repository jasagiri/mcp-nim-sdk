## MCP client tool operations

import asyncdispatch, json, options
import ./client
import ./content
export content

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
      ## As received (2025-06-18 and later); not validated against the
      ## tool's outputSchema.

  McpTool* = object
    name*: string
    title*: Option[string]
    description*: string
    inputSchema*: JsonNode
    outputSchema*: Option[JsonNode]
    annotations*: Option[JsonNode]

proc requireTools(client: McpClient, operation: string) =
  if client.serverCapabilities.isNone:
    raise newException(McpConnectionClosedError, operation & ": the client is not connected")
  client.requireServerCapability(client.serverCapabilities.get.tools.isSome,
                                 operation, "tools")

proc parseTool(item: JsonNode): McpTool =
  McpTool(
    name: requiredString(item, "name", "tools/list"),
    title: optionalString(item, "title"),
    description: item{"description"}.getStr(),
    inputSchema: item{"inputSchema"},
    outputSchema: (if item.hasKey("outputSchema"): some(item["outputSchema"]) else: none(JsonNode)),
    annotations: (if item.hasKey("annotations"): some(item["annotations"]) else: none(JsonNode)))

proc listTools*(client: McpClient, cursor: Option[string] = none(string),
                options: McpRequestOptions = McpRequestOptions()
               ): Future[tuple[tools: seq[McpTool], nextCursor: Option[string]]] {.async.} =
  ## One page of tools; pass the returned nextCursor for the next page.
  client.requireTools("tools/list")
  let reply = await client.callMethod("tools/list", pageParams(cursor), options)
  var tools: seq[McpTool]
  for item in requiredArray(reply, "tools", "tools/list"):
    tools.add parseTool(item)
  return (tools: tools, nextCursor: parseNextCursor(reply))

proc listAllTools*(client: McpClient,
                   options: McpRequestOptions = McpRequestOptions()): Future[seq[McpTool]] =
  ## Every tool, following nextCursor to the last page.
  allPages("tools/list", proc(cursor: Option[string]): Future[tuple[items: seq[McpTool], next: Option[string]]] {.async.} =
    let page = await client.listTools(cursor, options)
    return (items: page.tools, next: page.nextCursor))

proc callTool*(client: McpClient, name: string, arguments: JsonNode = newJObject(),
               options: McpRequestOptions = McpRequestOptions()): Future[McpToolContent] {.async.} =
  client.requireTools("tools/call")
  let reply = await client.callMethod("tools/call",
    %*{"name": name, "arguments": arguments}, options)
  result.isError = reply{"isError"}.getBool(false)
  for item in requiredArray(reply, "content", "tools/call"):
    result.contentItems.add parseContentItem(item, "tools/call")
  if reply.hasKey("structuredContent"):
    result.structuredContent = some(reply["structuredContent"])
