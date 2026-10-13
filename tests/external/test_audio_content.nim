## Audio content blocks (2025-03-26 and later) in tool results and prompt
## messages: sent where the version has them, read by the client.

import std/[unittest, asyncdispatch, json, options, strutils]
import ./server_harness
import ./client_peer
import client/client
import client/tools
import client/prompts
import server/tools as serverTools

proc audioServer(): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()), prompts: some(McpPromptsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    return createToolResult(@[createTextToolContent("before"),
      createAudioToolContent("QUJD", "audio/wav"), createTextToolContent("after")]))
  result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    return %*{"messages": [{"role": "user",
      "content": createAudioToolContent("QUJD", "audio/mpeg")}]})

suite "audio content on the server":

  test "Given a version that has audio, when a tool returns audio, then the block is sent as it is":
    for version in versionsWith(ftAudioContent):
      let server = audioServer()
      let peer = server.connect(server.attach(), version)
      let content = peer.ask("tools/call", %*{"name": "t"})["result"]["content"]
      check content.len == 3
      check content[1] == %*{"type": "audio", "data": "QUJD", "mimeType": "audio/wav"}

  test "Given a version without audio, when a tool returns audio, then a text block says so in its place":
    for version in versionsWithout(ftAudioContent):
      let server = audioServer()
      let peer = server.connect(server.attach(), version)
      let content = peer.ask("tools/call", %*{"name": "t"})["result"]["content"]
      check content.len == 3
      check content[0]["text"].getStr() == "before"
      check content[1]["type"].getStr() == "text"
      check "audio/wav" in content[1]["text"].getStr()
      check content[2]["text"].getStr() == "after"

  test "Given a version that has audio, when a prompt message holds audio, then it is sent as it is":
    for version in versionsWith(ftAudioContent):
      let server = audioServer()
      let peer = server.connect(server.attach(), version)
      let message = peer.ask("prompts/get", %*{"name": "p"})["result"]["messages"][0]
      check message["content"]["type"].getStr() == "audio"

  test "Given a version without audio, when a prompt message holds audio, then it is replaced by text":
    for version in versionsWithout(ftAudioContent):
      let server = audioServer()
      let peer = server.connect(server.attach(), version)
      let message = peer.ask("prompts/get", %*{"name": "p"})["result"]["messages"][0]
      check message["content"]["type"].getStr() == "text"
      check "audio/mpeg" in message["content"]["text"].getStr()

suite "audio content in the client":

  test "Given a tool result with audio, when the client calls the tool, then the item is audio with its data and type":
    let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.reply(message["id"], %*{"content": [
          {"type": "audio", "data": "QUJD", "mimeType": "audio/wav"}]}))
    let client = peer.connectedClient(LegacyDefault)
    let result = waitFor client.callTool("t")
    check result.contentItems[0].kind == mckAudio
    check result.contentItems[0].audioData == "QUJD"
    check result.contentItems[0].audioMimeType == "audio/wav"
    check result.contentItems[0].toJson == %*{"type": "audio", "data": "QUJD", "mimeType": "audio/wav"}

  test "Given an audio block without mimeType, when the client calls the tool, then the protocol violation is raised":
    let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.reply(message["id"], %*{"content": [{"type": "audio", "data": "QUJD"}]}))
    let client = peer.connectedClient(LegacyDefault)
    expect McpProtocolError:
      discard waitFor client.callTool("t")

  test "Given a prompt message with audio, when the client gets the prompt, then the content is audio":
    let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      if message{"method"}.getStr() == "prompts/get":
        peer.reply(message["id"], %*{"messages": [{"role": "user", "content":
          {"type": "audio", "data": "QUJD", "mimeType": "audio/mpeg"}}]}),
      capabilities = %*{"prompts": {}})
    let client = peer.connectedClient(LegacyDefault)
    let prompt = waitFor client.getPrompt("p")
    check prompt.messages[0].content.kind == mckAudio
