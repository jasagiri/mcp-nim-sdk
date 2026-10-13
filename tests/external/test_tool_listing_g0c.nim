## How a server treats the names of its tools and the order of its list:
## a name is compared as it is written, and the list comes in the order the
## handler gave it, on every request.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness

proc namesOf(reply: JsonNode): seq[string] =
  for tool in reply["result"]["tools"]:
    result.add tool["name"].getStr()

proc refused(reply: JsonNode): bool =
  ## Whether the call was turned away for its arguments: a protocol error
  ## before 2025-11-25, a tool result with isError from it.
  reply.hasKey("error") or reply["result"]{"isError"}.getBool(false)

suite "tool names are compared as written (every version)":

  proc caseServer(ran: ref seq[string]): McpServer =
    result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
    result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
      return McpPage(items: @[
        %*{"name": "echo", "inputSchema": {"type": "object",
           "properties": {"n": {"type": "integer"}}, "required": ["n"]}},
        %*{"name": "ECHO", "inputSchema": {"type": "object",
           "properties": {"s": {"type": "string"}}, "required": ["s"]}}]))
    result.onToolCall(proc(ctx: McpRequestContext, name: string,
                           arguments: JsonNode): Future[JsonNode] {.async.} =
      ran[].add name
      return %*{"content": [{"type": "text", "text": name}]})

  test "Given tools echo and ECHO with different required arguments, when each is called with its own, then each is checked against its own schema":
    for v in SupportedProtocolVersions:
      let ran = new(seq[string])
      let server = caseServer(ran)
      let peer = server.connect(server.attach(), v)
      check not peer.ask("tools/call", %*{"name": "echo", "arguments": {"n": 1}}).refused
      check not peer.ask("tools/call", %*{"name": "ECHO", "arguments": {"s": "x"}}).refused
      check peer.ask("tools/call", %*{"name": "ECHO", "arguments": {"n": 1}}).refused
      check peer.ask("tools/call", %*{"name": "echo", "arguments": {"s": "x"}}).refused
      check ran[] == @["echo", "ECHO"]

  test "Given only a tool echo that needs n, when Echo is called without it, then Echo is not echo and the handler is asked":
    for v in SupportedProtocolVersions:
      let ran = new(seq[string])
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
        return McpPage(items: @[%*{"name": "echo", "inputSchema": {"type": "object",
          "properties": {"n": {"type": "integer"}}, "required": ["n"]}}]))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        ran[].add name
        return %*{"content": [{"type": "text", "text": name}]})
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/call", %*{"name": "echo"}).refused
      check ran[].len == 0
      check not peer.ask("tools/call", %*{"name": "Echo"}).refused
      check ran[] == @["Echo"]

suite "the order of the tool list (every version)":

  proc orderedServer(): McpServer =
    result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
    result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
      proc tool(name: string): JsonNode = %*{"name": name, "inputSchema": {"type": "object"}}
      if cursor.isNone:
        return McpPage(items: @[tool("zeta"), tool("alpha")], nextCursor: some("more"))
      return McpPage(items: @[tool("mid"), tool("beta")]))

  test "Given a handler that lists zeta, alpha, mid and beta over two pages, when a client lists them twice, then both lists are in that order":
    for v in SupportedProtocolVersions:
      let server = orderedServer()
      let peer = server.connect(server.attach(), v)
      for _ in 1 .. 2:
        let first = peer.ask("tools/list")
        let second = peer.ask("tools/list", %*{"cursor": first["result"]["nextCursor"].getStr()})
        check first.namesOf & second.namesOf == @["zeta", "alpha", "mid", "beta"]
