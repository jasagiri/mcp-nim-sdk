## What a client puts on the wire, as the base protocol and the lifecycle fix
## it: the ids of its requests, notifications without an id, the clientInfo of
## initialize, what it does not ask of a
## server that did not declare it, and a timeout that progress does not extend.

import std/[unittest, asyncdispatch, json, options, sets, strutils]
import mcp
import ./client_peer

proc answeringEverything(peer: Peer, message: JsonNode) =
  if message.hasKey("id") and message.hasKey("method"):
    peer.reply(message["id"], %*{"tools": [], "resources": [], "prompts": []})

proc requestsOf(peer: Peer): seq[JsonNode] =
  for message in peer.received:
    if message.hasKey("id") and message.hasKey("method"):
      result.add message

suite "ids of the requests a client sends":

  test "Given a client that makes several requests, when they are sent, then every id is a string, none is empty and none is used twice":
    for v in SupportedProtocolVersions:
      let peer = startPeer(answeringEverything, modern = isModern(v))
      let client = peer.connectedClient(v)
      for _ in 1 .. 3:
        discard waitFor client.sendRequest("tools/list", newJObject())
      discard waitFor client.sendRequest("resources/list", newJObject())
      discard waitFor client.sendRequest("prompts/list", newJObject())
      let requests = peer.requestsOf()
      check requests.len >= 6
      var seen = initHashSet[string]()
      for request in requests:
        check request["id"].kind == JString
        check request["id"].getStr().len > 0
        check request["id"].getStr() notin seen
        seen.incl request["id"].getStr()
      check seen.len == requests.len

  test "Given requests that time out and requests that are answered, when they are sent, then no id is used twice":
    for v in SupportedProtocolVersions:
      let handler = proc(peer: Peer, message: JsonNode) =
        if message{"params"}{"cursor"}.getStr() == "answer":
          peer.reply(message["id"], %*{"tools": []})
      let peer = startPeer(handler, modern = isModern(v))
      let client = peer.connectedClient(v)
      for _ in 1 .. 2:
        expect McpTimeoutError:
          discard waitFor client.sendRequest("tools/list", newJObject(),
            McpRequestOptions(timeoutMs: some(10)))
        discard waitFor client.sendRequest("tools/list", %*{"cursor": "answer"})
      var seen = initHashSet[string]()
      for request in peer.requestsOf():
        check request["id"].getStr() notin seen
        seen.incl request["id"].getStr()

suite "notifications a client sends":

  test "Given a client that connects and gives up a request, when it notifies, then no notification carries an id":
    for v in SupportedProtocolVersions:
      let peer = startPeer(nil, modern = isModern(v))
      let client = peer.connectedClient(v)
      expect McpTimeoutError:
        discard waitFor client.sendRequest("tools/list", newJObject(),
          McpRequestOptions(timeoutMs: some(10)))
      waitFor sleepAsync(5)
      var notifications = 0
      for message in peer.received:
        if message{"method"}.getStr().startsWith("notifications/"):
          inc notifications
          check not message.hasKey("id")
      check notifications >= 1
      if not isModern(v):
        check "notifications/initialized" in peer.sentMethods()

suite "initialize of a client":

  test "Given a client of a version before 2026-07-28, when it connects, then initialize carries its name and version as clientInfo":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let peer = startPeer(nil)
      discard peer.connectedClient(v)
      let initialize = peer.requestsFor("initialize")
      check initialize.len == 1
      let info = initialize[0]["params"]["clientInfo"]
      check info.kind == JObject
      check info["name"].getStr() == "test-client"
      check info["version"].getStr() == "0"

suite "a client and the capabilities of a server":

  proc sentOnlyTheHandshake(peer: Peer): bool =
    for name in peer.sentMethods():
      if name notin ["server/discover", "initialize", "notifications/initialized"]:
        return false
    true

  test "Given a server that declares only prompts, when the client lists tools or reads resources, then it fails naming the capability and sends nothing":
    for v in SupportedProtocolVersions:
      let peer = startPeer(nil, modern = isModern(v), capabilities = %*{"prompts": {}})
      let client = peer.connectedClient(v)
      expect McpUnsupportedError:
        discard waitFor client.listTools()
      expect McpUnsupportedError:
        discard waitFor client.callTool("t")
      expect McpUnsupportedError:
        discard waitFor client.listResources()
      expect McpUnsupportedError:
        discard waitFor client.readResource("file:///a")
      check peer.sentOnlyTheHandshake()

  test "Given a server that declares only tools, when the client lists prompts or gets one, then it fails naming the capability and sends nothing":
    for v in SupportedProtocolVersions:
      let peer = startPeer(nil, modern = isModern(v), capabilities = %*{"tools": {}})
      let client = peer.connectedClient(v)
      expect McpUnsupportedError:
        discard waitFor client.listPrompts()
      expect McpUnsupportedError:
        discard waitFor client.getPrompt("p")
      check peer.sentOnlyTheHandshake()

  test "Given a server without logging or resource subscriptions, when the client sets a level or subscribes, then it fails and sends nothing":
    for v in SupportedProtocolVersions:
      let peer = startPeer(nil, modern = isModern(v),
                           capabilities = %*{"tools": {}, "resources": {}})
      let client = peer.connectedClient(v)
      expect McpUnsupportedError:
        waitFor client.setLoggingLevel(mllInfo)
      expect McpUnsupportedError:
        waitFor client.subscribeResource("file:///a")
      check peer.sentOnlyTheHandshake()

suite "timeouts and progress":

  proc streamProgress(peer: Peer, token: JsonNode, total: int,
                      sent: ref int) {.async.} =
    for step in 1 .. total:
      await sleepAsync(10)
      peer.push("notifications/progress", %*{"progressToken": token, "progress": step})
      inc sent[]

  test "Given a request that has a timeout, when progress keeps arriving, then the request still times out before the progress ends":
    for v in SupportedProtocolVersions:
      let sent = new int
      let handler = proc(peer: Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          let token = message["params"]["_meta"]["progressToken"]
          asyncCheck streamProgress(peer, token, 40, sent)
      let peer = startPeer(handler, modern = isModern(v))
      let client = peer.connectedClient(v)
      var updates = 0
      expect McpTimeoutError:
        discard waitFor client.sendRequest("tools/list", newJObject(), McpRequestOptions(
          timeoutMs: some(60),
          onProgress: proc(update: McpProgress) = inc updates))
      check updates >= 1
      check sent[] < 40

suite "reserved _meta keys in the request of a client":

  test "Given a request whose _meta holds reserved keys the SDK does not define, when the client sends it, then they go out with the values they had":
    let keys = ["io.modelcontextprotocol/not-defined-here", "mcp.dev/not-defined-here"]
    let values = [newJNull(), %5, %"text", %*[1, "a"], %*{"nested": true}]
    for v in SupportedProtocolVersions:
      let peer = startPeer(answeringEverything, modern = isModern(v))
      let client = peer.connectedClient(v)
      for value in values:
        let meta = newJObject()
        for key in keys:
          meta[key] = value
        discard waitFor client.sendRequest("tools/list", %*{"_meta": meta})
        let sent = peer.requestsFor("tools/list")[^1]["params"]["_meta"]
        for key in keys:
          check sent.hasKey(key)
          check sent[key] == value
