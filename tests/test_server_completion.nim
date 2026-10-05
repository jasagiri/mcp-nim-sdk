## completion/complete: argument suggestions for prompts and resource templates.

import std/[unittest, asyncdispatch, json, options, tables]
import ./server_harness

var lastRequest: McpCompletionRequest

proc completionServer(declare = true): McpServer =
  result = newServer(McpServerCapabilities(
    prompts: some(McpPromptsCapability()),
    completions: if declare: some(McpCompletionsCapability()) else: none(McpCompletionsCapability)))
  result.onComplete(proc(ctx: McpRequestContext,
                         request: McpCompletionRequest): Future[McpCompletion] {.async.} =
    lastRequest = request
    if request.argumentName == "boom":
      raise newInvalidParams("Unknown argument: boom")
    if request.argumentName == "many":
      var values: seq[string]
      for i in 1 .. 150:
        values.add "v" & $i
      return McpCompletion(values: values, total: some(150))
    return McpCompletion(values: @["python", "pytorch"], total: some(10),
                         hasMore: some(true)))

proc promptComplete(argument, value: string): JsonNode =
  %*{"ref": {"type": "ref/prompt", "name": "code_review"},
     "argument": {"name": argument, "value": value}}

suite "completion/complete (every version)":

  test "Given a prompt reference, when a client completes an argument, then the handler's values, total and hasMore come back":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let reply = server.connect(server.attach(), v).ask("completion/complete",
        promptComplete("language", "py"))
      check reply["result"]["completion"] == %*{
        "values": ["python", "pytorch"], "total": 10, "hasMore": true}
      check lastRequest.reference.kind == crkPrompt
      check lastRequest.reference.name == "code_review"
      check lastRequest.argumentName == "language"
      check lastRequest.argumentValue == "py"

  test "Given a resource template reference, when a client completes, then the handler sees the URI template":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let reply = server.connect(server.attach(), v).ask("completion/complete", %*{
        "ref": {"type": "ref/resource", "uri": "file:///{path}"},
        "argument": {"name": "path", "value": "ro"}})
      check reply["result"]["completion"]["values"].len == 2
      check lastRequest.reference.kind == crkResource
      check lastRequest.reference.uri == "file:///{path}"

  test "Given more than 100 values, when a client completes, then 100 are sent and hasMore is true":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let reply = server.connect(server.attach(), v).ask("completion/complete",
        promptComplete("many", ""))
      check reply["result"]["completion"]["values"].len == 100
      check reply["result"]["completion"]["total"].getInt() == 150
      check reply["result"]["completion"]["hasMore"].getBool() == true

  test "Given previously resolved arguments, when a client completes, then the handler gets them from 2025-06-18 on":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      var params = promptComplete("framework", "fla")
      params["context"] = %*{"arguments": {"language": "python"}}
      discard server.connect(server.attach(), v).ask("completion/complete", params)
      if v.has(ftCompletionContext):
        check lastRequest.resolved == {"language": "python"}.toTable
      else:
        check lastRequest.resolved.len == 0

  test "Given a malformed request, when a client completes, then the answer is invalid params":
    let bad = [
      %*{"argument": {"name": "a", "value": "b"}},
      %*{"ref": {"type": "ref/other", "name": "x"}, "argument": {"name": "a", "value": "b"}},
      %*{"ref": {"type": "ref/prompt"}, "argument": {"name": "a", "value": "b"}},
      %*{"ref": {"type": "ref/resource"}, "argument": {"name": "a", "value": "b"}},
      %*{"ref": {"type": "ref/prompt", "name": "x"}},
      %*{"ref": {"type": "ref/prompt", "name": "x"}, "argument": {"name": "a"}},
      %*{"ref": {"type": "ref/prompt", "name": "x"}, "argument": {"name": "a", "value": "b"},
         "context": {"arguments": {"k": 1}}}]
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let peer = server.connect(server.attach(), v)
      for params in bad:
        let rejected = peer.ask("completion/complete", params).hasKey("error")
        # An older client does not send context, so the server does not read it.
        check rejected == (v.has(ftCompletionContext) or not params.hasKey("context"))

  test "Given a handler that rejects the argument, when a client completes, then the answer is invalid params":
    for v in SupportedProtocolVersions:
      let server = completionServer()
      let reply = server.connect(server.attach(), v).ask("completion/complete",
        promptComplete("boom", ""))
      check reply.errorCode == -32602

  test "Given a server without the completions capability, when a client completes, then the method is not found":
    for v in SupportedProtocolVersions:
      let server = completionServer(declare = false)
      let reply = server.connect(server.attach(), v).ask("completion/complete",
        promptComplete("language", "py"))
      check reply.errorCode == -32601

  test "Given a declared completions capability, when a client initializes, then it is announced from 2025-03-26 on":
    for v in legacyVersions():
      let server = completionServer()
      let t = server.attach()
      let id = freshId()
      t.inject("", rpcRequest(id, "initialize", %*{
        "protocolVersion": $v, "capabilities": {},
        "clientInfo": {"name": "c", "version": "1"}}))
      let caps = t.responseTo(id)["result"]["capabilities"]
      check caps.hasKey("completions") == v.has(ftCompletionsCapability)

  test "Given a 2026-07-28 server, when a client discovers it, then the completions capability is announced":
    if isModern(DefaultProtocolVersion):
      let server = completionServer()
      let reply = server.connect(server.attach(), mpv20260728).ask("server/discover")
      check reply["result"]["capabilities"].hasKey("completions")
