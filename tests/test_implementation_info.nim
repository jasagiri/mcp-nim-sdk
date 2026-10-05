## What a server and a client say about themselves (`Implementation`):
## name and version always; title (2025-06-18), icons (2025-11-25),
## description and websiteUrl (2025-11-25) only where the version has them.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness
import ./loopback_transport
import client/client
import transport/transport

let DefaultLegacy = legacyVersions()[^1]
const SpeaksModern = isModern(DefaultProtocolVersion)

let FullIcon = McpIcon(src: "https://example.com/i.png", sizes: @["48x48"])

proc fullServerInfo(): McpServerInfo =
  McpServerInfo(name: "srv", version: "1.2", title: some("Server Title"),
                description: some("What the server is for"),
                websiteUrl: some("https://example.com"), icons: @[FullIcon])

proc fullClientInfo(): McpClientInfo =
  McpClientInfo(name: "cli", version: "3.4", title: some("Client Title"),
                description: some("What the client is for"),
                websiteUrl: some("https://client.example.com"), icons: @[FullIcon])

proc expectedKeys(version: McpProtocolVersion): seq[string] =
  ## The fields an Implementation has in `version`, besides name and version.
  if version.has(ftTitleFields): result.add "title"
  if version.has(ftImplementationDescription): result.add "description"
  if version.has(ftImplementationDescription): result.add "websiteUrl"
  if version.has(ftIcons): result.add "icons"

proc extraKeys(info: JsonNode): seq[string] =
  for key in ["title", "description", "websiteUrl", "icons"]:
    if info.hasKey(key): result.add key

proc initialize(server: McpServer, version: McpProtocolVersion,
                clientInfo: JsonNode): JsonNode =
  let t = server.attach()
  let id = freshId()
  t.inject("", rpcRequest(id, "initialize", %*{
    "protocolVersion": $version, "capabilities": {}, "clientInfo": clientInfo}))
  t.responseTo(id)

suite "implementation info on the server":

  test "Given a server with a full identity, when each legacy version initializes, then serverInfo has the fields of that version":
    for version in legacyVersions():
      let server = newMcpServer(fullServerInfo())
      let info = server.initialize(version, %*{"name": "c", "version": "1"})["result"]["serverInfo"]
      check info["name"].getStr() == "srv"
      check info["version"].getStr() == "1.2"
      check extraKeys(info) == expectedKeys(version)
      if version.has(ftImplementationDescription):
        check info["description"].getStr() == "What the server is for"
        check info["websiteUrl"].getStr() == "https://example.com"
      if version.has(ftTitleFields):
        check info["title"].getStr() == "Server Title"
      if version.has(ftIcons):
        check info["icons"] == %*[{"src": "https://example.com/i.png", "sizes": ["48x48"]}]

  test "Given a server with only a name and version, when it initializes, then serverInfo has only those":
    for version in legacyVersions():
      let server = newMcpServer(McpServerInfo(name: "srv", version: "1"))
      let info = server.initialize(version, %*{"name": "c", "version": "1"})["result"]["serverInfo"]
      check extraKeys(info).len == 0

  test "Given a client that describes itself, when it initializes, then the server keeps what it said":
    let server = newMcpServer(fullServerInfo())
    let wire = fullClientInfo()
    discard server.initialize(DefaultLegacy, %*{
      "name": wire.name, "version": wire.version, "title": "Client Title",
      "description": "What the client is for", "websiteUrl": "https://client.example.com",
      "icons": [{"src": "https://example.com/i.png", "sizes": ["48x48"]}]})
    check server.session().clientInfo == some(wire)

  test "Given a clientInfo field of the wrong type, when the client initializes, then the server answers invalid params":
    let server = newMcpServer(fullServerInfo())
    let reply = server.initialize(DefaultLegacy, %*{"name": "c", "version": "1", "title": 5})
    check reply.errorCode == -32602
    check server.session().state == mlsUninitialized

  test "Given a server with a full identity, when a 2026-07-28 client asks to discover, then serverInfo in _meta has every field":
    if SpeaksModern:
      let server = newMcpServer(fullServerInfo())
      let peer = server.connect(server.attach(), mpv20260728)
      let info = peer.ask("server/discover")["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]
      check info["description"].getStr() == "What the server is for"
      check info["websiteUrl"].getStr() == "https://example.com"
      check info["title"].getStr() == "Server Title"
      check info["icons"].len == 1


type Spy = ref object
  received: seq[JsonNode]

proc runPeer(pair: tuple[client, server: LoopbackTransport], spy: Spy,
             serverInfo: JsonNode) {.async.} =
  ## A server that answers the handshake with `serverInfo` and remembers what
  ## the client sent.
  try:
    while true:
      let message = await pair.server.receiveMessage()
      spy.received.add message
      let id = message{"id"}
      case message{"method"}.getStr()
      of "server/discover":
        pair.client.inject(%*{"jsonrpc": "2.0", "id": id, "result": {
          "resultType": "complete", "supportedVersions": [$DefaultProtocolVersion],
          "capabilities": {}, "_meta": {"io.modelcontextprotocol/serverInfo": serverInfo}}})
      of "initialize":
        pair.client.inject(%*{"jsonrpc": "2.0", "id": id, "result": {
          "protocolVersion": message["params"]["protocolVersion"], "capabilities": {},
          "serverInfo": serverInfo}})
      else: discard
  except McpTransportError:
    discard

proc connectTo(serverInfo: JsonNode, version: McpProtocolVersion): tuple[client: McpClient, spy: Spy] =
  let pair = newLoopbackPair()
  let spy = Spy()
  asyncCheck runPeer(pair, spy, serverInfo)
  let client = newMcpClient(fullClientInfo(), version)
  waitFor client.connect(pair.client)
  (client: client, spy: spy)

suite "implementation info in the client":

  test "Given a client with a full identity, when it initializes in each legacy version, then clientInfo has the fields of that version":
    for version in legacyVersions():
      let connected = connectTo(%*{"name": "p", "version": "0"}, version)
      let info = connected.spy.received[0]["params"]["clientInfo"]
      check connected.spy.received[0]["params"]["protocolVersion"].getStr() == $version
      check info["name"].getStr() == "cli"
      check extraKeys(info) == expectedKeys(version)

  test "Given a server that describes itself in the handshake, when the client connects, then serverInfo holds what the server said":
    let connected = connectTo(%*{"name": "p", "version": "0", "title": "P", "description": "D",
      "websiteUrl": "https://p.example.com", "icons": [{"src": "https://p.example.com/i.png"}]},
      DefaultLegacy)
    let info = connected.client.serverInfo.get
    check info.name == "p"
    check info.version == "0"
    check info.title == some("P")
    check info.description == some("D")
    check info.websiteUrl == some("https://p.example.com")
    check info.icons == @[McpIcon(src: "https://p.example.com/i.png")]

  test "Given a server whose serverInfo has a field of the wrong type, when the client connects, then the connection fails with a protocol error":
    expect McpProtocolError:
      discard connectTo(%*{"name": "p", "version": "0", "icons": "none"}, DefaultLegacy)

  test "Given a 2026-07-28 server that describes itself, when the client discovers it, then serverInfo holds what it said":
    if SpeaksModern:
      let connected = connectTo(%*{"name": "p", "version": "0", "description": "D",
        "websiteUrl": "https://p.example.com"}, DefaultProtocolVersion)
      check connected.client.serverInfo.get.description == some("D")
      check connected.client.serverInfo.get.websiteUrl == some("https://p.example.com")

  test "Given a client with a full identity, when it sends a 2026-07-28 request, then _meta carries every field":
    if SpeaksModern:
      let connected = connectTo(%*{"name": "p", "version": "0"}, DefaultProtocolVersion)
      let probe = connected.spy.received[0]
      let info = probe["params"]["_meta"]["io.modelcontextprotocol/clientInfo"]
      check info["description"].getStr() == "What the client is for"
      check info["title"].getStr() == "Client Title"
      check info["icons"].len == 1
