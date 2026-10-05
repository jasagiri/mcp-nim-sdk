## The typed operations of the client against a hand-written server: what
## they send, how they read the answer, and when they refuse to send.

import std/[unittest, asyncdispatch, json, options, strutils]
import client/client
import client/tools
import client/resources
import client/prompts
import client/utilities
import protocol/types
import ./client_peer

let AllCapabilities = %*{
  "tools": {}, "resources": {"subscribe": true}, "prompts": {},
  "logging": {}, "completions": {}}

proc pagedTools(peer: Peer, message: JsonNode) =
  ## Two pages of tools: a, b | c.
  if message{"method"}.getStr() == "tools/list":
    let cursor = message["params"]{"cursor"}.getStr()
    case cursor
    of "":
      peer.reply(message["id"], %*{"tools": [
        {"name": "a", "inputSchema": {"type": "object"}},
        {"name": "b", "description": "second", "inputSchema": {"type": "object"},
         "annotations": {"readOnlyHint": true}}], "nextCursor": "page-2"})
    of "page-2":
      peer.reply(message["id"], %*{"tools": [
        {"name": "c", "inputSchema": {"type": "object"}}]})
    else:
      peer.replyError(message["id"], -32602, "bad cursor")

suite "tools":

  test "Given a server with tools, when one page is listed, then the tools and nextCursor are returned":
    let peer = startPeer(pagedTools)
    let client = peer.connectedClient(LegacyDefault)
    let page = waitFor client.listTools()
    check page.tools.len == 2
    check page.tools[1].name == "b"
    check page.tools[1].description == "second"
    check page.tools[1].annotations.get["readOnlyHint"].getBool()
    check page.nextCursor == some("page-2")

  test "Given a cursor, when the next page is listed, then the cursor is sent and the last page has none":
    let peer = startPeer(pagedTools)
    let client = peer.connectedClient(LegacyDefault)
    let page = waitFor client.listTools(some("page-2"))
    check page.tools.len == 1
    check page.nextCursor.isNone
    check peer.requestsFor("tools/list")[0]["params"]["cursor"].getStr() == "page-2"

  test "Given a paged server, when every tool is listed, then all pages are followed":
    let peer = startPeer(pagedTools)
    let client = peer.connectedClient(LegacyDefault)
    let tools = waitFor client.listAllTools()
    check tools.len == 3
    check tools[2].name == "c"
    check peer.requestsFor("tools/list").len == 2

  test "Given a server that repeats a cursor, when every tool is listed, then McpProtocolError is raised":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        peer.reply(message["id"], %*{"tools": [], "nextCursor": "same"}))
    let client = peer.connectedClient(LegacyDefault)
    expect McpProtocolError:
      discard waitFor client.listAllTools()

  test "Given a nextCursor that is the empty string, when every tool is listed, then the empty cursor is sent and the list does not end there":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        if not message["params"].hasKey("cursor"):
          peer.reply(message["id"], %*{"tools": [
            {"name": "a", "inputSchema": {"type": "object"}}], "nextCursor": ""})
        elif message["params"]["cursor"].getStr() == "":
          peer.reply(message["id"], %*{"tools": [
            {"name": "b", "inputSchema": {"type": "object"}}]})
        else:
          peer.replyError(message["id"], -32602, "bad cursor"))
    let client = peer.connectedClient(LegacyDefault)
    let tools = waitFor client.listAllTools()
    check tools.len == 2
    check tools[1].name == "b"

  test "Given a tool result with several kinds of content, when it is called, then each block is read":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.reply(message["id"], %*{"content": [
          {"type": "text", "text": "hi"},
          {"type": "image", "data": "QQ==", "mimeType": "image/png"},
          {"type": "resource", "resource": {"uri": "file:///a", "text": "body", "mimeType": "text/plain"}},
          {"type": "resource_link", "uri": "file:///b", "name": "b"},
          {"type": "hologram", "x": 1}], "isError": false}))
    let client = peer.connectedClient(LegacyDefault)
    let content = waitFor client.callTool("t", %*{"k": "v"})
    check content.contentItems.len == 5
    check content.contentItems[0].text == "hi"
    check content.contentItems[1].imageMimeType == "image/png"
    check content.contentItems[2].resource.text == some("body")
    check content.contentItems[3].linkUri == "file:///b"
    check content.contentItems[4].kind == mckUnknown
    check content.contentItems[4].raw["x"].getInt() == 1
    check not content.isError
    check peer.requestsFor("tools/call")[0]["params"]["arguments"]["k"].getStr() == "v"

  test "Given a tool that failed, when it is called, then isError is set and nothing is raised":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.reply(message["id"], %*{"content": [{"type": "text", "text": "boom"}], "isError": true}))
    let client = peer.connectedClient(LegacyDefault)
    let content = waitFor client.callTool("t")
    check content.isError
    check content.contentItems[0].text == "boom"

  test "Given an unknown tool, when it is called, then McpRequestError carries the server's code":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.replyError(message["id"], -32602, "Unknown tool: t"))
    let client = peer.connectedClient(LegacyDefault)
    try:
      discard waitFor client.callTool("t")
      fail()
    except McpRequestError as e:
      check e.code == -32602

  test "Given a result without content, when the tool is called, then McpProtocolError is raised":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.reply(message["id"], %*{"isError": false}))
    let client = peer.connectedClient(LegacyDefault)
    expect McpProtocolError:
      discard waitFor client.callTool("t")

  test "Given structured output, when the tool is called, then it is passed through as received":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.reply(message["id"], %*{"content": [], "structuredContent": {"n": 1}}))
    let client = peer.connectedClient(LegacyDefault)
    check (waitFor client.callTool("t")).structuredContent.get["n"].getInt() == 1

  test "Given a server without the tools capability, when tools are listed, then McpUnsupportedError is raised and nothing is sent":
    let peer = startPeer(nil, capabilities = %*{"prompts": {}})
    let client = peer.connectedClient(LegacyDefault)
    expect McpUnsupportedError:
      discard waitFor client.listTools()
    check peer.requestsFor("tools/list").len == 0

  test "Given a client that is not connected, when tools are listed, then McpConnectionClosedError is raised":
    let client = newMcpClient(McpClientInfo(name: "c", version: "0"), LegacyDefault)
    expect McpConnectionClosedError:
      discard waitFor client.listTools()

suite "resources":

  test "Given resources, when listed, then fields are read and pages followed":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "resources/list":
        if message["params"]{"cursor"}.getStr() == "":
          peer.reply(message["id"], %*{"resources": [
            {"uri": "file:///a", "name": "a", "mimeType": "text/plain", "size": 5}],
            "nextCursor": "n"})
        else:
          peer.reply(message["id"], %*{"resources": [{"uri": "file:///b", "name": "b"}]}),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    let all = waitFor client.listAllResources()
    check all.len == 2
    check all[0].mimeType == some("text/plain")
    check all[0].size == some(5)
    check all[1].description.isNone

  test "Given templates, when listed, then the wire key resourceTemplates is read":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "resources/templates/list":
        peer.reply(message["id"], %*{"resourceTemplates": [
          {"uriTemplate": "file:///{path}", "name": "files"}]}),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    let page = waitFor client.listResourceTemplates()
    check page.templates[0].uriTemplate == "file:///{path}"
    check (waitFor client.listAllResourceTemplates()).len == 1

  test "Given a resource, when it is read, then text and blob entries are returned":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "resources/read":
        peer.reply(message["id"], %*{"contents": [
          {"uri": "file:///a", "mimeType": "text/plain", "text": "hello"},
          {"uri": "file:///a", "blob": "QQ=="}]}),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    let contents = waitFor client.readResource("file:///a")
    check contents.len == 2
    check contents[0].text == some("hello")
    check contents[1].blob == some("QQ==")
    check peer.requestsFor("resources/read")[0]["params"]["uri"].getStr() == "file:///a"

  test "Given a server that supports subscriptions, when a resource is subscribed and unsubscribed, then both requests are sent":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() in ["resources/subscribe", "resources/unsubscribe"]:
        peer.reply(message["id"], newJObject()),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    waitFor client.subscribeResource("file:///a")
    waitFor client.unsubscribeResource("file:///a")
    check peer.requestsFor("resources/subscribe")[0]["params"]["uri"].getStr() == "file:///a"
    check peer.requestsFor("resources/unsubscribe").len == 1

  test "Given resources without subscribe, when a resource is subscribed, then McpUnsupportedError is raised":
    let peer = startPeer(nil, capabilities = %*{"resources": {}})
    let client = peer.connectedClient(LegacyDefault)
    expect McpUnsupportedError:
      waitFor client.subscribeResource("file:///a")
    check peer.requestsFor("resources/subscribe").len == 0

  test "Given a resource whose entry has no uri, when it is read, then McpProtocolError is raised":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "resources/read":
        peer.reply(message["id"], %*{"contents": [{"text": "x"}]}),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    expect McpProtocolError:
      discard waitFor client.readResource("file:///a")

suite "prompts":

  test "Given prompts, when listed, then arguments are read":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "prompts/list":
        peer.reply(message["id"], %*{"prompts": [{"name": "review", "description": "d",
          "arguments": [{"name": "code", "required": true}, {"name": "style"}]}]}),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    let all = waitFor client.listAllPrompts()
    check all[0].name == "review"
    check all[0].arguments.len == 2
    check all[0].arguments[0].required
    check not all[0].arguments[1].required

  test "Given a prompt, when it is fetched with arguments, then they are sent as strings and messages are read":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "prompts/get":
        peer.reply(message["id"], %*{"description": "Review", "messages": [
          {"role": "user", "content": {"type": "text", "text": "look at this"}}]}),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    let prompt = waitFor client.getPrompt("review", {"code": "x = 1"})
    check prompt.description == some("Review")
    check prompt.messages[0].role == "user"
    check prompt.messages[0].content.text == "look at this"
    check peer.requestsFor("prompts/get")[0]["params"]["arguments"]["code"].getStr() == "x = 1"

  test "Given no arguments, when a prompt is fetched, then no arguments key is sent":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "prompts/get":
        peer.reply(message["id"], %*{"messages": []}),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    discard waitFor client.getPrompt("p")
    check not peer.requestsFor("prompts/get")[0]["params"].hasKey("arguments")

suite "ping, logging and completion":

  test "Given a legacy server, when pinged, then ping is sent and the empty answer succeeds":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "ping":
        peer.reply(message["id"], newJObject()))
    let client = peer.connectedClient(LegacyDefault)
    waitFor client.ping()
    check peer.requestsFor("ping").len == 1

  test "Given a server that supports logging, when the level is set, then logging/setLevel carries it":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "logging/setLevel":
        peer.reply(message["id"], newJObject()),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    waitFor client.setLoggingLevel(mllWarning)
    check peer.requestsFor("logging/setLevel")[0]["params"]["level"].getStr() == "warning"

  test "Given a server without logging, when the level is set, then McpUnsupportedError is raised":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    expect McpUnsupportedError:
      waitFor client.setLoggingLevel(mllInfo)

  test "Given a prompt reference, when an argument is completed, then ref and argument are sent and values read":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "completion/complete":
        peer.reply(message["id"], %*{"completion": {"values": ["python", "pytorch"],
          "total": 10, "hasMore": true}}),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    let completion = waitFor client.complete(promptRef("code_review"), "language", "py")
    check completion.values == @["python", "pytorch"]
    check completion.total == some(10)
    check completion.hasMore == some(true)
    let sent = peer.requestsFor("completion/complete")[0]["params"]
    check sent["ref"] == %*{"type": "ref/prompt", "name": "code_review"}
    check sent["argument"] == %*{"name": "language", "value": "py"}
    check not sent.hasKey("context")

  test "Given a resource template reference, when completed with context, then ref/resource and context are sent":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "completion/complete":
        peer.reply(message["id"], %*{"completion": {"values": []}}),
      capabilities = AllCapabilities)
    let client = peer.connectedClient(LegacyDefault)
    if LegacyDefault >= mpv20250618:
      discard waitFor client.complete(resourceTemplateRef("file:///{a}/{b}"), "b", "x", {"a": "src"})
      let sent = peer.requestsFor("completion/complete")[0]["params"]
      check sent["ref"] == %*{"type": "ref/resource", "uri": "file:///{a}/{b}"}
      check sent["context"]["arguments"]["a"].getStr() == "src"

  test "Given 2025-03-26 or later without the completions capability, when completing, then McpUnsupportedError is raised":
    if LegacyDefault >= mpv20250326:
      let peer = startPeer(nil, capabilities = %*{"tools": {}})
      let client = peer.connectedClient(LegacyDefault)
      expect McpUnsupportedError:
        discard waitFor client.complete(promptRef("p"), "a", "b")
      check peer.requestsFor("completion/complete").len == 0

  test "Given 2024-11-05, when completing, then the server need not declare completions":
    # The capability appeared in 2025-03-26.
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "completion/complete":
        peer.reply(message["id"], %*{"completion": {"values": ["x"]}}),
      capabilities = %*{"prompts": {}})
    let client = newMcpClient(McpClientInfo(name: "c", version: "0"), mpv20241105)
    waitFor client.connect(peer.pair.client)
    check (waitFor client.complete(promptRef("p"), "a", "b")).values == @["x"]

  test "Given 2024-11-05, when completing with context, then McpUnsupportedError is raised":
    let peer = startPeer(nil, capabilities = %*{"prompts": {}})
    let client = newMcpClient(McpClientInfo(name: "c", version: "0"), mpv20241105)
    waitFor client.connect(peer.pair.client)
    expect McpUnsupportedError:
      discard waitFor client.complete(promptRef("p"), "a", "b", {"c": "d"})
    check peer.requestsFor("completion/complete").len == 0

if SpeaksModern:
  suite "operations in the 2026-07-28 protocol":

    test "Given a 2026-07-28 server, when tools are called, then the request carries the per-request metadata":
      let peer = startPeer(proc(peer: Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/call":
          peer.reply(message["id"], %*{"resultType": "complete",
            "content": [{"type": "text", "text": "ok"}]}),
        modern = true)
      let client = peer.connectedClient()
      check (waitFor client.callTool("t")).contentItems[0].text == "ok"
      check peer.requestsFor("initialize").len == 0
      let meta = peer.requestsFor("tools/call")[0]["params"]["_meta"]
      check meta["io.modelcontextprotocol/protocolVersion"].getStr() == "2026-07-28"

    test "Given a 2026-07-28 connection, when ping, setLevel or subscribe is used, then McpUnsupportedError is raised and nothing is sent":
      let peer = startPeer(nil, modern = true,
        capabilities = %*{"logging": {}, "resources": {"subscribe": true}})
      let client = peer.connectedClient()
      expect McpUnsupportedError:
        waitFor client.ping()
      expect McpUnsupportedError:
        waitFor client.setLoggingLevel(mllInfo)
      expect McpUnsupportedError:
        waitFor client.subscribeResource("file:///a")
      check peer.requestsFor("ping").len == 0
      check peer.requestsFor("logging/setLevel").len == 0
      check peer.requestsFor("resources/subscribe").len == 0
