## A server's URL elicitation: the url it sends is a URL, and an answer
## counts only when it comes from the client that was asked.

import std/[unittest, asyncdispatch, json, options]
import server/elicit
import server/mrtr
import ./server_harness

let
  BothModes = %*{"elicitation": {"form": {}, "url": {}}}
  Id = "550e8400-e29b-41d4-a716-446655440000"
  Link = "https://mcp.example.com/ui/set_api_key"
  Form = %*{"type": "object", "properties": {"name": {"type": "string"}}}

proc askingVersions(feature: McpFeature): seq[McpProtocolVersion] =
  ## The versions in which the server asks the client itself, and that have `feature`.
  for v in versionsWith(feature):
    if v.has(ftServerInitiatedRequests):
      result.add v

proc awaitRequest(t: SessionedTransport, methodName: string, session = ""): Sent =
  untilTrue("the server's " & methodName, proc(): bool =
    for s in t.messagesOf(methodName):
      if s.session == session:
        return true
    false)
  for s in t.messagesOf(methodName):
    if s.session == session:
      return s

proc answer(t: SessionedTransport, asked: Sent, fromSession: string, resultNode: JsonNode) =
  t.inject(fromSession, %*{"jsonrpc": "2.0", "id": asked.message["id"], "result": resultNode})

proc caps(capabilities: JsonNode): JsonNode =
  %*{"io.modelcontextprotocol/clientCapabilities": capabilities}

proc urlServer(): McpServer =
  ## A tool that needs the user to visit the url it is given.
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    discard ctx.requireInput("visit", "elicitation/create",
      %*{"mode": "url", "message": "Provide your key", "elicitationId": Id,
         "url": arguments["url"].getStr()})
    return %*{"content": []})

const NotUrls = ["not a url", "", "no-scheme.example.com/path", "://missing-scheme", "1http://x"]

suite "the url of a URL elicitation sent before 2026-07-28":

  test "Given a string that is not a URL, when the server asks in url mode, then it raises and sends nothing":
    let versions = askingVersions(ftUrlElicitation)
    if versions.len == 0:
      skip()
    for v in versions:
      for link in NotUrls:
        let server = newServer(McpServerCapabilities())
        let t = server.attach()
        discard server.connect(t, v, clientCapabilities = BothModes)
        expect McpPayloadError:
          discard waitFor server.elicitUrl("", "Provide your key", Id, link)
        check t.messagesOf("elicitation/create").len == 0

  test "Given a URL, when the server asks in url mode, then the request carries it as given":
    let versions = askingVersions(ftUrlElicitation)
    if versions.len == 0:
      skip()
    for v in versions:
      let server = newServer(McpServerCapabilities())
      let t = server.attach()
      discard server.connect(t, v, clientCapabilities = BothModes)
      let pending = server.elicitUrl("", "Provide your key", Id, Link)
      let asked = t.awaitRequest("elicitation/create")
      check asked.message["params"]["url"].getStr() == Link
      t.answer(asked, "", %*{"action": "decline"})
      discard waitFor pending

suite "the url of a URL elicitation asked for from 2026-07-28":

  test "Given a handler whose url is not a URL, when the tool is called, then it is an internal error and nothing is asked":
    if versionsWith(ftMultiRoundTripRequests).len == 0:
      skip()
    for v in versionsWith(ftMultiRoundTripRequests):
      for link in NotUrls:
        let server = urlServer()
        let peer = server.connect(server.attach(), v)
        let reply = peer.ask("tools/call", %*{"name": "visit", "arguments": {"url": link}},
                             meta = caps(BothModes))
        check reply.errorCode == -32603
        check not reply.hasKey("result")

  test "Given a handler whose url is a URL, when the tool is called, then the answer asks for it as given":
    if versionsWith(ftMultiRoundTripRequests).len == 0:
      skip()
    for v in versionsWith(ftMultiRoundTripRequests):
      let server = urlServer()
      let peer = server.connect(server.attach(), v)
      let reply = peer.ask("tools/call", %*{"name": "visit", "arguments": {"url": Link}},
                           meta = caps(BothModes))
      check reply["result"]["resultType"].getStr() == "input_required"
      check reply["result"]["inputRequests"]["visit"]["params"]["url"].getStr() == Link

suite "whose answer an elicitation takes (before 2026-07-28)":

  test "Given a question put to one client, when another client answers with the same id, then the question stays open until the client asked answers":
    let versions = askingVersions(ftElicitation)
    if versions.len == 0:
      skip()
    for v in versions:
      let server = newServer(McpServerCapabilities())
      let t = server.attach()
      discard server.connect(t, v, session = "asked", clientCapabilities = BothModes)
      discard server.connect(t, v, session = "other", clientCapabilities = BothModes)
      let pending = server.elicit("asked", "Your name?", Form)
      let asked = t.awaitRequest("elicitation/create", "asked")
      t.answer(asked, "other", %*{"action": "accept", "content": {"name": "mallory"}})
      settle()
      check not pending.finished
      t.answer(asked, "asked", %*{"action": "accept", "content": {"name": "ada"}})
      let reply = waitFor pending
      check reply.action == eaAccept
      check reply.content["name"].getStr() == "ada"
