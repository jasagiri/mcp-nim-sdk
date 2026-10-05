## A hand-written MCP server for client tests: it answers the handshake
## and hands every other message to a callback, so a test decides exactly
## what the client sees.

import std/[asyncdispatch, json]
import client/client
import protocol/types
import transport/transport
import ./loopback_transport

const
  LegacyDefault* = min(DefaultProtocolVersion, mpv20251125)
  SpeaksModern* = isModern(DefaultProtocolVersion)

type
  Peer* = ref object
    pair*: tuple[client, server: LoopbackTransport]
    received*: seq[JsonNode]  ## every message the client sent, handshake included
    handler*: proc(peer: Peer, message: JsonNode)

proc reply*(peer: Peer, id: JsonNode, resultJson: JsonNode) =
  peer.pair.client.inject(%*{"jsonrpc": "2.0", "id": id, "result": resultJson})

proc replyError*(peer: Peer, id: JsonNode, code: int, message: string) =
  peer.pair.client.inject(%*{"jsonrpc": "2.0", "id": id,
                             "error": {"code": code, "message": message}})

proc push*(peer: Peer, methodName: string, params: JsonNode = newJObject()) =
  ## A notification from the server.
  peer.pair.client.inject(%*{"jsonrpc": "2.0", "method": methodName, "params": params})

proc ask*(peer: Peer, id: JsonNode, methodName: string, params: JsonNode = newJObject()) =
  ## A request from the server.
  peer.pair.client.inject(%*{"jsonrpc": "2.0", "id": id, "method": methodName, "params": params})

proc sentMethods*(peer: Peer): seq[string] =
  for message in peer.received:
    result.add message{"method"}.getStr()

proc requestsFor*(peer: Peer, methodName: string): seq[JsonNode] =
  for message in peer.received:
    if message{"method"}.getStr() == methodName:
      result.add message

proc serve(peer: Peer) {.async.} =
  try:
    while true:
      let message = await peer.pair.server.receiveMessage()
      peer.received.add message
      if not peer.handler.isNil:
        peer.handler(peer, message)
  except McpTransportError:
    discard  # the test is over

proc startPeer*(handler: proc(peer: Peer, message: JsonNode), modern = false,
                capabilities: JsonNode = %*{"tools": {}}): Peer =
  ## A peer that speaks the 2026-07-28 protocol when `modern`, else a
  ## legacy one. `handler` sees what follows the handshake.
  let peer = Peer(pair: newLoopbackPair())
  let served = capabilities
  peer.handler = proc(self: Peer, message: JsonNode) =
    case message{"method"}.getStr()
    of "server/discover":
      if modern:
        self.reply(message["id"], %*{
          "resultType": "complete",
          "supportedVersions": [$DefaultProtocolVersion],
          "capabilities": served,
          "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "peer", "version": "0"}}})
      else:
        self.replyError(message["id"], -32601, "Method not found")
    of "initialize":
      self.reply(message["id"], %*{
        "protocolVersion": message["params"]["protocolVersion"], "capabilities": served,
        "serverInfo": {"name": "peer", "version": "0"}})
    of "notifications/initialized":
      discard
    else:
      if not handler.isNil:
        handler(self, message)
  asyncCheck peer.serve()
  peer

proc connectedClient*(peer: Peer, version = DefaultProtocolVersion,
                      configure: proc(client: McpClient) = nil): McpClient =
  ## A client connected to `peer`. `configure` runs before connect().
  let client = newMcpClient(McpClientInfo(name: "test-client", version: "0"), version)
  if not configure.isNil:
    configure(client)
  waitFor client.connect(peer.pair.client)
  client
