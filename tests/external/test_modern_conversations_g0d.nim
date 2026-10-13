## A 2026-07-28 server holds no state between requests, so requests of
## several conversations that overlap in time are each served on their own
## metadata and answered on their own id.

import std/[unittest, asyncdispatch, json, options, tables]
import ./server_harness

type Gates = TableRef[string, Future[void]]

proc conversationServer(gates: Gates): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    let key = arguments["conversation"].getStr()
    gates[key] = newFuture[void]("gate " & key)
    await gates[key]
    return %*{"content": [{"type": "text", "text": $(%*{
      "conversation": key, "capabilities": ctx.declaredCapabilities})}]})

suite "overlapping conversations on one 2026-07-28 server":

  test "Given requests of three conversations in flight at once, when they finish in another order, then each is answered on its own id with its own declared capabilities":
    for v in SupportedProtocolVersions:
      if not isModern(v): continue
      let gates = newTable[string, Future[void]]()
      let server = conversationServer(gates)
      let t = server.attach()
      let peer = server.connect(t, v)
      let declared = {
        "a": %*{"sampling": {}},
        "b": %*{},
        "c": %*{"roots": {"listChanged": true}}}.toOrderedTable
      for key, capabilities in declared:
        peer.send(%("id-" & key), "tools/call", %*{"name": "t", "arguments": {"conversation": key}},
          meta = %*{"io.modelcontextprotocol/clientCapabilities": capabilities})
      untilTrue("all three handlers to wait", proc(): bool = gates.len == 3)
      for key in ["c", "a", "b"]:
        gates[key].complete()
        let answer = t.responseTo("id-" & key)
        let body = parseJson(answer["result"]["content"][0]["text"].getStr())
        check body["conversation"].getStr() == key
        check body["capabilities"] == declared[key]
