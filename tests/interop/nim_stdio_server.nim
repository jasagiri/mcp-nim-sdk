## A small MCP server on stdin/stdout, used to check this SDK against other
## implementations. It speaks the build's default protocol version and every
## earlier one.
##
## Tools: `echo` returns its `text` argument.

import std/[asyncdispatch, json, options]
import server/server
import transport/stdio
import protocol/types

proc main() =
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
        raise newException(ValueError, "Unknown tool: " & name)
      return %*{"content": [{"type": "text", "text": arguments{"text"}.getStr()}],
                "isError": false}
  server.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))

  server.transport = newStdioTransport()
  waitFor server.processMessages()

main()
