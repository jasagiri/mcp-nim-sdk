## Resource links in tool results and prompt messages (2025-06-18 and
## later): sent where the version has them, read by the client, and usable
## to fetch the resource they point at.

import std/[unittest, asyncdispatch, json, options, strutils]
import ./server_harness
import ./client_peer
import client/client
import client/tools
import client/prompts
import client/resources
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

  test "Given a version that has resource links, when a tool returns one, then the block is sent as it is":
    for version in versionsWith(ftResourceLinks):
      let server = linkServer()
      let peer = server.connect(server.attach(), version)
      let content = peer.ask("tools/call", %*{"name": "t"})["result"]["content"]
      check content[1] == Link

  test "Given a version without resource links, when a tool returns one, then a text block with its name and uri stands in":
    for version in versionsWithout(ftResourceLinks):
      let server = linkServer()
      let peer = server.connect(server.attach(), version)
      let content = peer.ask("tools/call", %*{"name": "t"})["result"]["content"]
      check content[1]["type"].getStr() == "text"
      check "main.rs" in content[1]["text"].getStr()
      check "file:///project/src/main.rs" in content[1]["text"].getStr()

  test "Given a version that has resource links, when a prompt message holds one, then it is sent as it is":
    for version in versionsWith(ftResourceLinks):
      let server = linkServer()
      let peer = server.connect(server.attach(), version)
      let message = peer.ask("prompts/get", %*{"name": "p"})["result"]["messages"][0]
      check message["content"] == Link

  test "Given a version without resource links, when a prompt message holds one, then it is replaced by text":
    for version in versionsWithout(ftResourceLinks):
      let server = linkServer()
      let peer = server.connect(server.attach(), version)
      let message = peer.ask("prompts/get", %*{"name": "p"})["result"]["messages"][0]
      check message["content"]["type"].getStr() == "text"
      check "file:///project/src/main.rs" in message["content"]["text"].getStr()


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

  test "Given a tool result with a resource link, when the client calls the tool, then the item carries the link's fields":
    let client = linkPeer().connectedClient(LegacyDefault)
    let item = waitFor(client.callTool("t")).contentItems[0]
    check item.kind == mckResourceLink
    check item.linkUri == "file:///project/src/main.rs"
    check item.linkName == "main.rs"
    check item.linkDescription == some("Primary application entry point")
    check item.linkMimeType == some("text/x-rust")
    check item.toJson == Link

  test "Given a resource link with title and size, when the client reads it, then both are kept and written back":
    let wire = %*{"type": "resource_link", "uri": "file:///a", "name": "a", "title": "A", "size": 12}
    let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.reply(message["id"], %*{"content": [wire]}))
    let client = peer.connectedClient(LegacyDefault)
    let item = waitFor(client.callTool("t")).contentItems[0]
    check item.linkTitle == some("A")
    check item.linkSize == some(12)
    check item.toJson == wire

  test "Given a resource link without a name or uri, when the client reads it, then the protocol violation is raised":
    for broken in [%*{"type": "resource_link", "uri": "file:///a"},
                   %*{"type": "resource_link", "name": "a"}]:
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/call":
          peer.reply(message["id"], %*{"content": [broken]}))
      let client = peer.connectedClient(LegacyDefault)
      expect McpProtocolError:
        discard waitFor client.callTool("t")

  test "Given a resource link in a tool result, when the client reads the resource it names, then the link's uri is requested":
    let peer = linkPeer()
    let client = peer.connectedClient(LegacyDefault)
    let item = waitFor(client.callTool("t")).contentItems[0]
    let contents = waitFor client.readResource(item.linkUri)
    check peer.requestsFor("resources/read")[0]["params"]["uri"].getStr() == "file:///project/src/main.rs"
    check contents.len == 1

  test "Given a prompt message with a resource link, when the client gets the prompt, then the content is a link":
    let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      if message{"method"}.getStr() == "prompts/get":
        peer.reply(message["id"], %*{"messages": [{"role": "user", "content": Link}]}),
      capabilities = %*{"prompts": {}})
    let client = peer.connectedClient(LegacyDefault)
    check waitFor(client.getPrompt("p")).messages[0].content.kind == mckResourceLink
