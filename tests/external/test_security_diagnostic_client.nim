## What the server of a client writes into a diagnostic line is made
## harmless (MCP-SEC-HTTP-7): the client's lines hold the text of a peer
## only as escapes and cut short.

import std/[unittest, asyncdispatch, json, os, strutils]
import client/client
import client/subscriptions
import protocol/subscriptions
import protocol/types
import ./client_peer
import ./loopback_transport

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-sec-diagnostic-client-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

const Hostile = "x\n[mcp-client] forged line \e[2J"

suite "peer text in the diagnostics of the client (MCP-SEC-HTTP-7)":
  test "Given a server message that is no JSON-RPC message, when the client logs it, then the log holds one line without the control characters":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    let logged = loggedWhile(proc() =
      peer.pair.client.inject(%*{"x": Hostile})
      waitFor sleepAsync(50))
    check "\e" notin logged
    check logged.count('\n') == 1
    check "[mcp-client] invalid message" in logged
    waitFor client.close()

  test "Given a server message that is no JSON-RPC message and very long, when the client logs it, then the log line is short":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    let logged = loggedWhile(proc() =
      peer.pair.client.inject(%*{"x": "y".repeat(100_000)})
      waitFor sleepAsync(50))
    check logged.len < 1000
    check logged.count('\n') == 1
    waitFor client.close()

  test "Given a request whose method name is hostile and whose handler fails with a hostile message, when the client logs it, then both are shown as escapes":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault, proc(c: McpClient) =
      c.registerRequestHandler(Hostile, proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
        raise newException(ValueError, Hostile)))
    let logged = loggedWhile(proc() =
      peer.ask(%1, Hostile)
      waitFor sleepAsync(50))
    check "\e" notin logged
    check logged.count('\n') == 1
    check logged.count("\\n[mcp-client] forged line \\x1b[2J") == 2
    waitFor client.close()

suite "failures the client cannot hand to a caller are reported, not swallowed":

  proc raising(): ref ValueError = newException(ValueError, "the callback broke")

  test "Given a progress callback that raises, when progress arrives, then the log names the callback and the error":
    let peer = startPeer(proc(peer: Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.push("notifications/progress", %*{
          "progressToken": message["params"]["_meta"]["progressToken"], "progress": 1})
        peer.reply(message["id"], %*{"content": []}))
    let client = peer.connectedClient(LegacyDefault)
    let logged = loggedWhile(proc() =
      discard waitFor client.sendRequest("tools/call", %*{"name": "t"},
        McpRequestOptions(onProgress: proc(update: McpProgress) = raise raising()))
      waitFor sleepAsync(50))
    check "progress callback raised ValueError: the callback broke" in logged
    waitFor client.close()

  test "Given a log callback that raises, when a log message arrives, then the log names the callback and the error":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault, proc(c: McpClient) =
      c.onLogMessage = proc(message: McpLogMessage) = raise raising())
    let logged = loggedWhile(proc() =
      peer.push("notifications/message", %*{"level": "info", "data": "x"})
      waitFor sleepAsync(50))
    check "log callback raised ValueError: the callback broke" in logged
    waitFor client.close()

  test "Given a resource-updated callback that raises, when an update arrives, then the log names the callback and the error":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault, proc(c: McpClient) =
      c.onResourceUpdated = proc(uri: string) = raise raising())
    let logged = loggedWhile(proc() =
      peer.push("notifications/resources/updated", %*{"uri": "file:///a"})
      waitFor sleepAsync(50))
    check "resource-updated callback raised ValueError: the callback broke" in logged
    waitFor client.close()

  test "Given a list-changed callback that raises, when the server reports a change, then the log names the callback and the error":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault, proc(c: McpClient) =
      c.onToolsListChanged = proc() = raise raising())
    let logged = loggedWhile(proc() =
      peer.push("notifications/tools/list_changed")
      waitFor sleepAsync(50))
    check "tools list_changed callback raised ValueError: the callback broke" in logged
    waitFor client.close()

  test "Given a handler for a notification that raises, when the notification arrives, then the log names the method and the error":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault, proc(c: McpClient) =
      c.registerNotificationHandler("notifications/custom",
        proc(notification: JsonRpcNotification): Future[void] {.async.} = raise raising()))
    let logged = loggedWhile(proc() =
      peer.push("notifications/custom")
      waitFor sleepAsync(50))
    check "handler for notifications/custom raised ValueError: the callback broke" in logged
    waitFor client.close()

  test "Given a transport that fails, when the receive loop ends, then the log names the error":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    let logged = loggedWhile(proc() =
      waitFor peer.pair.client.close()
      waitFor sleepAsync(50))
    check "transport loop ended with McpTransportError" in logged
    check not client.lastTransportError.isNil

  if SpeaksModern:
    test "Given a stream callback that raises, when a notification arrives on the stream, then the log names the callback and the error":
      var listenMessage: JsonNode
      let peer = startPeer(proc(peer: Peer, message: JsonNode) =
        if message{"method"}.getStr() == "subscriptions/listen":
          listenMessage = message
          peer.push("notifications/subscriptions/acknowledged", %*{
            "_meta": {"io.modelcontextprotocol/subscriptionId": message["id"]},
            "notifications": {"toolsListChanged": true}}), modern = true)
      let client = peer.connectedClient()
      let sub = waitFor client.listen(SubscriptionFilter(toolsListChanged: true))
      sub.onNotification = proc(methodName: string, params: JsonNode) = raise raising()
      let logged = loggedWhile(proc() =
        peer.push("notifications/tools/list_changed", %*{
          "_meta": {"io.modelcontextprotocol/subscriptionId": listenMessage["id"]}})
        waitFor sleepAsync(50))
      check "subscription callback raised ValueError: the callback broke" in logged
      waitFor client.close()
