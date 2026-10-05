## A small MCP server on Streamable HTTP, used to check this SDK against
## other implementations: `nim_http_server PORT` serves http://127.0.0.1:PORT/mcp
## with one tool, `echo`. It speaks the build's default protocol version and
## every earlier one. The port is the last argument, so the transport name the
## interop runner passes before it (`nim_http_server http PORT`) is accepted.

import std/[asyncdispatch, json, options, os, strutils]
import server/server
import transport/http_server
import protocol/types

proc main() =
  let port = if paramCount() >= 1: parseInt(paramStr(paramCount())) else: 0
  let server = newMcpServer(
    McpServerInfo(name: "mcp-nim-sdk-interop", version: $DefaultProtocolVersion),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))

  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      return @[%*{
        "name": "echo",
        "description": "Returns the text it is given",
        "inputSchema": {
          "type": "object",
          "properties": {"text": {"type": "string"}},
          "required": ["text"]}}]
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      if name != "echo":
        raise newUnknownTool(name)
      return %*{"content": [{"type": "text", "text": arguments{"text"}.getStr()}],
                "isError": false}
  server.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))

  let transport = newHttpServerTransport(port = port)
  transport.listen()
  stderr.writeLine("listening on http://127.0.0.1:" & $transport.port & "/mcp")
  waitFor server.attachTransport(transport)
  waitFor transport.serve()

main()
