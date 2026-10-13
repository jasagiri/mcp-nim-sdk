## Serving and speaking both protocol eras: the 2026-07-28 per-request
## protocol and the initialize handshake of the versions before it.
##
## Expectations are derived from `DefaultProtocolVersion`, so the same file
## passes on every `mcp-<version>` release branch: a build whose default is
## a legacy version must behave like a server that has never heard of
## 2026-07-28.

import std/[unittest, asyncdispatch, json, options, strutils, tables]
import server/server
import client/client
import protocol/types
import protocol/lifecycle
import protocol/modern
import ./loopback_transport
import ./stuck_transport

const
  SpeaksModern = isModern(DefaultProtocolVersion)
  LegacyDefault = min(DefaultProtocolVersion, mpv20251125)

proc nextSent(pair: tuple[client, server: LoopbackTransport]): JsonNode =
  ## What the client sends next; the test ends when nothing comes.
  let next = pair.server.receiveMessage()
  require waitFor withTimeout(next, 1000)
  next.read

proc serverInfo(): McpServerInfo = McpServerInfo(name: "ExampleServer", version: "1.0.0")
proc clientInfo(): McpClientInfo = McpClientInfo(name: "ExampleClient", version: "1.0.0")

proc weatherServer(version = DefaultProtocolVersion): McpServer =
  result = newMcpServer(serverInfo(), protocolVersion = version,
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      return @[%*{"name": "get_weather", "inputSchema": {"type": "object"}}]
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      return %*{"content": [{"type": "text",
                             "text": name & ":" & arguments{"location"}.getStr()}],
                "isError": false}
  result.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))

proc modernMeta(version = "2026-07-28"): JsonNode =
  %*{"io.modelcontextprotocol/protocolVersion": version,
     "io.modelcontextprotocol/clientInfo": {"name": "ExampleClient", "version": "1.0.0"},
     "io.modelcontextprotocol/clientCapabilities": {}}

proc request(id: JsonNode, methodName: string, params: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "method": methodName, "params": params}

proc attached(server: McpServer): tuple[client, server: LoopbackTransport] =
  result = newLoopbackPair()
  waitFor server.attachTransport(result.server)

proc replyTo(pair: tuple[client, server: LoopbackTransport], message: JsonNode): JsonNode =
  pair.server.inject(message)
  waitFor pair.client.receiveMessage()

proc initializeLegacy(pair: tuple[client, server: LoopbackTransport]) =
  discard replyTo(pair, request(%"init", "initialize", %*{
    "protocolVersion": $LegacyDefault, "capabilities": {},
    "clientInfo": {"name": "peer", "version": "0"}}))
  pair.server.inject(%*{"jsonrpc": "2.0", "method": "notifications/initialized"})
  waitFor sleepAsync(1)

suite "responses on the wire (every era)":

  test "Given a successful response, when it is sent, then it has a result and no error key":
    let pair = attached(weatherServer(LegacyDefault))
    initializeLegacy(pair)
    let reply = replyTo(pair, request(%"a", "tools/list", newJObject()))
    check reply.hasKey("result")
    check not reply.hasKey("error")

  test "Given an error response, when it is sent, then it has an error and no result key":
    let pair = attached(weatherServer(LegacyDefault))
    initializeLegacy(pair)
    let reply = replyTo(pair, request(%"a", "no/such/method", newJObject()))
    check reply["error"]["code"].getInt() == -32601
    check not reply.hasKey("result")
    check not reply["error"].hasKey("data")

  test "Given a request with a numeric id, when it is answered, then the response id is the same number":
    let pair = attached(weatherServer(LegacyDefault))
    initializeLegacy(pair)
    let reply = replyTo(pair, request(%7, "tools/list", newJObject()))
    check reply["id"].kind == JInt
    check reply["id"].getInt() == 7

  test "Given a request with a string id, when it is answered, then the response id is the same string":
    let pair = attached(weatherServer(LegacyDefault))
    initializeLegacy(pair)
    let reply = replyTo(pair, request(%"7", "tools/list", newJObject()))
    check reply["id"].kind == JString
    check reply["id"].getStr() == "7"

suite "legacy requests on any build":

  test "Given an initialized legacy client, when it lists tools, then the result carries no 2026-07-28 fields":
    let pair = attached(weatherServer())
    initializeLegacy(pair)
    let reply = replyTo(pair, request(%1, "tools/list", newJObject()))
    check reply["result"]["tools"][0]["name"].getStr() == "get_weather"
    check not reply["result"].hasKey("resultType")
    check not reply["result"].hasKey("ttlMs")
    check not reply["result"].hasKey("cacheScope")

  test "Given a legacy request whose _meta carries only a progress token, when it is answered, then it is handled as legacy":
    let pair = attached(weatherServer())
    initializeLegacy(pair)
    let reply = replyTo(pair, request(%1, "tools/call", %*{
      "name": "get_weather", "arguments": {"location": "Kyoto"},
      "_meta": {"progressToken": "p1"}}))
    check reply["result"]["content"][0]["text"].getStr() == "get_weather:Kyoto"
    check not reply["result"].hasKey("resultType")

  test "Given a legacy client, when it pings, then it gets an empty result":
    let pair = attached(weatherServer())
    initializeLegacy(pair)
    let reply = replyTo(pair, request(%1, "ping", newJObject()))
    check reply["result"] == newJObject()

suite "a build limited to legacy versions":

  test "Given a server limited to a legacy version, when a 2026-07-28 discover probe arrives, then it answers method not found":
    # -32022 would tell a dual-era client "modern server, do not fall back".
    let pair = attached(weatherServer(LegacyDefault))
    let reply = replyTo(pair, request(%"discover-1", "server/discover", %*{"_meta": modernMeta()}))
    check reply["error"]["code"].getInt() == -32601

  test "Given a version above the build default, when a server is created with it, then ValueError is raised":
    for v in McpProtocolVersion:
      if v > DefaultProtocolVersion:
        expect ValueError:
          discard weatherServer(v)

if SpeaksModern:
  suite "2026-07-28 server":

    test "Given the specification's discover request, when it is answered, then the result describes the server":
      let server = weatherServer()
      server.cachePolicy = CachePolicy(ttlMs: 3600000, scope: csPublic)
      server.instructions = "This server provides weather utilities."
      let pair = attached(server)
      let reply = replyTo(pair, request(%"discover-1", "server/discover", %*{"_meta": modernMeta()}))
      check reply["id"].getStr() == "discover-1"
      check reply["result"] == %*{
        "resultType": "complete",
        "supportedVersions": ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"],
        "capabilities": {"tools": {"listChanged": false}},
        "instructions": "This server provides weather utilities.",
        "_meta": {"io.modelcontextprotocol/serverInfo":
          {"name": "ExampleServer", "version": "1.0.0"}},
        "ttlMs": 3600000,
        "cacheScope": "public"}

    test "Given no initialize, when a 2026-07-28 tools/list arrives, then it is served and the server keeps no handshake state":
      let server = weatherServer()
      let pair = attached(server)
      let reply = replyTo(pair, request(%1, "tools/list", %*{"_meta": modernMeta()}))
      check reply["result"]["tools"][0]["name"].getStr() == "get_weather"
      check reply["result"]["resultType"].getStr() == "complete"
      check reply["result"]["ttlMs"].getInt() == 0
      check reply["result"]["cacheScope"].getStr() == "private"
      check server.state == mlsUninitialized
      check server.negotiatedVersion.isNone

    test "Given a 2026-07-28 tools/call, when it is answered, then the result is complete and carries no cache fields":
      let pair = attached(weatherServer())
      let reply = replyTo(pair, request(%"call-tool-example", "tools/call", %*{
        "_meta": modernMeta(), "name": "get_weather", "arguments": {"location": "New York"}}))
      check reply["result"]["resultType"].getStr() == "complete"
      check reply["result"]["content"][0]["text"].getStr() == "get_weather:New York"
      check reply["result"]["isError"].getBool() == false
      check reply["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"].getStr() == "ExampleServer"
      check not reply["result"].hasKey("ttlMs")

    test "Given a 2026-07-28 request without client capabilities, when it is answered, then it is invalid params":
      let pair = attached(weatherServer())
      let meta = modernMeta()
      meta.delete("io.modelcontextprotocol/clientCapabilities")
      let reply = replyTo(pair, request(%1, "tools/list", %*{"_meta": meta}))
      check reply["error"]["code"].getInt() == -32602

    test "Given a request naming an unknown version, when it is answered, then the error lists the supported versions":
      let pair = attached(weatherServer())
      let reply = replyTo(pair, request(%1, "tools/list", %*{"_meta": modernMeta("1900-01-01")}))
      check reply["error"]["code"].getInt() == -32022
      check reply["error"]["data"]["requested"].getStr() == "1900-01-01"
      check reply["error"]["data"]["supported"][0].getStr() == "2026-07-28"

    test "Given a 2026-07-28 request for a method the version removed, when it is answered, then it is method not found":
      for name in ["ping", "initialize", "logging/setLevel", "resources/subscribe"]:
        let pair = attached(weatherServer())
        let reply = replyTo(pair, request(%1, name, %*{"_meta": modernMeta()}))
        check reply["error"]["code"].getInt() == -32601

    test "Given a 2026-07-28 request for an unknown method, when it is answered, then it is method not found":
      let pair = attached(weatherServer())
      let reply = replyTo(pair, request(%1, "no/such/method", %*{"_meta": modernMeta()}))
      check reply["error"]["code"].getInt() == -32601

    test "Given one server, when a legacy client and a 2026-07-28 client use it in turn, then each is answered in its own era":
      let pair = attached(weatherServer())
      initializeLegacy(pair)
      let legacy = replyTo(pair, request(%1, "tools/list", newJObject()))
      let modern = replyTo(pair, request(%2, "tools/list", %*{"_meta": modernMeta()}))
      check not legacy["result"].hasKey("resultType")
      check modern["result"]["resultType"].getStr() == "complete"

  suite "2026-07-28 client":

    test "Given a 2026-07-28 server, when the client connects, then it discovers the server and sends no initialize":
      let pair = attached(weatherServer())
      let client = newMcpClient(clientInfo())
      waitFor client.connect(pair.client)
      check pair.client.sent.len == 1
      check pair.client.sent[0]["method"].getStr() == "server/discover"
      check pair.client.sent[0]["params"]["_meta"] == modernMeta()
      check client.negotiatedVersion == some(mpv20260728)
      check client.state == mlsOperational
      check client.capabilities().get.tools.isSome

    test "Given a connected 2026-07-28 client, when it sends a request, then the request carries the protocol metadata beside its own params":
      let pair = attached(weatherServer())
      let client = newMcpClient(clientInfo())
      waitFor client.connect(pair.client)
      let response = waitFor client.sendRequest("tools/call",
        %*{"name": "get_weather", "arguments": {"location": "Osaka"}})
      let sent = pair.client.sent[^1]
      check sent["params"]["_meta"] == modernMeta()
      check sent["params"]["name"].getStr() == "get_weather"
      check response.result.get["content"][0]["text"].getStr() == "get_weather:Osaka"

    test "Given a server limited to a legacy version, when a 2026-07-28 client connects, then it falls back to initialize":
      let pair = attached(weatherServer(mpv20251125))
      let client = newMcpClient(clientInfo())
      waitFor client.connect(pair.client)
      check pair.client.sent[0]["method"].getStr() == "server/discover"
      check pair.client.sent[1]["method"].getStr() == "initialize"
      check pair.client.sent[1]["params"]["protocolVersion"].getStr() == "2025-11-25"
      check pair.client.sent[2]["method"].getStr() == "notifications/initialized"
      check client.negotiatedVersion == some(mpv20251125)
      let response = waitFor client.sendRequest("tools/list", newJObject())
      check not pair.client.sent[^1]["params"].hasKey("_meta")
      check response.result.get["tools"].len == 1

    test "Given a peer that never answers the discover probe, when the probe times out, then the client sends initialize":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      client.probeTimeoutMs = 20
      let connecting = client.connect(pair.client)
      let probe = waitFor pair.server.receiveMessage()
      check probe["method"].getStr() == "server/discover"
      let init = waitFor pair.server.receiveMessage()
      check init["method"].getStr() == "initialize"
      pair.client.inject(%*{"jsonrpc": "2.0", "id": init["id"], "result": {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "serverInfo": {"name": "peer", "version": "0"}}})
      waitFor connecting
      check client.negotiatedVersion == some(mpv20250618)

    test "Given a modern peer that answers the probe only after the probe timed out, when it then refuses initialize as unsupported, then the client discovers again and stays modern":
      # A server that starts slowly (a loaded machine) answers the probe late;
      # that it refuses initialize with a modern error shows what it is.
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      client.probeTimeoutMs = 20
      let connecting = client.connect(pair.client)
      let probe = waitFor pair.server.receiveMessage()
      check probe["method"].getStr() == "server/discover"
      let init = waitFor pair.server.receiveMessage()
      check init["method"].getStr() == "initialize"
      let discovered = %*{"resultType": "complete", "supportedVersions": ["2026-07-28"],
        "capabilities": {}, "ttlMs": 0, "cacheScope": "private"}
      pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "result": discovered})
      pair.client.inject(%*{"jsonrpc": "2.0", "id": init["id"], "error": {
        "code": -32022, "message": "Unsupported protocol version",
        "data": {"supported": ["2026-07-28"], "requested": "2025-11-25"}}})
      let again = waitFor pair.server.receiveMessage()
      check again["method"].getStr() == "server/discover"
      pair.client.inject(%*{"jsonrpc": "2.0", "id": again["id"], "result": discovered})
      waitFor connecting
      check client.negotiatedVersion == some(mpv20260728)
      check pair.client.sent.len == 3

    test "Given a peer that refuses initialize as unsupported though the probe was answered with a legacy error, when the client connects, then connect fails":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      let connecting = client.connect(pair.client)
      let probe = waitFor pair.server.receiveMessage()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "error": {
        "code": -32601, "message": "Method not found"}})
      let init = waitFor pair.server.receiveMessage()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": init["id"], "error": {
        "code": -32022, "message": "Unsupported protocol version",
        "data": {"supported": ["2026-07-28"], "requested": "2025-11-25"}}})
      expect ValueError:
        waitFor connecting
      check pair.client.sent.len == 2

    test "Given a modern peer that supports only a version the client does not speak, when the client connects, then connect fails naming that version and no initialize is sent":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      let connecting = client.connect(pair.client)
      let probe = waitFor pair.server.receiveMessage()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "error": {
        "code": -32022, "message": "Unsupported protocol version",
        "data": {"supported": ["2027-01-01"], "requested": "2026-07-28"}}})
      var message = ""
      try:
        waitFor connecting
      except ValueError as e:
        message = e.msg
      check "2027-01-01" in message
      check pair.client.sent.len == 1

    test "Given a discover result that lists no version the client speaks, when the client connects, then connect fails":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      let connecting = client.connect(pair.client)
      let probe = waitFor pair.server.receiveMessage()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "result": {
        "resultType": "complete", "supportedVersions": ["2027-01-01"],
        "capabilities": {}, "ttlMs": 0, "cacheScope": "private"}})
      expect ValueError:
        waitFor connecting

    test "Given a peer that refuses the probe naming a modern version the client speaks, when the client connects, then it probes again and connects in the modern era":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      let connecting = client.connect(pair.client)
      let probe = pair.nextSent()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "error": {
        "code": -32022, "message": "Unsupported protocol version",
        "data": {"supported": ["2026-07-28"], "requested": "2026-07-28"}}})
      let again = pair.nextSent()
      check again["method"].getStr() == "server/discover"
      pair.client.inject(%*{"jsonrpc": "2.0", "id": again["id"], "result": {
        "resultType": "complete", "supportedVersions": ["2026-07-28"], "capabilities": {}}})
      waitFor connecting
      check client.negotiatedVersion == some(mpv20260728)
      check pair.client.sent.len == 2

    test "Given a peer that refuses the probe twice naming a modern version, when the client connects, then connect fails and no initialize is sent":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      let connecting = client.connect(pair.client)
      for _ in 1 .. 2:
        let probe = pair.nextSent()
        check probe["method"].getStr() == "server/discover"
        pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "error": {
          "code": -32022, "message": "Unsupported protocol version",
          "data": {"supported": ["2026-07-28"], "requested": "2026-07-28"}}})
      expect ValueError:
        waitFor connecting
      check pair.client.sent.len == 2

    test "Given a peer that refuses the probe naming only legacy versions, when the client connects, then it sends initialize and does not probe again":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      let connecting = client.connect(pair.client)
      let probe = pair.nextSent()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "error": {
        "code": -32022, "message": "Unsupported protocol version",
        "data": {"supported": ["2025-06-18"], "requested": "2026-07-28"}}})
      let init = pair.nextSent()
      check init["method"].getStr() == "initialize"
      pair.client.inject(%*{"jsonrpc": "2.0", "id": init["id"], "result": {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "serverInfo": {"name": "peer", "version": "0"}}})
      waitFor connecting
      check client.negotiatedVersion == some(mpv20250618)

    test "Given a discover result that lists only legacy versions, when the client connects, then it sends initialize":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      let connecting = client.connect(pair.client)
      let probe = pair.nextSent()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "result": {
        "resultType": "complete", "supportedVersions": ["2025-06-18"], "capabilities": {}}})
      let init = pair.nextSent()
      check init["method"].getStr() == "initialize"
      pair.client.inject(%*{"jsonrpc": "2.0", "id": init["id"], "result": {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "serverInfo": {"name": "peer", "version": "0"}}})
      waitFor connecting
      check client.negotiatedVersion == some(mpv20250618)

    test "Given a peer that refuses the probe as unsupported without naming versions, when the client connects, then connect fails saying no version is shared":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      let connecting = client.connect(pair.client)
      let probe = pair.nextSent()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "error": {
        "code": -32022, "message": "Unsupported protocol version"}})
      var message = ""
      try:
        waitFor connecting
      except ValueError as e:
        message = e.msg
      check "No protocol version in common" in message
      check pair.client.sent.len == 1

    test "Given a peer silent to the probe that refuses initialize with another error naming a modern version, when the client connects, then connect fails without discovering again":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      client.probeTimeoutMs = 20
      let connecting = client.connect(pair.client)
      discard pair.nextSent()
      let init = pair.nextSent()
      check init["method"].getStr() == "initialize"
      pair.client.inject(%*{"jsonrpc": "2.0", "id": init["id"], "error": {
        "code": -32603, "message": "Internal error",
        "data": {"supported": ["2026-07-28"]}}})
      expect ValueError:
        require waitFor withTimeout(connecting, 1000)
      check pair.client.sent.len == 2

    test "Given a transport that never finishes sending the probe, when the probe times out, then the client cancels it, leaves nothing pending and sends initialize":
      let transport = newStuckTransport(holdSend = "server/discover")
      let client = newMcpClient(clientInfo())
      client.probeTimeoutMs = 20
      let connecting = client.connect(transport)
      var waited = 0
      while "initialize" notin transport.sentMethods and waited < 200:
        waitFor sleepAsync(10)
        inc waited
      require "initialize" in transport.sentMethods
      transport.inject(%*{"jsonrpc": "2.0", "id": transport.sentIds[1], "result": {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "serverInfo": {"name": "peer", "version": "0"}}})
      waitFor connecting
      check transport.cancelled == @[transport.sentIds[0]]
      check client.pendingRequests.len == 0

    test "Given a result with a resultType the client does not know, when a request completes, then the client raises instead of returning it":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      let connecting = client.connect(pair.client)
      let probe = waitFor pair.server.receiveMessage()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "result": {
        "resultType": "complete", "supportedVersions": ["2026-07-28"],
        "capabilities": {}, "ttlMs": 0, "cacheScope": "private"}})
      waitFor connecting
      let pending = client.sendRequest("tools/call", %*{"name": "x"})
      let sent = waitFor pair.server.receiveMessage()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": sent["id"],
                            "result": {"resultType": "task", "taskId": "t"}})
      var message = ""
      try:
        discard waitFor pending
      except ValueError as e:
        message = e.msg
      check "task" in message

    test "Given a result without resultType from an older server, when a request completes, then it is returned as complete":
      let pair = newLoopbackPair()
      let client = newMcpClient(clientInfo())
      let connecting = client.connect(pair.client)
      let probe = waitFor pair.server.receiveMessage()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": probe["id"], "result": {
        "supportedVersions": ["2026-07-28"], "capabilities": {}}})
      waitFor connecting
      let pending = client.sendRequest("tools/list", newJObject())
      let sent = waitFor pair.server.receiveMessage()
      pair.client.inject(%*{"jsonrpc": "2.0", "id": sent["id"], "result": {"tools": []}})
      check (waitFor pending).result.get == %*{"tools": []}
