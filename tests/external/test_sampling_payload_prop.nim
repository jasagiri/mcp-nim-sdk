## What a server sends and accepts in sampling, said as properties: every
## message has a role of user or assistant and a content block, whatever the
## handler hands over, and a stop reason is whatever string the client's model
## gave.

import std/[unittest, asyncdispatch, json, options]
import server/mrtr
import propcheck
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

let
  WithSampling = %*{"sampling": {}}
  WithSamplingTools = %*{"sampling": {"tools": {}}}
  Hello = %*{"type": "text", "text": "hello"}

proc askingVersions(feature = ftServerInitiatedRequests): seq[McpProtocolVersion] =
  ## The versions in which the server asks the client itself, and that have `feature`.
  for v in versionsWith(feature):
    if v.has(ftServerInitiatedRequests):
      result.add v

proc requestsOf(messages: JsonNode): JsonNode =
  %*{"messages": messages, "maxTokens": 10}

proc awaitRequest(t: SessionedTransport, methodName: string): Sent =
  untilTrue("the server's " & methodName, proc(): bool = t.messagesOf(methodName).len > 0)
  t.messagesOf(methodName)[0]

proc answer(t: SessionedTransport, asked: Sent, resultNode: JsonNode) =
  t.inject(asked.session, %*{"jsonrpc": "2.0", "id": asked.message["id"], "result": resultNode})

proc caps(capabilities: JsonNode): JsonNode =
  %*{"io.modelcontextprotocol/clientCapabilities": capabilities}

proc askingServer(): McpServer =
  ## A tool that asks the client's model the messages it is given.
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    discard ctx.requireInput("ask", "sampling/createMessage", requestsOf(arguments["messages"]))
    return %*{"content": []})

# --- the messages ----------------------------------------------------------------------

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

suite "the messages of a sampling request, sent before 2026-07-28":

  test "Given any messages, when the server asks, then it raises and sends nothing unless every message has a role of user or assistant and a content block, and then the request is sent as given":
    let versions = askingVersions()
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyMessages(versions),
        guarded(proc(m: Messages): bool =
          let server = newServer(McpServerCapabilities())
          let t = server.attach()
          discard server.connect(t, m.version, clientCapabilities = WithSampling)
          let params = requestsOf(m.list)
          let pending = server.createMessage("", params)
          if m.wellFormed:
            let asked = t.awaitRequest("sampling/createMessage")
            t.answer(asked, %*{"role": "assistant", "content": Hello, "model": "m"})
            discard waitFor pending
            asked.message["params"] == params
          else:
            settle()
            if not pending.finished:
              return false          # the server is waiting for an answer: it asked
            var raised = false
            try:
              discard waitFor pending
            except McpPayloadError:
              raised = true
            raised and t.messagesOf("sampling/createMessage").len == 0))
      checkpoint describe(outcome)
      check outcome.passed

suite "the messages of a sampling request, asked for from 2026-07-28":

  test "Given any messages a tool handler asks, when the tool is called, then the answer is an internal error and nothing is asked unless every message is good, and then the answer asks for them as given":
    let versions = versionsWith(ftMultiRoundTripRequests)
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyMessages(versions),
        guarded(proc(m: Messages): bool =
          let server = askingServer()
          let peer = server.connect(server.attach(), m.version)
          let reply = peer.ask("tools/call", %*{"name": "ask", "arguments": {"messages": m.list}},
                               meta = caps(WithSampling))
          if m.wellFormed:
            reply.hasKey("result") and reply["result"]{"resultType"}.getStr() == "input_required" and
              reply["result"]["inputRequests"]["ask"]["params"]["messages"] == m.list
          else:
            reply.hasKey("error") and reply.errorCode == -32603 and not reply.hasKey("result")))
      checkpoint describe(outcome)
      check outcome.passed

# --- the stop reason (MCP-SAMPLING-TOOLS-14) ----------------------------------------------

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

suite "the stop reason of a sampling answer":

  test "Given any stopReason the specification does not list in an answer, when the server asked, then the answer is returned with it, with or without tools in the request":
    let versions = askingVersions()
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyStop(versions, true),
        guarded(proc(s: Stop): bool =
          let withTools = s.withTools and s.version.has(ftSamplingTools)
          let server = newServer(McpServerCapabilities())
          let t = server.attach()
          discard server.connect(t, s.version,
                                 clientCapabilities = if withTools: WithSamplingTools else: WithSampling)
          let params = requestsOf(%*[{"role": "user", "content": Hello}])
          if withTools:
            params["tools"] = %*[{"name": "t", "inputSchema": {"type": "object"}}]
          let pending = server.createMessage("", params)
          t.answer(t.awaitRequest("sampling/createMessage"),
                   %*{"role": "assistant", "content": Hello, "model": "m", "stopReason": s.reason})
          waitFor(pending){"stopReason"}.getStr("<none>") == s.reason))
      checkpoint describe(outcome)
      check outcome.passed

  test "Given any stopReason the specification does not list in the answer of a retry, when the tool is called again, then the handler reads it as it is":
    let versions = versionsWith(ftMultiRoundTripRequests)
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyStop(versions, true),
        guarded(proc(s: Stop): bool =
          let withTools = s.withTools and s.version.has(ftSamplingTools)
          let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
          server.onToolCall(proc(ctx: McpRequestContext, name: string,
                                 arguments: JsonNode): Future[JsonNode] {.async.} =
            let params = requestsOf(%*[{"role": "user", "content": Hello}])
            if withTools:
              params["tools"] = %*[{"name": "t", "inputSchema": {"type": "object"}}]
            let answered = ctx.requireInput("ask", "sampling/createMessage", params)
            return %*{"content": [{"type": "text", "text": answered{"stopReason"}.getStr("<none>")}]})
          let peer = server.connect(server.attach(), s.version)
          let meta = caps(if withTools: WithSamplingTools else: WithSampling)
          let first = peer.ask("tools/call", %*{"name": "go"}, meta = meta)
          if not first.hasKey("result") or first["result"]{"resultType"}.getStr() != "input_required":
            return false
          let retry = peer.ask("tools/call", %*{"name": "go", "inputResponses": {"ask": {
            "role": "assistant", "content": Hello, "model": "m", "stopReason": s.reason}}}, meta = meta)
          retry.hasKey("result") and retry.textOf == s.reason))
      checkpoint describe(outcome)
      check outcome.passed
