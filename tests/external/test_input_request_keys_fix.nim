## MRTR: the keys of one `inputRequests` map are unique, and the client
## answers by key. A handler that asks twice under one key is refused instead
## of one request silently replacing the other.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness
import server/mrtr

let ClientCapabilities = %*{"io.modelcontextprotocol/clientCapabilities":
                              {"roots": {}, "sampling": {}}}

proc callWith(requests: seq[InputRequestSpec], v: McpProtocolVersion,
              responses: JsonNode = nil): JsonNode =
  let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    discard ctx.requireInputs(requests)
    return %*{"content": []})
  var params = %*{"name": "t"}
  if not responses.isNil:
    params["inputResponses"] = responses
  server.connect(server.attach(), v).ask("tools/call", params, meta = ClientCapabilities)

suite "the keys of inputRequests":

  test "Given a handler that asks with the same key twice, when it is called, then the duplicate is refused instead of one request silently replacing the other":
    for v in versionsWith(ftMultiRoundTripRequests):
      let answer = callWith(@[
        (key: "a", methodName: "roots/list", params: newJObject()),
        (key: "a", methodName: "sampling/createMessage", params: %*{"messages": [], "maxTokens": 1})], v)
      check answer.hasKey("error")
      check answer.errorCode == -32603

  test "Given a handler that asks with the same key twice and the client has answered that key, when it is called again, then the duplicate is still refused":
    for v in versionsWith(ftMultiRoundTripRequests):
      let answer = callWith(@[
        (key: "a", methodName: "roots/list", params: newJObject()),
        (key: "a", methodName: "roots/list", params: newJObject())], v,
        responses = %*{"a": {"roots": []}})
      check answer.hasKey("error")
      check answer.errorCode == -32603

  test "Given a handler that asks under two different keys, when it is called, then both requests are asked":
    for v in versionsWith(ftMultiRoundTripRequests):
      let answer = callWith(@[
        (key: "a", methodName: "roots/list", params: newJObject()),
        (key: "b", methodName: "roots/list", params: newJObject())], v)
      check answer.hasKey("result")
      check answer["result"]["inputRequests"].len == 2

  test "Given a handler that builds an input_required with a duplicate key, when the exception is made, then it raises and does not drop a request":
    expect McpPayloadError:
      discard newInputRequired([
        (key: "a", methodName: "roots/list", params: newJObject()),
        (key: "a", methodName: "roots/list", params: newJObject())])
