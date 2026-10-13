## What a client does with the keys MCP reserves in the `_meta` of a result
## (schema MetaObject of 2026-07-28: "implementations MUST NOT make
## assumptions about values at these keys"): it reads what it understands
## after checking the type, and the rest, whatever it holds, does not stop it
## reading the result.

import std/[unittest, asyncdispatch, json]
import client/tools
import ./client_peer

let Odd = [newJNull(), %5, %"text", %[1, 2], %*{"a": {"b": 1}}, %true, %1.5]

if SpeaksModern:
  suite "A client reads results that carry reserved keys (2026-07-28)":
    test "Given results whose _meta holds reserved keys of any value, when the client reads them, then the content comes through":
      for value in Odd:
        let peer = startPeer(proc(self: Peer, message: JsonNode) =
          if message{"method"}.getStr() == "tools/call":
            self.reply(message["id"], %*{
              "resultType": "complete", "content": [{"type": "text", "text": "ok"}],
              "_meta": {"io.modelcontextprotocol/model-immediate-response": value,
                        "io.modelcontextprotocol/related-task": value,
                        "io.modelcontextprotocol/serverInfo": value,
                        "io.modelcontextprotocol/unknown": value}}), modern = true)
        let client = peer.connectedClient()
        let content = waitFor client.callTool("t")
        check content.contentItems.len == 1
