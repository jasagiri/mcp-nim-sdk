## What a client does with the keys MCP reserves in the `_meta` of a result
## (schema MetaObject of 2026-07-28: "implementations MUST NOT make
## assumptions about values at these keys"), said as a property: whatever the
## reserved keys hold, the client reads the content of the result.

import std/[unittest, asyncdispatch, json]
import propcheck
import client/tools
import ./client_peer

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
  Reserved = ["io.modelcontextprotocol/", "dev.mcp/", "org.modelcontextprotocol.api/", "com.mcp.tools/", "io.mcp/"]
  Defined = ["io.modelcontextprotocol/model-immediate-response", "io.modelcontextprotocol/related-task",
             "io.modelcontextprotocol/serverInfo", "io.modelcontextprotocol/unknown"]

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

suite "A client reads results that carry reserved keys (2026-07-28)":

  test "Given any value at reserved keys in the _meta of a result, when the client reads it, then the content comes through":
    # Space: the reserved keys the SDK knows and up to three unknown ones under any of the five
    # reserved prefixes, each holding JSON of any type.
    if not SpeaksModern:
      skip()
    else:
      let anyValue = map(pair(intIn(0, 7), pair(intIn(-5, 5), stringOf("abc01", 1, 4))),
        proc(x: (int, (int, string))): JsonNode {.raises: [].} = jsonOf(x))
      let anyMeta = pair(seqOf(anyValue, 4, 4),
                         seqOf(pair(pair(pick(Reserved), stringOf("abz09", 1, 4)), anyValue), 0, 3))
      let outcome = propcheck.check(anyMeta,
        guarded(proc(x: (seq[JsonNode], seq[((string, string), JsonNode)])): bool =
          var meta = newJObject()
          for i, key in Defined:
            meta[key] = x[0][i]
          for entry in x[1]:
            meta[entry[0][0] & entry[0][1]] = entry[1]
          let peer = startPeer(proc(self: Peer, message: JsonNode) =
            if message{"method"}.getStr() == "tools/call":
              self.reply(message["id"], %*{
                "resultType": "complete", "content": [{"type": "text", "text": "ok"}],
                "_meta": meta}), modern = true)
          let client = peer.connectedClient()
          let content = waitFor client.callTool("t")
          content.contentItems.len == 1))
      checkpoint describe(outcome)
      check outcome.passed
