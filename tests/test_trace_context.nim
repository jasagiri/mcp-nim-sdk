## OpenTelemetry trace context in `_meta` (2026-07-28, basic/index#meta):
## `traceparent`, `tracestate` and `baggage` follow the W3C formats, are
## accepted from a client, readable from the handler's context and carried
## on what the server sends for that request.

import std/[unittest, asyncdispatch, json, options, strutils]
import ./server_harness
import ./client_peer
import client/client
import protocol/trace_context

const
  Parent = "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"
  State = "congo=t61rcWkgMzE,rojo=00f067aa0ba902b7"
  Bag = "userId=alice,serverNode=DF%2028;prop=1"

proc echoServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability()),
                                           logging: some(McpLoggingCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    await ctx.reportProgress(1)
    await ctx.log(mllInfo, %"working")
    let seen = ctx.traceContext
    # As text: every version has text content, not every version has structuredContent.
    let report = %*{
      "traceparent": if seen.traceparent.isSome: %seen.traceparent.get else: newJNull(),
      "tracestate": if seen.tracestate.isSome: %seen.tracestate.get else: newJNull(),
      "baggage": if seen.baggage.isSome: %seen.baggage.get else: newJNull()}
    return %*{"content": [{"type": "text", "text": $report}]})

proc traceSeenByHandler(answer: JsonNode): JsonNode =
  parseJson(answer["result"]["content"][0]["text"].getStr())

suite "trace context values (W3C Trace Context and Baggage)":

  test "Given the specification's traceparent, when validated, then it is accepted":
    check validateTraceparent(Parent).isNone

  test "Given a traceparent of a later version with extra fields, when validated, then it is accepted":
    check validateTraceparent("01-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01-extra").isNone

  test "Given malformed traceparents, when validated, then each is rejected":
    for bad in ["", "garbage",
                "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7",
                "00-0AF7651916CD43DD8448EB211C80319C-00f067aa0ba902b7-01",
                "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
                "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01",
                "ff-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01",
                "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01-extra",
                "00-0af7651916cd43dd8448eb211c80319-00f067aa0ba902b7-01",
                "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-0g"]:
      check validateTraceparent(bad).isSome

  test "Given the specification's tracestate, when validated, then it is accepted":
    check validateTracestate(State).isNone
    check validateTracestate("fw529a3039@dd=1, rojo=2").isNone

  test "Given malformed tracestates, when validated, then each is rejected":
    for bad in ["", "novalue", "UPPER=1", "a=1,a=2", "a=b=c", "a=1,,b=2"]:
      check validateTracestate(bad).isSome
    var tooMany: seq[string]
    for i in 0 .. 32:
      tooMany.add "k" & $i & "=v"
    check validateTracestate(tooMany.join(",")).isSome

  test "Given a baggage header value, when validated, then well-formed members are accepted and malformed ones rejected":
    check validateBaggage(Bag).isNone
    check validateBaggage("key=value").isNone
    for bad in ["", "novalue", "=value", "bad key=1", "k=a b", "k=1,,j=2"]:
      check validateBaggage(bad).isSome

suite "trace context in _meta":

  test "Given params whose _meta carries trace context, when read, then each key is returned":
    let params = %*{"_meta": {"traceparent": Parent, "tracestate": State, "baggage": Bag}}
    let read = traceContextOf(params)
    check read.traceparent == some(Parent)
    check read.tracestate == some(State)
    check read.baggage == some(Bag)

  test "Given params without trace context, when read, then it is empty":
    check traceContextOf(%*{"_meta": {"progressToken": "p"}}).isEmpty
    check traceContextOf(nil).isEmpty
    check traceContextOf(%*{"name": "x"}).isEmpty

  test "Given a malformed or non-string value, when params are checked, then the rejection names the key as invalid params":
    let rejection = rejectInvalidTraceContext(%*{"_meta": {"traceparent": "garbage"}})
    check rejection.get.code == -32602
    check "traceparent" in rejection.get.message
    check rejectInvalidTraceContext(%*{"_meta": {"baggage": 5}}).get.code == -32602
    check rejectInvalidTraceContext(%*{"_meta": {"traceparent": Parent}}).isNone
    check rejectInvalidTraceContext(%*{"_meta": {}}).isNone

  test "Given a trace context, when added to params, then the other _meta keys stay and the original is untouched":
    let params = %*{"name": "x", "_meta": {"progressToken": "p"}}
    let context = TraceContext(traceparent: some(Parent), baggage: some(Bag))
    let sent = withTraceContext(params, context)
    check sent["_meta"]["progressToken"].getStr() == "p"
    check sent["_meta"]["traceparent"].getStr() == Parent
    check sent["_meta"]["baggage"].getStr() == Bag
    check not sent["_meta"].hasKey("tracestate")
    check not params["_meta"].hasKey("traceparent")

suite "trace context on the server (2026-07-28 only)":

  test "Given a request with trace context, when the handler runs, then ctx.traceContext holds what the client sent":
    for v in versionsWith(ftTraceContext):
      let server = echoServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "t"},
        meta = %*{"traceparent": Parent, "tracestate": State, "baggage": Bag})
      let seen = answer.traceSeenByHandler
      check seen["traceparent"].getStr() == Parent
      check seen["tracestate"].getStr() == State
      check seen["baggage"].getStr() == Bag

  test "Given a request without trace context, when the handler runs, then ctx.traceContext is empty":
    for v in versionsWith(ftTraceContext):
      let server = echoServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "t"})
      check answer.traceSeenByHandler["traceparent"].kind == JNull

  test "Given a request with trace context, when the handler reports progress and logs, then those notifications carry it":
    for v in versionsWith(ftTraceContext):
      let server = echoServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      discard peer.ask("tools/call", %*{"name": "t"},
        meta = %*{"traceparent": Parent, "tracestate": State, "progressToken": "p",
                  "io.modelcontextprotocol/logLevel": "debug"})
      for methodName in ["notifications/progress", "notifications/message"]:
        let sent = t.messagesOf(methodName)
        check sent.len == 1
        check sent[0].message["params"]["_meta"]["traceparent"].getStr() == Parent
        check sent[0].message["params"]["_meta"]["tracestate"].getStr() == State
        check not sent[0].message["params"]["_meta"].hasKey("baggage")

  test "Given a malformed traceparent, when the request arrives, then it is rejected as invalid params and no handler runs":
    for v in versionsWith(ftTraceContext):
      let server = echoServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      let answer = peer.ask("tools/call", %*{"name": "t"}, meta = %*{"traceparent": "garbage"})
      check answer.errorCode == -32602
      check "traceparent" in answer["error"]["message"].getStr()

  test "Given a version without trace context, when a request carries the keys, then the handler sees none and notifications carry none":
    for v in versionsWithout(ftTraceContext):
      let server = echoServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      let answer = peer.ask("tools/call", %*{"name": "t"},
        meta = %*{"traceparent": Parent, "progressToken": "p"})
      check answer.traceSeenByHandler["traceparent"].kind == JNull
      let progress = t.messagesOf("notifications/progress")
      check progress.len == 1
      check not progress[0].message["params"].hasKey("_meta")

suite "trace context on the client":

  test "Given a modern server and a trace context in the options, when a request is sent, then its _meta carries it":
    for v in versionsWith(ftTraceContext):
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          peer.reply(message["id"], %*{"resultType": "complete", "tools": []}), modern = true)
      let client = peer.connectedClient(v)
      discard waitFor client.sendRequest("tools/list", newJObject(), McpRequestOptions(
        traceContext: TraceContext(traceparent: some(Parent), tracestate: some(State),
                                   baggage: some(Bag))))
      let meta = peer.requestsFor("tools/list")[0]["params"]["_meta"]
      check meta["traceparent"].getStr() == Parent
      check meta["tracestate"].getStr() == State
      check meta["baggage"].getStr() == Bag
      check meta.hasKey("io.modelcontextprotocol/protocolVersion")

  test "Given a malformed trace context in the options, when a request is sent, then it raises and nothing is sent":
    for v in versionsWith(ftTraceContext):
      let peer = startPeer(nil, modern = true)
      let client = peer.connectedClient(v)
      expect ValueError:
        discard waitFor client.sendRequest("tools/list", newJObject(), McpRequestOptions(
          traceContext: TraceContext(traceparent: some("garbage"))))
      check peer.requestsFor("tools/list").len == 0

  test "Given a legacy version, when a request has a trace context in the options, then the keys are not sent":
    for v in versionsWithout(ftTraceContext):
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          peer.reply(message["id"], %*{"tools": []}))
      let client = peer.connectedClient(v)
      discard waitFor client.sendRequest("tools/list", newJObject(), McpRequestOptions(
        traceContext: TraceContext(traceparent: some(Parent))))
      let sent = peer.requestsFor("tools/list")[0]
      check not sent["params"].hasKey("_meta")
