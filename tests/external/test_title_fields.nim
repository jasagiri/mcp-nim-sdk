## Title fields (2025-06-18 and later): a human-readable name next to the
## programmatic `name` of tools, resources, resource templates, prompts,
## prompt arguments and resource links.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness
import ./client_peer
import client/tools
import client/resources
import client/prompts

proc titledServer(): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()), resources: some(McpResourcesCapability()),
    prompts: some(McpPromptsCapability())))
  proc one(item: JsonNode): ListHandler =
    result = proc(cursor: Option[string]): Future[McpPage] {.async.} =
      return McpPage(items: @[item])
  result.onToolsList(one(%*{"name": "t", "title": "Tool", "inputSchema": {"type": "object"},
                            "annotations": {"title": "From annotations"}}))
  result.onResourcesList(one(%*{"name": "r", "title": "Resource", "uri": "file:///r"}))
  result.onResourceTemplatesList(one(%*{"name": "tpl", "title": "Template", "uriTemplate": "file:///{x}"}))
  result.onPromptsList(one(%*{"name": "p", "title": "Prompt",
    "arguments": [{"name": "a", "title": "Argument", "required": true}]}))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    return %*{"content": [{"type": "resource_link", "uri": "file:///r", "name": "r", "title": "Link"}]})

const Lists = [("tools/list", "tools"), ("resources/list", "resources"),
               ("resources/templates/list", "resourceTemplates"), ("prompts/list", "prompts")]

suite "title fields on the server":

  test "Given a version that has titles, when each list is requested, then every title is sent":
    for version in versionsWith(ftTitleFields):
      let server = titledServer()
      let peer = server.connect(server.attach(), version)
      for (methodName, key) in Lists:
        let item = peer.ask(methodName)["result"][key][0]
        check item.hasKey("title")
      let argument = peer.ask("prompts/list")["result"]["prompts"][0]["arguments"][0]
      check argument["title"].getStr() == "Argument"

  test "Given a version without titles, when each list is requested, then no title is sent and the names stay":
    for version in versionsWithout(ftTitleFields):
      let server = titledServer()
      let peer = server.connect(server.attach(), version)
      for (methodName, key) in Lists:
        let item = peer.ask(methodName)["result"][key][0]
        check not item.hasKey("title")
        check item["name"].getStr().len > 0
      let argument = peer.ask("prompts/list")["result"]["prompts"][0]["arguments"][0]
      check not argument.hasKey("title")
      check argument["name"].getStr() == "a"

  test "Given a version without titles but with tool annotations, when tools are listed, then annotations.title is kept":
    for version in versionsWithout(ftTitleFields):
      if version.has(ftToolAnnotations):
        let server = titledServer()
        let peer = server.connect(server.attach(), version)
        let tool = peer.ask("tools/list")["result"]["tools"][0]
        check not tool.hasKey("title")
        check tool["annotations"]["title"].getStr() == "From annotations"

  test "Given a resource link with a title, when a version decides, then the title goes where titles do":
    for version in versionsWith(ftResourceLinks):
      let server = titledServer()
      let peer = server.connect(server.attach(), version)
      let link = peer.ask("tools/call", %*{"name": "t"})["result"]["content"][0]
      check link.hasKey("title") == version.has(ftTitleFields)

suite "title fields in the client":

  test "Given titled lists, when the client lists them, then every title is read":
    let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      case message{"method"}.getStr()
      of "tools/list":
        peer.reply(message["id"], %*{"tools": [{"name": "t", "title": "Tool", "inputSchema": {"type": "object"}}]})
      of "resources/list":
        peer.reply(message["id"], %*{"resources": [{"name": "r", "title": "Resource", "uri": "file:///r"}]})
      of "resources/templates/list":
        peer.reply(message["id"], %*{"resourceTemplates": [{"name": "tpl", "title": "Template", "uriTemplate": "file:///{x}"}]})
      of "prompts/list":
        peer.reply(message["id"], %*{"prompts": [{"name": "p", "title": "Prompt",
          "arguments": [{"name": "a", "title": "Argument"}]}]})
      else: discard,
      capabilities = %*{"tools": {}, "resources": {}, "prompts": {}})
    let client = peer.connectedClient(LegacyDefault)
    check waitFor(client.listAllTools())[0].displayName == "Tool"
    check waitFor(client.listAllResources())[0].displayName == "Resource"
    check waitFor(client.listAllResourceTemplates())[0].displayName == "Template"
    let prompt = waitFor(client.listAllPrompts())[0]
    check prompt.displayName == "Prompt"
    check prompt.arguments[0].title == some("Argument")
    check prompt.arguments[0].displayName == "Argument"

  test "Given items without a title, when their display names are read, then it is the name":
    check McpResource(name: "r", uri: "file:///r").displayName == "r"
    check McpResourceTemplate(name: "tpl", uriTemplate: "file:///{x}").displayName == "tpl"
    check McpPrompt(name: "p").displayName == "p"
    check McpPromptArgument(name: "a").displayName == "a"
