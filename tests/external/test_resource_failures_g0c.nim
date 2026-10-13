## A resource handler that breaks is the server's defect: the peer is told
## it was an internal error and is not given the cause.

import std/[unittest, asyncdispatch, json, options, strutils]
import ./server_harness

proc breakingServer(): McpServer =
  result = newServer(McpServerCapabilities(resources: some(McpResourcesCapability())))
  result.onResourcesList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    raise newException(ValueError, "secret listing detail"))
  result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    raise newException(IOError, "secret reading detail"))

suite "a resource handler that breaks (every version)":

  test "Given a resources/read handler that raises, when a client reads, then the answer is -32603 without the cause":
    for v in SupportedProtocolVersions:
      let server = breakingServer()
      let reply = server.connect(server.attach(), v).ask("resources/read", %*{"uri": "file:///a"})
      check reply.errorCode == -32603
      check "secret" notin $reply
      check not reply.hasKey("result")

  test "Given a resources/list handler that raises, when a client lists, then the answer is -32603 without the cause":
    for v in SupportedProtocolVersions:
      let server = breakingServer()
      let reply = server.connect(server.attach(), v).ask("resources/list")
      check reply.errorCode == -32603
      check "secret" notin $reply
      check not reply.hasKey("result")
