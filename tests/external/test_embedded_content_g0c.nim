## What a server sends of the content that carries data: the image and the
## embedded resource of a prompt message, and the resource a tool result
## embeds. A well formed block leaves the server as the handler built it.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness

const
  Png = "iVBORw0KGgo="  # the first bytes of a PNG, as base64

let
  TextResource = %*{"uri": "file:///notes.txt", "mimeType": "text/plain", "text": "hello"}
  BlobResource = %*{"uri": "file:///logo.png", "mimeType": "image/png", "blob": "iVBORw0KGgo="}

proc contentServer(): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()), prompts: some(McpPromptsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    return %*{"content": [
      {"type": "resource", "resource": TextResource},
      {"type": "resource", "resource": BlobResource}]})
  result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    return %*{"messages": [
      {"role": "user", "content": {"type": "image", "data": Png, "mimeType": "image/png"}},
      {"role": "user", "content": {"type": "resource", "resource": TextResource}},
      {"role": "assistant", "content": {"type": "resource", "resource": BlobResource}}]})

suite "content that carries data (every version)":

  test "Given a tool result that embeds a text resource and a blob resource, when the tool is called, then both arrive as the handler built them":
    for v in SupportedProtocolVersions:
      let server = contentServer()
      let reply = server.connect(server.attach(), v).ask("tools/call", %*{"name": "any"})
      let content = reply["result"]["content"]
      check content.len == 2
      check content[0] == %*{"type": "resource", "resource": TextResource}
      check content[1] == %*{"type": "resource", "resource": BlobResource}

  test "Given a prompt with an image and embedded resources, when it is got, then each message carries the block with its uri, mimeType and text or blob":
    for v in SupportedProtocolVersions:
      let server = contentServer()
      let reply = server.connect(server.attach(), v).ask("prompts/get", %*{"name": "any"})
      let messages = reply["result"]["messages"]
      check messages.len == 3
      check messages[0]["content"] == %*{"type": "image", "data": Png, "mimeType": "image/png"}
      check messages[1]["content"]["resource"] == TextResource
      check messages[2]["content"]["resource"] == BlobResource
