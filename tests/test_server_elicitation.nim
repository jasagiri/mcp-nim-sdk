## The server asks the user for input through the client (elicitation/create,
## 2025-06-18 to 2025-11-25): what it needs from the client first, what it
## sends, and what it does with the answer.

import std/[unittest, asyncdispatch, json, options]
import protocol/elicitation
import server/elicit
import ./server_harness

const
  Asking = block:
    ## The versions in which the server can ask, up to the build's default.
    var versions: seq[McpProtocolVersion]
    for v in [mpv20250618, mpv20251125]:
      if v <= DefaultProtocolVersion: versions.add v
    versions

let
  FormOnly = %*{"elicitation": {}}
  Schema = %*{"type": "object",
              "properties": {"name": {"type": "string"}, "age": {"type": "integer", "minimum": 18}},
              "required": ["name"]}

proc elicitServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    let answer = await ctx.elicit("Who are you?", Schema)
    return %*{"content": [{"type": "text", "text": answer.content["name"].getStr()}]})

proc awaitRequest(t: SessionedTransport, methodName: string, session = ""): Sent =
  untilTrue("the server's " & methodName, proc(): bool =
    for s in t.messagesOf(methodName):
      if s.session == session:
        return true
    false)
  for s in t.messagesOf(methodName):
    if s.session == session:
      return s

proc answer(t: SessionedTransport, asked: Sent, resultNode: JsonNode) =
  t.inject(asked.session, %*{"jsonrpc": "2.0", "id": asked.message["id"], "result": resultNode})

if DefaultProtocolVersion >= mpv20250618:
  suite "elicitation requested by the server":

    test "Given a client that can elicit, when the server asks, then elicitation/create carries the message and schema and the answer comes back":
      for v in Asking:
        let server = elicitServer()
        let t = server.attach()
        discard server.connect(t, v, session = "s", clientCapabilities = FormOnly)
        let pending = server.elicit("s", "Who are you?", Schema)
        let asked = t.awaitRequest("elicitation/create", "s")
        check asked.message["params"]["message"].getStr() == "Who are you?"
        check asked.message["params"]["requestedSchema"] == Schema
        t.answer(asked, %*{"action": "accept", "content": {"name": "Mona", "age": 30}})
        let reply = waitFor pending
        check reply.action == eaAccept
        check reply.content["name"].getStr() == "Mona"

    test "Given a client that declines or cancels, when the server asks, then the action says so and there is no content":
      for action in [eaDecline, eaCancel]:
        let server = elicitServer()
        let t = server.attach()
        discard server.connect(t, mpv20250618, clientCapabilities = FormOnly)
        let pending = server.elicit("", "m", Schema)
        t.answer(t.awaitRequest("elicitation/create"), %*{"action": $action})
        let reply = waitFor pending
        check reply.action == action
        check reply.content.isNil

    test "Given a client without the elicitation capability, when the server asks, then it raises and sends nothing":
      let server = elicitServer()
      let t = server.attach()
      discard server.connect(t, mpv20250618, clientCapabilities = %*{"sampling": {}})
      expect McpCapabilityError:
        discard waitFor server.elicit("", "m", Schema)
      check t.messagesOf("elicitation/create").len == 0

    test "Given a client of a version before elicitation, when the server asks, then it raises and sends nothing":
      let server = elicitServer()
      let t = server.attach()
      discard server.connect(t, mpv20250326, clientCapabilities = FormOnly)
      expect McpCapabilityError:
        discard waitFor server.elicit("", "m", Schema)
      check t.messagesOf("elicitation/create").len == 0

    test "Given a schema outside the rules, when the server asks, then McpPayloadError lists why and nothing is sent":
      let server = elicitServer()
      let t = server.attach()
      discard server.connect(t, mpv20250618, clientCapabilities = FormOnly)
      expect McpPayloadError:
        discard waitFor server.elicit("", "m", %*{"type": "object", "properties": {
          "nested": {"type": "object"}}})
      check t.messagesOf("elicitation/create").len == 0

    test "Given an answer that does not match the schema, when it arrives, then McpPayloadError is raised":
      let server = elicitServer()
      let t = server.attach()
      discard server.connect(t, mpv20250618, clientCapabilities = FormOnly)
      let pending = server.elicit("", "m", Schema)
      t.answer(t.awaitRequest("elicitation/create"),
               %*{"action": "accept", "content": {"age": 30}})
      expect McpPayloadError:
        discard waitFor pending

    test "Given a client that answers with an error, when the server asks, then McpRemoteError carries its code":
      let server = elicitServer()
      let t = server.attach()
      discard server.connect(t, mpv20250618, clientCapabilities = FormOnly)
      let pending = server.elicit("", "m", Schema)
      let asked = t.awaitRequest("elicitation/create")
      t.inject("", %*{"jsonrpc": "2.0", "id": asked.message["id"],
                      "error": {"code": -32602, "message": "no"}})
      try:
        discard waitFor pending
        check false
      except McpRemoteError as e:
        check e.code == -32602

    test "Given a handler that elicits, when a tool is called, then the request belongs to the tool call and the answer drives the result":
      for v in Asking:
        let server = elicitServer()
        let t = server.attach()
        let peer = server.connect(t, v, clientCapabilities = FormOnly)
        let callId = freshId()
        peer.send(%callId, "tools/call", %*{"name": "greet"})
        let asked = t.awaitRequest("elicitation/create")
        check asked.related == callId
        t.answer(asked, %*{"action": "accept", "content": {"name": "Mona"}})
        check textOf(t.responseTo(callId)) == "Mona"


if DefaultProtocolVersion >= mpv20251125:
  suite "elicitation requested by the server: enum schemas and defaults (2025-11-25)":

    let colours = %*{"type": "object", "properties": {
      "colours": {"type": "array", "items": {"anyOf": [
        {"const": "#f00", "title": "Red"}, {"const": "#0f0", "title": "Green"}]},
        "minItems": 1, "default": ["#f00"]},
      "nick": {"type": "string", "default": "anon"}}}

    test "Given a client of 2025-11-25, when the server asks for a multi-select with defaults, then the schema is sent as given and the answer is checked against it":
      let server = elicitServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = FormOnly)
      let pending = server.elicit("", "m", colours)
      let asked = t.awaitRequest("elicitation/create")
      check asked.message["params"]["requestedSchema"] == colours
      t.answer(asked, %*{"action": "accept", "content": {"colours": ["Red"]}})
      expect McpPayloadError:
        discard waitFor pending

    test "Given a client of 2025-06-18, when the server asks for a multi-select, then McpPayloadError says the version has none and nothing is sent":
      let server = elicitServer()
      let t = server.attach()
      discard server.connect(t, mpv20250618, clientCapabilities = FormOnly)
      expect McpPayloadError:
        discard waitFor server.elicit("", "m", colours)
      check t.messagesOf("elicitation/create").len == 0


if DefaultProtocolVersion >= mpv20251125:
  suite "URL mode elicitation requested by the server (2025-11-25)":

    let
      BothModes = %*{"elicitation": {"form": {}, "url": {}}}
      id = "550e8400-e29b-41d4-a716-446655440000"
      link = "https://mcp.example.com/ui/set_api_key"

    proc urlServer(): McpServer =
      result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      result.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        raise ctx.urlElicitationRequired(@[urlElicitationParams("Connect", id, link, ctx.version)]))

    test "Given a client that declared the url mode, when the server asks, then elicitation/create names the url mode and the accept comes back without content":
      let server = urlServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = BothModes)
      let pending = server.elicitUrl("", "Provide your key", id, link)
      let asked = t.awaitRequest("elicitation/create")
      check asked.message["params"] == %*{"mode": "url", "message": "Provide your key",
                                          "elicitationId": id, "url": link}
      t.answer(asked, %*{"action": "accept"})
      let reply = waitFor pending
      check reply.action == eaAccept
      check reply.content.isNil

    test "Given a client that declared only the form mode, when the server asks in url mode, then it raises and sends nothing":
      for caps in [%*{"elicitation": {}}, %*{"elicitation": {"form": {}}}]:
        let server = urlServer()
        let t = server.attach()
        discard server.connect(t, mpv20251125, clientCapabilities = caps)
        expect McpCapabilityError:
          discard waitFor server.elicitUrl("", "m", id, link)
        check t.messagesOf("elicitation/create").len == 0

    test "Given a client that declared only the url mode, when the server asks for a form, then it raises":
      let server = urlServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = %*{"elicitation": {"url": {}}})
      expect McpCapabilityError:
        discard waitFor server.elicit("", "m", Schema)
      check t.messagesOf("elicitation/create").len == 0

    test "Given a connection of 2025-06-18, when the server asks in url mode, then it raises and sends nothing":
      let server = urlServer()
      let t = server.attach()
      discard server.connect(t, mpv20250618, clientCapabilities = BothModes)
      expect McpCapabilityError:
        discard waitFor server.elicitUrl("", "m", id, link)
      check t.messagesOf("elicitation/create").len == 0

    test "Given a URL mode answer with content, when it arrives, then McpPayloadError is raised":
      let server = urlServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = BothModes)
      let pending = server.elicitUrl("", "m", id, link)
      t.answer(t.awaitRequest("elicitation/create"),
               %*{"action": "accept", "content": {"key": "secret"}})
      expect McpPayloadError:
        discard waitFor pending

    test "Given a completed interaction, when the server notifies, then only that client gets notifications/elicitation/complete":
      let server = urlServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, session = "a", clientCapabilities = BothModes)
      discard server.connect(t, mpv20251125, session = "b", clientCapabilities = BothModes)
      waitFor server.notifyElicitationComplete("a", id)
      let sent = t.messagesOf("notifications/elicitation/complete")
      check sent.len == 1
      check sent[0].session == "a"
      check sent[0].message["params"] == %*{"elicitationId": id}

    test "Given a client without the url mode, when the server notifies a completion, then it raises and sends nothing":
      let server = urlServer()
      let t = server.attach()
      discard server.connect(t, mpv20251125, clientCapabilities = FormOnly)
      expect McpCapabilityError:
        waitFor server.notifyElicitationComplete("", id)
      check t.messagesOf("notifications/elicitation/complete").len == 0

    test "Given a handler that needs a URL elicitation, when the client can do the url mode, then the call fails with code -32042 and the elicitations":
      let server = urlServer()
      let t = server.attach()
      let peer = server.connect(t, mpv20251125, clientCapabilities = BothModes)
      let reply = peer.ask("tools/call", %*{"name": "connect"})
      check reply.errorCode == -32042
      check reply["error"]["data"] == %*{"elicitations": [
        {"mode": "url", "message": "Connect", "elicitationId": id, "url": link}]}

    test "Given a handler that needs a URL elicitation, when the client cannot do the url mode, then the handler's raise is a capability error and the call fails as an internal error":
      let server = urlServer()
      let t = server.attach()
      let peer = server.connect(t, mpv20251125, clientCapabilities = FormOnly)
      check peer.ask("tools/call", %*{"name": "connect"}).errorCode == -32603
