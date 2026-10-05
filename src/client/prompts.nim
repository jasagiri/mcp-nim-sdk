## MCP client prompt operations

import asyncdispatch, json, options
import ./client
import ./content
export content

type
  McpPromptArgument* = object
    name*: string
    title*: Option[string]
    description*: Option[string]
    required*: bool

  McpPrompt* = object
    name*: string
    title*: Option[string]
    description*: string
    arguments*: seq[McpPromptArgument]

  McpPromptMessage* = object
    role*: string  ## "user" or "assistant"
    content*: McpContentItem

  McpPromptResult* = object
    description*: Option[string]
    messages*: seq[McpPromptMessage]

func displayName*(argument: McpPromptArgument): string =
  ## `title` when the server gave one, else `name`.
  argument.title.get(argument.name)

func displayName*(prompt: McpPrompt): string =
  prompt.title.get(prompt.name)

proc requirePrompts(client: McpClient, operation: string) =
  if client.serverCapabilities.isNone:
    raise newException(McpConnectionClosedError, operation & ": the client is not connected")
  client.requireServerCapability(client.serverCapabilities.get.prompts.isSome,
                                 operation, "prompts")

proc parsePrompt(item: JsonNode): McpPrompt =
  result = McpPrompt(
    name: requiredString(item, "name", "prompts/list"),
    title: optionalString(item, "title"),
    description: item{"description"}.getStr())
  let arguments = item{"arguments"}
  if not arguments.isNil and arguments.kind == JArray:
    for argument in arguments:
      result.arguments.add McpPromptArgument(
        name: requiredString(argument, "name", "prompts/list"),
        title: optionalString(argument, "title"),
        description: optionalString(argument, "description"),
        required: argument{"required"}.getBool(false))

proc listPrompts*(client: McpClient, cursor: Option[string] = none(string),
                  options: McpRequestOptions = McpRequestOptions()
                 ): Future[tuple[prompts: seq[McpPrompt], nextCursor: Option[string]]] {.async.} =
  client.requirePrompts("prompts/list")
  let reply = await client.callMethod("prompts/list", pageParams(cursor), options)
  var prompts: seq[McpPrompt]
  for item in requiredArray(reply, "prompts", "prompts/list"):
    prompts.add parsePrompt(item)
  return (prompts: prompts, nextCursor: parseNextCursor(reply))

proc listAllPrompts*(client: McpClient,
                     options: McpRequestOptions = McpRequestOptions()): Future[seq[McpPrompt]] =
  allPages("prompts/list", proc(cursor: Option[string]): Future[tuple[items: seq[McpPrompt], next: Option[string]]] {.async.} =
    let page = await client.listPrompts(cursor, options)
    return (items: page.prompts, next: page.nextCursor))

proc fetchPrompt(client: McpClient, params: JsonNode,
                 options: McpRequestOptions): Future[McpPromptResult] {.async.} =
  let reply = await client.callMethod("prompts/get", params, options)
  result.description = optionalString(reply, "description")
  for message in requiredArray(reply, "messages", "prompts/get"):
    result.messages.add McpPromptMessage(
      role: requiredString(message, "role", "prompts/get"),
      content: parseContentItem(message{"content"}, "prompts/get"))

proc getPrompt*(client: McpClient, name: string,
                arguments: openArray[(string, string)] = [],
                options: McpRequestOptions = McpRequestOptions()): Future[McpPromptResult] =
  ## Prompt arguments are strings on the wire.
  client.requirePrompts("prompts/get")
  var params = %*{"name": name}
  if arguments.len > 0:
    let argumentsJson = newJObject()
    for (key, value) in arguments:
      argumentsJson[key] = %value
    params["arguments"] = argumentsJson
  client.fetchPrompt(params, options)
