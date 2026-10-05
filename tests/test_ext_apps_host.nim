## MCP Apps on the client (the host): declaring support, reading the tools'
## UI references, and fetching a UI resource that came from a server the
## host does not trust. Specification:
## ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f,
## specification/2026-01-26/apps.mdx.

import std/[unittest, asyncdispatch, json, options, base64, strutils]
import ./client_peer
import ./server_harness
import ext/apps
import client/client
import protocol/[features, types]

const
  Html = "<!DOCTYPE html><html><body>weather</body></html>"
  Uri = "ui://weather-server/dashboard-template"

proc item(extra: JsonNode = nil): JsonNode =
  result = %*{"uri": Uri, "mimeType": ResourceMimeType, "text": Html}
  if not extra.isNil:
    for key, value in extra:
      result[key] = value

proc readAnswer(items: seq[JsonNode]): JsonNode =
  %*{"resultType": "complete", "contents": items}

proc hostPeer(handler: proc(peer: client_peer.Peer, message: JsonNode)): client_peer.Peer =
  startPeer(handler, modern = true,
            capabilities = %*{"tools": {}, "resources": {}})

proc answering(contents: seq[JsonNode]): client_peer.Peer =
  hostPeer(proc(peer: client_peer.Peer, message: JsonNode) =
    if message{"method"}.getStr() == "resources/read":
      peer.reply(message["id"], readAnswer(contents)))

proc appsClient(peer: client_peer.Peer, version: McpProtocolVersion): McpClient =
  peer.connectedClient(version, proc(c: McpClient) = c.declareApps())

proc fetchFails(contents: seq[JsonNode], limits = defaultLimits()): string =
  for v in versionsWith(ftExtensions):
    let client = appsClient(answering(contents), v)
    try:
      discard waitFor client.fetchUiResource(Uri, limits)
      return "fetched"
    except McpProtocolError as e:
      return e.msg

suite "declaring MCP Apps":

  test "Given declareApps, when a request is sent, then clientCapabilities lists the extension with the HTML mime type":
    for v in versionsWith(ftExtensions):
      let peer = hostPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          peer.reply(message["id"], %*{"resultType": "complete", "tools": []}))
      let client = appsClient(peer, v)
      check client.declaredApps
      discard waitFor client.listAppTools()
      let caps = peer.requestsFor("tools/list")[0]["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]
      check caps["extensions"][ExtensionId] == %*{"mimeTypes": [ResourceMimeType]}

  test "Given a client that never called declareApps, when it sends a request, then no extensions are declared":
    for v in versionsWith(ftExtensions):
      let peer = hostPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          peer.reply(message["id"], %*{"resultType": "complete", "tools": []}))
      let client = peer.connectedClient(v)
      check not client.declaredApps
      discard waitFor client.listAppTools()
      let caps = peer.requestsFor("tools/list")[0]["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]
      check not caps.hasKey("extensions")

  test "Given a build that speaks no version with extensions, when declareApps is called, then ValueError; otherwise it declares":
    let client = newMcpClient(McpClientInfo(name: "h", version: "0"))
    if versionsWith(ftExtensions).len == 0:
      expect ValueError: client.declareApps()
      check not client.declaredApps
    else:
      client.declareApps()
      check client.declaredApps

  test "Given empty or malformed mime types, when declareApps is called, then ValueError and nothing is declared":
    let client = newMcpClient(McpClientInfo(name: "h", version: "0"))
    expect ValueError: client.declareApps(@[])
    expect ValueError: client.declareApps(@[""])
    expect ValueError: client.declareApps(@[" text/html"])
    check not client.declaredApps

  test "Given a connected client, when it declares apps, then it raises because capabilities are fixed at connect":
    let client = startPeer(nil).connectedClient()
    expect McpError:
      client.declareApps()

  test "Given a legacy-version client, when it declares apps and initializes, then the capabilities do not mention extensions":
    for v in versionsWithout(ftExtensions):
      let peer = startPeer(nil)
      discard peer.connectedClient(v, proc(c: McpClient) =
        if versionsWith(ftExtensions).len > 0: c.declareApps())
      check not peer.requestsFor("initialize")[0]["params"]["capabilities"].hasKey("extensions")

suite "tools and their UI references":

  proc toolsPeer(tools: seq[JsonNode], pageSize = 0): client_peer.Peer =
    hostPeer(proc(peer: client_peer.Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/list":
        let cursor = message["params"]{"cursor"}.getStr()
        let start = if cursor.len == 0: 0 else: parseInt(cursor)
        let stop = if pageSize == 0: tools.len else: min(start + pageSize, tools.len)
        var answer = %*{"resultType": "complete", "tools": tools[start ..< stop]}
        if stop < tools.len:
          answer["nextCursor"] = %($stop)
        peer.reply(message["id"], answer))

  let schema = %*{"type": "object"}
  let both = %*{"name": "get_weather", "description": "d", "inputSchema": schema,
                "_meta": {"ui": {"resourceUri": Uri, "visibility": ["model", "app"]}}}
  let appOnly = %*{"name": "refresh", "description": "d", "inputSchema": schema,
                   "_meta": {"ui": {"resourceUri": Uri, "visibility": ["app"]}}}
  let modelOnly = %*{"name": "think", "description": "d", "inputSchema": schema,
                     "_meta": {"ui": {"resourceUri": Uri, "visibility": ["model"]}}}
  let plain = %*{"name": "plain", "description": "d", "inputSchema": schema}
  let legacy = %*{"name": "old", "description": "d", "inputSchema": schema,
                  "_meta": {"ui/resourceUri": Uri}}
  let broken = %*{"name": "broken", "description": "d", "inputSchema": schema,
                  "_meta": {"ui": {"resourceUri": "https://evil.example/x"}}}

  test "Given tools with UI references, when listed, then each keeps its _meta and the parsed reference":
    for v in versionsWith(ftExtensions):
      let client = appsClient(toolsPeer(@[both, appOnly, plain, legacy]), v)
      let tools = waitFor client.listAppTools()
      check tools.len == 4
      check tools[0].ui.get.resourceUri == some(Uri)
      check tools[0].definition == both
      check tools[1].ui.get.visibility == {tvApp}
      check tools[2].ui.isNone
      check tools[3].ui.get.resourceUri == some(Uri)

  test "Given a tool with a malformed UI reference, when listed, then the tool is kept as a plain tool with the reason":
    for v in versionsWith(ftExtensions):
      let tools = waitFor appsClient(toolsPeer(@[broken, both]), v).listAppTools()
      check tools.len == 2
      check tools[0].ui.isNone
      check "ui://" in tools[0].problem.get
      check tools[1].problem.isNone

  test "Given several pages, when listed, then every page is read":
    for v in versionsWith(ftExtensions):
      let tools = waitFor appsClient(toolsPeer(@[both, appOnly, plain], pageSize = 1), v).listAppTools()
      check tools.len == 3

  test "Given tools with visibility, when the agent's list is made, then tools without model are left out":
    for v in versionsWith(ftExtensions):
      let tools = waitFor appsClient(toolsPeer(@[both, appOnly, modelOnly, plain]), v).listAppTools()
      var names: seq[string]
      for tool in tools.modelVisible:
        names.add tool.name
      check names == @["get_weather", "think", "plain"]

  test "Given a View's tools/call, when the tool lacks app visibility or is unknown, then it is refused with a reason":
    for v in versionsWith(ftExtensions):
      let tools = waitFor appsClient(toolsPeer(@[both, appOnly, modelOnly, plain]), v).listAppTools()
      check tools.appCallProblem("get_weather").isNone
      check tools.appCallProblem("refresh").isNone
      check tools.appCallProblem("plain").isNone
      check "app" in tools.appCallProblem("think").get
      check "no tool" in tools.appCallProblem("missing").get

  test "Given a tool with an empty visibility, when asked, then neither the agent nor the app may use it":
    let tool = toAppTool(%*{"name": "x", "_meta": {"ui": {"resourceUri": Uri, "visibility": []}}})
    check not tool.visibleToModel
    check not tool.callableByApp

suite "fetching a UI resource":

  test "Given a server that serves the UI resource, when fetched, then the HTML and the declarations are returned":
    for v in versionsWith(ftExtensions):
      let meta = %*{"ui": {"csp": {"connectDomains": ["https://api.openweathermap.org"]},
                           "prefersBorder": true, "permissions": {"camera": {}}}}
      let client = appsClient(answering(@[item(%*{"_meta": meta})]), v)
      let ui = waitFor client.fetchUiResource(Uri)
      check ui.uri == Uri
      check ui.html == Html
      check ui.meta.csp.get.connectDomains == @["https://api.openweathermap.org"]
      check ui.meta.prefersBorder == some(true)
      check ui.meta.permissions == {upCamera}
      check not ui.metaFromListing

  test "Given a blob, when fetched, then it is decoded":
    for v in versionsWith(ftExtensions):
      let client = appsClient(answering(@[%*{"uri": Uri, "mimeType": ResourceMimeType,
                                             "blob": base64.encode(Html)}]), v)
      check (waitFor client.fetchUiResource(Uri)).html == Html

  test "Given content items for several URIs, when fetched, then the item for the requested URI is used":
    for v in versionsWith(ftExtensions):
      let other = %*{"uri": "ui://other", "mimeType": ResourceMimeType, "text": "<p>x</p>"}
      check (waitFor appsClient(answering(@[other, item()]), v).fetchUiResource(Uri)).html == Html

  test "Given a tool that points at a UI resource, when its UI is fetched, then the resource it names is read":
    for v in versionsWith(ftExtensions):
      let peer = answering(@[item()])
      let client = appsClient(peer, v)
      let tool = toAppTool(%*{"name": "t", "_meta": {"ui": {"resourceUri": Uri}}})
      check (waitFor client.fetchToolUi(tool)).html == Html
      check peer.requestsFor("resources/read")[0]["params"]["uri"].getStr() == Uri
      expect ValueError:
        discard waitFor client.fetchToolUi(toAppTool(%*{"name": "plain"}))

  test "Given a content item with the wrong mime type, when fetched, then McpProtocolError":
    for mimeType in ["text/html", "text/html; profile=mcp-app", "text/plain", ""]:
      check "mimeType" in fetchFails(@[item(%*{"mimeType": mimeType})])

  test "Given an answer with no item for the URI, when fetched, then McpProtocolError":
    check "no content item" in fetchFails(@[%*{"uri": "ui://other", "mimeType": ResourceMimeType, "text": Html}])
    check "no content item" in fetchFails(@[])

  test "Given text and blob together or neither, when fetched, then McpProtocolError":
    check "both" in fetchFails(@[item(%*{"blob": base64.encode(Html)})])
    check "neither" in fetchFails(@[%*{"uri": Uri, "mimeType": ResourceMimeType}])

  test "Given text or blob of the wrong type or invalid base64, when fetched, then McpProtocolError":
    check "not a string" in fetchFails(@[item(%*{"text": 3})])
    check "not a string" in fetchFails(@[%*{"uri": Uri, "mimeType": ResourceMimeType, "blob": 3}])
    check "base64" in fetchFails(@[%*{"uri": Uri, "mimeType": ResourceMimeType, "blob": "!!!not base64!!!"}])

  test "Given empty HTML, when fetched, then McpProtocolError":
    check "empty" in fetchFails(@[item(%*{"text": "  \n"})])

  test "Given HTML over the limit as text or as blob, when fetched, then McpProtocolError; at the limit it passes":
    let limits = UiLimits(maxHtmlBytes: 64)
    let big = "<p>" & repeat('a', 100) & "</p>"
    check "exceed" in fetchFails(@[item(%*{"text": big})], limits)
    check "exceed" in fetchFails(@[%*{"uri": Uri, "mimeType": ResourceMimeType,
                                      "blob": base64.encode(big)}], limits)
    let exact = "<p>" & repeat('a', 57) & "</p>"
    check exact.len == 64
    check fetchFails(@[item(%*{"text": exact})], limits) == "fetched"
    check fetchFails(@[%*{"uri": Uri, "mimeType": ResourceMimeType,
                          "blob": base64.encode(exact)}], limits) == "fetched"

  test "Given a huge blob, when fetched, then it is refused before it is decoded":
    let limits = UiLimits(maxHtmlBytes: 1024)
    check "exceeds" in fetchFails(@[%*{"uri": Uri, "mimeType": ResourceMimeType,
                                       "blob": repeat('A', 4 * 1024 * 1024)}], limits)

  test "Given a non-positive limit, when fetched, then McpProtocolError":
    check "limit" in fetchFails(@[item()], UiLimits(maxHtmlBytes: 0))

  test "Given declarations with a bad origin or wrong types, when fetched, then McpProtocolError":
    for meta in [%*{"ui": {"csp": {"connectDomains": ["https://a.com; script-src *"]}}},
                 %*{"ui": {"csp": {"connectDomains": ["*"]}}},
                 %*{"ui": {"prefersBorder": "yes"}}, %*{"ui": 3}, %*[1]]:
      check "ui" in fetchFails(@[item(%*{"_meta": meta})]) or
            "_meta" in fetchFails(@[item(%*{"_meta": meta})])
      check fetchFails(@[item(%*{"_meta": meta})]) != "fetched"

  test "Given metadata on the listing entry only, when fetched with it, then it is used; the item's own wins":
    let listing = %*{"csp": {"connectDomains": ["https://listed.example.com"]}}
    let fromListing = uiResourceFromContents(Uri, %*[item()], listingMeta = listing)
    check fromListing.meta.csp.get.connectDomains == @["https://listed.example.com"]
    check fromListing.metaFromListing
    let own = %*{"ui": {"csp": {"connectDomains": ["https://own.example.com"]}}}
    let fromItem = uiResourceFromContents(Uri, %*[item(%*{"_meta": own})], listingMeta = listing)
    check fromItem.meta.csp.get.connectDomains == @["https://own.example.com"]
    check not fromItem.metaFromListing

  test "Given a URI that is not ui://, when fetched, then ValueError and nothing is sent":
    for v in versionsWith(ftExtensions):
      let peer = answering(@[item()])
      let client = appsClient(peer, v)
      for bad in ["https://evil.example/x", "ui://", "file:///etc/passwd", "ui://a b"]:
        expect ValueError:
          discard waitFor client.fetchUiResource(bad)
      check peer.requestsFor("resources/read").len == 0

  test "Given a client that did not declare MCP Apps, when it fetches, then McpUnsupportedError and nothing is sent":
    for v in versionsWith(ftExtensions):
      let peer = answering(@[item()])
      let client = peer.connectedClient(v)
      expect McpUnsupportedError:
        discard waitFor client.fetchUiResource(Uri)
      check peer.requestsFor("resources/read").len == 0

  test "Given a server without the resources capability, when fetched, then McpUnsupportedError and nothing is sent":
    for v in versionsWith(ftExtensions):
      let peer = startPeer(nil, modern = true, capabilities = %*{"tools": {}})
      let client = appsClient(peer, v)
      expect McpUnsupportedError:
        discard waitFor client.fetchUiResource(Uri)
      check peer.requestsFor("resources/read").len == 0

  test "Given a server that answers with an error, when fetched, then McpRequestError":
    for v in versionsWith(ftExtensions):
      let peer = hostPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "resources/read":
          peer.replyError(message["id"], -32002, "Resource not found"))
      expect client.McpRequestError:
        discard waitFor appsClient(peer, v).fetchUiResource(Uri)

  test "Given a fetched UI, when the host builds its CSP, then it is the one of the declared origins":
    for v in versionsWith(ftExtensions):
      let meta = %*{"ui": {"csp": {"resourceDomains": ["https://cdn.jsdelivr.net"]}}}
      let ui = waitFor appsClient(answering(@[item(%*{"_meta": meta})]), v).fetchUiResource(Uri)
      check "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net" in
        contentSecurityPolicy(ui.meta.csp)
