## An MCP server on Streamable HTTP with one tool, `echo`.
##
##   nim c -r examples/http_server.nim [PORT]
##
## Serves http://127.0.0.1:PORT/mcp; without a PORT the system picks one and
## the address is printed on stderr.

import std/[asyncdispatch, json, options, os, strutils]
import mcp

proc main() =
  let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 0
  let server = newMcpServer(
    McpServerInfo(name: "echo-server", version: "0.1.0"),
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
        raise newException(ValueError, "Unknown tool: " & name)
      return %*{"content": [{"type": "text", "text": arguments{"text"}.getStr()}],
                "isError": false}

  server.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))

  let transport = newHttpServerTransport(port = port)
  transport.listen()
  stderr.writeLine "listening on http://127.0.0.1:" & $transport.port & "/mcp"
  waitFor server.attachTransport(transport)
  waitFor transport.serve()

main()
