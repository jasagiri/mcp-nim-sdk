## roots/list (before 2026-07-28): a root is a file:// URI, so the client
## sends no other kind and says why it did not.

import std/[unittest, asyncdispatch, json, options]
import client/client
import client/roots
import protocol/lifecycle
import ./client_peer

proc answerTo(peer: Peer, id: string): JsonNode =
  waitFor sleepAsync(5)
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
      return message
  nil

proc askForRoots(roots: seq[McpRoot]): tuple[answer: JsonNode, client: McpClient] =
  let peer = startPeer(nil)
  let client = peer.connectedClient(LegacyDefault, proc(client: McpClient) =
    client.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} = return roots))
  peer.ask(%"r1", "roots/list")
  (answer: peer.answerTo("r1"), client: client)

suite "the roots a client lists are file URIs":

  test "Given a roots provider that offers an https root, when the server asks, then the answer is an internal error and no root is listed":
    let asked = askForRoots(@[McpRoot(uri: "https://example.com/project", name: some("web"))])
    check not asked.answer.isNil
    check not asked.answer.hasKey("result")
    check asked.answer["error"]["code"].getInt() == -32603
    check asked.answer["error"]["message"].getStr() == "roots/list: a root's uri is not a file:// URI"

  test "Given a provider whose second root is not a file URI, when the server asks, then no root is listed":
    let asked = askForRoots(@[McpRoot(uri: "file:///home/a"), McpRoot(uri: "http://host/b")])
    check not asked.answer.hasKey("result")

  test "Given a root that is only a path, or has no scheme, when the server asks, then it is refused":
    for uri in ["/home/a", "", "file:/home/a", "FILE:///home/a"]:
      let asked = askForRoots(@[McpRoot(uri: uri)])
      check asked.answer["error"]["code"].getInt() == -32603

  test "Given roots that are file URIs, when the server asks, then all are listed as given":
    let asked = askForRoots(@[McpRoot(uri: "file:///home/a", name: some("a")),
                              McpRoot(uri: "file://host/b")])
    check asked.answer["result"]["roots"] == %*[{"uri": "file:///home/a", "name": "a"},
                                                 {"uri": "file://host/b"}]

  test "Given a refused root, when the server asks again with good roots, then the client is still operational":
    let peer = startPeer(nil)
    var roots = @[McpRoot(uri: "https://example.com/project")]
    let client = peer.connectedClient(LegacyDefault, proc(client: McpClient) =
      client.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} = return roots))
    peer.ask(%"r1", "roots/list")
    check peer.answerTo("r1").hasKey("error")
    roots = @[McpRoot(uri: "file:///home/a")]
    peer.ask(%"r2", "roots/list")
    check peer.answerTo("r2")["result"]["roots"].len == 1
    check client.state == mlsOperational
