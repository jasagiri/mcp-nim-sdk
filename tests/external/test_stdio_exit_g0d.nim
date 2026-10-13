## A stdio server that ends on its own initiative: it exits and its output
## stream closes, and the client that reads it treats the connection as over.
##
## The test binary starts itself with a role argument to act as the child.

import std/[unittest, asyncdispatch, json, options, os, strutils]
import mcp

proc leavingServer(): McpServer =
  result = newMcpServer(McpServerInfo(name: "child", version: "1"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      return @[%*{"name": "echo", "inputSchema": {"type": "object"}},
               %*{"name": "leave", "inputSchema": {"type": "object"}}]
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      if name == "leave":
        quit(0)
      return %*{"content": [{"type": "text", "text": "still here"}], "isError": false}
  result.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))

if paramCount() >= 1 and paramStr(1) == "--sleaves":
  let server = leavingServer()
  server.transport = newStdioTransport()
  waitFor server.processMessages()
  quit(0)

suite "a stdio server that exits":

  test "Given a server that exits while a request waits, when the output stream ends, then the request fails as a closed connection":
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"))
    waitFor client.connect(newProcessTransport(getAppFilename(), ["--sleaves"]))
    check (waitFor client.callTool("echo")).contentItems.len == 1
    expect McpConnectionClosedError:
      discard waitFor client.callTool("leave")
    check client.state == mlsShutdown
    waitFor client.close()

  test "Given a server that has exited, when the client sends another request, then it fails as a closed connection and close completes":
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"))
    waitFor client.connect(newProcessTransport(getAppFilename(), ["--sleaves"]))
    expect McpConnectionClosedError:
      discard waitFor client.callTool("leave")
    expect McpConnectionClosedError:
      discard waitFor client.callTool("echo")
    waitFor client.close()
