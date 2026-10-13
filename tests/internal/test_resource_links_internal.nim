## Resource links in tool results and prompt messages (2025-06-18 and
## later): sent where the version has them, read by the client, and usable
## to fetch the resource they point at.

import std/[unittest, asyncdispatch, json, options, strutils]
import ../external/server_harness
import ../external/client_peer
import server/tools as serverTools

let Link = %*{"type": "resource_link", "uri": "file:///project/src/main.rs",
              "name": "main.rs", "description": "Primary application entry point",
              "mimeType": "text/x-rust"}

proc linkServer(): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()), prompts: some(McpPromptsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    return createToolResult(@[createTextToolContent("see the file"), Link]))
  result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    return %*{"messages": [{"role": "user", "content": Link}]})

suite "resource links on the server":


  test "Given the builder, when a resource link is made, then only the fields that were given are sent":
    check createResourceLinkToolContent("file:///a", "a") ==
      %*{"type": "resource_link", "uri": "file:///a", "name": "a"}
    check createResourceLinkToolContent("file:///a", "a", description = "d",
                                        mimeType = "text/plain", title = "A", size = some(12)) ==
      %*{"type": "resource_link", "uri": "file:///a", "name": "a", "description": "d",
         "mimeType": "text/plain", "title": "A", "size": 12}

suite "resource links in the client":

  proc linkPeer(): client_peer.Peer =
    startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      case message{"method"}.getStr()
      of "tools/call":
        peer.reply(message["id"], %*{"content": [Link]})
      of "resources/read":
        peer.reply(message["id"], %*{"contents": [{"uri": message["params"]["uri"].getStr(),
                                                   "text": "fn main() {}"}]})
      else: discard,
      capabilities = %*{"tools": {}, "resources": {}})

