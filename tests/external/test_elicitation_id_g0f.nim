## The elicitationId of a URL mode request is opaque to the client (schema
## ElicitRequestURLParams of 2025-11-25): the client hands it to the
## application as it came, and matches the completion notification by the
## exact string, never by a reading of it.

import std/[unittest, asyncdispatch, json, strutils]
import client/client
import client/elicitation
import protocol/types
import ./client_peer

proc responseTo(peer: Peer, id: string): JsonNode =
  waitFor sleepAsync(5)
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
      return message
  nil

const
  Link = "https://mcp.example.com/ui/set_api_key"
  ## Ids that a client reading them would change: padding, case, a
  ## URL-looking id, non-ASCII, a number, one that looks like JSON, one with
  ## percent escapes or a line break.
  Ids = [" padded ", "MixedCase-Id", "https://Host.Example/Path?q=1#frag", "ünïcödé-ID",
         "12345", "{\"a\": 1}", "a%20b", "line\nbreak", "550E8400-E29B-41D4-A716-446655440000"]

proc variantsOf(id: string): seq[string] =
  ## What a client that normalized the id would treat as the same.
  result = @[id.strip(), id.toLowerAscii(), id.toUpperAscii(), id & " ", " " & id]

if LegacyDefault >= mpv20251125:
  suite "The elicitationId is opaque":
    test "Given ids of every awkward shape, when a URL request arrives, then the handler sees the id exactly":
      for id in Ids:
        var seen = ""
        let peer = startPeer(nil)
        discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
          client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
            seen = request.elicitationId
            return McpElicitResult(action: eaAccept), {emForm, emUrl}))
        peer.ask(%"u1", "elicitation/create",
                 %*{"mode": "url", "message": "Provide your key", "elicitationId": id, "url": Link})
        check peer.responseTo("u1")["result"] == %*{"action": "accept"}
        check seen == id

    test "Given an accepted request, when a completion names the id only after normalizing it, then it is not that request":
      for id in Ids:
        var completed: seq[string]
        let peer = startPeer(nil)
        discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
          client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
            return McpElicitResult(action: eaAccept), {emForm, emUrl},
            onComplete = proc(elicitationId: string) = completed.add elicitationId))
        peer.ask(%"u1", "elicitation/create",
                 %*{"mode": "url", "message": "Provide your key", "elicitationId": id, "url": Link})
        discard peer.responseTo("u1")
        for variant in variantsOf(id):
          if variant != id:
            peer.push("notifications/elicitation/complete", %*{"elicitationId": variant})
        waitFor sleepAsync(10)
        check completed.len == 0
        peer.push("notifications/elicitation/complete", %*{"elicitationId": id})
        waitFor sleepAsync(10)
        check completed == @[id]
