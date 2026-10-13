## "Servers MUST validate all tool inputs" (server/tools, every version):
## the arguments of a tools/call are checked against the `inputSchema` the
## server lists for the tool before the handler runs.
##
## What the client is told differs by version. Before 2025-11-25 invalid
## arguments are a protocol error (-32602); from 2025-11-25 an input that
## fails validation is a tool result with `isError`, which a model can read
## and correct.

import std/[unittest, asyncdispatch, json, options, strutils]
import ./server_harness
import server/server
import protocol/types
import protocol/features

proc forecastTool(): JsonNode =
  %*{"name": "forecast", "inputSchema": {"type": "object",
    "properties": {"city": {"type": "string", "minLength": 1},
                   "days": {"type": "integer", "minimum": 1, "maximum": 14}},
    "required": ["city"]}}

proc toolServer(tools: seq[JsonNode], calls: ref int): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: tools))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    inc calls[]
    return %*{"content": [{"type": "text", "text": "ran " & name}]})

proc askForecast(v: McpProtocolVersion, arguments: JsonNode, calls: ref int,
                 tools = @[forecastTool()]): JsonNode =
  let server = toolServer(tools, calls)
  let peer = server.connect(server.attach(), v)
  var params = %*{"name": "forecast"}
  if not arguments.isNil:
    params["arguments"] = arguments
  peer.ask("tools/call", params)

suite "tool input validation":

  test "Given arguments that fit the tool's inputSchema, when the tool is called, then the handler runs":
    for v in SupportedProtocolVersions:
      let calls = new int
      let answer = askForecast(v, %*{"city": "Paris", "days": 3}, calls)
      check answer.textOf == "ran forecast"
      check calls[] == 1

  test "Given arguments that break the inputSchema, when the tool is called, then the handler does not run and the answer is invalid params before 2025-11-25 and a tool error from it":
    for v in SupportedProtocolVersions:
      for arguments in [%*{"city": "Paris", "days": "three"}, %*{"city": "Paris", "days": 99},
                        %*{"days": 3}, %*{"city": ""}]:
        let calls = new int
        let answer = askForecast(v, arguments, calls)
        check calls[] == 0
        if v.has(ftToolInputErrors):
          check answer["result"]["isError"].getBool()
          check answer["result"]["content"][0]["type"].getStr() == "text"
          check answer["result"]["content"][0]["text"].getStr().len > 0
        else:
          check answer.errorCode == -32602

  test "Given arguments that break the inputSchema, when the answer is read, then it names the argument at fault":
    for v in SupportedProtocolVersions:
      let answer = askForecast(v, %*{"city": "Paris", "days": "three"}, new int)
      let said =
        if v.has(ftToolInputErrors): answer["result"]["content"][0]["text"].getStr()
        else: answer["error"]["message"].getStr()
      check "days" in said

  test "Given a call without arguments, when the inputSchema requires one, then it is checked as an empty object":
    for v in SupportedProtocolVersions:
      let calls = new int
      let answer = askForecast(v, nil, calls)
      check calls[] == 0
      if v.has(ftToolInputErrors):
        check answer["result"]["isError"].getBool()
      else:
        check answer.errorCode == -32602

  test "Given a tool the server lists without an inputSchema, or does not list, when it is called, then the handler decides":
    for v in SupportedProtocolVersions:
      for tools in [@[%*{"name": "forecast"}], @[%*{"name": "other", "inputSchema": {"type": "object"}}]]:
        let calls = new int
        let answer = askForecast(v, %*{"anything": 1}, calls, tools)
        check answer.textOf == "ran forecast"
        check calls[] == 1

  test "Given an inputSchema the server cannot check, when the tool is called, then it is an internal error and the handler does not run":
    for v in SupportedProtocolVersions:
      for schema in [%*{"$schema": "http://json-schema.org/draft-04/schema#", "type": "object"},
                     %*{"type": "object", "unevaluatedProperties": false}]:
        let calls = new int
        let answer = askForecast(v, %*{"city": "Paris"}, calls,
                                 @[%*{"name": "forecast", "inputSchema": schema}])
        check answer.errorCode == -32603
        check answer["error"]["message"].getStr() == "Internal error"
        check calls[] == 0
