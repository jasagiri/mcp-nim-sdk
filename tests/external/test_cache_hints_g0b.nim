## 2026-07-28 caching hints (server/utilities/caching): which results carry
## them, and that every page of a list carries the same ones.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness
import server/pagination
import protocol/modern

proc source(prefix: string, count: int): ListAll =
  proc(): Future[seq[JsonNode]] {.async.} =
    for i in 1 .. count:
      result.add %*{"name": prefix & $i, "uri": "file:///" & prefix & $i,
                    "uriTemplate": "file:///" & prefix & $i & "/{x}",
                    "inputSchema": {"type": "object"}}

proc cachedServer(policy: CachePolicy, pageSize = 0): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()),
    resources: some(McpResourcesCapability()),
    prompts: some(McpPromptsCapability())))
  result.cachePolicy = policy
  result.onToolsList(pagedList(source("tool", 5), pageSize))
  result.onPromptsList(pagedList(source("prompt", 5), pageSize))
  result.onResourcesList(pagedList(source("res", 5), pageSize))
  result.onResourceTemplatesList(pagedList(source("tpl", 5), pageSize))
  result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    return @[%*{"uri": uri, "text": "body"}])

let
  Cacheable = [
    ("server/discover", newJObject()),
    ("prompts/list", newJObject()),
    ("resources/list", newJObject()),
    ("resources/templates/list", newJObject()),
    ("resources/read", %*{"uri": "file:///a"})]
  Lists = ["tools/list", "prompts/list", "resources/list", "resources/templates/list"]

suite "cache hints on the results of the cacheable methods":

  test "Given a public cache policy, when each cacheable method is asked, then its complete result carries that ttlMs and cacheScope":
    let versions = versionsWith(ftCacheHints)
    if versions.len == 0:
      skip()
    for v in versions:
      for (name, params) in Cacheable:
        let server = cachedServer(CachePolicy(ttlMs: 60000, scope: csPublic))
        let reply = server.connect(server.attach(), v).ask(name, params)
        check reply["result"]["resultType"].getStr() == "complete"
        check reply["result"]["ttlMs"].getInt() == 60000
        check reply["result"]["cacheScope"].getStr() == "public"

  test "Given a server with no cache policy, when each cacheable method is asked, then its result is not reusable and private":
    let versions = versionsWith(ftCacheHints)
    if versions.len == 0:
      skip()
    for v in versions:
      for (name, params) in Cacheable:
        let server = cachedServer(UncachedPolicy)
        let reply = server.connect(server.attach(), v).ask(name, params)
        check reply["result"]["ttlMs"].getInt() == 0
        check reply["result"]["cacheScope"].getStr() == "private"

suite "cache hints on every page of a list":

  test "Given any cache policy, when every page of a list is followed, then every page carries the policy's cacheScope and ttlMs":
    let versions = versionsWith(ftCacheHints)
    if versions.len == 0:
      skip()
    let policies = [
      CachePolicy(ttlMs: 0, scope: csPrivate), CachePolicy(ttlMs: 1, scope: csPublic),
      CachePolicy(ttlMs: 300000, scope: csPrivate), CachePolicy(ttlMs: 300000, scope: csPublic)]
    for v in versions:
      for policy in policies:
        for name in Lists:
          let server = cachedServer(policy, pageSize = 2)
          let peer = server.connect(server.attach(), v)
          var cursor = ""
          var pages = 0
          while true:
            let params = if cursor == "": newJObject() else: %*{"cursor": cursor}
            let reply = peer.ask(name, params)
            check reply["result"]["cacheScope"].getStr() == $policy.scope
            check reply["result"]["ttlMs"].getInt() == policy.ttlMs.int
            inc pages
            cursor = reply["result"]{"nextCursor"}.getStr()
            if cursor == "":
              break
          check pages == 3
