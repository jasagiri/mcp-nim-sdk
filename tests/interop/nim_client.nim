## A small MCP client used to check this SDK against other implementations.
##
##   nim_client stdio CMD [ARGS...]
##   nim_client http URL    Streamable HTTP
##   nim_client sse URL     HTTP+SSE of 2024-11-05, URL of the event stream
##   nim_client auto URL    Streamable HTTP, falling back to HTTP+SSE on a 4xx
##
## MCP_VERSION limits the newest version the client speaks (default: the
## build's). Prints one JSON line with the negotiated version and the result
## of calling the `echo` tool; the exit code is 0 on success.

import std/[asyncdispatch, json, options, os]
import client/client
import transport/transport
import transport/stdio
import transport/http
import transport/sse_legacy
import transport/http_compat
import protocol/types

proc run(): Future[JsonNode] {.async.} =
  let wanted = getEnv("MCP_VERSION")
  var ceiling = DefaultProtocolVersion
  if wanted.len > 0 and wanted != "auto":
    let parsed = parseProtocolVersion(wanted)
    if parsed.isNone:
      raise newException(ValueError, "MCP_VERSION is not a released version: " & wanted)
    ceiling = parsed.get

  let args = commandLineParams()
  if args.len < 2:
    raise newException(ValueError, "usage: nim_client stdio CMD [ARGS...] | http URL | sse URL | auto URL")
  let transport: McpTransport =
    case args[0]
    of "stdio": newProcessTransport(args[1], args[2 .. ^1])
    of "http": newStreamableHttpTransport(args[1])
    of "sse": newSseLegacyTransport(args[1])
    of "auto": newAutoHttpTransport(args[1])
    else: raise newException(ValueError, "unknown transport: " & args[0])

  let client = newMcpClient(
    McpClientInfo(name: "mcp-nim-sdk-interop", version: $DefaultProtocolVersion),
    protocolVersion = ceiling)
  await client.connect(transport)

  let listed = await client.sendRequest("tools/list", newJObject())
  if listed.error.isSome:
    raise newException(ValueError, "tools/list failed: " & listed.error.get.message)
  var tools = newJArray()
  for tool in listed.result.get{"tools"}:
    tools.add tool{"name"}

  let called = await client.sendRequest("tools/call",
    %*{"name": "echo", "arguments": {"text": "hello"}})
  if called.error.isSome:
    raise newException(ValueError, "tools/call failed: " & called.error.get.message)
  let text = called.result.get{"content"}{0}{"text"}.getStr()
  await client.close()

  return %*{
    "ok": text == "hello",
    "impl": "mcp-nim-sdk",
    "requested": (if wanted.len == 0: "auto" else: wanted),
    "protocolVersion": $client.negotiatedVersion.get,
    "tools": tools,
    "result": text}

proc main() =
  var report: JsonNode
  try:
    report = waitFor run()
  except CatchableError as e:
    report = %*{"ok": false, "impl": "mcp-nim-sdk", "error": $e.name & ": " & e.msg}
  echo $report
  quit(if report["ok"].getBool(): 0 else: 1)

main()
