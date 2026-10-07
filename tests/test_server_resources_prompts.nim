## What a server answers to resources/list, resources/read, prompts/list and
## prompts/get, in every version: the shape of the answers and the refusal
## when the capability was not declared.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness

proc fixedList(items: seq[JsonNode]): ListHandler =
  proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: items)

proc contentServer(): McpServer =
  result = newServer(McpServerCapabilities(
    resources: some(McpResourcesCapability()),
    prompts: some(McpPromptsCapability())))
  result.onResourcesList(fixedList(@[
    %*{"uri": "file:///a.txt", "name": "a.txt", "mimeType": "text/plain"},
    %*{"uri": "file:///b.bin", "name": "b.bin"}]))
  result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    case uri
    of "file:///a.txt":
      return @[%*{"uri": uri, "mimeType": "text/plain", "text": "hello"}]
    of "file:///b.bin":
      return @[%*{"uri": uri, "blob": "QQ=="}]
    else:
      raise newResourceNotFound(uri))
  result.onPromptsList(fixedList(@[
    %*{"name": "greet", "description": "Greet someone",
       "arguments": [{"name": "who", "required": true}]}]))
  result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    if name != "greet":
      raise newInvalidParams("Invalid prompt name: " & name)
    if not arguments.hasKey("who"):
      raise newInvalidParams("Missing required argument: who")
    return %*{"description": "Greet someone", "messages": [
      {"role": "user", "content": {"type": "text",
                                   "text": "Hello, " & arguments["who"].getStr()}}]})

suite "resources and prompts on the wire (every version)":

  test "Given resources, when a client lists and reads them, then entries carry uri and name and contents carry the uri with text or blob":
    for v in SupportedProtocolVersions:
      let server = contentServer()
      let peer = server.connect(server.attach(), v)
      let listed = peer.ask("resources/list")["result"]["resources"]
      check listed.len == 2
      for entry in listed:
        check entry["uri"].getStr().len > 0
        check entry["name"].getStr().len > 0
      let text = peer.ask("resources/read", %*{"uri": "file:///a.txt"})["result"]["contents"]
      check text.len == 1
      check text[0]["uri"].getStr() == "file:///a.txt"
      check text[0]["text"].getStr() == "hello"
      let blob = peer.ask("resources/read", %*{"uri": "file:///b.bin"})["result"]["contents"]
      check blob[0]["uri"].getStr() == "file:///b.bin"
      check blob[0]["blob"].getStr() == "QQ=="

  test "Given no resources capability, when a client lists or reads resources, then the method is not found":
    for v in SupportedProtocolVersions:
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let peer = server.connect(server.attach(), v)
      check peer.ask("resources/list").errorCode == -32601
      check peer.ask("resources/read", %*{"uri": "file:///a"}).errorCode == -32601

  test "Given handlers for resources and prompts but no capability declared, when a client calls them, then the method is not found":
    for v in SupportedProtocolVersions:
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onResourcesList(fixedList(@[%*{"uri": "file:///a.txt", "name": "a.txt"}]))
      server.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
        return @[%*{"uri": uri, "text": "hello"}])
      server.onPromptsList(fixedList(@[%*{"name": "greet"}]))
      server.onPromptGet(proc(ctx: McpRequestContext, name: string,
                              arguments: JsonNode): Future[JsonNode] {.async.} =
        return %*{"messages": []})
      let peer = server.connect(server.attach(), v)
      check peer.ask("resources/list").errorCode == -32601
      check peer.ask("resources/read", %*{"uri": "file:///a.txt"}).errorCode == -32601
      check peer.ask("prompts/list").errorCode == -32601
      check peer.ask("prompts/get", %*{"name": "greet"}).errorCode == -32601

  test "Given the capabilities declared but no handlers, when a client calls the methods, then the method is not found":
    for v in SupportedProtocolVersions:
      let server = newServer(McpServerCapabilities(
        resources: some(McpResourcesCapability()), prompts: some(McpPromptsCapability())))
      let peer = server.connect(server.attach(), v)
      check peer.ask("resources/list").errorCode == -32601
      check peer.ask("resources/read", %*{"uri": "file:///a.txt"}).errorCode == -32601
      check peer.ask("prompts/list").errorCode == -32601
      check peer.ask("prompts/get", %*{"name": "greet"}).errorCode == -32601

  test "Given a prompt, when a client lists and gets it, then the name is listed and the messages the handler built come back":
    for v in SupportedProtocolVersions:
      let server = contentServer()
      let peer = server.connect(server.attach(), v)
      let listed = peer.ask("prompts/list")["result"]["prompts"]
      check listed.len == 1
      check listed[0]["name"].getStr() == "greet"
      let got = peer.ask("prompts/get", %*{"name": "greet", "arguments": {"who": "Ada"}})["result"]
      check got["messages"].len == 1
      check got["messages"][0]["role"].getStr() == "user"
      check got["messages"][0]["content"]["text"].getStr() == "Hello, Ada"

  test "Given no prompts capability, when a client lists or gets prompts, then the method is not found":
    for v in SupportedProtocolVersions:
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      let peer = server.connect(server.attach(), v)
      check peer.ask("prompts/list").errorCode == -32601
      check peer.ask("prompts/get", %*{"name": "greet"}).errorCode == -32601

  test "Given a prompt that needs an argument, when a client gets it without, then the answer is invalid params":
    for v in SupportedProtocolVersions:
      let server = contentServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("prompts/get", %*{"name": "greet"}).errorCode == -32602
