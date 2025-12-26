# Model Context Protocol (MCP) Server SDK for Nim
#
# Simple Client Tests - Tests for client-server communication using InMemoryTransport.

import unittest, asyncdispatch, json, options, tables
import ../src/mcp/client
import ../src/mcp/types
import ../src/mcp/protocol
import ../src/mcp/transport/inmemory
import ../src/mcp/transport/base

suite "Simple Client Tests":
  test "InMemoryTransport pair creation":
    let pair = newInMemoryTransport()

    check(pair.clientSide != nil)
    check(pair.serverSide != nil)

  test "InMemoryTransport start":
    proc testStart() {.async.} =
      let pair = newInMemoryTransport()

      await pair.clientSide.start()
      await pair.serverSide.start()

      check(pair.clientSide.state == Started)
      check(pair.serverSide.state == Started)

    waitFor testStart()

  test "InMemoryTransport stop":
    proc testStop() {.async.} =
      let pair = newInMemoryTransport()

      await pair.clientSide.start()
      await pair.serverSide.start()

      await pair.clientSide.stop()
      await pair.serverSide.stop()

      check(pair.clientSide.state == Closed)
      check(pair.serverSide.state == Closed)

    waitFor testStop()

  test "InMemoryTransport message sending":
    proc testSending() {.async.} =
      let pair = newInMemoryTransport()

      await pair.clientSide.start()
      await pair.serverSide.start()

      var receivedMessage = ""

      pair.serverSide.onMessageCallback = proc(msg: string) {.async.} =
        receivedMessage = msg

      await pair.clientSide.send("{\"test\": \"hello\"}")

      check(receivedMessage == "{\"test\": \"hello\"}")
      check(pair.clientSide.getSentMessages().len == 1)

    waitFor testSending()

  test "Client creation with capabilities":
    let capabilities = types.ClientCapabilities(
      resources: some(true),
      tools: some(true),
      sampling: some(true)
    )

    let client = client.newClient("simple-client", "1.0.0", capabilities)

    check(client != nil)
    check(client.name == "simple-client")
    check(client.version == "1.0.0")
    check(client.isInitialized == false)
    check(client.capabilities.resources.isSome)
    check(client.capabilities.tools.isSome)
    check(client.capabilities.sampling.isSome)

  test "Server creation with capabilities":
    let metadata = types.ServerMetadata(
      name: "simple-server",
      version: "1.0.0"
    )

    let capabilities = types.ServerCapabilities(
      resources: some(types.ResourcesCapability()),
      tools: some(types.ToolsCapability())
    )

    let server = newServer(metadata, capabilities)

    check(server != nil)
    check(server.name == "simple-server")
    check(server.version == "1.0.0")
    check(server.capabilities.resources.isSome)
    check(server.capabilities.tools.isSome)

  test "Bidirectional message exchange":
    proc testBidirectional() {.async.} =
      let pair = newInMemoryTransport()

      await pair.clientSide.start()
      await pair.serverSide.start()

      var serverReceived = ""
      var clientReceived = ""

      pair.serverSide.onMessageCallback = proc(msg: string) {.async.} =
        serverReceived = msg

      pair.clientSide.onMessageCallback = proc(msg: string) {.async.} =
        clientReceived = msg

      # Client to server
      await pair.clientSide.send("{\"from\": \"client\"}")
      check(serverReceived == "{\"from\": \"client\"}")

      # Server to client
      await pair.serverSide.send("{\"from\": \"server\"}")
      check(clientReceived == "{\"from\": \"server\"}")

    waitFor testBidirectional()

