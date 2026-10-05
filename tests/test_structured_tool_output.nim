## Structured tool output (2025-06-18 and later): outputSchema and
## structuredContent, sent only where the version has them, checked by the
## server before it answers and by the client when it reads the answer.

import std/[unittest, asyncdispatch, json, options, strutils]
import ./server_harness
import ./client_peer
import client/client
import client/tools
import server/tool_output

const WeatherSchema = """{"type": "object",
  "properties": {"temperature": {"type": "number"}, "conditions": {"type": "string"}},
  "required": ["temperature", "conditions"]}"""

proc weatherTool(): JsonNode =
  %*{"name": "weather", "inputSchema": {"type": "object"},
     "outputSchema": parseJson(WeatherSchema)}

proc plainTool(): JsonNode =
  %*{"name": "plain", "inputSchema": {"type": "object"}}

proc toolServer(answer: JsonNode): McpServer =
  ## A server with the weather tool whose handler always returns `answer`.
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  let tools = @[weatherTool(), plainTool()]
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: tools))
  result.onToolCall(outputChecked(
    proc(ctx: McpRequestContext, name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      return answer.copy(), tools))

proc callWeather(server: McpServer, version: McpProtocolVersion, name = "weather"): JsonNode =
  let peer = server.connect(server.attach(), version)
  peer.ask("tools/call", %*{"name": name})

let GoodResult = %*{"content": [], "structuredContent": {"temperature": 22.5, "conditions": "clear"}}

suite "structured output on the server":

  test "Given a version that has structured output, when tools are listed, then outputSchema is sent":
    for version in versionsWith(ftStructuredToolOutput):
      let server = toolServer(GoodResult)
      let peer = server.connect(server.attach(), version)
      let tool = peer.ask("tools/list")["result"]["tools"][0]
      check tool["outputSchema"] == parseJson(WeatherSchema)

  test "Given a version without structured output, when tools are listed, then outputSchema is not sent":
    for version in versionsWithout(ftStructuredToolOutput):
      let server = toolServer(GoodResult)
      let peer = server.connect(server.attach(), version)
      let tool = peer.ask("tools/list")["result"]["tools"][0]
      check not tool.hasKey("outputSchema")

  test "Given a conforming result, when a version with structured output is served, then structuredContent is sent":
    for version in versionsWith(ftStructuredToolOutput):
      let reply = toolServer(GoodResult).callWeather(version)
      check reply["result"]["structuredContent"]["temperature"].getFloat() == 22.5

  test "Given a version without structured output, when a tool returns structuredContent, then it is not sent and the text carries the data":
    for version in versionsWithout(ftStructuredToolOutput):
      let reply = toolServer(GoodResult).callWeather(version)
      check not reply["result"].hasKey("structuredContent")
      check parseJson(reply["result"]["content"][0]["text"].getStr()) ==
        GoodResult["structuredContent"]

  test "Given a version without structured output, when the tool also wrote its own text, then that text is kept alone":
    let answer = %*{"content": [{"type": "text", "text": "22.5 and clear"}],
                    "structuredContent": {"temperature": 22.5, "conditions": "clear"}}
    for version in versionsWithout(ftStructuredToolOutput):
      let reply = toolServer(answer).callWeather(version)
      check reply["result"]["content"].len == 1
      check reply["result"]["content"][0]["text"].getStr() == "22.5 and clear"

  test "Given structuredContent and no content, when the result is answered, then the serialized JSON is added as text":
    for version in versionsWith(ftStructuredToolOutput):
      let reply = toolServer(%*{"structuredContent": {"temperature": 1, "conditions": "x"}}).callWeather(version)
      check parseJson(reply["result"]["content"][0]["text"].getStr()) ==
        %*{"temperature": 1, "conditions": "x"}

  test "Given a result that breaks the outputSchema, when a version with structured output is served, then the server answers with an internal error":
    for version in versionsWith(ftStructuredToolOutput):
      let bad = %*{"content": [], "structuredContent": {"temperature": "hot", "conditions": "clear"}}
      let reply = toolServer(bad).callWeather(version)
      check reply.errorCode == -32603
      check "weather" in reply["error"]["message"].getStr()
      check "/temperature" in reply["error"]["message"].getStr()

  test "Given an outputSchema and a result without structuredContent, when a version with structured output is served, then the server answers with an internal error":
    for version in versionsWith(ftStructuredToolOutput):
      let reply = toolServer(%*{"content": [{"type": "text", "text": "x"}]}).callWeather(version)
      check reply.errorCode == -32603
      check "structuredContent" in reply["error"]["message"].getStr()

  test "Given a version without structured output, when the result has no structuredContent, then it is served as it is":
    for version in versionsWithout(ftStructuredToolOutput):
      let reply = toolServer(%*{"content": [{"type": "text", "text": "x"}]}).callWeather(version)
      check reply["result"]["content"][0]["text"].getStr() == "x"

  test "Given a result with isError, when the tool has an outputSchema, then it is not checked":
    for version in versionsWith(ftStructuredToolOutput):
      let failed = %*{"content": [{"type": "text", "text": "boom"}], "isError": true}
      let reply = toolServer(failed).callWeather(version)
      check reply["result"]["isError"].getBool()

  test "Given a tool without an outputSchema, when it returns any structuredContent, then it is not checked":
    for version in versionsWith(ftStructuredToolOutput):
      let reply = toolServer(%*{"content": [], "structuredContent": {"anything": 1}}).callWeather(version, "plain")
      check reply["result"]["structuredContent"]["anything"].getInt() == 1

  test "Given a schema in a dialect that cannot be checked, when a result arrives, then the server answers with an internal error naming the dialect":
    let schema = %*{"$schema": "https://example.com/own", "type": "object"}
    let tools = @[%*{"name": "odd", "inputSchema": {"type": "object"}, "outputSchema": schema}]
    for version in versionsWith(ftStructuredToolOutput):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolCall(outputChecked(
        proc(ctx: McpRequestContext, name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
          return %*{"content": [], "structuredContent": {}}, tools))
      let reply = server.callWeather(version, "odd")
      check reply.errorCode == -32603
      check "https://example.com/own" in reply["error"]["message"].getStr()

  test "Given a version before 2026-07-28, when structuredContent is not an object, then the server answers with an internal error; 2026-07-28 accepts any JSON":
    let tools = @[%*{"name": "list", "inputSchema": {"type": "object"},
                     "outputSchema": {"type": "array", "items": {"type": "integer"}}}]
    for version in versionsWith(ftStructuredToolOutput):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolCall(outputChecked(
        proc(ctx: McpRequestContext, name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
          return %*{"content": [], "structuredContent": [1, 2]}, tools))
      let reply = server.callWeather(version, "list")
      if isModern(version):
        check reply["result"]["structuredContent"] == %*[1, 2]
      else:
        check reply.errorCode == -32603

suite "structured output in the client":

  proc weatherPeer(answer: JsonNode): client_peer.Peer =
    startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      case message{"method"}.getStr()
      of "tools/list":
        peer.reply(message["id"], %*{"tools": [weatherTool(), plainTool()]})
      of "tools/call":
        peer.reply(message["id"], answer)
      else: discard)

  proc listed(peer: client_peer.Peer): McpClient =
    result = peer.connectedClient(LegacyDefault)
    discard waitFor result.listAllTools()

  test "Given a client of a version without structured output, when a result breaks the schema, then it is returned unchecked":
    for version in versionsWithout(ftStructuredToolOutput):
      let peer = weatherPeer(%*{"content": [], "structuredContent": {"temperature": "hot"}})
      let client = peer.connectedClient(version)
      discard waitFor client.listAllTools()
      check waitFor(client.callTool("weather")).structuredContent.isSome

  test "Given a listed tool with an outputSchema, when the result conforms, then structuredContent is returned":
    if LegacyDefault.has(ftStructuredToolOutput):
      let client = weatherPeer(GoodResult).listed()
      let result = waitFor client.callTool("weather")
      check result.structuredContent.get["conditions"].getStr() == "clear"

  test "Given a listed tool with an outputSchema, when the result breaks it, then the protocol violation names the tool and the path":
    if LegacyDefault.has(ftStructuredToolOutput):
      let client = weatherPeer(%*{"content": [], "structuredContent": {"temperature": "hot", "conditions": "x"}}).listed()
      var message = ""
      try:
        discard waitFor client.callTool("weather")
      except McpProtocolError as e:
        message = e.msg
      check "weather" in message
      check "/temperature" in message

  test "Given a listed tool with an outputSchema, when the result has no structuredContent, then it is a protocol violation":
    if LegacyDefault.has(ftStructuredToolOutput):
      let client = weatherPeer(%*{"content": [{"type": "text", "text": "x"}]}).listed()
      expect McpProtocolError:
        discard waitFor client.callTool("weather")

  test "Given a listed tool with an outputSchema, when the result is an error, then it is returned unchecked":
    if LegacyDefault.has(ftStructuredToolOutput):
      let client = weatherPeer(%*{"content": [{"type": "text", "text": "boom"}], "isError": true}).listed()
      let result = waitFor client.callTool("weather")
      check result.isError

  test "Given a result that breaks the schema, when validation is switched off for the call, then it is returned":
    if LegacyDefault.has(ftStructuredToolOutput):
      let client = weatherPeer(%*{"content": [], "structuredContent": {"temperature": "hot"}}).listed()
      let result = waitFor client.callTool("weather", validateOutput = false)
      check result.structuredContent.isSome

  test "Given a tool that was never listed, when it is called, then its structuredContent is not checked":
    let peer = weatherPeer(%*{"content": [], "structuredContent": {"temperature": "hot"}})
    let client = peer.connectedClient(LegacyDefault)
    let result = waitFor client.callTool("weather")
    check result.structuredContent.isSome

  test "Given a schema in a dialect that cannot be checked, when the result arrives, then the dialect is reported and validateOutput = false reads it":
    if LegacyDefault.has(ftStructuredToolOutput):
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        case message{"method"}.getStr()
        of "tools/list":
          peer.reply(message["id"], %*{"tools": [{"name": "odd", "inputSchema": {"type": "object"},
            "outputSchema": {"$schema": "https://example.com/own", "type": "object"}}]})
        of "tools/call":
          peer.reply(message["id"], %*{"content": [], "structuredContent": {}})
        else: discard)
      let client = peer.listed()
      var message = ""
      try:
        discard waitFor client.callTool("odd")
      except McpError as e:
        message = e.msg
      check "https://example.com/own" in message
      check waitFor(client.callTool("odd", validateOutput = false)).structuredContent.isSome
