## What a client reads of the content that carries data: the image and the
## embedded resource of a prompt message or a tool result. A block that
## lacks a field the specification requires of it is a protocol error.

import std/[unittest, asyncdispatch, json, options]
import client/client
import client/content
import client/tools
import client/prompts
import ./client_peer

const
  Png = "iVBORw0KGgo="

let
  TextResource = %*{"uri": "file:///notes.txt", "mimeType": "text/plain", "text": "hello"}
  BlobResource = %*{"uri": "file:///logo.png", "mimeType": "image/png", "blob": "iVBORw0KGgo="}

proc serving(promptMessages, toolContent: JsonNode): Peer =
  startPeer(proc(peer: Peer, message: JsonNode) =
    case message{"method"}.getStr()
    of "prompts/get":
      peer.reply(message["id"], %*{"messages": promptMessages})
    of "tools/call":
      peer.reply(message["id"], %*{"content": toolContent})
    else:
      discard, modern = SpeaksModern, capabilities = %*{"tools": {}, "prompts": {}})

suite "a client reads image and resource blocks":

  test "Given a prompt with an image and embedded resources, when it is got, then each block is read with its fields":
    let peer = serving(%*[
      {"role": "user", "content": {"type": "image", "data": Png, "mimeType": "image/png"}},
      {"role": "user", "content": {"type": "resource", "resource": TextResource}},
      {"role": "assistant", "content": {"type": "resource", "resource": BlobResource}}], %*[])
    let client = peer.connectedClient()
    let got = waitFor client.getPrompt("any")
    check got.messages[0].content.kind == mckImage
    check got.messages[0].content.imageData == Png
    check got.messages[0].content.imageMimeType == "image/png"
    check got.messages[1].content.kind == mckResource
    check got.messages[1].content.resource.uri == "file:///notes.txt"
    check got.messages[1].content.resource.mimeType == "text/plain"
    check got.messages[1].content.resource.text == some("hello")
    check got.messages[2].content.resource.blob == some(Png)
    check got.messages[2].content.resource.mimeType == "image/png"

  test "Given a tool result that embeds resources, when the tool is called, then they are read with their fields":
    let peer = serving(%*[], %*[{"type": "resource", "resource": TextResource},
                                {"type": "resource", "resource": BlobResource}])
    let client = peer.connectedClient()
    let called = waitFor client.callTool("any")
    check called.contentItems.len == 2
    check called.contentItems[0].kind == mckResource
    check called.contentItems[0].resource.text == some("hello")
    check called.contentItems[1].resource.blob == some(Png)

  test "Given a prompt image without its mimeType or data, when it is got, then the answer is a protocol error":
    for image in [%*{"type": "image", "data": Png}, %*{"type": "image", "mimeType": "image/png"}]:
      let peer = serving(%*[{"role": "user", "content": image}], %*[])
      let client = peer.connectedClient()
      expect McpProtocolError:
        discard waitFor client.getPrompt("any")

  test "Given an embedded resource without its uri, when the prompt is got or the tool is called, then the answer is a protocol error":
    let broken = %*{"type": "resource", "resource": {"mimeType": "text/plain", "text": "hello"}}
    let peer = serving(%*[{"role": "user", "content": broken}], %*[broken])
    let client = peer.connectedClient()
    expect McpProtocolError:
      discard waitFor client.getPrompt("any")
    expect McpProtocolError:
      discard waitFor client.callTool("any")
