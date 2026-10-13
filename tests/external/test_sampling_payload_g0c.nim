## What a server sends and accepts in sampling: every message has a role of
## user or assistant and a content, and a stop reason is whatever string the
## client's model gave.

import std/[unittest, asyncdispatch, json, options]
import server/mrtr
import ./server_harness

let
  WithSampling = %*{"sampling": {}}
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
  ## A tool that asks the client's model one message of the given shape.
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    discard ctx.requireInput("ask", "sampling/createMessage", requestsOf(arguments["messages"]))
    return %*{"content": []})

suite "the messages of a sampling request, sent before 2026-07-28":

  test "Given a message whose role is neither user nor assistant, or is missing, when the server asks, then it raises and sends nothing":
    let versions = askingVersions()
    if versions.len == 0:
      skip()
    for v in versions:
      for message in [%*{"role": "system", "content": Hello}, %*{"role": 7, "content": Hello},
                      %*{"content": Hello}]:
        let server = newServer(McpServerCapabilities())
        let t = server.attach()
        discard server.connect(t, v, clientCapabilities = WithSampling)
        expect McpPayloadError:
          discard waitFor server.createMessage("", requestsOf(%*[message]))
        check t.messagesOf("sampling/createMessage").len == 0

  test "Given a message without a content, or with one that is no content block, when the server asks, then it raises and sends nothing":
    let versions = askingVersions()
    if versions.len == 0:
      skip()
    for v in versions:
      for message in [%*{"role": "user"}, %*{"role": "user", "content": "hello"},
                      %*{"role": "assistant", "content": nil}]:
        let server = newServer(McpServerCapabilities())
        let t = server.attach()
        discard server.connect(t, v, clientCapabilities = WithSampling)
        expect McpPayloadError:
          discard waitFor server.createMessage("", requestsOf(%*[message]))
        check t.messagesOf("sampling/createMessage").len == 0

  test "Given a user message and an assistant message with content, when the server asks, then the request is sent as given":
    let versions = askingVersions()
    if versions.len == 0:
      skip()
    for v in versions:
      let server = newServer(McpServerCapabilities())
      let t = server.attach()
      discard server.connect(t, v, clientCapabilities = WithSampling)
      let params = requestsOf(%*[{"role": "user", "content": Hello},
                                 {"role": "assistant", "content": Hello}])
      let pending = server.createMessage("", params)
      let asked = t.awaitRequest("sampling/createMessage")
      check asked.message["params"] == params
      t.answer(asked, %*{"role": "assistant", "content": Hello, "model": "m"})
      discard waitFor pending

suite "the messages of a sampling request, asked for from 2026-07-28":

  test "Given a handler whose message has a role other than user or assistant, or none, or no content, when the tool is called, then it is an internal error and nothing is asked":
    if versionsWith(ftMultiRoundTripRequests).len == 0:
      skip()
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = askingServer()
      let peer = server.connect(server.attach(), v)
      for message in [%*{"role": "system", "content": Hello}, %*{"content": Hello},
                      %*{"role": "user"}]:
        let reply = peer.ask("tools/call", %*{"name": "ask", "arguments": {"messages": [message]}},
                             meta = caps(WithSampling))
        check reply.errorCode == -32603
        check not reply.hasKey("result")

  test "Given a user message and an assistant message with content, when the tool is called, then the answer asks for them as given":
    if versionsWith(ftMultiRoundTripRequests).len == 0:
      skip()
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = askingServer()
      let peer = server.connect(server.attach(), v)
      let messages = %*[{"role": "user", "content": Hello}, {"role": "assistant", "content": Hello}]
      let reply = peer.ask("tools/call", %*{"name": "ask", "arguments": {"messages": messages}},
                           meta = caps(WithSampling))
      check reply["result"]["resultType"].getStr() == "input_required"
      check reply["result"]["inputRequests"]["ask"]["params"]["messages"] == messages

suite "the stop reason of a sampling answer":

  test "Given an answer whose stopReason is a string the specification does not list, when the server asked, then the answer is returned with it":
    let versions = askingVersions()
    if versions.len == 0:
      skip()
    for v in versions:
      let server = newServer(McpServerCapabilities())
      let t = server.attach()
      discard server.connect(t, v, clientCapabilities = WithSampling)
      let pending = server.createMessage("", requestsOf(%*[{"role": "user", "content": Hello}]))
      t.answer(t.awaitRequest("sampling/createMessage"),
               %*{"role": "assistant", "content": Hello, "model": "m", "stopReason": "vendorBudgetSpent"})
      check waitFor(pending)["stopReason"].getStr() == "vendorBudgetSpent"

  test "Given a request with tools and an answer with a stopReason of the client's own, when the server asked, then the answer is returned with it":
    let versions = askingVersions(ftSamplingTools)
    if versions.len == 0:
      skip()
    for v in versions:
      let server = newServer(McpServerCapabilities())
      let t = server.attach()
      discard server.connect(t, v, clientCapabilities = %*{"sampling": {"tools": {}}})
      let params = requestsOf(%*[{"role": "user", "content": Hello}])
      params["tools"] = %*[{"name": "t", "inputSchema": {"type": "object"}}]
      let pending = server.createMessage("", params)
      t.answer(t.awaitRequest("sampling/createMessage"),
               %*{"role": "assistant", "content": Hello, "model": "m", "stopReason": "vendorBudgetSpent"})
      check waitFor(pending)["stopReason"].getStr() == "vendorBudgetSpent"
