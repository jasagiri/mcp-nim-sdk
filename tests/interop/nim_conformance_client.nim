## The client the official conformance suite (`@modelcontextprotocol/conformance`,
## `client` mode) runs: `nim_conformance_client URL`. The suite starts a mock
## server for a scenario, runs this program with the server's URL appended, and
## sets
##
##   MCP_CONFORMANCE_SCENARIO          the scenario name
##   MCP_CONFORMANCE_PROTOCOL_VERSION  the newest version the scenario expects
##   MCP_CONFORMANCE_CONTEXT           JSON the scenario hands the client
##                                     (pre-registered credentials, tool calls)
##
## The program acts as an application built on this SDK: it turns on every
## client feature of the core protocol (roots, sampling, elicitation,
## authorization), connects, and uses what the server offers: it calls each tool
## it lists, reads a resource, gets a prompt. What the scenario checks is what
## the SDK does on the wire while it does so. A scenario for a feature this
## SDK lacks is declined on stderr with the reason and exit code 2.
##
## An exit code other than 0 is not always a failure of the scenario: the
## scenarios that expect the client to refuse (a resource that is not the
## server asked for, an issuer that does not match) are met with the SDK's
## refusal, which this program reports and exits 1 for.

import std/[asyncdispatch, httpcore, json, options, os, strutils, tables, uri]
import client/[client, tools, resources, prompts, roots, sampling, elicitation]
import transport/http
import transport/http_wire as wire
import auth/client as oauth
import protocol/types
import protocol/features

const
  RedirectUri = "http://localhost:3000/callback"
  ClientMetadataUrl = "https://conformance-test.local/client-metadata.json"
    ## What the suite's Client ID Metadata Document scenario expects as the
    ## client id. The program does not host the document: the scenario's
    ## authorization server does not fetch it.
  Supported = ["initialize", "tools_call", "request-metadata", "http-standard-headers",
               "http-custom-headers", "http-invalid-tool-headers",
               "json-schema-2020-12-preservation", "json-schema-ref-no-deref",
               "sep-2322-client-request-state", "elicitation-sep1034-client-defaults",
               "sse-retry"]

proc declined(scenario, reason: string) {.noreturn.} =
  stderr.writeLine "scenario not supported by this client: " & scenario & " (" & reason & ")"
  quit(2)

proc scenarioContext(): JsonNode =
  let text = getEnv("MCP_CONFORMANCE_CONTEXT")
  if text.len == 0:
    return newJObject()
  parseJson(text)

proc redirectedTo(authorizationUrl: string): Future[seq[(string, string)]] {.async.} =
  ## What the user agent would do: open the authorization URL and report the
  ## parameters of the redirect that comes back. The scenario's authorization
  ## server approves at once; a page that asked the user something would
  ## need a person here.
  let response = await wire.request(authorizationUrl, HttpGet, followRedirects = false)
  defer: response.close()
  let location = response.headers.getOrDefault("Location")
  if response.code.int notin [301, 302, 303, 307, 308] or location.len == 0:
    raise newException(ValueError, "the authorization endpoint answered " & $response.code &
      " instead of redirecting to " & RedirectUri)
  for pair in decodeQuery(parseUri(location).query):
    result.add pair

proc defaultsOf(schema: JsonNode): JsonNode =
  ## The form as the user leaves it when they change nothing: every field that
  ## has a default holds it.
  result = newJObject()
  for name, property in schema{"properties"}.pairs:
    if property.hasKey("default"):
      result[name] = property["default"]

proc arguments(schema: JsonNode): JsonNode =
  ## Something that satisfies the required properties of a tool's input
  ## schema, for a tool the scenario gave no arguments for.
  result = newJObject()
  let properties = schema{"properties"}
  for name in schema{"required"}.getElems():
    let kind = properties{name.getStr()}{"type"}.getStr("string")
    result[name.getStr()] =
      case kind
      of "integer", "number": %1
      of "boolean": %true
      of "object": newJObject()
      of "array": newJArray()
      else: %"test"

proc newScenarioClient(wanted: McpProtocolVersion): McpClient =
  result = newMcpClient(
    McpClientInfo(name: "mcp-nim-sdk-conformance", version: $DefaultProtocolVersion),
    protocolVersion = wanted)
  if wanted.has(ftRoots):
    result.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} =
      return @[McpRoot(uri: "file://" & getCurrentDir(), name: some("work"))])
  if wanted.has(ftSampling):
    result.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
      return McpSamplingResult(role: "assistant", model: "conformance-model",
        content: McpContentItem(kind: mckText, text: "This is a test response from the client"),
        stopReason: some("endTurn")))
  if wanted.has(ftElicitation):
    result.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
      if request.mode != emForm:
        return McpElicitResult(action: eaDecline)
      # A form the user accepts as it stands: the defaults, and true for a
      # boolean nobody gave a default (the mock servers ask to confirm).
      var content = defaultsOf(request.requestedSchema)
      for name, property in request.requestedSchema{"properties"}.pairs:
        if not content.hasKey(name) and property{"type"}.getStr() == "boolean":
          content[name] = %true
      return McpElicitResult(action: eaAccept, content: content))

proc newTransport(url: string, scenario: string, wanted: McpProtocolVersion,
                  context: JsonNode): StreamableHttpTransport =
  result = newStreamableHttpTransport(url)
  if not scenario.startsWith("auth/"):
    return
  var config = newOAuthClientConfig(url, RedirectUri, redirectedTo, wanted,
                                    "mcp-nim-sdk-conformance")
  config.clientIdMetadataUrl = some(ClientMetadataUrl)
  if context.hasKey("client_id"):
    config.preRegistered = some(PreRegisteredClient(
      clientId: context["client_id"].getStr(),
      clientSecret: if context.hasKey("client_secret"): some(context["client_secret"].getStr())
                    else: none(string),
      issuer: if context.hasKey("issuer"): some(context["issuer"].getStr())
              else: none(string)))
  result.auth = asHttpAuth(newOAuthClient(config))

proc callListedTools(client: McpClient, scenario: string, context: JsonNode) {.async.} =
  let tools = await client.listAllTools()
  if scenario == "http-custom-headers":
    # The scenario names the calls whose headers it checks.
    for call in context["toolCalls"]:
      discard await client.callTool(call["name"].getStr(), call["arguments"])
    return
  var listed: Table[string, McpTool]
  for tool in tools:
    listed[tool.name] = tool
  for tool in tools:
    if scenario == "json-schema-2020-12-preservation":
      # Give the schema of the focal tool back through the echo tool, so the
      # scenario sees what this client kept of it.
      if tool.name == "json_schema_echo":
        discard await client.callTool(tool.name,
          %*{"schema": listed["json_schema_2020_12_tool"].inputSchema})
      continue
    if scenario == "json-schema-ref-no-deref":
      continue  # listing is the exercise; the schema must not be fetched
    let given = if scenario == "tools_call" and tool.name == "add_numbers":
                  %*{"a": 5, "b": 3}
                else: arguments(tool.inputSchema)
    discard await client.callTool(tool.name, given)

proc useResourcesAndPrompts(client: McpClient) {.async.} =
  let offered = client.serverCapabilities.get
  if offered.resources.isSome:
    let resources = await client.listAllResources()
    if resources.len > 0:
      discard await client.readResource(resources[0].uri)
  if offered.prompts.isSome:
    let prompts = await client.listAllPrompts()
    if prompts.len > 0:
      discard await client.getPrompt(prompts[0].name)

proc run(url, scenario: string) {.async.} =
  let wanted = parseProtocolVersion(getEnv("MCP_CONFORMANCE_PROTOCOL_VERSION", $DefaultProtocolVersion))
  if wanted.isNone:
    raise newException(ValueError, "MCP_CONFORMANCE_PROTOCOL_VERSION is not a released version")
  let version = min(wanted.get, DefaultProtocolVersion)
  let context = scenarioContext()
  let client = newScenarioClient(version)
  await client.connect(newTransport(url, scenario, version, context))
  if scenario != "initialize":
    if client.serverCapabilities.get.tools.isSome:
      await client.callListedTools(scenario, context)
    if scenario in ["http-standard-headers", "request-metadata"] or scenario.startsWith("auth/"):
      await client.useResourcesAndPrompts()
  await client.close()

proc main() =
  let scenario = getEnv("MCP_CONFORMANCE_SCENARIO")
  if paramCount() < 1:
    stderr.writeLine "usage: nim_conformance_client URL (with MCP_CONFORMANCE_SCENARIO set)"
    quit(64)
  if scenario notin Supported and not scenario.startsWith("auth/"):
    declined(scenario, "no client feature of this SDK corresponds to it")
  try:
    waitFor run(paramStr(paramCount()), scenario)
  except CatchableError as e:
    stderr.writeLine $e.name & ": " & e.msg
    quit(1)

main()
