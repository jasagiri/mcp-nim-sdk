## Verifies that processMessages stores the transport error on the
## client/server instead of silently swallowing it.
##
## Repro for audit finding #5: previously a `bare except:` echoed the error
## to stderr and let the message-loop future complete cleanly, leaving the
## server/client in a "silent dead" state with no programmatic signal.

import std/[unittest, asyncdispatch, json, strutils]
import transport/transport
import server/server
import client/client
import protocol/types
import protocol/lifecycle

type
  ExplodingTransport = ref object of McpTransport
    msg: string

method sendRequest*(t: ExplodingTransport, request: JsonRpcRequest): Future[void] {.async.} =
  discard

method sendNotification*(t: ExplodingTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  discard

method sendResponse*(t: ExplodingTransport, response: JsonRpcResponse): Future[void] {.async.} =
  discard

method receiveMessage*(t: ExplodingTransport): Future[JsonNode] {.async.} =
  raise newException(McpTransportError, t.msg)

method close*(t: ExplodingTransport): Future[void] {.async.} =
  discard

proc newExplodingTransport(msg: string): ExplodingTransport =
  ExplodingTransport(kind: mtkStdio, msg: msg)

type
  ClosedTransport = ref object of McpTransport

method receiveMessage*(t: ClosedTransport): Future[JsonNode] {.async.} =
  raise newException(McpTransportClosedError, "EOF on input stream")

suite "processMessages — the peer closing the connection":
  test "Given a transport the peer closed When the server loop exits Then the server is shut down and no error is recorded":
    let server = newMcpServer(McpServerInfo(name: "t", version: "0"))
    server.transport = ClosedTransport(kind: mtkStdio)
    waitFor server.processMessages()
    check server.state == mlsShutdown
    check server.lastTransportError.isNil

  test "Given a transport the peer closed When the client loop exits Then the client is shut down and no error is recorded":
    let client = newMcpClient(McpClientInfo(name: "t", version: "0"))
    client.transport = ClosedTransport(kind: mtkStdio)
    waitFor client.processMessages()
    check client.state == mlsShutdown
    check client.lastTransportError.isNil

suite "Server processMessages — error visibility":
  test "Given a transport that raises When processMessages exits Then lastTransportError is set":
    let server = newMcpServer(McpServerInfo(name: "t", version: "0"))
    server.transport = newExplodingTransport("boom-from-server")
    try:
      waitFor server.processMessages()
    except CatchableError:
      discard
    check not server.lastTransportError.isNil
    # Nim's async runtime may append a trailing newline / stack-trace blob
    # to exception messages; we only care that the original payload is
    # recoverable for diagnostics.
    check server.lastTransportError.msg.contains("boom-from-server")

  test "Given a healthy server with no transport activity Then lastTransportError remains nil before run":
    let server = newMcpServer(McpServerInfo(name: "t", version: "0"))
    check server.lastTransportError.isNil

suite "Client processMessages — error visibility":
  test "Given a transport that raises When processMessages exits Then lastTransportError is set":
    let client = newMcpClient(McpClientInfo(name: "t", version: "0"))
    client.transport = newExplodingTransport("boom-from-client")
    try:
      waitFor client.processMessages()
    except CatchableError:
      discard
    check not client.lastTransportError.isNil
    check client.lastTransportError.msg.contains("boom-from-client")

  test "Given a healthy client Then lastTransportError defaults to nil":
    let client = newMcpClient(McpClientInfo(name: "t", version: "0"))
    check client.lastTransportError.isNil
