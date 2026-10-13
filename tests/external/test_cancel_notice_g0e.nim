## What a server does with the cancellation notifications it receives and
## what it sends of its own (basic/utilities/cancellation, and
## basic/patterns/cancellation in 2026-07-28): it logs the reason, ignores a
## notification it cannot read, and in 2026-07-28 sends
## notifications/cancelled only to end a subscriptions/listen stream.

import std/[unittest, asyncdispatch, json, options, os, strutils]
import ./server_harness
import ./loopback_transport

var
  gate: Future[void]
  started: bool
  sawCancelled: bool

proc cancelServer(): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()),
    prompts: some(McpPromptsCapability(listChanged: true)),
    resources: some(McpResourcesCapability(subscribe: true, listChanged: true))))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "hold":
      started = true
      gate = newFuture[void]("gate")
      await gate
      sawCancelled = ctx.cancelled
      return %*{"content": [{"type": "text", "text": "held"}]}
    of "watch":
      started = true
      await ctx.whenCancelled
      return %*{"content": [{"type": "text", "text": "watched"}]}
    of "fail":
      raise newInvalidParams("bad arguments")
    else:
      raise newUnknownTool(name))

proc reset() =
  gate = nil
  started = false
  sawCancelled = false

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-cancel-notice-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

suite "a server logs why a request was cancelled (every version)":

  test "Given a request in flight, when the client cancels it with a reason, then the server says on stderr that it was cancelled and why":
    for v in SupportedProtocolVersions:
      reset()
      let server = cancelServer()
      let peer = server.connect(server.attach(), v)
      let id = freshId()
      peer.send(%id, "tools/call", %*{"name": "hold"})
      untilTrue("the handler to start", proc(): bool = started)
      let log = loggedWhile(proc() =
        peer.notify("notifications/cancelled", %*{"requestId": id, "reason": "user pressed stop"})
        settle())
      gate.complete()
      settle()
      check "cancelled" in log
      check "user pressed stop" in log

suite "a notification that cannot be read is ignored (every version)":

  test "Given a request in flight, when notifications/cancelled arrives malformed, then the request is not cancelled and is answered":
    let malformed = [
      %*{},
      %*{"requestId": nil},
      %*{"requestId": {"id": 1}},
      %*{"requestId": [1]},
      %*{"requestId": true},
      %*{"requestId": 1.5},
      %*{"reason": "no id"},
      %"not an object"]
    for v in SupportedProtocolVersions:
      for params in malformed:
        reset()
        let server = cancelServer()
        let t = server.attach()
        let peer = server.connect(t, v)
        let id = freshId()
        peer.send(%id, "tools/call", %*{"name": "hold"})
        untilTrue("the handler to start", proc(): bool = started)
        peer.notify("notifications/cancelled", params)
        settle()
        gate.complete()
        let answer = t.responseTo(id)
        check answer["result"]["content"][0]["text"].getStr() == "held"
        check not sawCancelled
        check t.dropped.len == 0
        check peer.ask("tools/call", %*{"name": "fail"}).errorCode == -32602

suite "a 2026-07-28 server cancels only subscriptions":

  test "Given requests that are cancelled, fail or end, when a subscription is ended by the server, then the only notifications/cancelled names the listen request":
    for v in versionsWith(ftSubscriptionsListen):
      reset()
      let server = cancelServer()
      let pair = newLoopbackPair()
      waitFor server.attachTransport(pair.server)
      let meta = modernMeta()
      pair.server.inject(%*{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "watch", "_meta": meta}})
      untilTrue("the handler to start", proc(): bool = started)
      pair.server.inject(%*{"jsonrpc": "2.0", "method": "notifications/cancelled",
        "params": {"requestId": 1, "reason": "enough"}})
      pair.server.inject(%*{"jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": "fail", "_meta": meta}})
      pair.server.inject(%*{"jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "nobody", "_meta": meta}})
      pair.server.inject(%*{"jsonrpc": "2.0", "id": 5, "method": "subscriptions/listen",
        "params": {"_meta": meta, "notifications": {"toolsListChanged": true}}})
      untilTrue("the acknowledgment", proc(): bool =
        for message in pair.server.sent:
          if message{"method"}.getStr() == "notifications/subscriptions/acknowledged":
            return true
        false)
      waitFor server.endSubscriptions()
      untilTrue("the answer to the listen request", proc(): bool =
        for message in pair.server.sent:
          if message{"id"}.getInt() == 5 and message.hasKey("result"):
            return true
        false)
      settle()
      var cancelled: seq[JsonNode]
      for message in pair.server.sent:
        if message{"method"}.getStr() == "notifications/cancelled":
          cancelled.add message
      check cancelled.len == 1
      check cancelled[0]["params"]["requestId"].getInt() == 5

  test "Given a 2026-07-28 session, when the server is asked to send a request to the client, then it refuses and sends nothing":
    for v in versionsWith(ftSubscriptionsListen):
      let server = cancelServer()
      let t = server.attach()
      discard server.connect(t, v)
      expect McpCapabilityError:
        discard waitFor server.request("", "ping", newJObject(), timeoutMs = 20)
      settle()
      check t.messagesOf("notifications/cancelled").len == 0
      check t.messagesOf("ping").len == 0
