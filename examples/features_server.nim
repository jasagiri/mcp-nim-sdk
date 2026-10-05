## A server that turns on every server-side feature of the core protocol:
## tools, resources (with subscriptions), prompts, completion and logging.
##
##   nim c -r examples/features_server.nim
##
## A feature is on when its capability is declared in `newMcpServer` and its
## handlers are registered; nothing else is needed. The server offers a
## client only what the version they settled on has.

import std/[asyncdispatch, json, options]
import mcp

proc main() =
  let server = newMcpServer(
    McpServerInfo(name: "features-server", version: "0.1.0"),
    capabilities = McpServerCapabilities(
      tools: some(McpToolsCapability(listChanged: true)),
      resources: some(McpResourcesCapability(subscribe: true, listChanged: true)),
      prompts: some(McpPromptsCapability(listChanged: true)),
      completions: some(McpCompletionsCapability()),
      logging: some(McpLoggingCapability())))

  # Tools. The arguments of a call are checked against `inputSchema` before
  # the handler runs.
  server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{
      "name": "add",
      "description": "Adds two integers",
      "inputSchema": {
        "type": "object",
        "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
        "required": ["a", "b"]}}]))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    if name != "add":
      raise newUnknownTool(name)
    # Progress reaches the client only when its request asked for it;
    # log messages only at the level the client asked for.
    await ctx.reportProgress(0.5)
    await ctx.log(mllInfo, %"adding")
    let sum = arguments["a"].getInt() + arguments["b"].getInt()
    return %*{"content": [{"type": "text", "text": $sum}]})

  # Resources.
  server.onResourcesList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"uri": "memo://greeting", "name": "greeting",
                               "mimeType": "text/plain"}]))
  server.onResourceRead(proc(ctx: McpRequestContext,
                             uri: string): Future[seq[JsonNode]] {.async.} =
    if uri != "memo://greeting":
      raise newResourceNotFound(uri)
    return @[%*{"uri": uri, "mimeType": "text/plain", "text": "hello"}])

  # Prompts.
  server.onPromptsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{
      "name": "greet", "description": "Greets someone",
      "arguments": [{"name": "who", "required": true}]}]))
  server.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    if name != "greet":
      raise newInvalidParams("Unknown prompt: " & name)
    return %*{"messages": [{"role": "user", "content": {
      "type": "text", "text": "Say hello to " & arguments{"who"}.getStr()}}]})

  # Completion of prompt arguments and resource template variables.
  server.onComplete(proc(ctx: McpRequestContext,
                         request: McpCompletionRequest): Future[McpCompletion] {.async.} =
    var names: seq[string]
    for name in ["Ada", "Alan", "Grace"]:
      if request.argumentValue.len == 0 or name[0] == request.argumentValue[0]:
        names.add name
    return McpCompletion(values: names))

  server.transport = newStdioTransport()
  waitFor server.processMessages()

main()
