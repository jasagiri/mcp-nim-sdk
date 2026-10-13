## completion/complete: what a server answers when its handler breaks, and
## the means an application has to limit the requests it serves.

import std/[unittest, asyncdispatch, json, options, strutils]
import ./server_harness

var handled = 0

proc completionServer(): McpServer =
  result = newServer(McpServerCapabilities(
    prompts: some(McpPromptsCapability()),
    completions: some(McpCompletionsCapability())))
  result.onComplete(proc(ctx: McpRequestContext,
                         request: McpCompletionRequest): Future[McpCompletion] {.async.} =
    inc handled
    if request.argumentName == "crash":
      raise newException(ValueError, "secret internal detail")
    return McpCompletion(values: @["python"]))

proc promptComplete(argument: string): JsonNode =
  %*{"ref": {"type": "ref/prompt", "name": "code_review"},
     "argument": {"name": argument, "value": "p"}}

suite "completion/complete when the handler breaks":

  test "Given a completion handler that breaks, when a client completes, then the answer is an internal error without the cause":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let reply = server.connect(server.attach(), v).ask("completion/complete",
        promptComplete("crash"))
      check reply.errorCode == -32603
      check not reply.hasKey("result")
      check "secret" notin $reply

  test "Given a completion handler that broke, when the client completes again, then the server still answers":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("completion/complete", promptComplete("crash")).errorCode == -32603
      check peer.ask("completion/complete", promptComplete("language"))["result"]["completion"]["values"] ==
        %*["python"]

suite "limiting completion requests":

  test "Given an interceptor that refuses the third completion request, when a client completes three times, then the third is refused and the handler is not run for it":
    for v in SupportedProtocolVersions:
      handled = 0
      let server = completionServer()
      var seen = 0
      server.addRequestInterceptor(proc(ctx: McpRequestContext,
                                        request: JsonRpcRequest): Future[Option[JsonRpcResponse]] {.async.} =
        if request.`method` != "completion/complete":
          return none(JsonRpcResponse)
        inc seen
        if seen > 2:
          return some(newJsonRpcErrorResponse(request.id, -32000, "Too many completion requests"))
        return none(JsonRpcResponse))
      let peer = server.connect(server.attach(), v)
      check not peer.ask("completion/complete", promptComplete("a")).hasKey("error")
      check not peer.ask("completion/complete", promptComplete("b")).hasKey("error")
      let refused = peer.ask("completion/complete", promptComplete("c"))
      check refused.errorCode == -32000
      check refused["error"]["message"].getStr() == "Too many completion requests"
      check handled == 2
