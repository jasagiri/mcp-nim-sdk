## How a server treats the names of its tools and the order of its list,
## said as properties: a name is compared as it is written, whatever tools
## differ in letter case, and the list comes in the order the handler gave
## it, over any number of pages and on every request.

import std/[unittest, asyncdispatch, json, options, strutils, sequtils]
import propcheck
import ./server_harness

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

let anyVersion = pick(SupportedProtocolVersions)

proc refused(reply: JsonNode): bool =
  ## Whether the call was turned away for its arguments: a protocol error
  ## before 2025-11-25, a tool result with isError from it.
  reply.hasKey("error") or reply["result"]{"isError"}.getBool(false)

# --- names compared as written (MCP-TOOLS-7) --------------------------------------

type
  Spelling = (int, seq[bool])   ## one of two words, with the letters that are in capitals
  Call = (Spelling, int)        ## the name called, and the tool whose required argument is given
  Case = object
    version: McpProtocolVersion
    tools: seq[Spelling]
    calls: seq[Call]

const Words = ["echo", "fetch"]

proc written(s: Spelling): string =
  for i, c in Words[s[0]]:
    result.add if i < s[1].len and s[1][i]: c.toUpperAscii else: c

let
  anySpelling = pair(intIn(0, Words.len - 1), seqOf(boolean(), 0, 5))
  anyCase = map(
    pair(anyVersion, pair(seqOf(anySpelling, 1, 3), seqOf(pair(anySpelling, intIn(0, 2)), 1, 4))),
    proc(x: (McpProtocolVersion, (seq[Spelling], seq[Call]))): Case {.raises: [].} =
      # tools whose names come out the same as an earlier one's are left out: the list holds each name once
      var tools: seq[Spelling]
      for s in x[1][0]:
        if tools.mapIt(written(it)).find(written(s)) < 0:
          tools.add s
      Case(version: x[0], tools: tools, calls: x[1][1]))

suite "tool names are compared as written (every version)":

  test "Given any tools whose names differ in letter case, when any name is called with the argument of any tool, then a listed name is checked against its own schema and a name that is not listed is left to the handler":
    # Space: one to three tools named by two words in any capitalisation (so many differ only
    # in case), each requiring an argument of its own; calls to those names and to others
    # that match one only when case is ignored, with the argument of any one tool.
    let outcome = propcheck.check(anyCase,
      guarded(proc(c: Case): bool =
        var ran: seq[string]
        let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
        server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
          var items: seq[JsonNode]
          for i, t in c.tools:
            items.add %*{"name": written(t), "inputSchema": {"type": "object",
              "properties": {"p" & $i: {"type": "integer"}}, "required": ["p" & $i]}}
          return McpPage(items: items))
        server.onToolCall(proc(ctx: McpRequestContext, name: string,
                               arguments: JsonNode): Future[JsonNode] {.async.} =
          ran.add name
          return %*{"content": [{"type": "text", "text": name}]})
        let peer = server.connect(server.attach(), c.version)
        var expected: seq[string]
        for (spelling, given) in c.calls:
          let name = written(spelling)
          let reply = peer.ask("tools/call", %*{"name": name, "arguments": {"p" & $given: 1}})
          var owner = -1
          for i, t in c.tools:
            if written(t) == name: owner = i
          let shouldRun = owner < 0 or owner == given
          if shouldRun: expected.add name
          if reply.refused == shouldRun:
            return false
        ran == expected))
    checkpoint describe(outcome)
    check outcome.passed

# --- the order of the list (MCP-TOOLS-8) -------------------------------------------

type
  Listing = object
    version: McpProtocolVersion
    names: seq[string]
    pageSize: int
    times: int

let anyListing = map(
  pair(pair(anyVersion, seqOf(stringOf("abcdefghijklmnopqrstuvwxyz", 1, 4), 0, 8)),
       pair(intIn(1, 4), intIn(1, 3))),
  proc(x: ((McpProtocolVersion, seq[string]), (int, int))): Listing {.raises: [].} =
    # a name once: the handler lists distinct tools, in the order it makes them
    var names: seq[string]
    for n in x[0][1]:
      if n notin names: names.add n
    Listing(version: x[0][0], names: names, pageSize: x[1][0], times: x[1][1]))

suite "the order of the tool list (every version)":

  test "Given any tools that a handler lists in an order over one page or several, when a client lists them more than once, then each list holds the tools in the order the handler gave them":
    # Space: zero to eight tools of distinct names in any order, cut into pages of one to four,
    # listed one to three times.
    let outcome = propcheck.check(anyListing,
      guarded(proc(l: Listing): bool =
        let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
        server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
          let start = if cursor.isSome: cursor.get.len else: 0   # the cursor is as many marks as tools before it
          var page = McpPage()
          for i in start ..< min(start + l.pageSize, l.names.len):
            page.items.add %*{"name": l.names[i], "inputSchema": {"type": "object"}}
          if start + l.pageSize < l.names.len:
            page.nextCursor = some('#'.repeat(start + l.pageSize))
          return page)
        let peer = server.connect(server.attach(), l.version)
        for _ in 1 .. l.times:
          var listed: seq[string]
          var cursor = ""
          for _ in 0 .. l.names.len:       # more requests than there are pages
            let reply = peer.ask("tools/list", if cursor == "": newJObject() else: %*{"cursor": cursor})
            if not reply.hasKey("result"): return false
            for tool in reply["result"]["tools"]:
              listed.add tool["name"].getStr()
            cursor = reply["result"]{"nextCursor"}.getStr()
            if cursor == "": break
          if listed != l.names: return false
        true))
    checkpoint describe(outcome)
    check outcome.passed
