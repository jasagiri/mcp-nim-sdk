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

  test "Given traceparent fields of the wrong length or alphabet, when validated, then each is rejected":
    # W3C Trace Context 3.2.2: version and flags are two, trace-id 32 and parent-id 16 lowercase hex digits.
    for bad in ["000-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01",
                "0g-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01",
                "00-0af7651916cd43dd8448eb211c80319g-00f067aa0ba902b7-01",
                "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b71-01",
                "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902bg-01",
                "00-0af7651916cd43dd8448eb211c80319c-00F067AA0BA902B7-01",
                "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-001",
                "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-"]:
      check validateTraceparent(bad).isSome

  test "Given tracestate keys outside the simple-key and multi-tenant grammars, when validated, then each is rejected":
    # W3C Trace Context 3.3.1.3.1: a simple key starts with a lowercase letter and has at most 256
    # characters; a tenant (at most 241) may also start with a digit, the system id (at most 14) may not.
    for bad in ["1a=1", "_a=1", "=1", "A=1", "a b=1",
                "a".repeat(257) & "=1",
                "@sys=1", "t@=1", "_a@sys=1", "aB@sys=1",
                "a".repeat(242) & "@sys=1",
                "t@1x=1", "t@sysTEM=1", "t@" & "b".repeat(15) & "=1"]:
      check validateTracestate(bad).isSome

  test "Given tracestate keys at the edge of the grammars, when validated, then they are accepted":
    for good in ["a_b-c*d/e=1", "1a@sys=1", "a".repeat(256) & "=1",
                 "a".repeat(241) & "@" & "b".repeat(14) & "=1"]:
      check validateTracestate(good).isNone

  test "Given a tracestate value, when its length is checked, then 256 characters are accepted and 257 characters or none are not":
    # W3C Trace Context 3.3.1.3.2: value = 0*255(chr) nblk-chr, so at least one character, the last not blank.
    check validateTracestate("a=" & "v".repeat(256)).isNone
    check validateTracestate("a=" & "v".repeat(257)).isSome
    check validateTracestate("a=").isSome
    check validateTracestate("a=b c").isNone  # blanks inside a value are characters of it

  test "Given a tracestate of 32 members, when validated, then it is accepted":
    # W3C Trace Context 3.3.1.1: at most 32 list-members.
    var members: seq[string]
    for i in 0 ..< 32:
      members.add "k" & $i & "=v"
    check validateTracestate(members.join(",")).isNone

  test "Given a baggage at the size limits, when validated, then 8192 bytes and 64 members are accepted and one more of either is not":
    # W3C Baggage 3.2.1: at least 64 list-members and 8192 bytes are to be kept.
    check validateBaggage("k=" & "v".repeat(8190)).isNone
    check validateBaggage("k=" & "v".repeat(8191)).isSome
    var members: seq[string]
    for i in 0 ..< 64:
      members.add "k" & $i & "=v"
    check validateBaggage(members.join(",")).isNone
    members.add "k64=v"
    check validateBaggage(members.join(",")).isSome

  test "Given blanks around the equals signs of baggage members and properties, when validated, then they are accepted":
    # W3C Baggage: list-member = key OWS "=" OWS value; property = key OWS "=" OWS value.
    check validateBaggage("key = value").isNone
    check validateBaggage("k=v;p = x").isNone
    check validateBaggage("k = v ; p = x , j=w").isNone

  test "Given a baggage property that is not a token or a token=value, when validated, then it is rejected":
    for bad in ["k=v;", "k=v;bad prop", "k=v;=x", "k=v;bad key=1", "k=v;p=a b"]:
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

  test "Given a malformed tracestate or baggage, when a context or params are checked, then each is reported":
    check validate(TraceContext(tracestate: some("UPPER=1"))).isSome
    check validate(TraceContext(baggage: some("novalue"))).isSome
    check validate(TraceContext(traceparent: some(Parent), tracestate: some(State),
                                baggage: some(Bag))).isNone
    check validate(TraceContext()).isNone
    for key in ["tracestate", "baggage"]:
      let rejection = rejectInvalidTraceContext(%*{"_meta": {key: "="}})
      check rejection.get.code == -32602
      check key in rejection.get.message
    check rejectInvalidTraceContext(%*{"name": "x"}).isNone
    check rejectInvalidTraceContext(nil).isNone

  test "Given params that are absent or not an object, when a trace context is added, then params with only the context's _meta result":
    let context = TraceContext(traceparent: some(Parent))
    check withTraceContext(nil, context)["_meta"]["traceparent"].getStr() == Parent
    check withTraceContext(%"text", context)["_meta"]["traceparent"].getStr() == Parent
    check withTraceContext(%[1, 2], context).kind == JObject

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
