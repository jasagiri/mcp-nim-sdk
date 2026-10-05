## What the server may ask of the client (ping, sampling, roots) and the
## notifications it may push, before 2026-07-28.

import std/[unittest, asyncdispatch, json, options, strutils]
import client/client
import client/content
import client/roots
import client/sampling
import protocol/types
import protocol/lifecycle
import ./client_peer

proc responseTo(peer: Peer, id: string): JsonNode =
  ## The client's answer to a request the peer made.
  waitFor sleepAsync(5)
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
      return message
  nil

proc echoSampler(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
  return McpSamplingResult(role: "assistant", model: "test-model",
    content: McpContentItem(kind: mckText, text: "echo:" & request.messages[0].content.text),
    stopReason: some("endTurn"))

let samplingParams = %*{
  "messages": [{"role": "user", "content": {"type": "text", "text": "hello"}}],
  "modelPreferences": {"hints": [{"name": "claude"}], "speedPriority": 0.5},
  "systemPrompt": "be brief", "maxTokens": 100, "temperature": 0.2,
  "stopSequences": ["END"]}

suite "ping from the server":

  test "Given a legacy connection, when the server pings, then the client answers with an empty result":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault)
    peer.ask(%"p1", "ping")
    check peer.responseTo("p1")["result"] == newJObject()

  test "Given a numeric request id, when the client answers, then the id keeps its JSON type":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault)
    peer.ask(%7, "ping")
    waitFor sleepAsync(5)
    check peer.received[^1]["id"].kind == JInt

suite "sampling":

  test "Given a sampling handler, when the server asks, then the request is parsed and the result is sent in wire form":
    var seen: McpSamplingRequest
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] =
        seen = request
        echoSampler(request)))
    peer.ask(%"s1", "sampling/createMessage", samplingParams)
    let answer = peer.responseTo("s1")["result"]
    check answer["role"].getStr() == "assistant"
    check answer["content"] == %*{"type": "text", "text": "echo:hello"}
    check answer["model"].getStr() == "test-model"
    check answer["stopReason"].getStr() == "endTurn"
    check seen.systemPrompt == some("be brief")
    check seen.maxTokens == 100
    check seen.temperature == some(0.2)
    check seen.stopSequences == @["END"]
    check seen.modelPreferences.get.hints[0].name == "claude"
    check seen.modelPreferences.get.speedPriority == some(0.5)
    check seen.modelPreferences.get.costPriority.isNone

  test "Given a sampling handler, when the client connects, then initialize declares sampling":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setSamplingHandler(echoSampler))
    check peer.requestsFor("initialize")[0]["params"]["capabilities"].hasKey("sampling")

  test "Given no sampling handler, when the server asks, then the client answers method not found":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault)
    peer.ask(%"s1", "sampling/createMessage", samplingParams)
    check peer.responseTo("s1")["error"]["code"].getInt() == -32601

  test "Given a handler that refuses, when the server asks, then the handler's error code is sent":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
        raise newException(McpRequestError, "User rejected sampling request")))
    peer.ask(%"s1", "sampling/createMessage", samplingParams)
    let answer = peer.responseTo("s1")
    # debug builds append the async traceback to the message
    check answer["error"]["message"].getStr().startsWith("User rejected sampling request")

  test "Given a handler that fails, when the server asks, then an internal error is sent and the client carries on":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
        raise newException(ValueError, "model offline")))
    peer.ask(%"s1", "sampling/createMessage", samplingParams)
    let answer = peer.responseTo("s1")
    check answer["error"]["code"].getInt() == -32603
    check "model offline" in answer["error"]["message"].getStr()
    check client.state == mlsOperational

  test "Given malformed sampling params, when the server asks, then the client answers invalid params":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setSamplingHandler(echoSampler))
    peer.ask(%"s1", "sampling/createMessage", %*{"maxTokens": 1})
    check peer.responseTo("s1")["error"]["code"].getInt() == -32602

  test "Given a connected client, when a sampling handler is set, then McpError is raised":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    expect McpError:
      client.setSamplingHandler(echoSampler)

suite "roots":

  test "Given a roots provider, when the server asks, then the roots are listed":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} =
        return @[McpRoot(uri: "file:///work", name: some("work")),
                 McpRoot(uri: "file:///tmp", name: none(string))]))
    peer.ask(%"r1", "roots/list")
    let roots = peer.responseTo("r1")["result"]["roots"]
    check roots.len == 2
    check roots[0] == %*{"uri": "file:///work", "name": "work"}
    check roots[1] == %*{"uri": "file:///tmp"}

  test "Given a roots provider, when the client connects, then initialize declares roots with listChanged":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} = return @[]))
    check peer.requestsFor("initialize")[0]["params"]["capabilities"]["roots"] ==
      %*{"listChanged": true}

  test "Given a client that declared no roots, when the server asks, then the client answers method not found":
    let peer = startPeer(nil)
    discard peer.connectedClient(LegacyDefault)
    peer.ask(%"r1", "roots/list")
    check peer.responseTo("r1")["error"]["code"].getInt() == -32601

  test "Given roots that changed, when the client notifies, then roots/list_changed is sent":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} = return @[]))
    waitFor client.notifyRootsListChanged()
    waitFor sleepAsync(5)
    check "notifications/roots/list_changed" in peer.sentMethods()

  test "Given roots declared without listChanged, when the client notifies, then McpUnsupportedError is raised":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} = return @[],
                              listChanged = false))
    expect McpUnsupportedError:
      waitFor client.notifyRootsListChanged()
    check "notifications/roots/list_changed" notin peer.sentMethods()

suite "notifications from the server":

  test "Given a log callback, when the server logs, then level, logger and data are passed":
    var seen: seq[McpLogMessage]
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    client.onLogMessage = proc(message: McpLogMessage) = seen.add message
    peer.push("notifications/message", %*{"level": "error", "logger": "db", "data": {"code": 5}})
    peer.push("notifications/message", %*{"level": "info", "data": "plain"})
    waitFor sleepAsync(5)
    check seen.len == 2
    check seen[0].level == "error"
    check seen[0].logger == some("db")
    check seen[0].data["code"].getInt() == 5
    check seen[1].logger.isNone

  test "Given a resource-updated callback, when the server reports an update, then the uri is passed":
    var uris: seq[string]
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    client.onResourceUpdated = proc(uri: string) = uris.add uri
    peer.push("notifications/resources/updated", %*{"uri": "file:///a"})
    waitFor sleepAsync(5)
    check uris == @["file:///a"]

  test "Given list-changed callbacks, when the server reports changes, then each callback fires once":
    var tools, resources, prompts = 0
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    client.onToolsListChanged = proc() = inc tools
    client.onResourcesListChanged = proc() = inc resources
    client.onPromptsListChanged = proc() = inc prompts
    peer.push("notifications/tools/list_changed")
    peer.push("notifications/resources/list_changed")
    peer.push("notifications/prompts/list_changed")
    waitFor sleepAsync(5)
    check (tools, resources, prompts) == (1, 1, 1)

  test "Given a callback that raises, when a notification arrives, then the client keeps receiving":
    var calls = 0
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    client.onToolsListChanged = proc() =
      inc calls
      raise newException(ValueError, "callback bug")
    peer.push("notifications/tools/list_changed")
    peer.push("notifications/tools/list_changed")
    waitFor sleepAsync(5)
    check calls == 2
    check client.state == mlsOperational

  test "Given no callbacks, when notifications arrive, then they are ignored":
    let peer = startPeer(nil)
    let client = peer.connectedClient(LegacyDefault)
    peer.push("notifications/message", %*{"level": "info", "data": 1})
    peer.push("notifications/tools/list_changed")
    waitFor sleepAsync(5)
    check client.state == mlsOperational

if SpeaksModern:
  suite "server requests in the 2026-07-28 protocol":

    test "Given a 2026-07-28 connection, when the server sends a request, then the client answers method not found":
      # The era has no server-initiated requests, even for a declared capability.
      let peer = startPeer(nil, modern = true)
      discard peer.connectedClient(DefaultProtocolVersion, proc(client: McpClient) =
        client.setSamplingHandler(echoSampler))
      for name in ["ping", "sampling/createMessage"]:
        peer.ask(%name, name, samplingParams)
        check peer.responseTo(name)["error"]["code"].getInt() == -32601
