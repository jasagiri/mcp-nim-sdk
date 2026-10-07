## The `extensions` capability of 2026-07-28 (basic/versioning#extension-negotiation):
## declaring extensions, negotiating them, registering the methods and result
## types an extension defines, and the errors when the peer lacks one. No
## official extension is implemented here; these tests use a made-up one.

import std/[unittest, asyncdispatch, json, options, os]
import ./server_harness
import ./client_peer
import client/client
import client/extensions
import server/extensions
import protocol/extensions as ext
import protocol/lifecycle
import protocol/types

const
  Ext = "com.example/widgets"
  Fixtures = currentSourcePath().parentDir / "fixtures" / "2026-07-28"

proc fixture(name: string): JsonNode =
  parseJson(readFile(Fixtures / name))

proc clientCaps(extensions: JsonNode): JsonNode =
  %*{"io.modelcontextprotocol/clientCapabilities": {"extensions": extensions}}

proc widgetServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.registerExtension(Ext, %*{"flavours": ["a", "b"]}, resultTypes = ["widget_job"])
  result.registerExtensionMethod(Ext, "widgets/make",
    proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} =
      let settings = ctx.clientExtension(Ext)
      let kind = params{"kind"}.getStr()
      if kind == "job":
        return %*{"resultType": "widget_job", "jobId": "j1"}
      if kind == "rogue":
        return %*{"resultType": "undeclared_type"}
      return %*{"made": params{"kind"}, "flavour": settings.get(newJObject()){"flavour"}})

suite "extension identifiers and capability wire form":

  test "Given identifiers with a reverse-DNS prefix, when validated, then they are accepted":
    check validateExtensionId("io.modelcontextprotocol/tasks").isNone
    check validateExtensionId("com.example/my-ext_2.0").isNone

  test "Given identifiers without a prefix or with a malformed one, when validated, then they are rejected":
    for bad in ["tasks", "/tasks", "com.example/", "1com.example/x", "com-.example/x",
                "com.example/-x", "com.example/x-", "com example/x", "com.example/a b"]:
      check validateExtensionId(bad).isSome

  test "Given the specification's client and server capability examples, when parsed and written, then they round-trip":
    let clientJson = fixture("ClientCapabilities_extensions-ui-mime-types.json")
    let serverJson = fixture("ServerCapabilities_extensions-tasks.json")
    check extensionsOf(clientJson) == clientJson["extensions"]
    check extensionsOf(serverJson) == serverJson["extensions"]
    var clientCaps = McpClientCapabilities(extensions: some(clientJson["extensions"]))
    var serverCaps = McpServerCapabilities(extensions: some(serverJson["extensions"]))
    check clientCaps.toJson() == clientJson
    check serverCaps.toJson() == serverJson

  test "Given capabilities with no extensions or a non-object value, when read, then no extensions are declared":
    check extensionsOf(%*{"tools": {}}).kind == JNull
    check extensionsOf(%*{"extensions": 3}).kind == JNull

suite "extensions on the server":

  test "Given a registered extension, when a 2026-07-28 client discovers the server, then the capabilities list it with its settings":
    for v in versionsWith(ftExtensions):
      let server = widgetServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("server/discover")
      check answer["result"]["capabilities"]["extensions"][Ext]["flavours"].len == 2

  test "Given a registered extension, when a legacy client initializes, then the capabilities do not mention extensions":
    for v in versionsWithout(ftExtensions):
      let server = widgetServer()
      let t = server.attach()
      discard server.connect(t, v)
      let init = t.sent[0].message
      check not init["result"]["capabilities"].hasKey("extensions")

  test "Given a client that declares the extension, when it calls an extension method, then the handler runs and sees the settings":
    for v in versionsWith(ftExtensions):
      let server = widgetServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("widgets/make", %*{"kind": "gear"},
        meta = clientCaps(%*{Ext: {"flavour": "blue"}}))
      check answer["result"]["made"].getStr() == "gear"
      check answer["result"]["flavour"].getStr() == "blue"
      check answer["result"]["resultType"].getStr() == "complete"

  test "Given a client that does not declare the extension, when it calls an extension method, then it gets the missing-capability error naming the extension":
    for v in versionsWith(ftExtensions):
      let server = widgetServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("widgets/make", %*{"kind": "gear"})
      check answer.errorCode == -32021
      check answer["error"]["data"]["requiredCapabilities"]["extensions"][Ext] == newJObject()

  test "Given a version without extensions, when an extension method is called, then it is method not found":
    for v in versionsWithout(ftExtensions):
      let server = widgetServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("widgets/make", %*{"kind": "gear"}).errorCode == -32601

  test "Given an extension that defines a resultType, when its handler returns it, then the result passes through unchanged":
    for v in versionsWith(ftExtensions):
      let server = widgetServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("widgets/make", %*{"kind": "job"},
        meta = clientCaps(%*{Ext: {}}))
      check answer["result"]["resultType"].getStr() == "widget_job"
      check answer["result"]["jobId"].getStr() == "j1"
      check not answer["result"].hasKey("ttlMs")

  test "Given a handler that returns a resultType no extension defines, when it answers, then it is an internal error":
    for v in versionsWith(ftExtensions):
      let server = widgetServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("widgets/make", %*{"kind": "rogue"},
        meta = clientCaps(%*{Ext: {}}))
      check answer.errorCode == -32603

  test "Given a handler that uses ctx.requireClientExtension, when the client lacks the extension, then the answer is the missing-capability error":
    for v in versionsWith(ftExtensions):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        ctx.requireClientExtension(Ext)
        return %*{"content": []})
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/call", %*{"name": "t"}).errorCode == -32021
      check peer.ask("tools/call", %*{"name": "t"},
        meta = clientCaps(%*{Ext: {}}))["result"].hasKey("content")

  test "Given bad registrations, when made, then each raises ValueError":
    let server = widgetServer()
    expect ValueError: server.registerExtension("tasks")
    expect ValueError: server.registerExtension(Ext, resultTypes = ["complete"])
    expect ValueError: server.registerExtensionMethod("com.example/other", "widgets/x",
      proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} = return newJObject())
    expect ValueError: server.registerExtensionMethod(Ext, "tools/call",
      proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} = return newJObject())
    expect ValueError: server.registerExtensionMethod(Ext, "widgets/make",
      proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} = return newJObject())

suite "extensions on the client":

  test "Given a declared extension, when a request is sent, then clientCapabilities carries it":
    for v in versionsWith(ftExtensions):
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          peer.reply(message["id"], %*{"resultType": "complete", "tools": []}), modern = true)
      let client = peer.connectedClient(v, proc(c: McpClient) =
        c.declareExtension(Ext, %*{"flavour": "blue"}))
      discard waitFor client.callMethod("tools/list", newJObject())
      let caps = peer.requestsFor("tools/list")[0]["params"]["_meta"]["io.modelcontextprotocol/clientCapabilities"]
      check caps["extensions"][Ext]["flavour"].getStr() == "blue"

  test "Given a declared extension, when the client initializes in a legacy version, then the capabilities do not mention extensions":
    for v in versionsWithout(ftExtensions):
      let peer = startPeer(nil)
      discard peer.connectedClient(v, proc(c: McpClient) = c.declareExtension(Ext))
      let init = peer.requestsFor("initialize")[0]
      check not init["params"]["capabilities"].hasKey("extensions")

  test "Given a connected client, when it declares an extension, then it raises because capabilities are fixed at connect":
    let peer = startPeer(nil)
    let client = peer.connectedClient()
    expect McpError:
      client.declareExtension(Ext)

  test "Given a server that declares an extension, when the client connects, then it can read the server's settings":
    for v in versionsWith(ftExtensions):
      let peer = startPeer(nil, modern = true,
        capabilities = %*{"extensions": {Ext: {"flavours": ["a"]}}})
      let client = peer.connectedClient(v)
      check client.serverExtension(Ext).get["flavours"][0].getStr() == "a"
      check client.serverExtension("com.example/other").isNone

  test "Given a server that declares a capability the core does not define, when the client connects, then serverCapability returns its settings and only those":
    for v in versionsWith(ftExtensions) & versionsWithout(ftExtensions):
      let peer = startPeer(nil, modern = isModern(v), capabilities = %*{
        "tools": {}, "logging": {}, "widgets": {"flavour": "a"}, "flag": true})
      let client = peer.connectedClient(v)
      check client.serverCapability("widgets").get["flavour"].getStr() == "a"
      check client.serverCapability("flag").isNone
      check client.serverCapability("tools").isNone
      check client.serverCapability("logging").isNone

  test "Given a server that declares only capabilities the core defines, when the client connects, then it has none of another kind":
    for v in versionsWith(ftExtensions) & versionsWithout(ftExtensions):
      let peer = startPeer(nil, modern = isModern(v), capabilities = %*{"tools": {}})
      let client = peer.connectedClient(v)
      check client.serverCapabilities.get.additional.isNone
      check client.serverCapability("tools").isNone

  test "Given a server whose capabilities are not an object, when the client connects, then it connects and the server declared nothing":
    for v in versionsWith(ftExtensions) & versionsWithout(ftExtensions):
      let peer = startPeer(nil, modern = isModern(v), capabilities = %*["tools"])
      let client = peer.connectedClient(v)
      check client.serverCapabilities.get.tools.isNone
      check client.serverCapabilities.get.additional.isNone

  test "Given a server without the extension, when the client calls an extension method, then it raises McpUnsupportedError and sends nothing":
    for v in versionsWith(ftExtensions):
      let peer = startPeer(nil, modern = true)
      let client = peer.connectedClient(v, proc(c: McpClient) = c.declareExtension(Ext))
      expect McpUnsupportedError:
        discard waitFor client.callExtension(Ext, "widgets/make", %*{"kind": "gear"})
      check peer.requestsFor("widgets/make").len == 0

  test "Given an extension the server alone declares, when a client that declared nothing calls its method, then the server serves it and the client sends it":
    for v in versionsWith(ftExtensions):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.registerExtension(Ext)
      server.registerExtensionMethod(Ext, "widgets/count",
        proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} =
          return %*{"count": 3},
        clientDeclares = false)
      let asked = server.connect(server.attach(), v).ask("widgets/count", newJObject())
      check asked["result"]["count"].getInt() == 3

      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "widgets/count":
          peer.reply(message["id"], %*{"resultType": "complete", "count": 3}),
        modern = true, capabilities = %*{"extensions": {Ext: {}}})
      let client = peer.connectedClient(v)
      let reply = waitFor client.callExtension(Ext, "widgets/count", newJObject(),
                                               clientDeclares = false)
      check reply["count"].getInt() == 3
      # Still not sent to a server that did not declare the extension.
      let bare = startPeer(nil, modern = true, capabilities = newJObject())
      expect McpUnsupportedError:
        discard waitFor bare.connectedClient(v).callExtension(Ext, "widgets/count",
          newJObject(), clientDeclares = false)
      check bare.requestsFor("widgets/count").len == 0

  test "Given a client that did not declare the extension, when it calls an extension method, then it raises McpUnsupportedError":
    for v in versionsWith(ftExtensions):
      let peer = startPeer(nil, modern = true,
        capabilities = %*{"extensions": {Ext: {}}})
      let client = peer.connectedClient(v)
      expect McpUnsupportedError:
        discard waitFor client.callExtension(Ext, "widgets/make", newJObject())

  test "Given both sides support the extension, when the server answers with the extension's resultType, then the client returns the result":
    for v in versionsWith(ftExtensions):
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "widgets/make":
          peer.reply(message["id"], %*{"resultType": "widget_job", "jobId": "j1"}),
        modern = true, capabilities = %*{"extensions": {Ext: {}}})
      let client = peer.connectedClient(v, proc(c: McpClient) =
        c.declareExtension(Ext, resultTypes = ["widget_job"]))
      let answer = waitFor client.callExtension(Ext, "widgets/make", %*{"kind": "job"})
      check answer["resultType"].getStr() == "widget_job"
      check answer["jobId"].getStr() == "j1"

  test "Given a resultType the client's extensions do not define, when the server answers with it, then the client raises":
    for v in versionsWith(ftExtensions):
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "widgets/make":
          peer.reply(message["id"], %*{"resultType": "widget_job"}),
        modern = true, capabilities = %*{"extensions": {Ext: {}}})
      let client = peer.connectedClient(v, proc(c: McpClient) = c.declareExtension(Ext))
      expect ValueError:
        discard waitFor client.callExtension(Ext, "widgets/make", newJObject())

suite "extensions in the initialize handshake of the versions before 2026-07-28":

  test "Given extensions registered without onLegacyHandshake, when a legacy client initializes, then the request and the result are those of a peer with no extensions":
    for v in versionsWithout(ftExtensions):
      let plainPeer = startPeer(nil)
      discard plainPeer.connectedClient(v)
      let declaringPeer = startPeer(nil)
      discard declaringPeer.connectedClient(v, proc(c: McpClient) = c.declareExtension(Ext, %*{"a": 1}))
      check declaringPeer.requestsFor("initialize")[0]["params"] ==
            plainPeer.requestsFor("initialize")[0]["params"]
      let server = widgetServer()
      let t = server.attach()
      discard server.connect(t, v)
      check t.sent[0].message["result"]["capabilities"] == %*{"tools": {"listChanged": false}}

  test "Given an extension declared with onLegacyHandshake, when a legacy client initializes, then the request carries it and only it":
    for v in versionsWithout(ftExtensions):
      let peer = startPeer(nil)
      discard peer.connectedClient(v, proc(c: McpClient) =
        c.declareExtension(Ext, %*{"flavour": "blue"}, onLegacyHandshake = true)
        c.declareExtension("com.example/other"))
      let caps = peer.requestsFor("initialize")[0]["params"]["capabilities"]
      check caps["extensions"] == %*{Ext: {"flavour": "blue"}}

  test "Given a legacy client that declared an extension in initialize, when a handler asks, then it sees the settings; without the declaration it does not":
    for v in versionsWithout(ftExtensions):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        let settings = ctx.clientExtension(Ext)
        return %*{"content": [{"type": "text",
          "text": if settings.isSome: settings.get{"flavour"}.getStr() else: "none"}]})
      let declared = server.connect(server.attach(), v,
        clientCapabilities = %*{"extensions": {Ext: {"flavour": "blue"}}})
      check declared.ask("tools/call", %*{"name": "t"}).textOf == "blue"
      let other = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      other.onToolCall(proc(ctx: McpRequestContext, name: string,
                            arguments: JsonNode): Future[JsonNode] {.async.} =
        return %*{"content": [{"type": "text", "text": $ctx.clientExtension(Ext).isSome}]})
      check other.connect(other.attach(), v).ask("tools/call", %*{"name": "t"}).textOf == "false"

  test "Given an extension registered with onLegacyHandshake, when a legacy client initializes, then the result announces it and only it":
    for v in versionsWithout(ftExtensions):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.registerExtension(Ext, %*{"flavours": ["a"]}, onLegacyHandshake = true)
      server.registerExtension("com.example/other")
      let t = server.attach()
      discard server.connect(t, v)
      check t.sent[0].message["result"]["capabilities"]["extensions"] == %*{Ext: {"flavours": ["a"]}}
