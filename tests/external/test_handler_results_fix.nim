## What a server's handler may hand to a client: the images and embedded
## resources of a prompt, the blob of a resource, the arguments of a prompt
## and the entries of the tool list. A value the specification does not allow
## is the handler's defect: the client gets an internal error and nothing of
## it; a prompt called without a required argument is invalid params and the
## handler does not run.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness

let
  Png = "iVBORw0KGgo="

proc isError(reply: JsonNode, code: int): bool =
  reply.hasKey("error") and reply.errorCode == code

proc promptServer(message: JsonNode): McpServer =
  result = newServer(McpServerCapabilities(
    prompts: some(McpPromptsCapability()), resources: some(McpResourcesCapability()),
    tools: some(McpToolsCapability())))
  result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    return %*{"messages": [{"role": "user", "content": message}]})
  result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    return @[message])

proc gotPrompt(message: JsonNode, v: McpProtocolVersion): JsonNode =
  let server = promptServer(message)
  server.connect(server.attach(), v).ask("prompts/get", %*{"name": "p"})

proc readResource(contents: JsonNode, v: McpProtocolVersion): JsonNode =
  let server = promptServer(contents)
  server.connect(server.attach(), v).ask("resources/read", %*{"uri": "file:///b"})

suite "the image of a prompt":

  test "Given a prompt image whose data is not base64 or that has no mimeType, when the prompt is got, then the answer is an internal error":
    for v in SupportedProtocolVersions:
      for image in [%*{"type": "image", "data": "not base64!!", "mimeType": "image/png"},
                    %*{"type": "image", "data": "abc", "mimeType": "image/png"},
                    %*{"type": "image", "data": Png},
                    %*{"type": "image", "data": Png, "mimeType": ""}]:
        check gotPrompt(image, v).isError(-32603)

suite "the embedded resource of a prompt":

  test "Given an embedded resource without uri, without mimeType, or without text and blob, when the prompt is got, then the answer is an internal error":
    for v in SupportedProtocolVersions:
      for resource in [%*{"mimeType": "text/plain", "text": "x"},
                       %*{"uri": "file:///a", "text": "x"},
                       %*{"uri": "file:///a", "mimeType": "text/plain"},
                       %*{"uri": "file:///a", "mimeType": "image/png", "blob": "not base64!!"}]:
        check gotPrompt(%*{"type": "resource", "resource": resource}, v).isError(-32603)

  test "Given an embedded resource whose uri or mimeType is empty, or that has no resource, when the prompt is got, then the answer is an internal error":
    for v in SupportedProtocolVersions:
      check gotPrompt(%*{"type": "resource", "resource": {"uri": "", "mimeType": "text/plain", "text": "x"}}, v).isError(-32603)
      check gotPrompt(%*{"type": "resource", "resource": {"uri": "file:///a", "mimeType": "", "text": "x"}}, v).isError(-32603)
      check gotPrompt(%*{"type": "resource"}, v).isError(-32603)

  test "Given an embedded resource that is not an object, when the prompt is got, then the answer is an internal error":
    for v in SupportedProtocolVersions:
      for resource in [%*"x", %*7, %*[1, 2], %*true]:
        check gotPrompt(%*{"type": "resource", "resource": resource}, v).isError(-32603)

  test "Given message content that is an array holding a bad image or an embedded resource without uri, when the prompt is got, then the answer is an internal error":
    for v in SupportedProtocolVersions:
      for blocks in [%*[{"type": "image", "data": "not base64!!", "mimeType": "image/png"}],
                     %*[{"type": "text", "text": "ok"}, {"type": "image", "data": Png}],
                     %*[{"type": "resource", "resource": {"mimeType": "text/plain", "text": "x"}}]]:
        check gotPrompt(blocks, v).isError(-32603)

  test "Given an embedded resource with a uri, a mimeType and its text, or its base64 blob, when the prompt is got, then it is sent as it is":
    for v in SupportedProtocolVersions:
      for resource in [%*{"uri": "file:///a", "mimeType": "text/plain", "text": "x"},
                       %*{"uri": "file:///a", "mimeType": "text/plain", "text": ""},
                       %*{"uri": "file:///a", "mimeType": "image/png", "blob": Png}]:
        let message = %*{"type": "resource", "resource": resource}
        let answer = gotPrompt(message, v)
        check answer.hasKey("result")
        check answer["result"]["messages"][0]["content"] == message

suite "the shape of a prompt result":

  proc gotResult(promptResult: JsonNode, v: McpProtocolVersion): JsonNode =
    let server = newServer(McpServerCapabilities(prompts: some(McpPromptsCapability())))
    server.onPromptGet(proc(ctx: McpRequestContext, name: string,
                            arguments: JsonNode): Future[JsonNode] {.async.} =
      return promptResult)
    server.connect(server.attach(), v).ask("prompts/get", %*{"name": "p"})

  test "Given a prompt result without messages, or a message without content, when the prompt is got, then the answer is an internal error":
    for v in SupportedProtocolVersions:
      for promptResult in [%*{}, %*{"description": "no messages"},
                           %*{"messages": [{"role": "user"}]},
                           %*{"messages": [{"role": "user", "content": {"type": "text", "text": "ok"}},
                                           {"role": "assistant"}]}]:
        let answer = gotResult(promptResult, v)
        check answer.isError(-32603)
        check not answer.hasKey("result")

suite "the blob of a resource":

  test "Given a resource whose blob is not base64, when it is read, then the answer is an internal error":
    for v in SupportedProtocolVersions:
      for blob in ["not base64!!", "abc", "QQ=", "QQ==QQ==", "=QUE"]:
        check readResource(%*{"uri": "file:///b", "mimeType": "image/png", "blob": blob}, v).isError(-32603)

  test "Given a resource whose blob is base64 with or without padding groups, or that has text only, when it is read, then the contents are sent as they are":
    for v in SupportedProtocolVersions:
      for contents in [%*{"uri": "file:///b", "mimeType": "image/png", "blob": Png},
                       %*{"uri": "file:///b", "mimeType": "image/png", "blob": "QUJD"},
                       %*{"uri": "file:///b", "mimeType": "image/png", "blob": ""},
                       %*{"uri": "file:///b", "mimeType": "text/plain", "text": "x"}]:
        let answer = readResource(contents, v)
        check answer.hasKey("result")
        check answer["result"]["contents"][0] == contents

suite "the entries of the contents of a resource":

  test "Given a resource whose contents hold an entry that is not an object, when it is read, then the answer is an internal error":
    for v in SupportedProtocolVersions:
      for entry in [%*"x", %*7, %*[1, 2], %*true, newJNull()]:
        let answer = readResource(entry, v)
        check answer.isError(-32603)
        check not answer.hasKey("result")

suite "the arguments of a prompt":

  proc listedServer(ran: ref int, arguments: JsonNode): McpServer =
    result = newServer(McpServerCapabilities(prompts: some(McpPromptsCapability())))
    result.onPromptsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
      return McpPage(items: @[%*{"name": "greet", "arguments": arguments}]))
    result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                            arguments: JsonNode): Future[JsonNode] {.async.} =
      inc ran[]
      return %*{"messages": []})

  test "Given a prompt that lists a required argument, when it is got without it, then the handler is not run and the answer is invalid params":
    for v in SupportedProtocolVersions:
      let ran = new(int)
      let server = listedServer(ran, %*[{"name": "who", "required": true}])
      let peer = server.connect(server.attach(), v)
      check peer.ask("prompts/get", %*{"name": "greet"}).isError(-32602)
      check peer.ask("prompts/get", %*{"name": "greet", "arguments": {}}).isError(-32602)
      check peer.ask("prompts/get", %*{"name": "greet", "arguments": {"other": "x"}}).isError(-32602)
      check ran[] == 0
      check peer.ask("prompts/get", %*{"name": "greet", "arguments": {"who": "Ada"}}).hasKey("result")
      check ran[] == 1

  test "Given a prompt whose arguments are optional or absent, when it is got without them, then the handler runs":
    for v in SupportedProtocolVersions:
      for listed in [%*[{"name": "who"}], %*[{"name": "who", "required": false}], %*[]]:
        let ran = new(int)
        let server = listedServer(ran, listed)
        let peer = server.connect(server.attach(), v)
        check peer.ask("prompts/get", %*{"name": "greet"}).hasKey("result")
        check ran[] == 1

  test "Given a prompt the server does not list, when it is got without arguments, then the handler decides":
    for v in SupportedProtocolVersions:
      let ran = new(int)
      let server = listedServer(ran, %*[{"name": "who", "required": true}])
      let peer = server.connect(server.attach(), v)
      check peer.ask("prompts/get", %*{"name": "unlisted"}).hasKey("result")
      check ran[] == 1

  test "Given arguments that are not an object, when a prompt is got, then the answer is invalid params and the handler is not run":
    for v in SupportedProtocolVersions:
      let ran = new(int)
      let server = listedServer(ran, %*[])
      let peer = server.connect(server.attach(), v)
      check peer.ask("prompts/get", %*{"name": "greet", "arguments": "x"}).isError(-32602)
      check ran[] == 0

suite "the inputSchema of a listed tool":

  proc listing(tool: JsonNode, v: McpProtocolVersion): JsonNode =
    let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
    server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
      return McpPage(items: @[tool]))
    server.connect(server.attach(), v).ask("tools/list")

  test "Given a handler that lists a tool whose inputSchema is null, when a client lists tools from 2025-11-25, then the answer is an internal error":
    for v in SupportedProtocolVersions:
      if v < mpv20251125:
        continue
      check listing(%*{"name": "bad", "inputSchema": nil}, v).isError(-32603)
      check listing(%*{"name": "bad", "inputSchema": "object"}, v).isError(-32603)

  test "Given a tool listed with an inputSchema that is not of type object and version 2026-07-28, when the tools are listed, then the answer is an internal error":
    if mpv20260728 notin SupportedProtocolVersions:
      skip()   # a build that does not speak 2026-07-28 has no such client to answer
    else:
      for schema in [%*{"type": "string"}, %*{}, %*{"properties": {}}, %*{"type": ["object", "null"]}]:
        check listing(%*{"name": "t", "inputSchema": schema}, mpv20260728).isError(-32603)

  test "Given a tool listed with an object inputSchema of type object, when the tools are listed in any version, then it is listed as given":
    for v in SupportedProtocolVersions:
      for schema in [%*{"type": "object"},
                     %*{"type": "object", "properties": {"a": {"type": "string"}}, "required": ["a"]}]:
        let answer = listing(%*{"name": "t", "inputSchema": schema}, v)
        check answer.hasKey("result")
        check answer["result"]["tools"][0]["inputSchema"] == schema

  test "Given a tool listed with an inputSchema without a type, when the tools are listed before 2026-07-28, then it is listed":
    for v in SupportedProtocolVersions:
      if v >= mpv20260728:
        continue
      check listing(%*{"name": "t", "inputSchema": {"properties": {}}}, v).hasKey("result")
