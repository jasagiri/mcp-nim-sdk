## The keys of `_meta` (schema MetaObject of 2026-07-28): the ones this SDK
## writes follow the key syntax, and the values at the keys MCP reserves are
## not assumed to be anything: an unknown reserved key is passed over whatever
## it holds, a known one is checked before it is used.

import std/[unittest, asyncdispatch, json, options, strutils, sets]
import ./server_harness
import protocol/modern
import protocol/trace_context

const
  Letters = {'a' .. 'z', 'A' .. 'Z'}
  Digits = {'0' .. '9'}
  Alnum = Letters + Digits

func isLabel(label: string): bool =
  ## Starts with a letter, ends with a letter or digit, letters digits and
  ## hyphens between.
  label.len > 0 and label[0] in Letters and label[^1] in Alnum and
    label.allCharsInSet(Alnum + {'-'})

func isName(name: string): bool =
  ## Empty, or starts and ends alphanumeric, with alphanumerics, hyphens,
  ## underscores and dots between.
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

suite "The syntax of a key":
  test "Given keys the specification calls valid and invalid, when they are judged, then each is judged as the specification says":
    for key in ["com.example/k", "io.modelcontextprotocol/protocolVersion", "a-b.c1/n_m.x-y",
                "a1/", "traceparent", "x", "a/b"]:
      check isValidMetaKey(key)
    for key in ["1a/x", "a-/x", "-a/x", "a..b/x", ".a/x", "a./x", "a b/x", "a/-x", "a/x-", "a/_x",
                "/name", "a/x_", "a/.x", "a/x.", "a_b/x", "a/x y", "a/x/y", "-x", "x-", "", "a.1b/x"]:
      if key == "": continue   # an empty key has an empty name, which is valid
      check not isValidMetaKey(key)

suite "The keys the SDK writes (2026-07-28)":
  test "Given the keys the SDK defines, when they are judged, then every one is valid":
    for key in [MetaProtocolVersion, MetaClientInfo, MetaClientCapabilities, MetaLogLevel,
                MetaServerInfo, MetaSubscriptionId, MetaTraceparent, MetaTracestate, MetaBaggage]:
      check isValidMetaKey(key)

  test "Given a server that answers discovery, a list, a call, a failed call and an unknown method, when its messages are read, then every _meta key in them is valid":
    for v in SupportedProtocolVersions:
      if not isModern(v): continue
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
      let peer = server.connect(t, v)
      discard peer.ask("server/discover")
      discard peer.ask("tools/list")
      discard peer.ask("tools/call", %*{"name": "t"})
      discard peer.ask("tools/call", %*{"name": "breaks"})
      discard peer.ask("nosuch/method")
      discard peer.ask("tools/call", %*{"name": "t"}, meta = %*{"traceparent":
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"})
      var keys = initHashSet[string]()
      for sent in t.sent:
        metaKeysIn(sent.message, keys)
      check MetaServerInfo in keys   # the messages did carry SDK keys to judge
      for key in keys:
        check isValidMetaKey(key)

let Odd = [newJNull(), %5, %"text", %[1, 2], %*{"a": {"b": 1}}, %true, %1.5]

suite "The values at reserved keys are not assumed (2026-07-28)":
  test "Given requests whose _meta holds unknown reserved keys with any value, when the server answers, then it answers as it would without them":
    for v in SupportedProtocolVersions:
      if not isModern(v): continue
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
        return McpPage(items: @[%*{"name": "t", "inputSchema": {"type": "object"}}]))
      server.onToolCall(proc(ctx: McpRequestContext, name: string,
                             arguments: JsonNode): Future[JsonNode] {.async.} =
        return %*{"content": [{"type": "text", "text": "ok"}]})
      let peer = server.connect(server.attach(), v)
      for key in ["io.modelcontextprotocol/unknown", "dev.mcp/x", "org.modelcontextprotocol.api/y",
                  "com.mcp.tools/z", "io.mcp/w"]:
        for value in Odd:
          let listed = peer.ask("tools/list", meta = %*{key: value})
          check listed.hasKey("result")
          check listed["result"]["tools"].len == 1
          let called = peer.ask("tools/call", %*{"name": "t"}, meta = %*{key: value})
          check called.hasKey("result")
          check textOf(called) == "ok"

  test "Given a reserved key the server reads and a value of the wrong type, when a request carries it, then the answer is invalid params and never an internal error":
    let wrong = [
      (MetaLogLevel, %5), (MetaLogLevel, %true), (MetaLogLevel, %[1]), (MetaLogLevel, %*{"a": 1}),
      (MetaClientInfo, %"x"), (MetaClientInfo, %5), (MetaClientInfo, %[1]), (MetaClientInfo, %true),
      (MetaClientCapabilities, %"x"), (MetaClientCapabilities, %5), (MetaClientCapabilities, %[1]),
      (MetaClientCapabilities, %true),
      (MetaTraceparent, %5), (MetaTraceparent, %true), (MetaTraceparent, %[1]),
      (MetaTraceparent, %*{"a": 1})]
    for v in SupportedProtocolVersions:
      if not isModern(v): continue
      let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
      server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
        return McpPage(items: @[]))
      let peer = server.connect(server.attach(), v)
      for (key, value) in wrong:
        let reply = peer.ask("tools/list", meta = %*{key: value})
        check reply.hasKey("error")
        if reply.hasKey("error"):
          check reply.errorCode == -32602
