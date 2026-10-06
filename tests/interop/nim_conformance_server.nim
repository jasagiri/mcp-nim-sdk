## The server the official conformance suite (`@modelcontextprotocol/conformance`,
## `server` mode) is pointed at: `nim_conformance_server PORT` serves
## http://127.0.0.1:PORT/mcp.
##
## The suite looks tools, resources and prompts up by fixed names (the names of
## the upstream "everything" server), so this program carries those names and
## nothing else. It turns on every server-side feature of the core protocol the
## scenarios exercise: logging, progress, completion, resource subscriptions,
## sampling and elicitation (asked of the client with `ctx.createMessage` and
## `ctx.elicit` before 2026-07-28, with `ctx.requireInput` from then on),
## multi round-trip requests and `x-mcp-header` parameters. What still fails
## and why is in docs/quality/conformance-*.md.

import std/[asyncdispatch, json, options, os, strutils, sysrand, tables]
import server/server
import server/errors
import server/mrtr
import server/elicit
import server/request_state
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

let stateKey = block:
  # Signs the requestState of the multi round-trip tools; it lives as long as
  # this process, which is all a conformance run needs.
  var key = ""
  for b in urandom(32):
    key.add toHex(int(b), 2)
  key

proc objectSchema(properties: openArray[(string, JsonNode)], required: seq[string] = @[]): JsonNode =
  result = %*{"type": "object", "properties": {}}
  for (name, schema) in properties:
    result["properties"][name] = schema
  if required.len > 0:
    result["required"] = %required

# SEP-1034: every primitive type with a default.
let elicitationDefaultsSchema = %*{
  "type": "object",
  "properties": {
    "name": {"type": "string", "default": "John Doe"},
    "age": {"type": "integer", "default": 30},
    "score": {"type": "number", "default": 95.5},
    "status": {"type": "string", "enum": ["active", "inactive", "pending"], "default": "active"},
    "verified": {"type": "boolean", "default": true}}}

# SEP-1330: the five enum shapes.
let elicitationEnumsSchema = %*{
  "type": "object",
  "properties": {
    "untitledSingle": {"type": "string", "enum": ["option1", "option2", "option3"]},
    "titledSingle": {"type": "string", "oneOf": [
      {"const": "value1", "title": "First Option"},
      {"const": "value2", "title": "Second Option"},
      {"const": "value3", "title": "Third Option"}]},
    "legacyEnum": {"type": "string", "enum": ["opt1", "opt2", "opt3"],
                   "enumNames": ["Option One", "Option Two", "Option Three"]},
    "untitledMulti": {"type": "array",
                      "items": {"type": "string", "enum": ["option1", "option2", "option3"]}},
    "titledMulti": {"type": "array", "items": {"anyOf": [
      {"const": "value1", "title": "First Choice"},
      {"const": "value2", "title": "Second Choice"},
      {"const": "value3", "title": "Third Choice"}]}}}}

var toolListGeneration, promptListGeneration = 0
  ## Bumped by the trigger tools below; the listings show it, so a
  ## `list_changed` notification announces a list that did differ.

let nameForm = %*{"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}

proc formParams(message: string, schema: JsonNode): JsonNode =
  %*{"message": message, "requestedSchema": schema}

proc samplingParams(prompt: string, maxTokens: int): JsonNode =
  %*{"messages": [{"role": "user", "content": textContent(prompt)}], "maxTokens": maxTokens}

let sepHeaderSchema = %*{
  "type": "object",
  "properties": {
    "region": {"type": "string", "x-mcp-header": "Region"},
    "priority": {"type": "integer", "x-mcp-header": "Priority"},
    "query": {"type": "string"}},
  "required": ["region"]}

proc toolList(): seq[JsonNode] =
  @[tool("test_simple_text", "Tests simple text content response"),
    tool("test_image_content", "Tests image content response"),
    tool("test_audio_content", "Tests audio content response"),
    tool("test_embedded_resource", "Tests embedded resource content response"),
    tool("test_multiple_content_types",
         "Tests response with multiple content types (text, image, resource)"),
    tool("test_error_handling", "Tests error response handling"),
    tool("test_tool_with_logging", "Tests tool that sends log messages during execution"),
    tool("test_tool_with_progress", "Tests tool that reports progress notifications"),
    tool("test_sampling", "Tests tool that requests LLM sampling from the client",
         objectSchema({"prompt": %*{"type": "string"}}, @["prompt"])),
    tool("test_elicitation", "Tests tool that requests user input from the client",
         objectSchema({"message": %*{"type": "string"}}, @["message"])),
    tool("test_elicitation_sep1034_defaults",
         "Tests elicitation with default values for every primitive type (SEP-1034)"),
    tool("test_elicitation_sep1330_enums",
         "Tests elicitation with all five enum shapes (SEP-1330)"),
    tool("json_schema_2020_12_tool",
         "Tool with JSON Schema 2020-12 features for conformance testing (SEP-1613)", jsonSchema2020),
    tool("test_custom_headers",
         "Tool whose parameters travel in Mcp-Param headers (SEP-2243)", sepHeaderSchema),
    tool("test_trigger_tool_change",
         "Changes the tool list and announces it (generation " & $toolListGeneration & ")"),
    tool("test_trigger_prompt_change",
         "Changes the prompt list and announces it (generation " & $promptListGeneration & ")"),
    tool("test_streaming_elicitation",
         "Asks the user while its response stream is open (SEP-2575 diagnostic)"),
    tool("test_logging_tool", "Logs once; silent unless the request asked for a level (SEP-2575 diagnostic)"),
    tool("test_missing_capability",
         "Needs the sampling capability: rejected when the client did not declare it (SEP-2575)"),
    tool("test_input_required_result_elicitation", "Asks for a name with one input request (SEP-2322)"),
    tool("test_input_required_result_sampling", "Asks the client's model one question (SEP-2322)"),
    tool("test_input_required_result_list_roots", "Asks for the client's roots (SEP-2322)"),
    tool("test_input_required_result_request_state", "Round-trips a signed requestState (SEP-2322)"),
    tool("test_input_required_result_multiple_inputs",
         "Asks for an elicitation, a sampling and the roots at once (SEP-2322)"),
    tool("test_input_required_result_multi_round", "Asks twice, with evolving state (SEP-2322)"),
    tool("test_input_required_result_tampered_state",
         "Rejects a requestState whose signature does not verify (SEP-2322)"),
    tool("test_input_required_result_capabilities",
         "Asks only for what the client declared (SEP-2322)")]

proc userAnswer(action: ElicitAction, content: JsonNode): string =
  "action=" & $action & ", content=" & (if content.isNil: "{}" else: $content)

proc firstText(answer: JsonNode): string =
  let content = answer{"content"}
  if not content.isNil and content.kind == JObject: content{"text"}.getStr() else: ""

proc openState(ctx: McpRequestContext, name: string, arguments: JsonNode): JsonNode =
  ## The payload of the requestState a retry carries; a missing or altered
  ## state is an invalid-params error.
  openRequestState(stateKey, ctx.requestState.get(""), "tools/call",
                   salient = %*{"name": name, "arguments": arguments},
                   principal = ctx.principal.get(""))

proc stateFor(ctx: McpRequestContext, name: string, arguments: JsonNode,
              step: int): Option[string] =
  some(sealRequestState(stateKey, %*{"step": step}, "tools/call",
                        salient = %*{"name": name, "arguments": arguments},
                        principal = ctx.principal.get("")))

proc callMrtrTool(ctx: McpRequestContext, name: string, arguments: JsonNode): JsonNode =
  case name
  of "test_input_required_result_elicitation":
    let answer = ctx.requireInput("user_name", "elicitation/create",
                                  formParams("What is your name?", nameForm))
    toolResult(textContent("Hello, " & answer{"content"}{"name"}.getStr() & "!"))
  of "test_input_required_result_sampling":
    let answer = ctx.requireInput("capital_question", "sampling/createMessage",
                                  samplingParams("What is the capital of France?", 100))
    toolResult(textContent("Sampling response: " & firstText(answer)))
  of "test_input_required_result_list_roots":
    let answer = ctx.requireInput("client_roots", "roots/list", newJObject())
    var uris: seq[string]
    for root in answer{"roots"}:
      uris.add root{"uri"}.getStr()
    toolResult(textContent("Roots: " & uris.join(", ")))
  of "test_input_required_result_request_state":
    discard ctx.requireInput("confirm", "elicitation/create",
      formParams("Please confirm",
                 %*{"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"]}),
      ctx.stateFor(name, arguments, 1))
    discard ctx.openState(name, arguments)
    toolResult(textContent("state-ok"))
  of "test_input_required_result_tampered_state":
    discard ctx.requireInput("confirm", "elicitation/create",
      formParams("Please confirm",
                 %*{"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"]}),
      ctx.stateFor(name, arguments, 1))
    discard ctx.openState(name, arguments)
    toolResult(textContent("state-verified"))
  of "test_input_required_result_multiple_inputs":
    let answers = ctx.requireInputs([
      (key: "user_name", methodName: "elicitation/create",
       params: formParams("What is your name?", nameForm)),
      (key: "greeting", methodName: "sampling/createMessage",
       params: samplingParams("Generate a greeting", 50)),
      (key: "client_roots", methodName: "roots/list", params: newJObject())],
      ctx.stateFor(name, arguments, 1))
    discard ctx.openState(name, arguments)
    toolResult(textContent("Received " & $answers.len & " answers"))
  of "test_input_required_result_multi_round":
    # Round 3 carries the answer to step 2 only, so the step the state names
    # decides what is asked; both of the first two rounds end in step 2's
    # question until it is answered.
    if ctx.requestState.isNone:
      raise newInputRequired([(key: "step1", methodName: "elicitation/create",
        params: formParams("Step 1: What is your name?", nameForm))],
        ctx.stateFor(name, arguments, 1))
    let step = ctx.openState(name, arguments){"step"}.getInt()
    discard ctx.requireInput("step2", "elicitation/create",
      formParams("Step 2: What is your favorite color?",
                 %*{"type": "object", "properties": {"color": {"type": "string"}},
                    "required": ["color"]}),
      ctx.stateFor(name, arguments, step + 1))
    toolResult(textContent("Multi-round complete"))
  of "test_input_required_result_capabilities":
    var asked: seq[InputRequestSpec]
    let declared = ctx.clientCapabilities
    if not declared.isNil and declared.kind == JObject:
      if declared.hasKey("sampling"):
        asked.add (key: "sampling", methodName: "sampling/createMessage",
                   params: samplingParams("Say hello", 20))
      if declared.hasKey("elicitation"):
        asked.add (key: "elicitation", methodName: "elicitation/create",
                   params: formParams("What is your name?", nameForm))
      if declared.hasKey("roots"):
        asked.add (key: "roots", methodName: "roots/list", params: newJObject())
    if asked.len == 0:
      toolResult(textContent("The client declared nothing to ask."))
    else:
      discard ctx.requireInputs(asked)
      toolResult(textContent("Answered: " & $asked.len))
  else:
    raise newUnknownTool(name)

proc logAfter(ctx: McpRequestContext, text: string): Future[void] {.async.} =
  await sleepAsync(50)
  await ctx.log(mllInfo, %text)

proc callTool(ctx: McpRequestContext, name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
  case name
  of "test_simple_text":
    return toolResult(textContent("This is a simple text response for testing."))
  of "test_image_content":
    return toolResult(%*{"type": "image", "data": TestImage, "mimeType": "image/png"})
  of "test_audio_content":
    return toolResult(%*{"type": "audio", "data": TestAudio, "mimeType": "audio/wav"})
  of "test_embedded_resource":
    return toolResult(%*{"type": "resource", "resource": {
      "uri": "test://embedded-resource", "mimeType": "text/plain",
      "text": "This is an embedded resource content."}})
  of "test_multiple_content_types":
    return toolResult(
      textContent("Multiple content types test:"),
      %*{"type": "image", "data": TestImage, "mimeType": "image/png"},
      %*{"type": "resource", "resource": {
        "uri": "test://mixed-content-resource", "mimeType": "application/json",
        "text": $(%*{"test": "data", "value": 123})}})
  of "test_error_handling":
    # A tool failure is a result with isError, not a protocol error.
    raise newToolFailure("This tool intentionally returns an error for testing")
  of "test_tool_with_logging":
    await ctx.log(mllInfo, %"Tool execution started")
    await ctx.logAfter("Tool processing data")
    await ctx.logAfter("Tool execution completed")
    return toolResult(textContent("Tool with logging executed successfully"))
  of "test_tool_with_progress":
    await ctx.reportProgress(0, some(100.0))
    await sleepAsync(50)
    await ctx.reportProgress(50, some(100.0))
    await sleepAsync(50)
    await ctx.reportProgress(100, some(100.0))
    return toolResult(textContent("Tool with progress executed successfully"))
  of "test_sampling":
    let prompt = arguments{"prompt"}.getStr()
    let params = samplingParams(prompt, 100)
    let answer =
      if isModern(ctx.version): ctx.requireInput("sampling", "sampling/createMessage", params)
      else: await ctx.createMessage(params)
    return toolResult(textContent("LLM response: " & firstText(answer)))
  of "test_trigger_tool_change":
    inc toolListGeneration
    await ctx.server.notifyToolListChanged()
    return toolResult(textContent("Tool list changed"))
  of "test_trigger_prompt_change":
    inc promptListGeneration
    await ctx.server.notifyPromptListChanged()
    return toolResult(textContent("Prompt list changed"))
  of "test_logging_tool":
    await ctx.log(mllInfo, %"test_logging_tool ran")
    return toolResult(textContent("Logged once"))
  of "test_elicitation", "test_elicitation_sep1034_defaults", "test_elicitation_sep1330_enums",
     "test_streaming_elicitation":
    let (message, schema) =
      case name
      of "test_elicitation", "test_streaming_elicitation":
        let asked = if name == "test_elicitation": arguments{"message"}.getStr()
                    else: "Please provide your information"
        (asked, %*{"type": "object", "properties": {
           "username": {"type": "string", "description": "User's response"},
           "email": {"type": "string", "description": "User's email address"}},
           "required": ["username", "email"]})
      of "test_elicitation_sep1034_defaults":
        ("Please review and update the form fields with defaults", elicitationDefaultsSchema)
      else:
        ("Select options from the enum fields", elicitationEnumsSchema)
    var action: ElicitAction
    var content: JsonNode
    if isModern(ctx.version):
      let answer = ctx.requireInput("elicitation", "elicitation/create", formParams(message, schema))
      action = parseEnum[ElicitAction](answer{"action"}.getStr())
      content = answer{"content"}
    else:
      let answer = await ctx.elicit(message, schema)
      action = answer.action
      content = answer.content
    let label = if name == "test_elicitation": "User response: " else: "Elicitation completed: "
    return toolResult(textContent(label & userAnswer(action, content)))
  of "json_schema_2020_12_tool":
    return toolResult(textContent("JSON Schema 2020-12 tool called with: " & $arguments))
  of "test_custom_headers":
    return toolResult(textContent("Custom headers tool called with: " & $arguments))
  of "test_missing_capability":
    # Needs the client's sampling; the SDK answers with the missing-capability
    # error when the request did not declare it.
    discard ctx.requireInput("sampling", "sampling/createMessage", samplingParams("ping", 1))
    return toolResult(textContent("Sampling answered"))
  else:
    return ctx.callMrtrTool(name, arguments)

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
      raise newResourceNotFound(uri)

proc promptArgument(name, description: string): JsonNode =
  %*{"name": name, "description": description, "required": true}

proc promptList(): seq[JsonNode] =
  @[%*{"name": "test_simple_prompt", "title": "Simple Test Prompt",
       "description": "A simple prompt without arguments" &
         (if promptListGeneration > 0: " (list generation " & $promptListGeneration & ")" else: "")},
    %*{"name": "test_prompt_with_arguments", "title": "Prompt With Arguments",
       "description": "A prompt with required arguments",
       "arguments": [promptArgument("arg1", "First test argument"),
                     promptArgument("arg2", "Second test argument")]},
    %*{"name": "test_prompt_with_embedded_resource", "title": "Prompt With Embedded Resource",
       "description": "A prompt that includes an embedded resource",
       "arguments": [promptArgument("resourceUri", "URI of the resource to embed")]},
    %*{"name": "test_prompt_with_image", "title": "Prompt With Image",
       "description": "A prompt that includes image content"},
    %*{"name": "test_input_required_result_prompt", "title": "Prompt That Needs Input",
       "description": "A prompt that asks the client for input before it answers (SEP-2322)"}]

proc promptMessage(content: JsonNode): JsonNode =
  %*{"role": "user", "content": content}

proc argument(arguments: JsonNode, name: string): string =
  let value = arguments{name}
  if value.isNil or value.kind != JString:
    raise newException(ValueError, "Missing required argument: " & name)
  value.getStr()

proc getPrompt(ctx: McpRequestContext, name: string, arguments: JsonNode): JsonNode =
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
  of "test_input_required_result_prompt":
    let answer = ctx.requireInput("user_context", "elicitation/create", formParams(
      "What context should the prompt use?",
      %*{"type": "object", "properties": {"context": {"type": "string"}}, "required": ["context"]}))
    %*{"messages": [promptMessage(textContent(
      "Prompt with context: " & answer{"content"}{"context"}.getStr()))]}
  else:
    raise newInvalidParams("Unknown prompt: " & name)


const CompletionExamples = ["paris", "park", "party"]

proc main() =
  let port = if paramCount() >= 1: parseInt(paramStr(paramCount())) else: 0
  let server = newMcpServer(
    McpServerInfo(name: "mcp-nim-sdk-conformance", version: $DefaultProtocolVersion),
    capabilities = McpServerCapabilities(
      tools: some(McpToolsCapability(listChanged: true)),
      resources: some(McpResourcesCapability(subscribe: true)),
      prompts: some(McpPromptsCapability(listChanged: true)),
      completions: some(McpCompletionsCapability()),
      logging: some(McpLoggingCapability())))

  server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: toolList()))
  server.onToolCall(callTool)
  server.onResourcesList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: resourceList()))
  server.onResourceTemplatesList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: resourceTemplateList()))
  server.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    return @[readResource(uri)])
  server.onPromptsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: promptList()))
  server.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    return getPrompt(ctx, name, arguments))
  server.onComplete(proc(ctx: McpRequestContext,
                         request: McpCompletionRequest): Future[McpCompletion] {.async.} =
    var values: seq[string]
    for candidate in CompletionExamples:
      if candidate.startsWith(request.argumentValue):
        values.add candidate
    return McpCompletion(values: values, total: some(values.len), hasMore: some(false)))

  let transport = newHttpServerTransport(port = port)
  transport.listen()
  stderr.writeLine("listening on http://127.0.0.1:" & $transport.port & "/mcp")
  waitFor server.attachTransport(transport)
  waitFor transport.serve()

main()
