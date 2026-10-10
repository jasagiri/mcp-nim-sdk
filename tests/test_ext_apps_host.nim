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
import client/extensions
import protocol/types

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

var peerVersion = DefaultProtocolVersion

iterator eachVersion(): McpProtocolVersion =
  ## Every version the build speaks; `hostPeer` answers in the era of the
  ## version being tried.
  for v in SupportedProtocolVersions:
    peerVersion = v
    yield v

proc hostPeer(handler: proc(peer: client_peer.Peer, message: JsonNode)): client_peer.Peer =
  startPeer(handler, modern = isModern(peerVersion),
            capabilities = %*{"tools": {}, "resources": {}})

proc answering(contents: seq[JsonNode]): client_peer.Peer =
  hostPeer(proc(peer: client_peer.Peer, message: JsonNode) =
    if message{"method"}.getStr() == "resources/read":
      peer.reply(message["id"], readAnswer(contents)))

proc appsClient(peer: client_peer.Peer, version: McpProtocolVersion): McpClient =
  peer.connectedClient(version, proc(c: McpClient) = c.declareApps())

proc fetchOutcome(version: McpProtocolVersion, contents: seq[JsonNode],
                  limits: UiLimits): string =
  ## "fetched", or the message of the McpProtocolError.
  let client = appsClient(answering(contents), version)
  try:
    discard waitFor client.fetchUiResource(Uri, limits)
    return "fetched"
  except McpProtocolError as e:
    return e.msg

template expectRefused(contents: seq[JsonNode], fragment: string,
                       limits: UiLimits = defaultLimits()) =
  ## In every version with extensions the fetch is refused, naming `fragment`.
  for v in eachVersion():
    let outcome = fetchOutcome(v, contents, limits)
    check outcome != "fetched"
    check fragment in outcome

template expectFetched(contents: seq[JsonNode], limits: UiLimits = defaultLimits()) =
  for v in eachVersion():
    check fetchOutcome(v, contents, limits) == "fetched"

suite "declaring MCP Apps":

  proc declaredIn(peer: client_peer.Peer, version: McpProtocolVersion): JsonNode =
    ## The capabilities the host declared: in `_meta` of a request in
    ## 2026-07-28, in the `initialize` request before it.
    if isModern(version):
      peer.requestsFor("tools/list")[0]["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]
    else:
      peer.requestsFor("initialize")[0]["params"]["capabilities"]

  test "Given declareApps, when the host connects in any version, then its capabilities list the extension with the HTML mime type":
    for v in eachVersion():
      let peer = hostPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          peer.reply(message["id"], %*{"resultType": "complete", "tools": []}))
      let client = appsClient(peer, v)
      check client.declaredApps
      discard waitFor client.listAppTools()
      check peer.declaredIn(v)["extensions"][ExtensionId] == %*{"mimeTypes": [ResourceMimeType]}

  test "Given a client that never called declareApps, when it connects in any version, then no extensions are declared":
    for v in eachVersion():
      let peer = hostPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          peer.reply(message["id"], %*{"resultType": "complete", "tools": []}))
      let client = peer.connectedClient(v)
      check not client.declaredApps
      discard waitFor client.listAppTools()
      check not peer.declaredIn(v).hasKey("extensions")

  test "Given a client that declared another extension besides apps, when it initializes in a legacy version, then only apps is sent":
    for v in SupportedProtocolVersions:
      if not isModern(v):
        let peer = startPeer(nil)
        discard peer.connectedClient(v, proc(c: McpClient) =
          c.declareExtension("com.example/other")
          c.declareApps())
        check peer.requestsFor("initialize")[0]["params"]["capabilities"]["extensions"] ==
              %*{ExtensionId: {"mimeTypes": [ResourceMimeType]}}

  test "Given empty or malformed mime types, when declareApps is called, then ValueError and nothing is declared":
    let client = newMcpClient(McpClientInfo(name: "h", version: "0"))
    expect ValueError: client.declareApps(@[])
    expect ValueError: client.declareApps(@[""])
    expect ValueError: client.declareApps(@[" text/html"])
    check not client.declaredApps

  test "Given a connected client, when it declares apps, then it raises because capabilities are fixed at connect":
    let client = startPeer(nil, modern = isModern(DefaultProtocolVersion)).connectedClient()
    expect McpError:
      client.declareApps()

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
    for v in eachVersion():
      let client = appsClient(toolsPeer(@[both, appOnly, plain, legacy]), v)
      let tools = waitFor client.listAppTools()
      check tools.len == 4
      check tools[0].ui.get.resourceUri == some(Uri)
      check tools[0].definition == both
      check tools[1].ui.get.visibility == {tvApp}
      check tools[2].ui.isNone
      check tools[3].ui.get.resourceUri == some(Uri)

  test "Given a tool with a malformed UI reference, when listed, then the tool is kept as a plain tool with the reason":
    for v in eachVersion():
      let tools = waitFor appsClient(toolsPeer(@[broken, both]), v).listAppTools()
      check tools.len == 2
      check tools[0].ui.isNone
      check "ui://" in tools[0].problem.get
      check tools[1].problem.isNone

  test "Given a server without the tools capability, when tools are listed, then McpUnsupportedError and nothing is sent":
    for v in eachVersion():
      let peer = startPeer(nil, modern = isModern(peerVersion), capabilities = %*{"resources": {}})
      let client = appsClient(peer, v)
      expect McpUnsupportedError:
        discard waitFor client.listAppTools()
      check peer.requestsFor("tools/list").len == 0

  test "Given several pages, when listed, then every page is read":
    for v in eachVersion():
      let tools = waitFor appsClient(toolsPeer(@[both, appOnly, plain], pageSize = 1), v).listAppTools()
      check tools.len == 3

  test "Given tools with visibility, when the agent's list is made, then tools without model are left out":
    for v in eachVersion():
      let tools = waitFor appsClient(toolsPeer(@[both, appOnly, modelOnly, plain]), v).listAppTools()
      var names: seq[string]
      for tool in tools.modelVisible:
        names.add tool.name
      check names == @["get_weather", "think", "plain"]

  test "Given a View's tools/call, when the tool lacks app visibility or is unknown, then it is refused with a reason":
    for v in eachVersion():
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
    for v in eachVersion():
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
    for v in eachVersion():
      let client = appsClient(answering(@[%*{"uri": Uri, "mimeType": ResourceMimeType,
                                             "blob": base64.encode(Html)}]), v)
      check (waitFor client.fetchUiResource(Uri)).html == Html

  test "Given content items for several URIs, when fetched, then the item for the requested URI is used":
    for v in eachVersion():
      let other = %*{"uri": "ui://other", "mimeType": ResourceMimeType, "text": "<p>x</p>"}
      check (waitFor appsClient(answering(@[other, item()]), v).fetchUiResource(Uri)).html == Html

  test "Given a tool that points at a UI resource, when its UI is fetched, then the resource it names is read":
    for v in eachVersion():
      let peer = answering(@[item()])
      let client = appsClient(peer, v)
      let tool = toAppTool(%*{"name": "t", "_meta": {"ui": {"resourceUri": Uri}}})
      check (waitFor client.fetchToolUi(tool)).html == Html
      check peer.requestsFor("resources/read")[0]["params"]["uri"].getStr() == Uri
      expect ValueError:
        discard waitFor client.fetchToolUi(toAppTool(%*{"name": "plain"}))

  test "Given a content item with the wrong mime type, when fetched, then McpProtocolError":
    for mimeType in ["text/html", "text/html; profile=mcp-app", "text/plain", ""]:
      expectRefused(@[item(%*{"mimeType": mimeType})], "mimeType")

  test "Given an answer with no item for the URI, when fetched, then McpProtocolError":
    expectRefused(@[%*{"uri": "ui://other", "mimeType": ResourceMimeType, "text": Html}], "no content item")
    expectRefused(@[], "no content item")

  test "Given text and blob together or neither, when fetched, then McpProtocolError":
    expectRefused(@[item(%*{"blob": base64.encode(Html)})], "both")
    expectRefused(@[%*{"uri": Uri, "mimeType": ResourceMimeType}], "neither")

  test "Given text or blob of the wrong type or invalid base64, when fetched, then McpProtocolError":
    expectRefused(@[item(%*{"text": 3})], "not a string")
    expectRefused(@[%*{"uri": Uri, "mimeType": ResourceMimeType, "blob": 3}], "not a string")
    expectRefused(@[%*{"uri": Uri, "mimeType": ResourceMimeType, "blob": "!!!not base64!!!"}], "base64")

  test "Given empty HTML, when fetched, then McpProtocolError":
    expectRefused(@[item(%*{"text": "  \n"})], "empty")

  test "Given HTML over the limit as text or as blob, when fetched, then McpProtocolError; at the limit it passes":
    let limits = UiLimits(maxHtmlBytes: 64)
    let big = "<p>" & repeat('a', 100) & "</p>"
    expectRefused(@[item(%*{"text": big})], "exceed", limits)
    expectRefused(@[%*{"uri": Uri, "mimeType": ResourceMimeType,
                       "blob": base64.encode(big)}], "exceed", limits)
    let exact = "<p>" & repeat('a', 57) & "</p>"
    check exact.len == 64
    expectFetched(@[item(%*{"text": exact})], limits)
    expectFetched(@[%*{"uri": Uri, "mimeType": ResourceMimeType,
                       "blob": base64.encode(exact)}], limits)

  test "Given a huge blob, when fetched, then it is refused before it is decoded":
    let limits = UiLimits(maxHtmlBytes: 1024)
    expectRefused(@[%*{"uri": Uri, "mimeType": ResourceMimeType,
                       "blob": repeat('A', 4 * 1024 * 1024)}], "the blob exceeds", limits)

  test "Given a blob just over the limit once decoded, when fetched, then it is refused before it is decoded":
    let limits = UiLimits(maxHtmlBytes: 1024)
    # 1372 characters decode to 1029 bytes: the size estimate alone refuses it.
    expectRefused(@[%*{"uri": Uri, "mimeType": ResourceMimeType,
                       "blob": repeat('A', 1372)}], "the blob exceeds", limits)

  test "Given a non-positive limit, when fetched, then McpProtocolError":
    expectRefused(@[item()], "limit", UiLimits(maxHtmlBytes: 0))
    expectRefused(@[item()], "must be positive", UiLimits(maxHtmlBytes: 0))
    expectRefused(@[item()], "must be positive", UiLimits(maxHtmlBytes: -1))

  test "Given an answer whose contents is missing or not an array, when checked, then McpAppsError":
    expect McpAppsError:
      discard uiResourceFromContents(Uri, nil)
    expect McpAppsError:
      discard uiResourceFromContents(Uri, %*{"uri": Uri})

  test "Given declarations with a bad origin or wrong types, when fetched, then McpProtocolError":
    for (meta, fragment) in [
        (%*{"ui": {"csp": {"connectDomains": ["https://a.com; script-src *"]}}}, "csp.connectDomains"),
        (%*{"ui": {"csp": {"connectDomains": ["*"]}}}, "csp.connectDomains"),
        (%*{"ui": {"prefersBorder": "yes"}}, "prefersBorder"),
        (%*{"ui": 3}, "_meta.ui must be an object"), (%*[1], "_meta is not an object")]:
      expectRefused(@[item(%*{"_meta": meta})], fragment)

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
    for v in eachVersion():
      let peer = answering(@[item()])
      let client = appsClient(peer, v)
      for bad in ["https://evil.example/x", "ui://", "file:///etc/passwd", "ui://a b"]:
        expect ValueError:
          discard waitFor client.fetchUiResource(bad)
      check peer.requestsFor("resources/read").len == 0

  test "Given a client that did not declare MCP Apps, when it fetches, then McpUnsupportedError and nothing is sent":
    for v in eachVersion():
      let peer = answering(@[item()])
      let client = peer.connectedClient(v)
      expect McpUnsupportedError:
        discard waitFor client.fetchUiResource(Uri)
      check peer.requestsFor("resources/read").len == 0

  test "Given a server without the resources capability, when fetched, then McpUnsupportedError and nothing is sent":
    for v in eachVersion():
      let peer = startPeer(nil, modern = isModern(peerVersion), capabilities = %*{"tools": {}})
      let client = appsClient(peer, v)
      expect McpUnsupportedError:
        discard waitFor client.fetchUiResource(Uri)
      check peer.requestsFor("resources/read").len == 0

  test "Given a server that answers with an error, when fetched, then McpRequestError":
    for v in eachVersion():
      let peer = hostPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "resources/read":
          peer.replyError(message["id"], -32002, "Resource not found"))
      expect client.McpRequestError:
        discard waitFor appsClient(peer, v).fetchUiResource(Uri)

  test "Given a fetched UI, when the host builds its CSP, then it is the one of the declared origins":
    for v in eachVersion():
      let meta = %*{"ui": {"csp": {"resourceDomains": ["https://cdn.jsdelivr.net"]}}}
      let ui = waitFor appsClient(answering(@[item(%*{"_meta": meta})]), v).fetchUiResource(Uri)
      check "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net" in
        contentSecurityPolicy(ui.meta.csp)
