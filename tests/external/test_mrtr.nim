## Multi round-trip requests of 2026-07-28 (basic/patterns/mrtr): a server
## answers `tools/call`, `prompts/get` or `resources/read` with
## `input_required`; the client answers the input requests and retries.
##
## Message shapes follow the examples published with the specification
## (tests/fixtures/2026-07-28). The elicitation and sampling payloads obey
## the rules of their own methods (protocol/elicitation, protocol/sampling_tools).

import std/[unittest, asyncdispatch, base64, json, options, os, sequtils, strutils, tables]
import ./server_harness
import ./client_peer
from ./ext_auth_fixtures import hmacSha256
import client/client
import client/client as clientMod
import server/errors as serverErrors
import client/roots
import client/sampling
import client/elicitation
import protocol/elicitation as elicitationRules
import server/mrtr
import server/request_state
import protocol/mrtr

const
  Fixtures = currentSourcePath().parentDir.parentDir / "fixtures" / "2026-07-28"
  Parent = "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"
  Key = "0123456789abcdef-secret-key"

proc fixture(name: string): JsonNode =
  parseJson(readFile(Fixtures / name))

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-mrtr-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc caps(capabilities: JsonNode): JsonNode =
  %*{"io.modelcontextprotocol/clientCapabilities": capabilities}

proc rootsRequest(): JsonNode =
  %*{"method": "roots/list", "params": {}}

let LoginSchema = %*{"type": "object", "properties": {"name": {"type": "string"}},
                     "required": ["name"]}

proc askModel(): JsonNode =
  %*{"messages": [{"role": "user", "content": {"type": "text", "text": "Hi"}}], "maxTokens": 1}

proc loginServer(): McpServer =
  ## A tool that needs an elicitation before it can finish.
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()), prompts: some(McpPromptsCapability()),
    resources: some(McpResourcesCapability()), completions: some(McpCompletionsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "login":
      let answer = ctx.requireInput("github_login", "elicitation/create",
        %*{"message": "Please provide your GitHub username", "requestedSchema": LoginSchema},
        requestState = some("state-1"))
      return %*{"content": [{"type": "text", "text": "hello " &
        answer{"content"}{"name"}.getStr() & " " & ctx.requestState.get("no state")}]}
    of "two":
      let answers = ctx.requireInputs([
        (key: "a", methodName: "roots/list", params: newJObject()),
        (key: "b", methodName: "sampling/createMessage", params: askModel())])
      return %*{"content": [{"type": "text", "text": $answers.len}]}
    of "state_only":
      if ctx.requestState.isNone:
        raise newInputRequired(requestState = some("later"))
      return %*{"content": [{"type": "text", "text": ctx.requestState.get}]}
    of "nothing":
      raise newInputRequired()
    of "form_without_schema":
      discard ctx.requireInput("q", "elicitation/create", %*{"message": "Name?"})
      return %*{"content": []}
    of "sampling_without_messages":
      discard ctx.requireInput("q", "sampling/createMessage", %*{"maxTokens": 1})
      return %*{"content": []}
    of "open_page":
      discard ctx.requireInput("q", "elicitation/create", %*{
        "mode": "url", "message": "Sign in", "elicitationId": "e-1",
        "url": "https://example.com/signin"})
      return %*{"content": []}
    of "model_with_tools":
      var params = askModel()
      params["tools"] = %*[{"name": "lookup", "inputSchema": {"type": "object"}}]
      discard ctx.requireInput("q", "sampling/createMessage", params)
      return %*{"content": []}
    else:
      raise newUnknownTool(name))
  result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    discard ctx.requireInput("r", "roots/list", newJObject())
    return %*{"messages": []})
  result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    discard ctx.requireInput("r", "roots/list", newJObject())
    return @[%*{"uri": uri, "text": "x"}])
  result.onComplete(proc(ctx: McpRequestContext,
                         request: McpCompletionRequest): Future[McpCompletion] {.async.} =
    discard ctx.requireInput("r", "roots/list", newJObject())
    return McpCompletion())

suite "input required: the types of the specification":

  test "Given the specification's InputRequiredResult examples, when parsed, then requests and state are read":
    let full = fixture("InputRequiredResult_input-required-result-with-elicitation-and-sampling-and-request-state.json")
    let parsed = parseInputRequired(full)
    check parsed.problem.isNone
    check parsed.parsed.inputRequests.len == 2
    check parsed.parsed.requestState == some("eyJsb2NhdGlvbiI6Ik5ldyBZb3JrIn0")
    let stateOnly = parseInputRequired(
      fixture("InputRequiredResult_input-required-result-with-request-state-only.json"))
    check stateOnly.problem.isNone
    check stateOnly.parsed.inputRequests.isNil

  test "Given the specification's input requests, when the payload is built, then it equals the specification's result":
    let full = fixture("InputRequiredResult_input-required-result-with-elicitation-and-sampling-and-request-state.json")
    let built = inputRequiredPayload(full["inputRequests"], some(full["requestState"].getStr()))
    check built == full

  test "Given results that are not an InputRequiredResult, when parsed, then each is rejected":
    check parseInputRequired(%*{"resultType": "input_required"}).problem.isSome
    check parseInputRequired(%*{"inputRequests": {}}).problem.isSome
    check parseInputRequired(%*{"requestState": 5}).problem.isSome
    check parseInputRequired(%*{"inputRequests": []}).problem.isSome
    check parseInputRequired(%*{"inputRequests": {"a": {"method": "tools/list"}}}).problem.isSome
    check parseInputRequired(%*{"inputRequests": {"a": 3}}).problem.isSome
    check parseInputRequired(%*{"inputRequests": {"a": {"method": "roots/list", "params": 1}}}).problem.isSome

  test "Given input requests, when compared with a client's capabilities, then the undeclared ones are named":
    let requests = fixture("InputRequests_elicitation-and-sampling-input-requests.json")
    check missingCapabilities(requests, %*{}) == %*{"elicitation": {}, "sampling": {}}
    check missingCapabilities(requests, %*{"sampling": {}}) == %*{"elicitation": {}}
    check missingCapabilities(requests, %*{"sampling": {}, "elicitation": {}}).len == 0
    check missingCapabilities(requests, nil).len == 2

  test "Given a URL elicitation or sampling with tools, when compared with a client's capabilities, then the mode and the tools must be declared too":
    let page = %*{"q": {"method": "elicitation/create", "params": {
      "mode": "url", "message": "Sign in", "elicitationId": "e", "url": "https://example.com/"}}}
    check missingCapabilities(page, %*{"elicitation": {}}) == %*{"elicitation": {"url": {}}}
    check missingCapabilities(page, %*{"elicitation": {"form": {}}}) == %*{"elicitation": {"url": {}}}
    check missingCapabilities(page, %*{"elicitation": {"url": {}}}).len == 0
    let form = %*{"q": {"method": "elicitation/create", "params": {"message": "Name?"}}}
    check missingCapabilities(form, %*{"elicitation": {"url": {}}}) == %*{"elicitation": {"form": {}}}
    check missingCapabilities(form, %*{"elicitation": {}}).len == 0
    var withTools = askModel()
    withTools["tools"] = %*[{"name": "lookup", "inputSchema": {"type": "object"}}]
    let model = %*{"q": {"method": "sampling/createMessage", "params": withTools}}
    check missingCapabilities(model, %*{"sampling": {}}) == %*{"sampling": {"tools": {}}}
    check missingCapabilities(model, %*{"sampling": {"tools": {}}}).len == 0
    check missingCapabilities(%*{"q": {"method": "sampling/createMessage", "params": askModel()}},
                              %*{"sampling": {}}).len == 0

  test "Given a sampling input request without params, when compared with a client that declared sampling, then nothing is missing":
    check missingCapabilities(%*{"q": {"method": "sampling/createMessage"}}, %*{"sampling": {}}).len == 0

  test "Given input requests whose params break the rules of their method, when checked, then each problem names its request":
    for v in versionsWith(ftMultiRoundTripRequests):
      check inputRequestProblems(fixture("InputRequests_elicitation-and-sampling-input-requests.json"), v).len == 0
      check inputRequestProblems(%*{"where": rootsRequest()}, v).len == 0
      let problems = inputRequestProblems(%*{
        "a": {"method": "elicitation/create", "params": {"message": "Name?"}},
        "b": {"method": "sampling/createMessage", "params": {"maxTokens": 1}}}, v)
      check problems.len == 2
      check problems.anyIt(it.startsWith("inputRequests[\"a\"]") and "requestedSchema" in it)
      check problems.anyIt(it.startsWith("inputRequests[\"b\"]") and "messages" in it)

  test "Given original params, when a retry is built, then the responses are added, the state is echoed exactly and the original stays":
    let original = %*{"name": "login", "requestState": "stale"}
    let retry = retryParams(original, %*{"a": {"x": 1}}, some(" opaque=="))
    check retry["name"].getStr() == "login"
    check retry["inputResponses"]["a"]["x"].getInt() == 1
    check retry["requestState"].getStr() == " opaque=="
    check original["requestState"].getStr() == "stale"
    check not retryParams(original, nil, none(string)).hasKey("requestState")

  test "Given something that is not an InputRequests map, when validated, then each reason is given":
    check validateInputRequests(%*[1]).isSome
    check validateInputRequests(%*"x").isSome
    check validateInputRequests(%*{"a": {"params": {}}}).isSome
    check validateInputRequests(%*{"a": {"method": 3}}).isSome
    check validateInputRequests(%*{"a": {"method": "roots/list"}}).isNone

  test "Given params that are nil or not an object, when the input fields are read, checked or a retry is built, then nothing is carried, nothing is rejected and the retry holds only what was added":
    check inputResponsesOf(nil) == newJObject()
    check inputResponsesOf(%*[1]) == newJObject()
    check inputResponsesOf(%*{"inputResponses": 3}) == newJObject()
    check requestStateOf(nil).isNone
    check requestStateOf(%*[1]).isNone
    check requestStateOf(%*{"requestState": 3}).isNone
    check rejectInvalidInputParams(nil).isNone
    check rejectInvalidInputParams(%*[1]).isNone
    check retryParams(nil, %*{"a": {}}, some("s")) ==
      %*{"inputResponses": {"a": {}}, "requestState": "s"}
    check retryParams(%*[1], nil, none(string)) == newJObject()

suite "input required on the server (2026-07-28 only)":

  test "Given a tool that needs input, when it is called, then the answer is input_required with the request and the state":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "login"},
        meta = caps(%*{"elicitation": {}}))
      let result = answer["result"]
      check result["resultType"].getStr() == "input_required"
      check result["inputRequests"]["github_login"]["method"].getStr() == "elicitation/create"
      check result["inputRequests"]["github_login"]["params"]["message"].getStr() ==
        "Please provide your GitHub username"
      check result["requestState"].getStr() == "state-1"
      check result["_meta"].hasKey("io.modelcontextprotocol/serverInfo")
      check not result.hasKey("ttlMs")

  test "Given a retry with the answers and the state, when the tool runs again, then it sees both and completes":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "login",
        "inputResponses": {"github_login": {"action": "accept", "content": {"name": "octocat"}},
                           "unrequested": {"x": 1}},
        "requestState": "state-1"}, meta = caps(%*{"elicitation": {}}))
      check answer["result"]["resultType"].getStr() == "complete"
      check answer.textOf == "hello octocat state-1"

  test "Given a retry that answers only some requests, when the tool runs, then only the missing ones are asked again":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      let meta = caps(%*{"roots": {}, "sampling": {}})
      let first = peer.ask("tools/call", %*{"name": "two"}, meta = meta)
      check first["result"]["inputRequests"].len == 2
      let second = peer.ask("tools/call", %*{"name": "two",
        "inputResponses": {"a": {"roots": []}}}, meta = meta)
      check second["result"]["resultType"].getStr() == "input_required"
      check second["result"]["inputRequests"].len == 1
      check second["result"]["inputRequests"].hasKey("b")
      let third = peer.ask("tools/call", %*{"name": "two",
        "inputResponses": {"a": {"roots": []}, "b": {"role": "assistant"}}}, meta = meta)
      check third.textOf == "2"

  test "Given a handler that asks only to retry with a state, when it is called, then the answer carries the state alone":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      let first = peer.ask("tools/call", %*{"name": "state_only"})
      check first["result"]["resultType"].getStr() == "input_required"
      check first["result"]["requestState"].getStr() == "later"
      check not first["result"].hasKey("inputRequests")
      let retry = peer.ask("tools/call", %*{"name": "state_only", "requestState": "later"})
      check retry.textOf == "later"

  test "Given a client that did not declare the capability a request needs, when the tool asks, then the answer is the missing-capability error":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "login"}, meta = caps(%*{"roots": {}}))
      check answer.errorCode == -32021
      check answer["error"]["data"]["requiredCapabilities"] == %*{"elicitation": {}}

  test "Given a client that declared elicitation without the url mode, when the tool asks for a page, then the missing-capability error names the mode":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "open_page"}, meta = caps(%*{"elicitation": {}}))
      check answer.errorCode == -32021
      check answer["error"]["data"]["requiredCapabilities"] == %*{"elicitation": {"url": {}}}
      let allowed = peer.ask("tools/call", %*{"name": "open_page"},
        meta = caps(%*{"elicitation": {"url": {}}}))
      check allowed["result"]["resultType"].getStr() == "input_required"

  test "Given a client that declared sampling without tools, when the tool asks the model with tools, then the missing-capability error names the tools":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "model_with_tools"}, meta = caps(%*{"sampling": {}}))
      check answer.errorCode == -32021
      check answer["error"]["data"]["requiredCapabilities"] == %*{"sampling": {"tools": {}}}
      let allowed = peer.ask("tools/call", %*{"name": "model_with_tools"},
        meta = caps(%*{"sampling": {"tools": {}}}))
      check allowed["result"]["resultType"].getStr() == "input_required"

  test "Given a handler whose input request breaks the rules of its method, when it is called, then it is an internal error and nothing is asked":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      for tool in ["form_without_schema", "sampling_without_messages"]:
        let answer = peer.ask("tools/call", %*{"name": tool},
          meta = caps(%*{"elicitation": {}, "sampling": {}}))
        check answer.errorCode == -32603
        check answer["error"]["message"].getStr() == "Internal error"

  test "Given a handler that asks for nothing, when it is called, then it is an internal error":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/call", %*{"name": "nothing"}).errorCode == -32603

  test "Given prompts/get and resources/read, when their handlers need input, then they answer input_required too":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      let meta = caps(%*{"roots": {}})
      let prompt = peer.ask("prompts/get", %*{"name": "p"}, meta = meta)
      check prompt["result"]["resultType"].getStr() == "input_required"
      let resource = peer.ask("resources/read", %*{"uri": "file:///x"}, meta = meta)
      check resource["result"]["resultType"].getStr() == "input_required"

  test "Given a request that does not support input_required, when its handler asks, then it is an internal error":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("completion/complete", %*{
        "ref": {"type": "ref/prompt", "name": "p"},
        "argument": {"name": "a", "value": "b"}}, meta = caps(%*{"roots": {}}))
      check answer.errorCode == -32603

  test "Given inputResponses or requestState of the wrong type, when the request arrives, then it is invalid params":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/call", %*{"name": "login", "inputResponses": []}).errorCode == -32602
      check peer.ask("tools/call", %*{"name": "login", "inputResponses": {"a": 1}}).errorCode == -32602
      check peer.ask("tools/call", %*{"name": "login", "requestState": 7}).errorCode == -32602

  test "Given a version without multi round-trips, when a handler asks for input, then it is an internal error and the fields are ignored":
    for v in versionsWithout(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/call", %*{"name": "login"}).errorCode == -32603
      check peer.ask("tools/call", %*{"name": "login", "inputResponses": 5}).errorCode == -32603

  test "Given a request with trace context, when the server asks for input, then each input request carries it":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = loginServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "login"},
        meta = %*{"traceparent": Parent,
                  "io.modelcontextprotocol/clientCapabilities": {"elicitation": {}}})
      check answer["result"]["inputRequests"]["github_login"]["params"]["_meta"]["traceparent"]
        .getStr() == Parent

suite "sealed request state":

  test "Given a sealed state, when opened for the same request, then the payload comes back":
    let state = sealRequestState(Key, %*{"step": 2}, "tools/call",
      salient = %*{"name": "t", "arguments": {"a": 1, "b": 2}}, principal = "alice")
    let opened = openRequestState(Key, state, "tools/call",
      salient = %*{"arguments": {"b": 2, "a": 1}, "name": "t"}, principal = "alice")
    check opened["step"].getInt() == 2

  test "Given a state, when it is tampered with, signed by another key, expired or presented elsewhere, then each is rejected with its reason":
    let salient = %*{"name": "t"}
    let state = sealRequestState(Key, %*{"step": 2}, "tools/call", salient, "alice", 60, now = 1000.0)
    check verifyRequestState(Key, state, "tools/call", salient, "alice", now = 1010.0).problem.isNone
    check "signature" in verifyRequestState(Key, "x" & state, "tools/call", salient, "alice",
      now = 1010.0).problem.get
    check "signature" in verifyRequestState("another-key-0123456789", state, "tools/call",
      salient, "alice", now = 1010.0).problem.get
    check "expired" in verifyRequestState(Key, state, "tools/call", salient, "alice",
      now = 1061.0).problem.get
    check "method" in verifyRequestState(Key, state, "prompts/get", salient, "alice",
      now = 1010.0).problem.get
    check "parameters" in verifyRequestState(Key, state, "tools/call", %*{"name": "u"}, "alice",
      now = 1010.0).problem.get
    check "principal" in verifyRequestState(Key, state, "tools/call", salient, "mallory",
      now = 1010.0).problem.get
    check verifyRequestState(Key, "garbage", "tools/call", salient, "alice").problem.isSome

  test "Given parameters that differ only in the items or the nesting of an array or an object, when a state sealed for one is verified for the other, then it is issued for other parameters":
    let pairs = [
      (%*{"a": [1, 2]}, %*{"a": [12]}),
      (%*{"a": [1, 2]}, %*{"a": [3, 4]}),
      (%*{"a": [[1], 2]}, %*{"a": [[1, 2]]}),
      (%*{"a": {"b": 1}, "c": 2}, %*{"a": {"b": 1, "c": 2}})]
    for (sealed, presented) in pairs:
      let state = sealRequestState(Key, %*{"step": 1}, "tools/call", sealed, now = 1000.0)
      check verifyRequestState(Key, state, "tools/call", sealed, now = 1000.0).problem.isNone
      check verifyRequestState(Key, state, "tools/call", presented, now = 1000.0).problem.isSome

  test "Given a state signed by the key whose body is not an envelope the server seals, when verified, then it is never accepted":
    for body in [base64.encode("@@@@", safe = true), base64.encode("not json", safe = true),
                 base64.encode("[1]", safe = true)]:
      let state = body & "." & base64.encode(hmacSha256(Key, body), safe = true)
      check verifyRequestState(Key, state, "tools/call", now = 1000.0).problem.isSome

  test "Given a state that is not acceptable, when a handler opens it, then the peer gets invalid params without the reason":
    expect serverErrors.McpRequestError:
      discard openRequestState(Key, "garbage", "tools/call")
    try:
      discard openRequestState(Key, "garbage", "tools/call")
    except serverErrors.McpRequestError as e:
      check e.code == -32602
      check "signature" notin e.msg and "malformed" notin e.msg

  test "Given a key shorter than the minimum, when sealing, then it raises ValueError":
    expect ValueError:
      discard sealRequestState("short", newJObject(), "tools/call")

  test "Given a key of exactly the minimum length, when a state is sealed and verified, then it works, and one byte less is refused by both":
    let exact = "0123456789abcdef"
    let short = "0123456789abcde"
    check exact.len == MinKeyBytes
    let state = sealRequestState(exact, %*{"step": 1}, "tools/call", now = 1000.0)
    check verifyRequestState(exact, state, "tools/call", now = 1000.0).payload["step"].getInt() == 1
    expect ValueError:
      discard sealRequestState(short, newJObject(), "tools/call")
    check verifyRequestState(short, state, "tools/call", now = 1000.0).problem == some("malformed")

  test "Given a state sealed at a time with a lifetime, when verified at the last second of it and the second after, then the first is accepted and the second expired":
    let state = sealRequestState(Key, %*{"step": 1}, "tools/call", ttlSeconds = 60, now = 1000.0)
    check verifyRequestState(Key, state, "tools/call", now = 1060.0).problem.isNone
    check verifyRequestState(Key, state, "tools/call", now = 1061.0).problem == some("expired")

  test "Given payloads that make plain base64 use + and /, when sealed, then the state holds only URL-safe characters":
    let urlSafe = {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '=', '.'}
    var payloads = @["???", "a???", "aa???", "~~~~~~", "a~~~~~~", "aa~~~~~~"]
    for i in 0 ..< 64:
      payloads.add $i
    for payload in payloads:
      check sealRequestState(Key, %payload, "tools/call", now = 1000.0).allCharsInSet(urlSafe)

  test "Given a state that is not acceptable, when a handler opens it, then the method and the reason go to stderr":
    let state = sealRequestState(Key, newJObject(), "tools/call", now = 1000.0)
    let log = loggedWhile(proc() =
      expect serverErrors.McpRequestError:
        discard openRequestState(Key, "x" & state, "tools/call", now = 1000.0))
    check "tools/call" in log
    check "requestState rejected" in log
    check "signature does not verify" in log

suite "input required on the client":

  proc inputRequired(requests: JsonNode, state = ""): JsonNode =
    result = %*{"resultType": "input_required"}
    if not requests.isNil: result["inputRequests"] = requests
    if state.len > 0: result["requestState"] = %state

  proc answerWith(replies: seq[JsonNode]): proc(peer: client_peer.Peer, message: JsonNode) =
    ## A server whose n-th tools/call is answered with replies[n]; the last
    ## repeats.
    var seen = 0
    result = proc(peer: client_peer.Peer, message: JsonNode) =
      if message{"method"}.getStr() == "tools/call":
        peer.reply(message["id"], replies[min(seen, replies.high)])
        inc seen

  proc rootsClient(peer: client_peer.Peer, calls: ref int = nil): McpClient =
    peer.connectedClient(configure = proc(c: McpClient) =
      c.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} =
        if not calls.isNil: inc calls[]
        return @[McpRoot(uri: "file:///work", name: some("work"))]))

  test "Given an input_required answer, when the client has the handler, then it answers and retries with a new id until the request completes":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(answerWith(@[
        inputRequired(%*{"where": rootsRequest()}, "opaque=="),
        %*{"resultType": "complete", "content": [{"type": "text", "text": "done"}]}]),
        modern = true)
      let client = peer.connectedClient(v, proc(c: McpClient) =
        c.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} =
          return @[McpRoot(uri: "file:///work", name: some("work"))]))
      let answer = waitFor client.callMethod("tools/call", %*{"name": "t", "arguments": {"a": 1}})
      check answer["content"][0]["text"].getStr() == "done"
      let calls = peer.requestsFor("tools/call")
      check calls.len == 2
      check calls[0]["id"] != calls[1]["id"]
      check not calls[0]["params"].hasKey("inputResponses")
      let retry = calls[1]["params"]
      check retry["name"].getStr() == "t"
      check retry["arguments"]["a"].getInt() == 1
      check retry["requestState"].getStr() == "opaque=="
      check retry["inputResponses"]["where"]["roots"][0]["uri"].getStr() == "file:///work"
      check retry["_meta"].hasKey("io.modelcontextprotocol/protocolVersion")

  test "Given a result with requests only, when the client retries, then no requestState is sent":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(answerWith(@[
        inputRequired(%*{"where": rootsRequest()}),
        %*{"resultType": "complete", "content": []}]), modern = true)
      let client = rootsClient(peer)
      discard waitFor client.callMethod("tools/call", %*{"name": "t", "requestState": "mine"})
      check not peer.requestsFor("tools/call")[1]["params"].hasKey("requestState")

  test "Given a result with only a state, when the client retries, then it retries at once echoing the state":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(answerWith(@[
        inputRequired(nil, "wait"),
        %*{"resultType": "complete", "content": []}]), modern = true)
      let client = peer.connectedClient(v)
      discard waitFor client.callMethod("tools/call", %*{"name": "t"})
      let retry = peer.requestsFor("tools/call")[1]["params"]
      check retry["requestState"].getStr() == "wait"
      check not retry.hasKey("inputResponses")

  test "Given a server that keeps asking, when the limit is reached, then the client raises McpInputRoundsError":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(answerWith(@[inputRequired(%*{"where": rootsRequest()}, "s")]),
        modern = true)
      let client = rootsClient(peer)
      client.maxInputRounds = 3
      expect McpInputRoundsError:
        discard waitFor client.callMethod("tools/call", %*{"name": "t"})
      check peer.requestsFor("tools/call").len == 4

  test "Given a request for a capability the client did not declare, when the server asks, then the client raises without calling a handler or retrying":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(answerWith(@[inputRequired(%*{"q": {
        "method": "sampling/createMessage", "params": {"maxTokens": 1}}})]), modern = true)
      let calls = new int
      let client = rootsClient(peer, calls)
      expect McpProtocolError:
        discard waitFor client.callMethod("tools/call", %*{"name": "t"})
      check calls[] == 0
      check peer.requestsFor("tools/call").len == 1

  test "Given an elicitation request, when the client declared no elicitation, then it raises McpProtocolError":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(answerWith(@[inputRequired(
        fixture("InputRequests_elicitation-and-sampling-input-requests.json"))]), modern = true)
      let client = peer.connectedClient(v)
      expect McpProtocolError:
        discard waitFor client.callMethod("tools/call", %*{"name": "t"})

  test "Given a form elicitation, when the client's handler accepts, then the retry carries the ElicitResult":
    for v in versionsWith(ftMultiRoundTripRequests):
      let requests = %*{"github_login": fixture(
        "InputRequests_elicitation-and-sampling-input-requests.json")["github_login"]}
      let peer = startPeer(answerWith(@[inputRequired(requests),
        %*{"resultType": "complete", "content": [{"type": "text", "text": "done"}]}]), modern = true)
      var asked: seq[McpElicitRequest]
      let client = peer.connectedClient(v, proc(c: McpClient) =
        c.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
          asked.add request
          return McpElicitResult(action: eaAccept, content: %*{"name": "octocat"})))
      discard waitFor client.callMethod("tools/call", %*{"name": "t"})
      check asked.len == 1
      check asked[0].message == "Please provide your GitHub username"
      let calls = peer.requestsFor("tools/call")
      check calls.len == 2
      check calls[1]["params"]["inputResponses"]["github_login"] ==
        %*{"action": "accept", "content": {"name": "octocat"}}

  test "Given a form elicitation, when the client's handler answers outside the schema, then the request is abandoned and nothing is retried":
    for v in versionsWith(ftMultiRoundTripRequests):
      let requests = %*{"github_login": fixture(
        "InputRequests_elicitation-and-sampling-input-requests.json")["github_login"]}
      let peer = startPeer(answerWith(@[inputRequired(requests)]), modern = true)
      let client = peer.connectedClient(v, proc(c: McpClient) =
        c.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
          return McpElicitResult(action: eaAccept, content: %*{"name": 7})))
      expect clientMod.McpRequestError:
        discard waitFor client.callMethod("tools/call", %*{"name": "t"})
      check peer.requestsFor("tools/call").len == 1

  test "Given a URL elicitation, when the client declared only the form mode, then it raises without calling the handler or retrying":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(answerWith(@[inputRequired(%*{"q": {"method": "elicitation/create",
        "params": {"mode": "url", "message": "Sign in", "elicitationId": "e-1",
                   "url": "https://example.com/signin"}}})]), modern = true)
      let calls = new int
      let client = peer.connectedClient(v, proc(c: McpClient) =
        c.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
          inc calls[]
          return McpElicitResult(action: eaAccept)))
      expect McpProtocolError:
        discard waitFor client.callMethod("tools/call", %*{"name": "t"})
      check calls[] == 0
      check peer.requestsFor("tools/call").len == 1

  test "Given a declared capability with no handler, when the server asks, then the client raises McpUnsupportedError":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(answerWith(@[inputRequired(%*{"where": rootsRequest()})]),
        modern = true)
      let client = peer.connectedClient(v, proc(c: McpClient) =
        c.capabilities.roots = some(McpRootsCapability()))
      expect McpUnsupportedError:
        discard waitFor client.callMethod("tools/call", %*{"name": "t"})

  test "Given a handler that answers with an error, when the server asks, then the request is abandoned with McpRequestError":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(answerWith(@[inputRequired(%*{"q": {
        "method": "sampling/createMessage", "params": {"messages": [], "maxTokens": 1}}})]),
        modern = true)
      let client = peer.connectedClient(v, proc(c: McpClient) =
        c.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
          raise newException(clientMod.McpRequestError, "user rejected sampling request")))
      expect clientMod.McpRequestError:
        discard waitFor client.callMethod("tools/call", %*{"name": "t"})
      check peer.requestsFor("tools/call").len == 1

  test "Given input_required for a request that does not allow it, when it arrives, then the client raises McpProtocolError":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          peer.reply(message["id"], inputRequired(%*{"where": rootsRequest()})), modern = true)
      let client = rootsClient(peer)
      expect McpProtocolError:
        discard waitFor client.callMethod("tools/list", newJObject())

  test "Given an input_required result that is malformed, when it arrives, then the client raises McpProtocolError":
    for v in versionsWith(ftMultiRoundTripRequests):
      for bad in [%*{"resultType": "input_required"},
                  %*{"resultType": "input_required", "inputRequests": {"a": {"method": "tools/list"}}},
                  %*{"resultType": "input_required", "requestState": 3}]:
        let peer = startPeer(answerWith(@[bad]), modern = true)
        let client = rootsClient(peer)
        expect McpProtocolError:
          discard waitFor client.callMethod("tools/call", %*{"name": "t"})

  test "Given a slow answer to the input requests, when the request has a timeout, then the timeout counts each attempt and not the answering":
    for v in versionsWith(ftMultiRoundTripRequests):
      let peer = startPeer(answerWith(@[
        inputRequired(%*{"where": rootsRequest()}),
        %*{"resultType": "complete", "content": []}]), modern = true)
      let client = peer.connectedClient(v, proc(c: McpClient) =
        c.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} =
          await sleepAsync(120)
          return @[]))
      let answer = waitFor client.callMethod("tools/call", %*{"name": "t"},
        McpRequestOptions(timeoutMs: some(60)))
      check answer["resultType"].getStr() == "complete"
