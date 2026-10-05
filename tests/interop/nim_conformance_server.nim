## The server the official conformance suite (`@modelcontextprotocol/conformance`,
## `server` mode) is pointed at: `nim_conformance_server PORT` serves
## http://127.0.0.1:PORT/mcp.
##
## The suite looks tools, resources and prompts up by fixed names (the names of
## the upstream "everything" server), so this program carries those names and
## nothing else. It offers only what this SDK can serve through its public
## handlers today: content-only tools, static and templated resources, prompts.
## Scenarios that need more (logging, progress, completion, sampling,
## elicitation, subscriptions, ...) are left out on purpose and fail; the list
## of failures and their causes is in docs/quality/conformance-*.md.

import std/[asyncdispatch, json, options, os, strutils]
import server/server
import transport/http_server
import protocol/types

const
  # A 1x1 PNG and a minimal WAV, the same bytes the upstream server uses.
  TestImage = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
  TestAudio = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="
  TemplatePrefix = "test://template/"
  TemplateSuffix = "/data"

proc emptySchema(): JsonNode =
  %*{"type": "object", "properties": {}}

proc tool(name, description: string, inputSchema: JsonNode = emptySchema()): JsonNode =
  %*{"name": name, "description": description, "inputSchema": inputSchema}

proc textContent(text: string): JsonNode =
  %*{"type": "text", "text": text}

proc toolResult(content: varargs[JsonNode]): JsonNode =
  %*{"content": @content}

# SEP-1613: the schema must come back from tools/list exactly as written.
let jsonSchema2020 = %*{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "$defs": {"address": {"$anchor": "addressDef", "type": "object",
                        "properties": {"street": {"type": "string"}, "city": {"type": "string"}}}},
  "properties": {
    "name": {"type": "string"},
    "address": {"$ref": "#/$defs/address"},
    "contactMethod": {"type": "string", "enum": ["phone", "email"]},
    "phone": {"type": "string"},
    "email": {"type": "string"}},
  "allOf": [{"anyOf": [{"required": ["phone"]}, {"required": ["email"]}]}],
  "if": {"properties": {"contactMethod": {"const": "phone"}}, "required": ["contactMethod"]},
  "then": {"required": ["phone"]},
  "else": {"required": ["email"]},
  "additionalProperties": false}

proc toolList(): seq[JsonNode] =
  @[tool("test_simple_text", "Tests simple text content response"),
    tool("test_image_content", "Tests image content response"),
    tool("test_audio_content", "Tests audio content response"),
    tool("test_embedded_resource", "Tests embedded resource content response"),
    tool("test_multiple_content_types",
         "Tests response with multiple content types (text, image, resource)"),
    tool("test_error_handling", "Tests error response handling"),
    tool("json_schema_2020_12_tool",
         "Tool with JSON Schema 2020-12 features for conformance testing (SEP-1613)", jsonSchema2020)]

proc callTool(name: string, arguments: JsonNode): JsonNode =
  case name
  of "test_simple_text":
    toolResult(textContent("This is a simple text response for testing."))
  of "test_image_content":
    toolResult(%*{"type": "image", "data": TestImage, "mimeType": "image/png"})
  of "test_audio_content":
    toolResult(%*{"type": "audio", "data": TestAudio, "mimeType": "audio/wav"})
  of "test_embedded_resource":
    toolResult(%*{"type": "resource", "resource": {
      "uri": "test://embedded-resource", "mimeType": "text/plain",
      "text": "This is an embedded resource content."}})
  of "test_multiple_content_types":
    toolResult(
      textContent("Multiple content types test:"),
      %*{"type": "image", "data": TestImage, "mimeType": "image/png"},
      %*{"type": "resource", "resource": {
        "uri": "test://mixed-content-resource", "mimeType": "application/json",
        "text": $(%*{"test": "data", "value": 123})}})
  of "test_error_handling":
    # A tool failure is a result with isError, not a protocol error.
    %*{"content": [textContent("This tool intentionally returns an error for testing")],
       "isError": true}
  of "json_schema_2020_12_tool":
    toolResult(textContent("JSON Schema 2020-12 tool called with: " & $arguments))
  else:
    raise newException(ValueError, "Unknown tool: " & name)

proc resourceList(): seq[JsonNode] =
  @[%*{"uri": "test://static-text", "name": "static-text", "title": "Static Text Resource",
       "description": "A static text resource for testing", "mimeType": "text/plain"},
    %*{"uri": "test://static-binary", "name": "static-binary", "title": "Static Binary Resource",
       "description": "A static binary resource (image) for testing", "mimeType": "image/png"},
    %*{"uri": "test://watched-resource", "name": "watched-resource", "title": "Watched Resource",
       "description": "A resource that auto-updates every 3 seconds", "mimeType": "text/plain"}]

proc resourceTemplateList(): seq[JsonNode] =
  @[%*{"uriTemplate": "test://template/{id}/data", "name": "template", "title": "Resource Template",
       "description": "A resource template with parameter substitution", "mimeType": "application/json"}]

proc readResource(uri: string): JsonNode =
  case uri
  of "test://static-text":
    %*{"uri": uri, "mimeType": "text/plain",
       "text": "This is the content of the static text resource."}
  of "test://static-binary":
    %*{"uri": uri, "mimeType": "image/png", "blob": TestImage}
  of "test://watched-resource":
    %*{"uri": uri, "mimeType": "text/plain", "text": "Watched resource content"}
  else:
    if uri.startsWith(TemplatePrefix) and uri.endsWith(TemplateSuffix) and
        uri.len > TemplatePrefix.len + TemplateSuffix.len:
      let id = uri[TemplatePrefix.len ..< uri.len - TemplateSuffix.len]
      %*{"uri": uri, "mimeType": "application/json",
         "text": $(%*{"id": id, "templateTest": true, "data": "Data for ID: " & id})}
    else:
      raise newException(ValueError, "Unknown resource: " & uri)

proc promptArgument(name, description: string): JsonNode =
  %*{"name": name, "description": description, "required": true}

proc promptList(): seq[JsonNode] =
  @[%*{"name": "test_simple_prompt", "title": "Simple Test Prompt",
       "description": "A simple prompt without arguments"},
    %*{"name": "test_prompt_with_arguments", "title": "Prompt With Arguments",
       "description": "A prompt with required arguments",
       "arguments": [promptArgument("arg1", "First test argument"),
                     promptArgument("arg2", "Second test argument")]},
    %*{"name": "test_prompt_with_embedded_resource", "title": "Prompt With Embedded Resource",
       "description": "A prompt that includes an embedded resource",
       "arguments": [promptArgument("resourceUri", "URI of the resource to embed")]},
    %*{"name": "test_prompt_with_image", "title": "Prompt With Image",
       "description": "A prompt that includes image content"}]

proc promptMessage(content: JsonNode): JsonNode =
  %*{"role": "user", "content": content}

proc argument(arguments: JsonNode, name: string): string =
  let value = arguments{name}
  if value.isNil or value.kind != JString:
    raise newException(ValueError, "Missing required argument: " & name)
  value.getStr()

proc getPrompt(name: string, arguments: JsonNode): JsonNode =
  case name
  of "test_simple_prompt":
    %*{"messages": [promptMessage(textContent("This is a simple prompt for testing."))]}
  of "test_prompt_with_arguments":
    %*{"messages": [promptMessage(textContent(
      "Prompt with arguments: arg1='" & argument(arguments, "arg1") &
      "', arg2='" & argument(arguments, "arg2") & "'"))]}
  of "test_prompt_with_embedded_resource":
    %*{"messages": [
      promptMessage(%*{"type": "resource", "resource": {
        "uri": argument(arguments, "resourceUri"), "mimeType": "text/plain",
        "text": "Embedded resource content for testing."}}),
      promptMessage(textContent("Please process the embedded resource above."))]}
  of "test_prompt_with_image":
    %*{"messages": [
      promptMessage(%*{"type": "image", "data": TestImage, "mimeType": "image/png"}),
      promptMessage(textContent("Please analyze the image above."))]}
  else:
    raise newException(ValueError, "Unknown prompt: " & name)

proc listToolsHandler(): Future[seq[JsonNode]] {.async.} = return toolList()
proc callToolHandler(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
  return callTool(name, arguments)
proc listResourcesHandler(): Future[seq[JsonNode]] {.async.} = return resourceList()
proc readResourceHandler(uri: string): Future[JsonNode] {.async.} = return readResource(uri)
proc listTemplatesHandler(): Future[seq[JsonNode]] {.async.} = return resourceTemplateList()
proc listPromptsHandler(): Future[seq[JsonNode]] {.async.} = return promptList()
proc getPromptHandler(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
  return getPrompt(name, arguments)

proc main() =
  let port = if paramCount() >= 1: parseInt(paramStr(paramCount())) else: 0
  let server = newMcpServer(
    McpServerInfo(name: "mcp-nim-sdk-conformance", version: $DefaultProtocolVersion),
    capabilities = McpServerCapabilities(
      tools: some(McpToolsCapability()),
      resources: some(McpResourcesCapability()),
      prompts: some(McpPromptsCapability())))

  # The handler fields are closures; a plain proc needs the type spelled out.
  let toolHandlers = McpToolHandlers(
    listHandler: some(typeof(McpToolHandlers().listHandler.get)(listToolsHandler)),
    callHandler: some(typeof(McpToolHandlers().callHandler.get)(callToolHandler)))
  let resourceHandlers = McpResourceHandlers(
    listHandler: some(typeof(McpResourceHandlers().listHandler.get)(listResourcesHandler)),
    readHandler: some(typeof(McpResourceHandlers().readHandler.get)(readResourceHandler)),
    listTemplatesHandler: some(typeof(McpResourceHandlers().listTemplatesHandler.get)(listTemplatesHandler)))
  let promptHandlers = McpPromptHandlers(
    listHandler: some(typeof(McpPromptHandlers().listHandler.get)(listPromptsHandler)),
    getHandler: some(typeof(McpPromptHandlers().getHandler.get)(getPromptHandler)))
  server.setToolHandlers(toolHandlers)
  server.setResourceHandlers(resourceHandlers)
  server.setPromptHandlers(promptHandlers)

  let transport = newHttpServerTransport(port = port)
  transport.listen()
  stderr.writeLine("listening on http://127.0.0.1:" & $transport.port & "/mcp")
  waitFor server.attachTransport(transport)
  waitFor transport.serve()

main()
