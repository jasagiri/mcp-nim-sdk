## A client that turns on every client-side feature of the core protocol:
## roots, sampling and elicitation.
##
##   nim c examples/features_server.nim
##   nim c -r examples/features_client.nim examples/features_server
##
## A feature is on when its handler is registered before `connect`; the
## registration declares the capability. The client offers a server only
## what the version they settled on has.

import std/[asyncdispatch, json, options, os]
import mcp

proc run(command: string, args: seq[string]) {.async.} =
  let client = newMcpClient(McpClientInfo(name: "features-client", version: "0.1.0"))

  # Roots: the directories the server may work in.
  client.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} =
    return @[McpRoot(uri: "file://" & getCurrentDir(), name: some("work"))])

  # Sampling: the server asks this client's model for a completion. A real
  # host shows the request to its user before it runs a model.
  client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
    return McpSamplingResult(role: "assistant", model: "none",
      content: McpContentItem(kind: mckText, text: "(no model attached)"),
      stopReason: some("endTurn")))

  # Elicitation: the server asks the user for input. Declining is always
  # an answer.
  client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
    return McpElicitResult(action: eaDecline))

  await client.connect(newProcessTransport(command, args))
  echo "connected, protocol version ", client.negotiatedVersion.get

  for tool in (await client.listTools()).tools:
    echo "tool: ", tool.name
  let sum = await client.callTool("add", %*{"a": 2, "b": 3})
  echo "2 + 3 = ", sum.contentItems[0].text

  await client.close()

if paramCount() < 1:
  stderr.writeLine "usage: features_client SERVER_COMMAND [ARGS...]"
  quit(2)
waitFor run(paramStr(1), commandLineParams()[1 .. ^1])
