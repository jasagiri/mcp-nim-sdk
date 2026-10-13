## The elicitationId of a URL mode request is opaque to the client, said as
## properties over ids of any shape: the application sees the id exactly as
## sent, and a completion that names it only after trimming it or changing
## its case is not that request.

import std/[unittest, asyncdispatch, json, strutils]
import client/client
import client/elicitation
import protocol/types
import propcheck
import ./client_peer

proc guarded[T](body: proc(x: T): bool): Property[T] =
  ## A property whose body may raise what the SDK's setup raises: anything it raises
  ## is a counterexample, named by its type and message.
  result = proc(x: T): bool {.raises: [CatchableError].} =
    try:
      body(x)
    except CatchableError:
      raise
    except Exception as e:
      raise newException(CatchableError, "raised " & $e.name & ": " & e.msg)

proc responseTo(peer: Peer, id: string): JsonNode =
  waitFor sleepAsync(5)
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
      return message
  nil

const Link = "https://mcp.example.com/ui/set_api_key"

let
  # Space: an id of one to six pieces, each a letter in either case, a digit, padding, a
  # line break, a percent escape, a bracket or a quote, a slash or a colon, or non-ASCII text.
  anyId = map(seqOf(pick(["a", "Z", "k", "0", "7", " ", "\t", "\n", "%20", "%2F", "{", "}", "\"", "[", "]",
                          "/", ":", "http://", "?q=1", "#f", "-", "_", "ü", "日本", "É"]), 1, 6),
    proc(pieces: seq[string]): string {.raises: [].} = pieces.join(""))

proc variantsOf(id: string): seq[string] =
  ## What a client that normalized the id would treat as the same.
  @[id.strip(), id.toLowerAscii(), id.toUpperAscii(), id & " ", " " & id]

suite "The elicitationId is opaque":

  test "Given any elicitationId, when a URL request arrives, then the handler sees the id exactly":
    if LegacyDefault < mpv20251125:
      skip()
    else:
      let outcome = propcheck.check(anyId,
        guarded(proc(id: string): bool =
          var seen = ""
          var asked = false
          let peer = startPeer(nil)
          discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
            client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
              asked = true
              seen = request.elicitationId
              return McpElicitResult(action: eaAccept), {emForm, emUrl}))
          peer.ask(%"u1", "elicitation/create",
                   %*{"mode": "url", "message": "Provide your key", "elicitationId": id, "url": Link})
          let reply = peer.responseTo("u1")
          not reply.isNil and reply["result"] == %*{"action": "accept"} and asked and seen == id))
      checkpoint describe(outcome)
      check outcome.passed

  test "Given any elicitationId of an accepted request, when a completion names it only after normalizing it, then it is not that request, and one that names it exactly is":
    if LegacyDefault < mpv20251125:
      skip()
    else:
      let outcome = propcheck.check(anyId,
        guarded(proc(id: string): bool =
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
          if completed.len != 0:
            return false
          peer.push("notifications/elicitation/complete", %*{"elicitationId": id})
          waitFor sleepAsync(10)
          completed == @[id]))
      checkpoint describe(outcome)
      check outcome.passed
