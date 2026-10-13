## Progress tokens and values (basic/utilities/progress, basic/patterns/progress
## in 2026-07-28), and how a progress notification meets a request timeout
## (basic/patterns/cancellation, Timeouts).

import std/[unittest, asyncdispatch, json, options, sets, times]
import client/client
import protocol/types
import ./client_peer
import ./server_harness

proc tokenOf(request: JsonNode): string =
  request["params"]["_meta"]["progressToken"].getStr()

proc askWithProgress(client: McpClient, seen: ref seq[McpProgress]): Future[JsonRpcResponse] =
  client.sendRequest("tools/list", newJObject(), McpRequestOptions(
    onProgress: proc(update: McpProgress) = seen[].add update))

suite "progress tokens are unique across active requests (every version)":

  test "Given many requests active at once, when the client sends them with progress callbacks, then no two carry the same token, and a token is not reused after one ends":
    for v in SupportedProtocolVersions:
      let peer = startPeer(nil, modern = isModern(v))
      let client = peer.connectedClient(v)
      let seen = new(seq[McpProgress])
      var pending: seq[Future[JsonRpcResponse]]
      for _ in 1 .. 12:
        pending.add client.askWithProgress(seen)
      untilTrue("all requests to be sent", proc(): bool = peer.requestsFor("tools/list").len == 12)
      var tokens = initHashSet[string]()
      for request in peer.requestsFor("tools/list"):
        check request.tokenOf notin tokens
        tokens.incl request.tokenOf
      # The first six end; their tokens are free to be taken again, and the
      # requests that follow must still not collide with the six that stay.
      for request in peer.requestsFor("tools/list")[0 ..< 6]:
        peer.reply(request["id"], newJObject())
      for index in 0 ..< 6:
        discard waitFor pending[index]
      for _ in 1 .. 6:
        pending.add client.askWithProgress(seen)
      untilTrue("the later requests to be sent", proc(): bool = peer.requestsFor("tools/list").len == 18)
      var active = initHashSet[string]()
      for request in peer.requestsFor("tools/list")[6 .. ^1]:
        check request.tokenOf notin active
        active.incl request.tokenOf
      check active.len == 12
      for request in peer.requestsFor("tools/list")[6 .. ^1]:
        peer.reply(request["id"], newJObject())
      for index in 6 ..< pending.len:
        discard waitFor pending[index]

suite "progress and total may be floating point (every version)":

  test "Given a server that sends fractional progress and total, when the client has a callback, then the callback sees the exact values":
    for v in SupportedProtocolVersions:
      let peer = startPeer(nil, modern = isModern(v))
      let client = peer.connectedClient(v)
      let seen = new(seq[McpProgress])
      let pending = client.askWithProgress(seen)
      untilTrue("the request to be sent", proc(): bool = peer.requestsFor("tools/list").len == 1)
      let request = peer.requestsFor("tools/list")[0]
      peer.push("notifications/progress", %*{"progressToken": request.tokenOf,
        "progress": 0.25, "total": 1.5})
      peer.push("notifications/progress", %*{"progressToken": request.tokenOf,
        "progress": 0.75})
      peer.reply(request["id"], newJObject())
      discard waitFor pending
      check seen[].len == 2
      check seen[][0].progress == 0.25
      check seen[][0].total == some(1.5)
      check seen[][1].progress == 0.75
      check seen[][1].total.isNone

  test "Given a handler that reports fractional progress and total, when the client has a token, then they are sent as given":
    for v in SupportedProtocolVersions:
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        await ctx.reportProgress(0.125, some(0.5))
        await ctx.reportProgress(0.375, some(0.5))
        return %*{"content": [{"type": "text", "text": "done"}]})
      let t = server.attach()
      discard server.connect(t, v).ask("tools/call", %*{"name": "t"},
        meta = %*{"progressToken": "p"})
      let sent = t.messagesOf("notifications/progress")
      check sent.len == 2
      check sent[0].message["params"]["progress"].getFloat() == 0.125
      check sent[0].message["params"]["total"].getFloat() == 0.5
      check sent[1].message["params"]["progress"].getFloat() == 0.375

suite "a timeout holds while progress arrives (every version)":

  test "Given a server that keeps sending progress, when the request's timeout passes, then the request times out and the server is told":
    for v in SupportedProtocolVersions:
      let peer = startPeer(nil, modern = isModern(v))
      let client = peer.connectedClient(v)
      let seen = new(seq[McpProgress])
      proc keepSending() {.async.} =
        while peer.requestsFor("tools/list").len == 0:
          await sleepAsync(2)
        let token = peer.requestsFor("tools/list")[0].tokenOf
        for step in 1 .. 20:
          await sleepAsync(40)
          peer.push("notifications/progress", %*{"progressToken": token, "progress": step})
      asyncCheck keepSending()
      let started = epochTime()
      expect McpTimeoutError:
        discard waitFor client.sendRequest("tools/list", newJObject(), McpRequestOptions(
          timeoutMs: some(300),
          onProgress: proc(update: McpProgress) = seen[].add update))
      let elapsed = epochTime() - started
      check elapsed < 0.7
      check seen[].len >= 3
      waitFor sleepAsync(10)
      let cancelled = peer.requestsFor("notifications/cancelled")
      check cancelled.len == 1
      check cancelled[0]["params"]["requestId"] == peer.requestsFor("tools/list")[0]["id"]
