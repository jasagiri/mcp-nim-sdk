## What a client does with a sampling request, said as properties: it takes
## only messages with a role of user or assistant and a content block, whatever
## the server sends, and it passes on whatever stop reason its handler gives.

import std/[unittest, asyncdispatch, json, options]
import client/client
import client/content
import client/sampling
import protocol/features
import protocol/types
import propcheck
import ./client_peer

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

let Hello = %*{"type": "text", "text": "hello"}

proc modernVersions(): seq[McpProtocolVersion] =
  for v in SupportedProtocolVersions:
    if v.has(ftMultiRoundTripRequests):
      result.add v

proc responseTo(peer: Peer, id: string): JsonNode =
  waitFor sleepAsync(5)
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
      return message
  nil

proc requestOf(messages: JsonNode): JsonNode =
  %*{"messages": messages, "maxTokens": 10}

proc samplerGiving(reason: string): proc(request: McpSamplingRequest): Future[McpSamplingResult] =
  result = proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
    return McpSamplingResult(role: "assistant", model: "m", stopReason: some(reason),
                             content: McpContentItem(kind: mckText, text: "ok"))

proc inputRequired(requests: JsonNode): JsonNode =
  %*{"resultType": "input_required", "inputRequests": requests}

proc askedOnce(first: JsonNode): proc(peer: Peer, message: JsonNode) =
  ## A server whose first tools/call needs input and whose retry completes.
  var seen = 0
  result = proc(peer: Peer, message: JsonNode) =
    if message{"method"}.getStr() == "tools/call":
      peer.reply(message["id"], if seen == 0: first
                                else: %*{"resultType": "complete", "content": []})
      inc seen

type
  Messages = object
    version: McpProtocolVersion
    list: JsonNode
    wellFormed: bool    ## every message made with a role of user or assistant and a content block

proc messageOf(x: (int, (int, (string, int)))): (JsonNode, bool) =
  ## Space of one message: a good one (a user or an assistant, with a text or an image block), one
  ## with a role that is another string, a number or missing, and one with a content that is
  ## missing, a string, null, a number or a boolean.
  let (mode, (choice, (other, number))) = x
  let good = if choice mod 2 == 0: %*{"type": "text", "text": other}
             else: %*{"type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"}
  let goodRole = if choice mod 4 < 2: "user" else: "assistant"
  case mode
  of 0, 1: (%*{"role": goodRole, "content": good}, true)
  of 2:
    case choice mod 3
    of 0: (%*{"role": ["system", "tool", "User", "ASSISTANT", other][choice mod 5], "content": good}, false)
    of 1: (%*{"role": number, "content": good}, false)
    else: (%*{"content": good}, false)
  else:
    case choice mod 5
    of 0: (%*{"role": goodRole}, false)
    of 1: (%*{"role": goodRole, "content": other}, false)
    of 2: (%*{"role": goodRole, "content": nil}, false)
    of 3: (%*{"role": goodRole, "content": number}, false)
    else: (%*{"role": goodRole, "content": number mod 2 == 0}, false)

let
  anyMessage = map(
    pair(intIn(0, 3), pair(intIn(0, 11), pair(stringOf("abc xyz", 0, 6), intIn(0, 50)))),
    proc(x: (int, (int, (string, int)))): (JsonNode, bool) {.raises: [].} = messageOf(x))

proc anyMessages(versions: seq[McpProtocolVersion]): Gen[Messages] =
  map(pair(pick(versions), seqOf(anyMessage, 1, 3)),
    proc(x: (McpProtocolVersion, seq[(JsonNode, bool)])): Messages {.raises: [].} =
      var list = newJArray()
      var ok = true
      for (message, good) in x[1]:
        list.add message
        ok = ok and good
      Messages(version: x[0], list: list, wellFormed: ok))

type
  Stop = object
    version: McpProtocolVersion
    reason: string
    withTools: bool

const Listed = ["endTurn", "stopSequence", "maxTokens", "toolUse"]

proc anyStop(versions: seq[McpProtocolVersion], toolsToo: bool): Gen[Stop] =
  # Space: any string the specification does not list as a stop reason (empty ones included),
  # with tools in the request when the version has them and without.
  map(pair(pair(pick(versions), boolean()), stringOf("abcdeABCDE0123-_ ", 0, 12)),
    proc(x: ((McpProtocolVersion, bool), string)): Stop {.raises: [].} =
      var reason = x[1]
      for known in Listed:
        if reason == known: reason.add "_"
      Stop(version: x[0][0], reason: reason, withTools: toolsToo and x[0][1]))

suite "a sampling request that reaches a client before 2026-07-28":

  test "Given any messages, when the server asks, then the client answers invalid params and the handler is not called unless every message has a role of user or assistant and a content block, and then the handler is called":
    let outcome = propcheck.check(anyMessages(@[LegacyDefault]),
      guarded(proc(m: Messages): bool =
        var called = 0
        let peer = startPeer(nil)
        discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
          client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
            inc called
            return await samplerGiving("endTurn")(request)))
        peer.ask(%"s1", "sampling/createMessage", requestOf(m.list))
        let reply = peer.responseTo("s1")
        if reply.isNil: return false
        if m.wellFormed:
          reply.hasKey("result") and called == 1
        else:
          reply{"error"}{"code"}.getInt() == -32602 and called == 0))
    checkpoint describe(outcome)
    check outcome.passed

suite "a sampling request that reaches a client from 2026-07-28":

  test "Given any messages in an input request, when the client reads it, then it abandons the request with invalid params, without calling the handler or retrying, unless every message is good, and then it calls the handler and retries":
    let versions = modernVersions()
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyMessages(versions),
        guarded(proc(m: Messages): bool =
          var called = 0
          let peer = startPeer(askedOnce(inputRequired(%*{"ask": {
            "method": "sampling/createMessage", "params": requestOf(m.list)}})), modern = true)
          let client = peer.connectedClient(m.version, proc(client: McpClient) =
            client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
              inc called
              return await samplerGiving("endTurn")(request)))
          var refusal = 0
          try:
            discard waitFor client.callMethod("tools/call", %*{"name": "t"})
          except McpRequestError as e:
            refusal = e.code
          if m.wellFormed:
            refusal == 0 and called == 1 and peer.requestsFor("tools/call").len == 2
          else:
            refusal == -32602 and called == 0 and peer.requestsFor("tools/call").len == 1))
      checkpoint describe(outcome)
      check outcome.passed

suite "the stop reason of a client's sampling answer":

  test "Given any stopReason the specification does not list in a handler's answer, when the server asks, then the answer carries that stopReason":
    let outcome = propcheck.check(anyStop(@[LegacyDefault], false),
      guarded(proc(s: Stop): bool =
        let peer = startPeer(nil)
        discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
          client.setSamplingHandler(samplerGiving(s.reason)))
        peer.ask(%"s1", "sampling/createMessage",
                 requestOf(%*[{"role": "user", "content": Hello}]))
        let reply = peer.responseTo("s1")
        not reply.isNil and reply{"result"}{"stopReason"}.getStr("<none>") == s.reason))
    checkpoint describe(outcome)
    check outcome.passed

  test "Given any stopReason the specification does not list in a handler's answer, when the server asks for input, then the retry carries that stopReason":
    let versions = modernVersions()
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyStop(versions, false),
        guarded(proc(s: Stop): bool =
          let peer = startPeer(askedOnce(inputRequired(%*{"ask": {
            "method": "sampling/createMessage",
            "params": requestOf(%*[{"role": "user", "content": Hello}])}})), modern = true)
          let client = peer.connectedClient(s.version, proc(client: McpClient) =
            client.setSamplingHandler(samplerGiving(s.reason)))
          discard waitFor client.callMethod("tools/call", %*{"name": "t"})
          let retry = peer.requestsFor("tools/call")[1]["params"]
          retry{"inputResponses"}{"ask"}{"stopReason"}.getStr("<none>") == s.reason))
      checkpoint describe(outcome)
      check outcome.passed
