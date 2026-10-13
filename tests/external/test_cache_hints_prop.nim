## The cache hints of 2026-07-28, said as properties: whatever cache policy a
## server holds, every cacheable method answers with it, and so does every
## page of every list; a server without a policy answers not reusable and
## private.

import std/[unittest, asyncdispatch, json, options, strutils]
import propcheck
import ./server_harness
import protocol/modern

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

const
  Cacheable = [
    ("server/discover", "{}"),
    ("prompts/list", "{}"),
    ("resources/list", "{}"),
    ("resources/templates/list", "{}"),
    ("resources/read", """{"uri": "file:///a"}""")]
  Lists = ["tools/list", "prompts/list", "resources/list", "resources/templates/list"]

type
  PolicyChoice = object
    version: McpProtocolVersion
    index: int            ## which method (of the five, or of the four lists)
    policy: Option[CachePolicy]   ## none: the server was given no policy
    pageSize: int
    items: int

proc policyOf(ttl: int, isPublic: bool): CachePolicy =
  CachePolicy(ttlMs: ttl, scope: if isPublic: csPublic else: csPrivate)

proc anyChoice(versions: seq[McpProtocolVersion], methods: int): Gen[PolicyChoice] =
  # Space: a version that has cache hints, a method, a policy of any ttl from 0 to the
  # largest a server can write and either scope or no policy at all, and a list of 0 to 9
  # items cut into pages of 1 to 4.
  map(
    pair(pair(pick(versions), intIn(0, methods - 1)),
         pair(pair(boolean(), pair(intIn(0, 4_000_000_000), boolean())), pair(intIn(1, 4), intIn(0, 9)))),
    proc(x: ((McpProtocolVersion, int), ((bool, (int, bool)), (int, int)))): PolicyChoice {.raises: [].} =
      PolicyChoice(version: x[0][0], index: x[0][1],
                   policy: if x[1][0][0]: some(policyOf(x[1][0][1][0], x[1][0][1][1])) else: none(CachePolicy),
                   pageSize: x[1][1][0], items: x[1][1][1]))

proc itemFor(name: string, i: int): JsonNode =
  %*{"name": name & $i, "uri": "file:///" & name & $i,
     "uriTemplate": "file:///" & name & $i & "/{x}", "inputSchema": {"type": "object"}}

proc cachedServer(c: PolicyChoice): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()), resources: some(McpResourcesCapability()),
    prompts: some(McpPromptsCapability())))
  if c.policy.isSome:
    result.cachePolicy = c.policy.get
  proc pages(name: string): proc(cursor: Option[string]): Future[McpPage] =
    result = proc(cursor: Option[string]): Future[McpPage] {.async.} =
      let start = if cursor.isSome: cursor.get.len else: 0   # the cursor is as many marks as items before it
      var page = McpPage()
      for i in start ..< min(start + c.pageSize, c.items):
        page.items.add itemFor(name, i)
      if start + c.pageSize < c.items:
        page.nextCursor = some('#'.repeat(start + c.pageSize))
      return page
  result.onToolsList(pages("tool"))
  result.onPromptsList(pages("prompt"))
  result.onResourcesList(pages("res"))
  result.onResourceTemplatesList(pages("tpl"))
  result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    return @[%*{"uri": uri, "text": "body"}])

proc hints(c: PolicyChoice): (int, string) =
  ## What the policy the server was given says; a server without one says not reusable and private.
  if c.policy.isSome: (c.policy.get.ttlMs.int, $c.policy.get.scope) else: (0, "private")

let versions = versionsWith(ftCacheHints)

suite "cache hints on the results of the cacheable methods (2026-07-28)":

  test "Given any cache policy or none, when any cacheable method is asked, then its complete result carries the policy's ttlMs and cacheScope":
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyChoice(versions, Cacheable.len),
        guarded(proc(c: PolicyChoice): bool =
          let (name, params) = Cacheable[c.index]
          let server = cachedServer(c)
          let reply = server.connect(server.attach(), c.version).ask(name, parseJson(params))
          let (ttl, scope) = c.hints
          reply.hasKey("result") and reply["result"]{"resultType"}.getStr() == "complete" and
            reply["result"]{"ttlMs"}.getInt(-1) == ttl and reply["result"]{"cacheScope"}.getStr() == scope))
      checkpoint describe(outcome)
      check outcome.passed

suite "cache hints on every page of a list (2026-07-28)":

  test "Given any cache policy and a list of any length cut into pages, when every page is followed from the first to the last, then every page carries the policy's cacheScope and ttlMs":
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyChoice(versions, Lists.len),
        guarded(proc(c: PolicyChoice): bool =
          let server = cachedServer(c)
          let peer = server.connect(server.attach(), c.version)
          let (ttl, scope) = c.hints
          var cursor = ""
          var pages = 0
          while true:
            let reply = peer.ask(Lists[c.index], if cursor == "": newJObject() else: %*{"cursor": cursor})
            if not reply.hasKey("result") or reply["result"]{"ttlMs"}.getInt(-1) != ttl or
               reply["result"]{"cacheScope"}.getStr() != scope:
              return false
            inc pages
            cursor = reply["result"]{"nextCursor"}.getStr()
            if cursor == "" or pages > 20:
              break
          pages <= 20))
      checkpoint describe(outcome)
      check outcome.passed
