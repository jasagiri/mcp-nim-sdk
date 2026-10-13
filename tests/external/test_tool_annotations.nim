## Tool annotations (2025-03-26 and later): what a server sends in which
## version, and what a client makes of them.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness
import ./client_peer
import client/tools
import protocol/content
import server/tools as serverTools

proc annotatedServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{
      "name": "delete_file", "inputSchema": {"type": "object"},
      "annotations": {"title": "Delete a file", "readOnlyHint": false,
                      "destructiveHint": true, "idempotentHint": true,
                      "openWorldHint": false}}]))

suite "tool annotations on the server":

  test "Given a version that has tool annotations, when tools are listed, then every hint is sent":
    for version in versionsWith(ftToolAnnotations):
      let server = annotatedServer()
      let peer = server.connect(server.attach(), version)
      let tool = peer.ask("tools/list")["result"]["tools"][0]
      check tool["annotations"]["title"].getStr() == "Delete a file"
      check tool["annotations"]["readOnlyHint"].getBool() == false
      check tool["annotations"]["destructiveHint"].getBool() == true
      check tool["annotations"]["idempotentHint"].getBool() == true
      check tool["annotations"]["openWorldHint"].getBool() == false

  test "Given a version without tool annotations, when tools are listed, then the tool has no annotations":
    for version in versionsWithout(ftToolAnnotations):
      let server = annotatedServer()
      let peer = server.connect(server.attach(), version)
      let tool = peer.ask("tools/list")["result"]["tools"][0]
      check tool["name"].getStr() == "delete_file"
      check not tool.hasKey("annotations")

  test "Given only some hints, when annotations are built, then the hints left out are not sent":
    let built = McpToolAnnotations(readOnlyHint: some(true)).toJson
    check built == %*{"readOnlyHint": true}
    check McpToolAnnotations().toJson == newJObject()

  test "Given every hint, when annotations are built, then they round-trip through the parser":
    let built = McpToolAnnotations(title: some("T"), readOnlyHint: some(false),
      destructiveHint: some(false), idempotentHint: some(true), openWorldHint: some(false))
    let parsed = parseToolAnnotations(built.toJson)
    check parsed.title == some("T")
    check parsed.readOnlyHint == some(false)
    check parsed.destructiveHint == some(false)
    check parsed.idempotentHint == some(true)
    check parsed.openWorldHint == some(false)

suite "tool annotations in the client":

  test "Given no hints, when the effective values are read, then they are the specification's defaults":
    let none = parseToolAnnotations(newJObject())
    check not none.isReadOnly
    check none.isDestructive
    check not none.isIdempotent
    check none.isOpenWorld

  test "Given a read-only tool, when asked if it is destructive, then it is not, whatever destructiveHint says":
    let readOnly = parseToolAnnotations(%*{"readOnlyHint": true, "destructiveHint": true})
    check readOnly.isReadOnly
    check not readOnly.isDestructive
    check not readOnly.isIdempotent  # meaningful only when readOnlyHint is false, default false

  test "Given an additive tool, when asked if it is destructive, then it is not":
    check not parseToolAnnotations(%*{"destructiveHint": false}).isDestructive

  test "Given a hint of the wrong type, when annotations are parsed, then the protocol violation is raised":
    expect ValueError:
      discard parseToolAnnotations(%*{"readOnlyHint": "yes"})

  test "Given a tool with a title and annotations.title, when its display name is read, then the order is title, annotations.title, name":
    let both = McpTool(name: "n", title: some("T"),
      annotations: some(%*{"title": "A"}))
    check both.displayName == "T"
    let onlyAnnotation = McpTool(name: "n", annotations: some(%*{"title": "A"}))
    check onlyAnnotation.displayName == "A"
    check McpTool(name: "n").displayName == "n"

  test "Given a server that lists annotated tools, when the client lists them, then the annotations are typed":
    let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        peer.reply(message["id"], %*{"tools": [{"name": "t", "inputSchema": {"type": "object"},
          "annotations": {"readOnlyHint": true, "openWorldHint": false}}]}))
    let client = peer.connectedClient(LegacyDefault)
    let tools = waitFor client.listAllTools()
    let annotations = tools[0].annotationsOf
    check annotations.isReadOnly
    check not annotations.isOpenWorld

suite "tool definitions as a server builds them":

  test "Given annotations that are not a JSON object, when they are parsed, then the protocol violation is raised":
    for value in [newJNull(), %"x", %*[1]]:
      expect McpShapeError:
        discard parseToolAnnotations(value)
    expect McpShapeError:
      discard parseToolAnnotations(nil)

  test "Given only a name, a description and a schema, when a tool is defined, then no optional field is sent":
    check createToolInfo("t", "d", %*{"type": "object"}) ==
      %*{"name": "t", "description": "d", "inputSchema": {"type": "object"}}

  test "Given a title and an icon, when a tool is defined, then both are sent":
    let tool = createToolInfo("t", "d", %*{"type": "object"}, title = "T",
      icons = @[McpIcon(src: "https://example.com/i.png")])
    check tool["title"].getStr() == "T"
    check tool["icons"] == %*[{"src": "https://example.com/i.png"}]

  test "Given a result built without isError, when it is read, then it is not an error":
    check createToolResult(@[createTextToolContent("x")]) ==
      %*{"content": [{"type": "text", "text": "x"}], "isError": false}

  test "Given no description and no required list, when schemas are built, then only type and shape are sent":
    check createInputSchema(%*{}) == %*{"type": "object", "properties": {}}
    check createObjectProperty(%*{}) == %*{"type": "object", "properties": {}}
    check createStringProperty() == %*{"type": "string"}
    check createNumberProperty() == %*{"type": "number"}
    check createBooleanProperty() == %*{"type": "boolean"}
    check createArrayProperty(createStringProperty()) ==
      %*{"type": "array", "items": {"type": "string"}}
    check createEnumProperty(@["a"]) == %*{"type": "string", "enum": ["a"]}

  test "Given a description and required names, when schemas are built, then they are sent":
    check createInputSchema(%*{}, @["a"])["required"] == %*["a"]
    check createObjectProperty(%*{}, @["a"], "o") ==
      %*{"type": "object", "properties": {}, "required": ["a"], "description": "o"}
    check createStringProperty("s")["description"].getStr() == "s"
    check createNumberProperty("n")["description"].getStr() == "n"
    check createBooleanProperty("b")["description"].getStr() == "b"
    check createArrayProperty(createStringProperty(), "a")["description"].getStr() == "a"
    check createEnumProperty(@["a"], "e")["description"].getStr() == "e"
