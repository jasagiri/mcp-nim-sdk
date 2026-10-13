## Progress tokens and timeouts (basic/utilities/progress, basic/patterns/
## progress and cancellation), said as properties: no two active requests
## carry the same token however requests start and end, and a request times
## out at its timeout whatever progress arrives.

import std/[unittest, asyncdispatch, json, options, sets, strutils, times]
import propcheck
import client/client
import protocol/types
import ./client_peer
import ./server_harness

proc guarded[T](body: proc(x: T): bool): Property[T] =
  ## A property whose body may raise what the SDK's setup raises: anything it raises
  ## is a counterexample, named by its type and message.
  result = proc(x: T): bool {.raises: [CatchableError].} =
    try:
      body(x)
    except CatchableError:
      raise
    except Exception as e:
      raise newException(CatchableError, "raised " & $e.name & ": " & e.msg)

proc tokenOf(request: JsonNode): string =
  ## The token as it is written on the wire, whatever its type.
  $request["params"]["_meta"]["progressToken"]

proc askWithProgress(client: McpClient, seen: ref seq[McpProgress]): Future[JsonRpcResponse] =
  client.sendRequest("tools/list", newJObject(), McpRequestOptions(
    onProgress: proc(update: McpProgress) = seen[].add update))

# --- tokens of the active requests (MCP-PROGRESS-8) ----------------------------------------------

type
  Script = object
    version: McpProtocolVersion
    steps: seq[(int, int)]    ## a request is sent (0, 1), or the one at this place among the active ones ends (2, place)

let
  anyScript = map(
    pair(pick(SupportedProtocolVersions), seqOf(pair(intIn(0, 2), intIn(0, 40)), 1, 24)),
    proc(x: (McpProtocolVersion, seq[(int, int)])): Script {.raises: [].} =
      Script(version: x[0], steps: x[1]))

suite "progress tokens are unique across active requests (every version)":

  test "Given any number of requests active at once, each sent with a progress callback, when some end and more are sent, then no two active requests carry the same progressToken":
    # Space: a run of one to twenty-four steps, each a request sent with a progress callback or
    # an active one (any of them) answered; so any number of requests are active, and
    # tokens of ended requests are free to be taken again.
    let outcome = propcheck.check(anyScript,
      guarded(proc(s: Script): bool =
        let peer = startPeer(nil, modern = isModern(s.version))
        let client = peer.connectedClient(s.version)
        let seen = new(seq[McpProgress])
        var active: seq[(JsonNode, Future[JsonRpcResponse], string)]   # the request id, its future, its token
        var sent = 0
        for (kind, place) in s.steps:
          if kind < 2 or active.len == 0:
            let pending = client.askWithProgress(seen)
            inc sent
            untilTrue("the request to be sent", proc(): bool = peer.requestsFor("tools/list").len == sent)
            let request = peer.requestsFor("tools/list")[sent - 1]
            for (_, _, token) in active:
              if token == request.tokenOf:
                return false
            active.add (request["id"], pending, request.tokenOf)
          else:
            let (id, pending, _) = active[place mod active.len]
            peer.reply(id, newJObject())
            discard waitFor pending
            active.delete(place mod active.len)
        for (id, pending, _) in active:
          peer.reply(id, newJObject())
          discard waitFor pending
        true))
    checkpoint describe(outcome)
    check outcome.passed

# --- a timeout holds while progress arrives (MCP-PROGRESS-7) ---------------------------------------

type
  Timing = object
    version: McpProtocolVersion
    timeoutMs: int
    everyMs: int      ## how often the server sends progress

let
  anyTiming = map(
    pair(pick(SupportedProtocolVersions), pair(intIn(150, 300), intIn(10, 40))),
    proc(x: (McpProtocolVersion, (int, int))): Timing {.raises: [].} =
      Timing(version: x[0], timeoutMs: x[1][0], everyMs: x[1][1]))

suite "a timeout holds while progress arrives (every version)":

  test "Given any pace at which a server keeps sending progress past the timeout, when the request's timeout passes, then the request times out at its timeout, the progress before it was delivered, and the server is told":
    # Space: a timeout of 150 to 300 ms and progress every 10 to 40 ms, sent until three times
    # the timeout. Twenty values, not a hundred: each takes the time of its timeout (100 would take 25 s).
    let outcome = propcheck.check(anyTiming,
      guarded(proc(t: Timing): bool =
        let peer = startPeer(nil, modern = isModern(t.version))
        let client = peer.connectedClient(t.version)
        let seen = new(seq[McpProgress])
        let pushedAt = new(seq[float])      # when each progress notification was sent
        proc keepSending() {.async.} =
          while peer.requestsFor("tools/list").len == 0:
            await sleepAsync(2)
          let token = peer.requestsFor("tools/list")[0]["params"]["_meta"]["progressToken"]
          for step in 1 .. (3 * t.timeoutMs) div t.everyMs:
            await sleepAsync(t.everyMs)
            pushedAt[].add epochTime()
            peer.push("notifications/progress", %*{"progressToken": token, "progress": step})
        asyncCheck keepSending()
        let started = epochTime()
        var timedOut = false
        try:
          discard waitFor client.sendRequest("tools/list", newJObject(), McpRequestOptions(
            timeoutMs: some(t.timeoutMs),
            onProgress: proc(update: McpProgress) = seen[].add update))
        except McpTimeoutError:
          timedOut = true
        let elapsedMs = (epochTime() - started) * 1000.0
        let pushedByThen = pushedAt[].len
        waitFor sleepAsync(10)
        let cancelled = peer.requestsFor("notifications/cancelled")
        # A value sent at least 50 ms before the timeout has been delivered (a busy machine sends
        # fewer, so the pace is counted as it happened). Late is not measured by the clock, which
        # a busy machine stretches: a timeout that progress put back would come only after the
        # server stopped sending, so the server must still have been sending when it came.
        var due = 0
        for at in pushedAt[]:
          if at <= started + float(t.timeoutMs - 50) / 1000.0:
            inc due
        var why: seq[string]
        if not timedOut: why.add "no timeout error"
        if elapsedMs < float(t.timeoutMs) * 0.9: why.add "timed out early: " & $elapsedMs & " ms"
        if pushedByThen >= (3 * t.timeoutMs) div t.everyMs:
          why.add "timed out only after the progress stopped: " & $elapsedMs & " ms"
        if seen[].len < due: why.add "delivered " & $seen[].len & " of " & $due & " values sent before the timeout"
        if cancelled.len != 1: why.add "cancellations sent: " & $cancelled.len
        elif cancelled[0]["params"]["requestId"] != peer.requestsFor("tools/list")[0]["id"]:
          why.add "cancelled another request"
        if why.len > 0:
          raise newException(ValueError, why.join("; "))
        true),
      CheckConfig(runs: 20, seed: 0, maxShrinks: 2000))
    checkpoint describe(outcome)
    check outcome.passed
