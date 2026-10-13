## The error codes of 2026-07-28: which ones a server emits, what a client
## makes of the ones it receives, and that a failure local to the SDK is
## never given the shape of a peer's error.

import std/[unittest, asyncdispatch, json, options, strutils]
import mcp
import ./server_harness
import ./client_peer as peers

type PeerError = client.McpRequestError
  ## The error a client raises for a JSON-RPC error its peer answered with.

const
  DefinedCodes = [-32700, -32600, -32601, -32602, -32603, -32020, -32021, -32022]

proc codeServer(): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()),
    resources: some(McpResourcesCapability()),
    prompts: some(McpPromptsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "breaks":
      raise newException(ValueError, "an internal detail")
    else:
      raise newUnknownTool(name))
  result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    raise newResourceNotFound(uri))
  result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    raise newInvalidParams("Invalid prompt name: " & name))

suite "the codes a 2026-07-28 server emits":

  test "Given requests that fail in the ways a server fails, when it answers in 2026-07-28, then every code is one the specification defines":
    for v in SupportedProtocolVersions:
      if not isModern(v): continue
      let server = codeServer()
      let t = server.attach()
      let peer = server.connect(t, v)
      let withoutCapabilities = freshId()
      t.inject("", rpcRequest(withoutCapabilities, "tools/list", %*{"_meta": {
        "io.modelcontextprotocol/protocolVersion": $v,
        "io.modelcontextprotocol/clientInfo": {"name": "c", "version": "1"}}}))
      let unknownVersion = freshId()
      t.inject("", rpcRequest(unknownVersion, "tools/list", %*{"_meta": modernMeta(
        %*{"io.modelcontextprotocol/protocolVersion": "2099-01-01"})}))
      let answers = [
        peer.ask("no/such/method"),
        peer.ask("ping"),
        peer.ask("tools/call", %*{}),
        peer.ask("tools/call", %*{"name": "no-such-tool"}),
        peer.ask("tools/call", %*{"name": "breaks"}),
        peer.ask("resources/read", %*{"uri": "file:///missing"}),
        peer.ask("prompts/get", %*{"name": "missing"}),
        t.responseTo(withoutCapabilities),
        t.responseTo(unknownVersion),
      ]
      for answer in answers:
        check answer.hasKey("error")
        check answer.errorCode in DefinedCodes

  test "Given a resource that does not exist, when it is read in 2026-07-28, then the code is not the legacy -32002":
    for v in SupportedProtocolVersions:
      if not isModern(v): continue
      let server = codeServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("resources/read", %*{"uri": "file:///missing"})
      check answer.errorCode != -32002
      check answer.errorCode == -32602

  test "Given a version before 2026-07-28, when a URL elicitation is required, then the error carries -32042, and from 2026-07-28 it cannot be built":
    for v in SupportedProtocolVersions:
      let link = urlElicitationParams("Connect", "e-1", "https://example.com/connect", mpv20251125)
      if isModern(v):
        expect McpPayloadError:
          discard urlElicitationRequired(v, @[link])
      elif v.has(ftUrlElicitation):
        check urlElicitationRequired(v, @[link]).code == -32042

suite "the codes a client receives":

  test "Given errors with codes in the legacy sub-range, when a server answers a request with one, then the client raises the peer's error with that code and goes on":
    for v in SupportedProtocolVersions:
      for code in [-32000, -32001, -32002, -32010, -32019]:
        let handler = proc(peer: peers.Peer, message: JsonNode) =
          case message{"params"}{"cursor"}.getStr()
          of "fail": peer.replyError(message["id"], code, "the peer's own words")
          else: peer.reply(message["id"], %*{"tools": []})
        let peer = peers.startPeer(handler, modern = isModern(v))
        let client = peer.connectedClient(v)
        var raised: ref PeerError
        try:
          discard waitFor client.callMethod("tools/list", %*{"cursor": "fail"})
        except PeerError as e:
          raised = e
        check not raised.isNil
        check raised.code == code
        check "the peer's own words" in raised.msg
        check client.state == mlsOperational
        discard waitFor client.callMethod("tools/list", newJObject())

  test "Given a request that timed out and a connection that was closed, when they fail, then neither is a peer's error":
    for v in SupportedProtocolVersions:
      let peer = peers.startPeer(nil, modern = isModern(v))
      let client = peer.connectedClient(v)
      var timeout: ref CatchableError
      try:
        discard waitFor client.callMethod("tools/list", newJObject(),
          McpRequestOptions(timeoutMs: some(10)))
      except CatchableError as e:
        timeout = e
      check not timeout.isNil
      check timeout of McpTimeoutError
      check not (timeout of PeerError)
      let pending = client.callMethod("tools/list", newJObject(),
        McpRequestOptions(timeoutMs: some(0)))
      waitFor client.close()
      var closed: ref CatchableError
      try:
        discard waitFor pending
      except CatchableError as e:
        closed = e
      check not closed.isNil
      check closed of McpConnectionClosedError
      check not (closed of PeerError)
