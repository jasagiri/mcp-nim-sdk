## Caching (2026-07-28): "Servers MUST provide a ttlMs value that is >= 0".
## A ttlMs a handler set that is below zero or not an integer is the handler's
## defect: the client is told of an internal error and gets no result.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness

proc serverWithTtl(ttl: JsonNode): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.addRequestInterceptor(proc(ctx: McpRequestContext,
                                    request: JsonRpcRequest): Future[Option[JsonRpcResponse]] {.async.} =
    if request.`method` == "tools/list":
      return some(newJsonRpcResponse(request.id, %*{"tools": [], "ttlMs": ttl}))
    return none(JsonRpcResponse))

suite "a ttlMs below zero":

  test "Given a handler whose tools/list result says ttlMs -5, when a 2026-07-28 client lists tools, then the answer is an internal error and no result carries a negative ttlMs":
    for v in versionsWith(ftCacheHints):
      let server = serverWithTtl(%(-5))
      let reply = server.connect(server.attach(), v).ask("tools/list")
      check reply.errorCode == -32603
      check not reply.hasKey("result")

  test "Given a handler whose tools/list result says ttlMs is not a number, when a 2026-07-28 client lists tools, then the answer is an internal error":
    for v in versionsWith(ftCacheHints):
      let server = serverWithTtl(%"soon")
      let reply = server.connect(server.attach(), v).ask("tools/list")
      check reply.errorCode == -32603

  test "Given a handler whose tools/list result says ttlMs 0 or a positive number, when a 2026-07-28 client lists tools, then the result carries that ttlMs":
    for v in versionsWith(ftCacheHints):
      for ttl in [0, 1, 60000]:
        let server = serverWithTtl(%ttl)
        let reply = server.connect(server.attach(), v).ask("tools/list")
        check reply.hasKey("result")
        check reply["result"]["ttlMs"].getInt() == ttl

  test "Given a handler whose tools/list result says a ttlMs that is a fraction or a boolean, when a 2026-07-28 client lists tools, then the answer is an internal error":
    for v in versionsWith(ftCacheHints):
      for ttl in [%1.5, %true, newJNull()]:
        let server = serverWithTtl(ttl)
        let reply = server.connect(server.attach(), v).ask("tools/list")
        check reply.errorCode == -32603
        check not reply.hasKey("result")

  test "Given a handler whose tools/list result says a cacheScope that is neither public nor private, when a 2026-07-28 client lists tools, then the answer is an internal error":
    for v in versionsWith(ftCacheHints):
      for scope in [%"shared", %1]:
        let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
        server.addRequestInterceptor(proc(ctx: McpRequestContext,
                                          request: JsonRpcRequest): Future[Option[JsonRpcResponse]] {.async.} =
          if request.`method` == "tools/list":
            return some(newJsonRpcResponse(request.id, %*{"tools": [], "ttlMs": 5, "cacheScope": scope}))
          return none(JsonRpcResponse))
        let reply = server.connect(server.attach(), v).ask("tools/list")
        check reply.errorCode == -32603
        check not reply.hasKey("result")

  test "Given a handler whose tools/list result says ttlMs 5 and cacheScope public, when a 2026-07-28 client lists tools, then both are sent as set":
    for v in versionsWith(ftCacheHints):
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.addRequestInterceptor(proc(ctx: McpRequestContext,
                                        request: JsonRpcRequest): Future[Option[JsonRpcResponse]] {.async.} =
        if request.`method` == "tools/list":
          return some(newJsonRpcResponse(request.id, %*{"tools": [], "ttlMs": 5, "cacheScope": "public"}))
        return none(JsonRpcResponse))
      let reply = server.connect(server.attach(), v).ask("tools/list")
      check reply["result"]["ttlMs"].getInt() == 5
      check reply["result"]["cacheScope"].getStr() == "public"
