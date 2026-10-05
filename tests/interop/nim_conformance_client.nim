## The client the official conformance suite (`@modelcontextprotocol/conformance`,
## `client` mode) runs: `nim_conformance_client URL`. The suite starts a server
## for a scenario, runs this program with the server's URL appended, and sets
##
##   MCP_CONFORMANCE_SCENARIO          the scenario name
##   MCP_CONFORMANCE_PROTOCOL_VERSION  the newest version the scenario expects
##
## Only the scenarios this SDK's client can act out are implemented: connecting
## and calling a tool. Every other scenario (authorization, HTTP headers,
## request-state round trips, ...) needs a client feature that does not exist
## yet; the program says so on stderr and exits with 2 instead of pretending.

import std/[asyncdispatch, json, options, os]
import client/client
import transport/http
import protocol/types

proc run(url, scenario: string): Future[void] {.async.} =
  let wanted = parseProtocolVersion(getEnv("MCP_CONFORMANCE_PROTOCOL_VERSION", $DefaultProtocolVersion))
  if wanted.isNone:
    raise newException(ValueError, "MCP_CONFORMANCE_PROTOCOL_VERSION is not a released version")
  let client = newMcpClient(
    McpClientInfo(name: "mcp-nim-sdk-conformance", version: $DefaultProtocolVersion),
    protocolVersion = min(wanted.get, DefaultProtocolVersion))
  await client.connect(newStreamableHttpTransport(url))
  case scenario
  of "initialize":
    discard
  of "tools_call", "request-metadata":
    let listed = await client.sendRequest("tools/list", newJObject())
    if listed.error.isSome:
      raise newException(ValueError, "tools/list failed: " & listed.error.get.message)
    let called = await client.sendRequest("tools/call",
      %*{"name": "add_numbers", "arguments": {"a": 5, "b": 3}})
    if called.error.isSome:
      raise newException(ValueError, "tools/call failed: " & called.error.get.message)
  else:
    raise newException(ValueError, "unreachable: " & scenario)
  await client.close()

proc main() =
  let scenario = getEnv("MCP_CONFORMANCE_SCENARIO")
  if paramCount() < 1:
    stderr.writeLine "usage: nim_conformance_client URL (with MCP_CONFORMANCE_SCENARIO set)"
    quit(64)
  if scenario notin ["initialize", "tools_call", "request-metadata"]:
    stderr.writeLine "scenario not supported by this client: " & scenario
    quit(2)
  try:
    waitFor run(paramStr(paramCount()), scenario)
  except CatchableError as e:
    stderr.writeLine $e.name & ": " & e.msg
    quit(1)

main()
