## completion/complete: how a client reads an answer that leaves out the
## optional parts.

import std/[unittest, asyncdispatch, json, options]
import client/client
import client/utilities
import ./client_peer

let Completes = %*{"completions": {}}

proc completingPeer(completion: JsonNode): Peer =
  startPeer(proc(peer: Peer, message: JsonNode) =
    if message{"method"}.getStr() == "completion/complete":
      peer.reply(message["id"], %*{"completion": completion}),
    capabilities = Completes)

suite "an answer to completion/complete that leaves parts out":

  test "Given an answer with values only, when a client completes, then the values are read and total and hasMore are absent":
    let client = completingPeer(%*{"values": ["python", "pytorch"]}).connectedClient(LegacyDefault)
    let completion = waitFor client.complete(promptRef("p"), "language", "py")
    check completion.values == @["python", "pytorch"]
    check completion.total.isNone
    check completion.hasMore.isNone

  test "Given an answer with no values, when a client completes, then there are no suggestions and no error":
    let client = completingPeer(%*{"values": []}).connectedClient(LegacyDefault)
    let completion = waitFor client.complete(promptRef("p"), "language", "zz")
    check completion.values.len == 0

  test "Given an answer with a total and no hasMore, when a client completes, then the total is read and hasMore is absent":
    let client = completingPeer(%*{"values": ["a"], "total": 7}).connectedClient(LegacyDefault)
    let completion = waitFor client.complete(promptRef("p"), "x", "")
    check completion.total == some(7)
    check completion.hasMore.isNone

  test "Given an answer whose completion has no values, when a client completes, then McpProtocolError is raised":
    let client = completingPeer(%*{"total": 1}).connectedClient(LegacyDefault)
    expect McpProtocolError:
      discard waitFor client.complete(promptRef("p"), "x", "")

  test "Given an answer whose hasMore is not a boolean, when a client completes, then McpProtocolError is raised":
    let client = completingPeer(%*{"values": ["a"], "hasMore": "yes"}).connectedClient(LegacyDefault)
    expect McpProtocolError:
      discard waitFor client.complete(promptRef("p"), "x", "")
