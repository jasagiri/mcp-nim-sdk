## `_meta` keys under a prefix that MCP reserves: a key the SDK does not
## define is carried as it is and changes nothing about how the request is
## served, whatever its value.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness

let ReservedKeys = [
  "io.modelcontextprotocol/not-defined-here",
  "modelcontextprotocol.io/not-defined-here",
  "mcp.dev/not-defined-here",
  "com.mcp.tools/not-defined-here"]

let Values = [newJNull(), %5, %"text", %*[1, "a"], %*{"nested": true}, %true, %(-1.5)]

type Seen = ref object
  meta: JsonNode

proc metaServer(seen: Seen): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    seen.meta = ctx.meta
    return %*{"content": [{"type": "text", "text": "ok"}]})

suite "reserved _meta keys the SDK does not define":

  test "Given a request whose _meta holds reserved keys with any kind of value, when the server serves it, then it is answered normally and the handler sees every key as sent":
    for v in SupportedProtocolVersions:
      for value in Values:
        let seen = Seen()
        let server = metaServer(seen)
        let peer = server.connect(server.attach(), v)
        let meta = newJObject()
        for key in ReservedKeys:
          meta[key] = value
        let answer = peer.ask("tools/call", %*{"name": "t"}, meta = meta)
        check answer.hasKey("result")
        check not answer.hasKey("error")
        check answer["result"]["content"][0]["text"].getStr() == "ok"
        check not seen.meta.isNil
        for key in ReservedKeys:
          check seen.meta.hasKey(key)
          check seen.meta[key] == value
