## The keys of `_meta` (schema MetaObject of 2026-07-28), said as properties:
## every key the SDK writes follows the key syntax whatever it is asked, the
## values at the keys MCP reserves are not assumed to be anything (an unknown
## reserved key is passed over whatever it holds), and a key the server reads
## is checked before it is used.

import std/[unittest, asyncdispatch, json, options, strutils, sets]
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
  Letters = {'a' .. 'z', 'A' .. 'Z'}
  Digits = {'0' .. '9'}
  Alnum = Letters + Digits

# The syntax of schema MetaObject: an optional prefix, which is dot-separated labels and a slash,
# a label starting with a letter and ending with a letter or digit, and a name that is empty or
# starts and ends alphanumeric.

func isLabel(label: string): bool =
  label.len > 0 and label[0] in Letters and label[^1] in Alnum and
    label.allCharsInSet(Alnum + {'-'})

func isName(name: string): bool =
  name.len == 0 or (name[0] in Alnum and name[^1] in Alnum and
                    name.allCharsInSet(Alnum + {'-', '_', '.'}))

func isValidMetaKey(key: string): bool =
  let slash = key.find('/')
  if slash < 0:
    return key.isName
  for label in key[0 ..< slash].split('.'):
    if not label.isLabel:
      return false
  key[slash + 1 .. ^1].isName

proc metaKeysIn(node: JsonNode, keys: var HashSet[string]) =
  ## Every key of every `_meta` object anywhere in `node`.
  case node.kind
  of JObject:
    for key, value in node.pairs:
      if key == "_meta" and value.kind == JObject:
        for metaKey in value.keys:
          keys.incl metaKey
      metaKeysIn(value, keys)
  of JArray:
    for item in node:
      metaKeysIn(item, keys)
  else:
    discard

let
  modernVersions = block:
    var vs: seq[McpProtocolVersion]
    for v in SupportedProtocolVersions:
      if isModern(v): vs.add v
    vs
  Reserved = ["io.modelcontextprotocol/", "dev.mcp/", "org.modelcontextprotocol.api/", "com.mcp.tools/", "io.mcp/"]

# JSON of any type, in a shape a reader might trip on.
proc jsonOf(x: (int, (int, string))): JsonNode =
  case x[0]
  of 0: newJNull()
  of 1: %x[1][0]
  of 2: %(x[1][0].float / 2.0)
  of 3: %x[1][1]
  of 4: %(x[1][0] > 0)
  of 5: %*[x[1][0], x[1][1]]
  of 6: %*{"a": {"b": x[1][0]}}
  else: newJObject()

let
  anyWord = stringOf("abc01", 1, 4)
  anyJson = map(pair(intIn(0, 7), pair(intIn(-5, 5), anyWord)),
    proc(x: (int, (int, string))): JsonNode {.raises: [].} = jsonOf(x))
  # A name that starts and ends alphanumeric, with the characters between that a name may hold.
  anyName = map(pair(pair(stringOf("abz09", 1, 1), stringOf("ab-_.0", 0, 4)), stringOf("abz09", 1, 1)),
    proc(x: ((string, string), string)): string {.raises: [].} = x[0][0] & x[0][1] & x[1])
  # A key the syntax allows: no prefix, or a reserved prefix, with a name.
  anyKey = map(pair(pick(@["", "io.modelcontextprotocol/", "dev.mcp/", "com.example/", "a-b.c1/"]), anyName),
    proc(x: (string, string)): string {.raises: [].} = x[0] & x[1])

# --- the keys the SDK writes (MCP-META-1) -------------------------------------------------------

type
  Asked = object
    version: McpProtocolVersion
    requests: seq[int]            ## which of the requests below, in order
    meta: seq[(string, JsonNode)] ## keys of the syntax, with any value, on every request

proc anyAsked(): Gen[Asked] =
  ## Built where it is used: a build with no 2026-07-28 has no version to pick.
  map(
    pair(pair(pick(modernVersions), seqOf(intIn(0, 6), 1, 4)), seqOf(pair(anyKey, anyJson), 0, 3)),
    proc(x: ((McpProtocolVersion, seq[int]), seq[(string, JsonNode)])): Asked {.raises: [].} =
      Asked(version: x[0][0], requests: x[0][1], meta: x[1]))

suite "The keys the SDK writes (2026-07-28)":

  test "Given any requests of a 2026-07-28 server, discovery, a list, a call, a failed call or an unknown method, with any keys of the syntax in _meta, when its messages are read, then every _meta key in them is valid":
    # Space: one to four requests (discovery, a list, a call, a handler that fails, a tool that is
    # not there, a method that is not there, a call without its name), with up to three
    # _meta keys of the allowed syntax holding any JSON.
    if modernVersions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyAsked(),
        guarded(proc(a: Asked): bool =
          let server = newServer(McpServerCapabilities(
            tools: some(McpToolsCapability(listChanged: true))))
          server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
            return McpPage(items: @[%*{"name": "t", "inputSchema": {"type": "object"}}]))
          server.onToolCall(proc(ctx: McpRequestContext, name: string,
                                 arguments: JsonNode): Future[JsonNode] {.async.} =
            if name == "breaks":
              raise newException(ValueError, "x")
            return %*{"content": [{"type": "text", "text": "ok"}]})
          let t = server.attach()
          let peer = server.connect(t, a.version)
          var meta = newJObject()
          for (key, value) in a.meta:
            meta[key] = value
          for request in a.requests:
            discard case request
              of 0: peer.ask("server/discover", meta = meta)
              of 1: peer.ask("tools/list", meta = meta)
              of 2: peer.ask("tools/call", %*{"name": "t"}, meta = meta)
              of 3: peer.ask("tools/call", %*{"name": "breaks"}, meta = meta)
              of 4: peer.ask("tools/call", %*{"name": "nope"}, meta = meta)
              of 5: peer.ask("nosuch/method", meta = meta)
              else: peer.ask("tools/call", newJObject(), meta = meta)
          var keys = initHashSet[string]()
          for sent in t.sent:
            metaKeysIn(sent.message, keys)
          for key in keys:
            if not isValidMetaKey(key):
              return false
          # Not valid for want of keys: a result (the first three requests) names the server.
          var answered = false
          for request in a.requests:
            if request <= 2: answered = true
          if answered and MetaServerInfo notin keys:
            return false
          true))
      checkpoint describe(outcome)
      check outcome.passed

# --- the values at reserved keys (MCP-META-2) ------------------------------------------------------

suite "The values at reserved keys are not assumed (2026-07-28)":

  test "Given any value at unknown keys under a reserved prefix in _meta, when the server answers, then it answers as it would without them":
    # Space: one to three keys under any of the five reserved prefixes, with names the SDK does
    # not define, each holding JSON of any type; a list and a call.
    if modernVersions.len == 0:
      skip()
    else:
      let anyReserved = pair(pick(modernVersions),
        seqOf(pair(pair(pick(Reserved), anyName), anyJson), 1, 3))
      let outcome = propcheck.check(anyReserved,
        guarded(proc(x: (McpProtocolVersion, seq[((string, string), JsonNode)])): bool =
          let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
          server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
            return McpPage(items: @[%*{"name": "t", "inputSchema": {"type": "object"}}]))
          server.onToolCall(proc(ctx: McpRequestContext, name: string,
                                 arguments: JsonNode): Future[JsonNode] {.async.} =
            return %*{"content": [{"type": "text", "text": "ok"}]})
          let peer = server.connect(server.attach(), x[0])
          var meta = newJObject()
          for entry in x[1]:
            meta[entry[0][0] & entry[0][1]] = entry[1]
          let plainList = peer.ask("tools/list")
          let plainCall = peer.ask("tools/call", %*{"name": "t"})
          let listed = peer.ask("tools/list", meta = meta)
          let called = peer.ask("tools/call", %*{"name": "t"}, meta = meta)
          plainList.hasKey("result") and plainCall.hasKey("result") and
            listed{"result"} == plainList{"result"} and called{"result"} == plainCall{"result"}))
      checkpoint describe(outcome)
      check outcome.passed

  test "Given any value of the wrong type at a key the server reads, when a request carries it, then the answer is invalid params and never an internal error":
    # Space: logLevel, clientInfo, clientCapabilities or traceparent holding JSON of any type
    # but the one it is defined to hold (null is left out: it may stand for a key not given).
    if modernVersions.len == 0:
      skip()
    else:
      let reads = [(MetaLogLevel, JString), (MetaClientInfo, JObject),
                   (MetaClientCapabilities, JObject), (MetaTraceparent, JString)]
      let anyWrong = map(pair(pair(pick(modernVersions), intIn(0, 3)), pair(intIn(1, 7), pair(intIn(-5, 5), anyWord))),
        proc(x: ((McpProtocolVersion, int), (int, (int, string)))): (McpProtocolVersion, string, JsonNode) {.raises: [].} =
          let (key, expected) = reads[x[0][1]]
          var value = jsonOf(x[1])
          if value.kind == expected:          # the right type: make it the next one over
            value = %(x[1][1][0])
          (x[0][0], key, value))
      let outcome = propcheck.check(anyWrong,
        guarded(proc(x: (McpProtocolVersion, string, JsonNode)): bool =
          let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
          server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
            return McpPage(items: @[]))
          var meta = newJObject()
          meta[x[1]] = x[2]
          let reply = server.connect(server.attach(), x[0]).ask("tools/list", meta = meta)
          reply.hasKey("error") and reply.errorCode == -32602))
      checkpoint describe(outcome)
      check outcome.passed
