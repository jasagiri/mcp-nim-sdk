## An MCP server on stdin/stdout with one tool, `echo`.
##
##   nim c -r examples/stdio_server.nim
##
## Speaks the build's default protocol version and every earlier one. Stdout
## carries the protocol, so anything for people goes to stderr.

import std/[asyncdispatch, json, options]
import mcp

proc main() =
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

  server.transport = newStdioTransport()
  waitFor server.processMessages()

main()
