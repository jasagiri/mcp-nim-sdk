## The initialize handshake of the versions before 2026-07-28, between the
## SDK's own client and server and against hand-written peers.
##
## Expectations are derived from `DefaultProtocolVersion`, so the same file
## passes on every `mcp-<version>` release branch.

import std/[unittest, asyncdispatch, json, options, strutils]
import server/server
import client/client
import protocol/types
import protocol/lifecycle
import ./loopback_transport

const LegacyDefault = min(DefaultProtocolVersion, mpv20251125)

proc info(): McpServerInfo = McpServerInfo(name: "srv", version: "1")
proc clientInfo(): McpClientInfo = McpClientInfo(name: "cli", version: "1")

proc initializeRequest(version: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": "1", "method": "initialize",
     "params": {"protocolVersion": version,
                "clientInfo": {"name": "peer", "version": "0"},
                "capabilities": {}}}

proc replyTo(pair: tuple[client, server: LoopbackTransport], request: JsonNode): JsonNode =
  ## Send `request` to the server side and return what it answers.
  pair.server.inject(request)
  waitFor pair.client.receiveMessage()

suite "legacy handshake: server":

  test "Given a server, when a client requests a version the server speaks, then the response carries the same version":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let pair = newLoopbackPair()
      let server = newMcpServer(info())
      waitFor server.attachTransport(pair.server)
      let reply = replyTo(pair, initializeRequest(%($v)))
      check reply["result"]["protocolVersion"].getStr() == $v
      check server.negotiatedVersion == some(v)

  test "Given a server, when a client requests an unknown version, then the response carries the server's latest legacy version":
    let pair = newLoopbackPair()
    let server = newMcpServer(info())
    waitFor server.attachTransport(pair.server)
    let reply = replyTo(pair, initializeRequest(%"2099-01-01"))
    check reply.hasKey("result")
    check reply["result"]["protocolVersion"].getStr() == $LegacyDefault

  test "Given a server limited to 2024-11-05, when a client requests a newer version, then the response carries 2024-11-05":
    let pair = newLoopbackPair()
    let server = newMcpServer(info(), protocolVersion = mpv20241105)
    waitFor server.attachTransport(pair.server)
    let reply = replyTo(pair, initializeRequest(%"2025-06-18"))
    check reply["result"]["protocolVersion"].getStr() == "2024-11-05"

  test "Given a server, when initialize has no protocolVersion, then it answers invalid params":
    let pair = newLoopbackPair()
    let server = newMcpServer(info())
    waitFor server.attachTransport(pair.server)
    let reply = replyTo(pair, %*{"jsonrpc": "2.0", "id": "1", "method": "initialize",
                                  "params": {"capabilities": {}}})
    check reply["error"]["code"].getInt() == -32602
    check server.state == mlsUninitialized

  test "Given a server, when initialize carries a non-string protocolVersion, then it answers invalid params":
    let pair = newLoopbackPair()
    let server = newMcpServer(info())
    waitFor server.attachTransport(pair.server)
    let reply = replyTo(pair, initializeRequest(%*{"major": 1, "minor": 0, "patch": 0}))
    check reply["error"]["code"].getInt() == -32602

  test "Given a server, when initialize omits capabilities, then it still answers with a result":
    let pair = newLoopbackPair()
    let server = newMcpServer(info())
    waitFor server.attachTransport(pair.server)
    let reply = replyTo(pair, %*{"jsonrpc": "2.0", "id": "1", "method": "initialize",
                                  "params": {"protocolVersion": $LegacyDefault}})
    check reply.hasKey("result")

  test "Given a server that declares only tools, when it answers initialize, then no other capability key is present":
    let pair = newLoopbackPair()
    let server = newMcpServer(info(), capabilities = McpServerCapabilities(
      tools: some(McpToolsCapability(listChanged: true))))
    waitFor server.attachTransport(pair.server)
    let reply = replyTo(pair, initializeRequest(%($LegacyDefault)))
    check reply["result"]["capabilities"] == %*{"tools": {"listChanged": true}}

  test "Given a server, when initialize carries null for a capability, then it treats the capability as not declared":
    let pair = newLoopbackPair()
    let server = newMcpServer(info())
    waitFor server.attachTransport(pair.server)
    let reply = replyTo(pair, %*{"jsonrpc": "2.0", "id": "1", "method": "initialize",
                                  "params": {"protocolVersion": $LegacyDefault,
                                             "capabilities": {"roots": nil, "sampling": nil}}})
    check reply.hasKey("result")
    check server.clientCapabilities.get.roots.isNone
    check server.clientCapabilities.get.sampling.isNone

  test "Given a legacy client, when it pings with a string id or an integer id, then the answer is an empty result of JSON-RPC 2.0 under the same id":
    let pair = newLoopbackPair()
    let server = newMcpServer(info())
    waitFor server.attachTransport(pair.server)
    discard replyTo(pair, initializeRequest(%($LegacyDefault)))
    for id in [%"ping-1", %7]:
      let reply = replyTo(pair, %*{"jsonrpc": "2.0", "id": id, "method": "ping"})
      check reply["jsonrpc"].getStr() == "2.0"
      check reply["id"] == id
      check reply["result"] == newJObject()

  test "Given a version above the build default, when a server is created with it, then ValueError is raised":
    for v in McpProtocolVersion:
      if v > DefaultProtocolVersion:
        expect ValueError:
          discard newMcpServer(info(), protocolVersion = v)

suite "legacy handshake: client":

  test "Given a client limited to a legacy version, when it connects, then initialize offers that version as a string":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let pair = newLoopbackPair()
      let server = newMcpServer(info())
      waitFor server.attachTransport(pair.server)
      let client = newMcpClient(clientInfo(), protocolVersion = v)
      waitFor client.connect(pair.client)
      let first = pair.client.sent[0]
      check first["method"].getStr() == "initialize"
      check first["params"]["protocolVersion"].kind == JString
      check first["params"]["protocolVersion"].getStr() == $v
      check client.negotiatedVersion == some(v)
      check client.state == mlsOperational

  test "Given a client that declares only roots, when it connects, then initialize carries no other capability key":
    let pair = newLoopbackPair()
    let server = newMcpServer(info())
    waitFor server.attachTransport(pair.server)
    let client = newMcpClient(clientInfo(), protocolVersion = LegacyDefault,
      capabilities = McpClientCapabilities(roots: some(McpRootsCapability(listChanged: true))))
    waitFor client.connect(pair.client)
    check pair.client.sent[0]["params"]["capabilities"] == %*{"roots": {"listChanged": true}}
    check server.clientCapabilities.get.roots.get.listChanged

  test "Given a legacy client, when the handshake completes, then it sends notifications/initialized":
    let pair = newLoopbackPair()
    let server = newMcpServer(info())
    waitFor server.attachTransport(pair.server)
    let client = newMcpClient(clientInfo(), protocolVersion = LegacyDefault)
    waitFor client.connect(pair.client)
    check pair.client.sent[1]["method"].getStr() == "notifications/initialized"
    check not pair.client.sent[1].hasKey("id")
    waitFor sleepAsync(1)
    check server.state == mlsOperational

  test "Given a client newer than the server, when it connects, then both settle on the server's version":
    if LegacyDefault > mpv20241105:
      let pair = newLoopbackPair()
      let server = newMcpServer(info(), protocolVersion = mpv20241105)
      waitFor server.attachTransport(pair.server)
      let client = newMcpClient(clientInfo(), protocolVersion = LegacyDefault)
      waitFor client.connect(pair.client)
      check client.negotiatedVersion == some(mpv20241105)

  test "Given a client attached to a transport, when initialize is called, then it returns the capabilities the server declared":
    let pair = newLoopbackPair()
    let client = newMcpClient(clientInfo(), protocolVersion = LegacyDefault)
    client.transport = pair.client
    asyncCheck client.processMessages()
    let initializing = client.initialize()
    let request = waitFor pair.server.receiveMessage()
    pair.client.inject(%*{"jsonrpc": "2.0", "id": request["id"],
                          "result": {"protocolVersion": $LegacyDefault,
                                     "serverInfo": {"name": "peer", "version": "0"},
                                     "capabilities": {"tools": {"listChanged": true}}}})
    let declared = waitFor initializing
    check declared.tools.get.listChanged
    check client.serverCapabilities == some(declared)

  test "Given a client limited to 2024-11-05, when the server answers with a newer version, then connect fails naming that version":
    let pair = newLoopbackPair()
    let client = newMcpClient(clientInfo(), protocolVersion = mpv20241105)
    let connecting = client.connect(pair.client)
    let request = waitFor pair.server.receiveMessage()
    pair.client.inject(%*{"jsonrpc": "2.0", "id": request["id"],
                          "result": {"protocolVersion": "2025-06-18",
                                     "serverInfo": {"name": "peer", "version": "0"},
                                     "capabilities": {}}})
    var message = ""
    try:
      waitFor connecting
    except ValueError as e:
      message = e.msg
    check "2025-06-18" in message
    check client.state != mlsOperational

  test "Given a client, when the server answers with an unknown version, then connect fails naming that version":
    let pair = newLoopbackPair()
    let client = newMcpClient(clientInfo(), protocolVersion = LegacyDefault)
    let connecting = client.connect(pair.client)
    let request = waitFor pair.server.receiveMessage()
    pair.client.inject(%*{"jsonrpc": "2.0", "id": request["id"],
                          "result": {"protocolVersion": "2099-01-01",
                                     "serverInfo": {"name": "peer", "version": "0"},
                                     "capabilities": {}}})
    var message = ""
    try:
      waitFor connecting
    except ValueError as e:
      message = e.msg
    check "2099-01-01" in message

  test "Given a version above the build default, when a client is created with it, then ValueError is raised":
    for v in McpProtocolVersion:
      if v > DefaultProtocolVersion:
        expect ValueError:
          discard newMcpClient(clientInfo(), protocolVersion = v)

suite "lifecycle messages: wire forms":

  test "Given a tasks capability that supports list only, when written, then it declares no requests":
    check McpTasksCapability(list: true).toJson() == %*{"list": {}}
    check McpTasksCapability().toJson() == newJObject()

  test "Given a tasks capability that supports a request type, when written, then it names that type under requests":
    check McpTasksCapability(toolsCall: true).toJson() == %*{"requests": {"tools": {"call": {}}}}

  test "Given the end of the handshake, when the initialized notification is made, then it is notifications/initialized with an empty object":
    let notification = createInitializedNotification()
    check notification.jsonrpc == "2.0"
    check notification.`method` == "notifications/initialized"
    check notification.params == newJObject()

  test "Given requests, when asked whether they are pings, then only ping is":
    check isPingRequest(newJsonRpcRequest("1", "ping", newJObject()))
    check not isPingRequest(newJsonRpcRequest("1", "tools/list", newJObject()))

  test "Given a cancellation without a reason, when made, then it names the request and carries no reason":
    let notification = createCancelledNotification("7")
    check notification.`method` == "notifications/cancelled"
    check notification.params == %*{"requestId": "7"}

  test "Given a cancellation with a reason, when made, then the reason is carried":
    check createCancelledNotification("7", "too slow").params ==
      %*{"requestId": "7", "reason": "too slow"}

  test "Given progress with only a token and a value, when made, then it carries neither total nor message":
    let notification = createProgressNotification("tok", 0.5)
    check notification.`method` == "notifications/progress"
    check notification.params == %*{"progressToken": "tok", "progress": 0.5}

  test "Given progress with a total and a message, when made, then both are carried":
    check createProgressNotification("tok", 3.0, some(10.0), "working").params ==
      %*{"progressToken": "tok", "progress": 3.0, "total": 10.0, "message": "working"}
