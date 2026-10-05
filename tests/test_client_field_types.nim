## An optional string field of an answer that is present but not a string is
## a protocol violation of the server, not an absent field: the client says so
## instead of reading it as nothing.

import std/[unittest, asyncdispatch, json, options, strutils]
import client/client
import client/content
import client/tools
import client/resources
import client/prompts
import ./client_peer

let Capabilities = %*{"tools": {}, "resources": {}, "prompts": {}}

proc answering(listKey: string, body: JsonNode): proc(peer: Peer, message: JsonNode) =
  result = proc(peer: Peer, message: JsonNode) =
    peer.reply(message["id"], body)

suite "optional string fields of answers":
  test "Given a tool whose title is a number, when tools are listed, then it is a protocol error naming the field":
    let peer = startPeer(answering("tools", %*{"tools": [
      {"name": "a", "title": 5, "inputSchema": {"type": "object"}}]}), capabilities = Capabilities)
    let client = peer.connectedClient(LegacyDefault)
    var message = ""
    try:
      discard waitFor client.listTools()
    except McpProtocolError as e:
      message = e.msg
    check "title" in message
    check "tools/list" in message

  test "Given a resource whose mimeType is an object, when resources are listed, then it is a protocol error":
    let peer = startPeer(answering("resources", %*{"resources": [
      {"uri": "file:///a", "name": "a", "mimeType": {}}]}), capabilities = Capabilities)
    let client = peer.connectedClient(LegacyDefault)
    expect McpProtocolError:
      discard waitFor client.listResources()

  test "Given a nextCursor that is a number, when tools are listed, then it is a protocol error":
    let peer = startPeer(answering("tools", %*{"tools": [], "nextCursor": 7}),
                         capabilities = Capabilities)
    let client = peer.connectedClient(LegacyDefault)
    expect McpProtocolError:
      discard waitFor client.listTools()

  test "Given a prompt description that is a list, when the prompt is fetched, then it is a protocol error":
    let peer = startPeer(answering("prompts", %*{"description": [1], "messages": []}),
                         capabilities = Capabilities)
    let client = peer.connectedClient(LegacyDefault)
    expect McpProtocolError:
      discard waitFor client.getPrompt("p")

  test "Given an embedded text resource whose text is a number, when parsed, then it is a protocol error":
    expect McpProtocolError:
      discard parseContentItem(%*{"type": "resource",
        "resource": {"uri": "file:///a", "text": 3}}, "tools/call")

  test "Given optional strings that are absent or strings, when read, then they are none or the string":
    check optionalString(%*{}, "title", "ctx").isNone
    check optionalString(%*{"title": "T"}, "title", "ctx") == some("T")
