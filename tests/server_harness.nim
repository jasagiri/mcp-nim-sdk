## What the server tests share: a server on a transport that serves several
## clients, a way to speak either protocol era to it, and waits that fail
## instead of hanging.

import std/[asyncdispatch, json]
import server/server
import protocol/types
import protocol/lifecycle
import protocol/features
import ./sessioned_transport

export sessioned_transport, server, types, lifecycle, features

const
  PollMs = 2
  PatienceMs = 2000

type
  Peer* = object
    ## A client of the server: its session and the version it speaks.
    transport*: SessionedTransport
    session*: string
    version*: McpProtocolVersion

var idCounter = 0

proc freshId*(): string =
  inc idCounter
  "t" & $idCounter

proc legacyVersions*(): seq[McpProtocolVersion] =
  for v in SupportedProtocolVersions:
    if not isModern(v):
      result.add v

proc modernMeta*(extra: JsonNode = nil): JsonNode =
  result = %*{"io.modelcontextprotocol/protocolVersion": "2026-07-28",
              "io.modelcontextprotocol/clientInfo": {"name": "test-client", "version": "1"},
              "io.modelcontextprotocol/clientCapabilities": {}}
  if not extra.isNil:
    for key, value in extra.pairs:
      result[key] = value

proc settle*() =
  ## Let the server's pending work run.
  waitFor sleepAsync(20)

proc untilTrue*(what: string, check: proc(): bool, ms = PatienceMs) =
  var waited = 0
  while not check():
    if waited >= ms:
      raise newException(AssertionDefect, "timed out waiting for " & what)
    waitFor sleepAsync(PollMs)
    waited += PollMs

proc attach*(server: McpServer): SessionedTransport =
  result = newSessionedTransport()
  waitFor server.attachTransport(result)

proc rpcRequest*(id: string, methodName: string, params: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "method": methodName, "params": params}

proc rpcNotification*(methodName: string, params: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "method": methodName, "params": params}

proc responseTo*(t: SessionedTransport, id: string): JsonNode =
  untilTrue("the response to " & id, proc(): bool =
    for s in t.sent:
      if not s.message.hasKey("method") and s.message{"id"}.getStr() == id:
        return true
    false)
  for s in t.sent:
    if not s.message.hasKey("method") and s.message{"id"}.getStr() == id:
      return s.message

proc messagesOf*(t: SessionedTransport, methodName: string): seq[Sent] =
  ## What the server sent with this method, request or notification.
  for s in t.sent:
    if s.message{"method"}.getStr() == methodName:
      result.add s

proc connect*(server: McpServer, t: SessionedTransport, version: McpProtocolVersion,
              session = "", clientCapabilities: JsonNode = nil): Peer =
  ## A client that speaks `version`: legacy ones handshake on `session`,
  ## 2026-07-28 ones need nothing.
  result = Peer(transport: t, session: session, version: version)
  if not isModern(version):
    let id = freshId()
    t.inject(session, rpcRequest(id, "initialize", %*{
      "protocolVersion": $version,
      "capabilities": if clientCapabilities.isNil: newJObject() else: clientCapabilities,
      "clientInfo": {"name": "test-client", "version": "1"}}))
    discard t.responseTo(id)
    t.inject(session, rpcNotification("notifications/initialized", newJObject()))
    untilTrue("the session to be operational", proc(): bool =
      server.session(session).state == mlsOperational)

proc ask*(peer: Peer, methodName: string, params: JsonNode = nil,
          meta: JsonNode = nil): JsonNode =
  ## The response to a request in the peer's era. `meta` adds to the
  ## request's `_meta` (a progress token, a log level).
  let id = freshId()
  var body = if params.isNil: newJObject() else: params.copy()
  if isModern(peer.version) or not meta.isNil:
    let merged = if isModern(peer.version): modernMeta(meta) else: meta
    body["_meta"] = merged
  peer.transport.inject(peer.session, rpcRequest(id, methodName, body))
  peer.transport.responseTo(id)

proc send*(peer: Peer, id: JsonNode, methodName: string, params: JsonNode,
           meta: JsonNode = nil) =
  ## Send a request without waiting for its answer.
  var body = params.copy()
  if isModern(peer.version) or not meta.isNil:
    body["_meta"] = if isModern(peer.version): modernMeta(meta) else: meta
  peer.transport.inject(peer.session, %*{"jsonrpc": "2.0", "id": id,
                                          "method": methodName, "params": body})

proc notify*(peer: Peer, methodName: string, params: JsonNode) =
  peer.transport.inject(peer.session, rpcNotification(methodName, params))

proc errorCode*(response: JsonNode): int =
  response["error"]["code"].getInt()

proc newServer*(capabilities: McpServerCapabilities): McpServer =
  newMcpServer(McpServerInfo(name: "test-server", version: "1"),
               capabilities = capabilities)

proc textOf*(response: JsonNode): string =
  response["result"]["content"][0]["text"].getStr()

proc versionsWith*(feature: McpFeature): seq[McpProtocolVersion] =
  for v in SupportedProtocolVersions:
    if v.has(feature):
      result.add v

proc versionsWithout*(feature: McpFeature): seq[McpProtocolVersion] =
  for v in SupportedProtocolVersions:
    if not v.has(feature):
      result.add v
