## What a server puts on the wire, as the base protocol fixes it: the shape of
## an error response, a result of any structure, a notification without an id,
## the ids of the server's own requests, and a response that carries one of
## result and error.

import std/[unittest, asyncdispatch, json, options, sets, strutils]
import transport/transport
import ./server_harness

proc wireServer(): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability(listChanged: true))))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "progress":
      await ctx.reportProgress(1, some(2.0))
      await ctx.reportProgress(2, some(2.0))
      return %*{"content": [{"type": "text", "text": "done"}]}
    of "custom-error":
      raise newRequestError(4242, "the handler's own error", %*{"detail": [1, 2]})
    of "breaks":
      raise newException(ValueError, "an internal detail")
    else:
      raise newUnknownTool(name))
  result.registerRequestHandler("x/custom",
    proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
      return newJsonRpcResponse(request.id, %*{
        "anything": [1, 2.5, nil, {"nested": "yes"}], "flag": true, "text": "kept"}))

proc hasErrorShape(response: JsonNode): bool =
  ## An error response has exactly an integer code and a string message, and
  ## no result beside them.
  response.hasKey("error") and not response.hasKey("result") and
    response["error"]{"code"}.kind == JInt and
    response["error"]{"message"}.kind == JString

suite "error responses of a server":

  test "Given requests that fail in different ways, when the server answers, then each answer has an integer code and a message and no result":
    for v in SupportedProtocolVersions:
      let server = wireServer()
      let peer = server.connect(server.attach(), v)
      let failures = [
        peer.ask("no/such/method"),
        peer.ask("tools/call", %*{}),
        peer.ask("tools/call", %*{"name": "no-such-tool"}),
        peer.ask("tools/call", %*{"name": "custom-error"}),
        peer.ask("tools/call", %*{"name": "breaks"}),
        peer.ask("tools/list", %*{"cursor": 5}),
      ]
      for failure in failures:
        check failure.hasErrorShape()

  test "Given a handler that raises its own error, when the server answers, then the code and the message are the handler's":
    for v in SupportedProtocolVersions:
      let server = wireServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "custom-error"})
      check answer.hasErrorShape()
      check answer["error"]["code"].getInt() == 4242
      check answer["error"]["message"].getStr() == "the handler's own error"
      check answer["error"]["data"] == %*{"detail": [1, 2]}

  test "Given a handler that breaks, when the server answers, then the code is the internal error and the message does not carry the cause":
    for v in SupportedProtocolVersions:
      let server = wireServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "breaks"})
      check answer.hasErrorShape()
      check answer["error"]["code"].getInt() == -32603
      check "internal detail" notin answer["error"]["message"].getStr()

  test "Given an unknown method, when the server answers, then the code is method not found":
    for v in SupportedProtocolVersions:
      let server = wireServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("no/such/method")
      check answer.hasErrorShape()
      check answer["error"]["code"].getInt() == -32601

suite "results of a server":

  test "Given a handler whose result is an object of its own shape, when the server answers, then every member arrives as the handler gave it":
    for v in SupportedProtocolVersions:
      let server = wireServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("x/custom")
      check answer.hasKey("result")
      check not answer.hasKey("error")
      for key, value in %*{"anything": [1, 2.5, nil, {"nested": "yes"}],
                           "flag": true, "text": "kept"}:
        check answer["result"][key] == value

suite "notifications of a server":

  test "Given a request with a progress token and a list change, when the server notifies, then no notification carries an id":
    for v in SupportedProtocolVersions:
      let server = wireServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      let answer = peer.ask("tools/call", %*{"name": "progress"},
                            meta = %*{"progressToken": "p-1"})
      check answer.hasKey("result")
      waitFor server.notifyToolListChanged()
      var seen = 0
      for sent in t.sent:
        if sent.message{"method"}.getStr().startsWith("notifications/"):
          inc seen
          check not sent.message.hasKey("id")
      check seen >= 2

suite "requests of a server":

  test "Given several requests to a client, when the server sends them, then each id is a string and none is used twice":
    for v in versionsWith(ftServerInitiatedRequests):
      let server = wireServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      var ids = initHashSet[string]()
      for _ in 1 .. 4:
        let pinging = server.ping(peer.session)
        let asked = t.messagesOf("ping")
        let id = asked[^1].message["id"]
        check id.kind == JString
        check id.getStr().len > 0
        check id.getStr() notin ids
        ids.incl id.getStr()
        t.inject(peer.session, %*{"jsonrpc": "2.0", "id": id, "result": {}})
        waitFor pinging
      check ids.len == 4

suite "responses on the wire":

  test "Given a response that holds both a result and an error, when it is encoded, then it carries the error alone":
    let both = JsonRpcResponse(jsonrpc: "2.0", id: "1", result: some(%*{"a": 1}),
      error: some(JsonRpcError(code: -32603, message: "failed", data: nil)))
    let wire = parseJson(encodeMessage(both))
    check wire.hasKey("error")
    check not wire.hasKey("result")
    check wire["error"]["code"].getInt() == -32603

  test "Given a response with a result, when it is encoded, then it carries the result alone":
    let wire = parseJson(encodeMessage(newJsonRpcResponse("1", %*{"a": 1})))
    check wire.hasKey("result")
    check not wire.hasKey("error")

  test "Given an error response, when it is encoded, then it carries the error alone with an integer code":
    let wire = parseJson(encodeMessage(newJsonRpcErrorResponse("1", -32602, "bad")))
    check wire.hasKey("error")
    check not wire.hasKey("result")
    check wire["error"]["code"].kind == JInt
    check wire["error"]["message"].getStr() == "bad"
