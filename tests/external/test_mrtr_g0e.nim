## Multi round-trip requests of 2026-07-28 (basic/patterns/mrtr): which
## requests a server may ask for, that it does not wait for a retry, that it
## ignores answers it did not ask for, and that a client keeps the state of
## one request away from every other request.

import std/[unittest, asyncdispatch, json, options, tables]
import ./server_harness
import ./client_peer
import client/client
import client/roots
import server/mrtr

let LoginSchema = %*{"type": "object", "properties": {"name": {"type": "string"}},
                     "required": ["name"]}

proc mrtrServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "login":
      let answer = ctx.requireInput("github_login", "elicitation/create",
        %*{"message": "Please provide your GitHub username", "requestedSchema": LoginSchema})
      return %*{"content": [{"type": "text", "text": "hello " &
        answer{"content"}{"name"}.getStr()}]}
    of "two":
      let answers = ctx.requireInputs([
        (key: "a", methodName: "roots/list", params: newJObject()),
        (key: "b", methodName: "roots/list", params: newJObject())])
      return %*{"content": [{"type": "text", "text": $answers.len}]}
    of "listing":
      discard ctx.requireInput("q", "tools/list", newJObject())
      return %*{"content": []}
    of "pinging":
      discard ctx.requireInput("q", "ping", newJObject())
      return %*{"content": []}
    else:
      raise newUnknownTool(name))

let Elicitation = %*{"elicitation": {}}

suite "what a server may ask for (2026-07-28)":

  test "Given a handler that asks for a request that is no elicitation, sampling or roots request, when it is called, then it is an internal error and nothing is asked":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = mrtrServer()
      let peer = server.connect(server.attach(), v)
      for tool in ["listing", "pinging"]:
        let answer = peer.ask("tools/call", %*{"name": tool},
          meta = %*{"io.modelcontextprotocol/clientCapabilities": {"elicitation": {}, "sampling": {}, "roots": {}}})
        check answer.errorCode == -32603
        check not answer.hasKey("result")

suite "a server does not wait for the client (2026-07-28)":

  test "Given an input_required answer, when the client never retries, then the request is already answered and the server serves other requests":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = mrtrServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      let first = peer.ask("tools/call", %*{"name": "login"},
        meta = %*{"io.modelcontextprotocol/clientCapabilities": Elicitation})
      check first["result"]["resultType"].getStr() == "input_required"
      settle()
      check t.dropped.len == 0
      check peer.ask("tools/call", %*{"name": "nobody"}).hasKey("error")

  test "Given a server that is asked again, when the client asks the same request twice without answering, then each time the server asks again":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = mrtrServer()
      let peer = server.connect(server.attach(), v)
      for attempt in 1 .. 3:
        let answer = peer.ask("tools/call", %*{"name": "login"},
          meta = %*{"io.modelcontextprotocol/clientCapabilities": Elicitation})
        check answer["result"]["resultType"].getStr() == "input_required"
        check answer["result"]["inputRequests"].hasKey("github_login")

  test "Given the first request answered by one server, when the retry goes to another server that never saw the first, then the retry completes":
    for v in versionsWith(ftMultiRoundTripRequests):
      let first = mrtrServer()
      let asked = first.connect(first.attach(), v).ask("tools/call", %*{"name": "login"},
        meta = %*{"io.modelcontextprotocol/clientCapabilities": Elicitation})
      check asked["result"]["resultType"].getStr() == "input_required"
      let second = mrtrServer()
      let retried = second.connect(second.attach(), v).ask("tools/call", %*{"name": "login",
        "inputResponses": {"github_login": {"action": "accept", "content": {"name": "octocat"}}}},
        meta = %*{"io.modelcontextprotocol/clientCapabilities": Elicitation})
      check retried["result"]["resultType"].getStr() == "complete"
      check retried.textOf == "hello octocat"

suite "answers the server did not ask for (2026-07-28)":

  test "Given a retry with answers it did not ask for, when the server runs the request, then they are ignored and the request completes":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = mrtrServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "login", "inputResponses": {
        "github_login": {"action": "accept", "content": {"name": "octocat"}},
        "unknown_key": {"x": 1}, "another": {}, "third": {"action": "decline"}}},
        meta = %*{"io.modelcontextprotocol/clientCapabilities": Elicitation})
      check answer["result"]["resultType"].getStr() == "complete"
      check answer.textOf == "hello octocat"

  test "Given a retry with only answers it did not ask for, when the server runs the request, then it asks again for what it needs":
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = mrtrServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("tools/call", %*{"name": "two",
        "inputResponses": {"zzz": {"roots": []}, "a": {"roots": []}}},
        meta = %*{"io.modelcontextprotocol/clientCapabilities": {"roots": {}}})
      check answer["result"]["resultType"].getStr() == "input_required"
      check answer["result"]["inputRequests"].len == 1
      check answer["result"]["inputRequests"].hasKey("b")

suite "input requests and state belong to one request (2026-07-28)":

  test "Given a request that waits for its input answers while another request is sent, when both run, then the other request carries none of the first one's state or answers":
    for v in versionsWith(ftMultiRoundTripRequests):
      var calls = 0
      let peer = startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
        case message{"method"}.getStr()
        of "tools/call":
          inc calls
          if calls == 1:
            peer.reply(message["id"], %*{"resultType": "input_required",
              "inputRequests": {"where": {"method": "roots/list", "params": {}}},
              "requestState": "state-of-the-first"})
          else:
            peer.reply(message["id"], %*{"resultType": "complete", "content": []})
        of "tools/list":
          peer.reply(message["id"], %*{"resultType": "complete", "tools": []})
        else:
          discard, modern = true)
      let client = peer.connectedClient(v, proc(c: McpClient) =
        c.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} =
          await sleepAsync(80)
          return @[McpRoot(uri: "file:///work", name: some("work"))]))
      let first = client.callMethod("tools/call", %*{"name": "t"})
      untilTrue("the first request to be sent", proc(): bool = peer.requestsFor("tools/call").len == 1)
      let other = client.callMethod("tools/list", newJObject())
      discard waitFor other
      discard waitFor first
      let listed = peer.requestsFor("tools/list")[0]["params"]
      check not listed.hasKey("requestState")
      check not listed.hasKey("inputResponses")
      let retry = peer.requestsFor("tools/call")[1]["params"]
      check retry["requestState"].getStr() == "state-of-the-first"
      check retry["inputResponses"].hasKey("where")
      discard waitFor client.callMethod("tools/list", newJObject())
      let later = peer.requestsFor("tools/list")[1]["params"]
      check not later.hasKey("requestState")
      check not later.hasKey("inputResponses")
