## 2026-07-28: the client MUST NOT write JSON-RPC responses (stdio and
## Streamable HTTP). A request from the server is reported on stderr and
## answered with nothing. Before that version the client answers.

import std/[unittest, asyncdispatch, json, os, strutils]
import client/client
import client/sampling
import protocol/types
import transport/transport
import ./client_peer
from ./server_harness import untilTrue

proc loggedWhile(body: proc()): string =
  let path = getTempDir() / "mcp-client-silent-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc responses(peer: Peer): seq[JsonNode] =
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method"):
      result.add message

proc sampler(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
  raise newException(ValueError, "the handler must not run")

suite "a client of 2026-07-28 writes no response":

  test "Given a 2026-07-28 connection, when the server sends requests, then no response is written and each request is reported on stderr":
    for v in SupportedProtocolVersions:
      if not isModern(v): continue
      for kind in [mtkStdio, mtkHttp]:
        let peer = startPeer(proc(peer: Peer, message: JsonNode) =
          if message{"method"}.getStr() == "tools/list":
            peer.reply(message["id"], %*{"resultType": "complete", "tools": []}),
          modern = true, kind = kind)
        let client = peer.connectedClient(v, proc(client: McpClient) =
          client.setSamplingHandler(sampler))
        let log = loggedWhile(proc() =
          for name in ["ping", "sampling/createMessage", "roots/list", "no/such/method"]:
            peer.ask(%name, name)
          # The client takes its messages in the order they came: when the
          # answer to its own request is in, the four above have been handled.
          discard waitFor client.callMethod("tools/list", newJObject()))
        check peer.responses().len == 0
        for name in ["ping", "sampling/createMessage", "roots/list", "no/such/method"]:
          check ("request " & name & " from the server ignored") in log

  test "Given a 2026-07-28 connection, when the server sends a request, then the client carries on with its own":
    for v in SupportedProtocolVersions:
      if not isModern(v): continue
      let peer = startPeer(proc(peer: Peer, message: JsonNode) =
        if message{"method"}.getStr() == "tools/list":
          peer.reply(message["id"], %*{"resultType": "complete", "tools": []}),
        modern = true)
      let client = peer.connectedClient(v)
      peer.ask(%"s1", "ping")
      discard waitFor client.callMethod("tools/list", newJObject())
      check peer.responses().len == 0

  test "Given a version before 2026-07-28, when the server sends a ping, then the client answers it":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let peer = startPeer(nil)
      discard peer.connectedClient(v)
      peer.ask(%"p1", "ping")
      untilTrue("the answer to the ping", proc(): bool = peer.responses().len >= 1)
      check peer.responses().len == 1
      check peer.responses()[0]["result"] == newJObject()

  test "Given a version before 2026-07-28, when the server sends a request the client cannot serve, then the client answers method not found":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let peer = startPeer(nil)
      discard peer.connectedClient(v)
      peer.ask(%"x1", "no/such/method")
      untilTrue("the answer to the request", proc(): bool = peer.responses().len >= 1)
      check peer.responses()[0]["error"]["code"].getInt() == -32601
