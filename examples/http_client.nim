## An MCP client that connects to a Streamable HTTP server, lists its tools and
## calls `echo`.
##
##   nim c -r examples/http_client.nim http://127.0.0.1:PORT/mcp

import std/[asyncdispatch, json, options, os]
import mcp

proc run(url: string) {.async.} =
  let client = newMcpClient(McpClientInfo(name: "echo-client", version: "0.1.0"))
  await client.connect(newStreamableHttpTransport(url))
  echo "connected, protocol version ", client.negotiatedVersion.get

  let listed = await client.sendRequest("tools/list", newJObject())
  if listed.error.isSome:
    raise newException(ValueError, "tools/list failed: " & listed.error.get.message)
  for tool in listed.result.get{"tools"}:
    echo "tool: ", tool{"name"}.getStr()

  let called = await client.sendRequest("tools/call",
    %*{"name": "echo", "arguments": {"text": "hello"}})
  if called.error.isSome:
    raise newException(ValueError, "tools/call failed: " & called.error.get.message)
  echo "echo says: ", called.result.get{"content"}{0}{"text"}.getStr()

  await client.close()

if paramCount() < 1:
  stderr.writeLine "usage: http_client URL"
  quit(2)
waitFor run(paramStr(1))
