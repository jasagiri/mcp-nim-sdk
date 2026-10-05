## The stdio transport: line framing over streams, and a client talking to a
## server it started as a child process.
##
## The test binary starts itself with a role argument to act as the child.

import std/[unittest, asyncdispatch, json, options, os, osproc, streams, strutils]
import transport/transport
import transport/stdio
import server/server
import client/client
import protocol/types

const LegacyDefault = min(DefaultProtocolVersion, mpv20251125)

proc echoServer(version: McpProtocolVersion): McpServer =
  result = newMcpServer(McpServerInfo(name: "child", version: "1"),
    protocolVersion = version,
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      return @[%*{"name": "echo", "inputSchema": {"type": "object"}}]
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      return %*{"content": [{"type": "text", "text": arguments{"text"}.getStr()}],
                "isError": false}
  result.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))

proc runChild(role: string) =
  case role
  of "--serve", "--serve-legacy":
    let server = echoServer(if role == "--serve": DefaultProtocolVersion else: mpv20241105)
    server.transport = newStdioTransport()
    stderr.writeLine("child diagnostics go to stderr")
    waitFor server.processMessages()
  of "--silent":
    # Reads everything, answers nothing.
    let transport = newStdioTransport()
    try:
      while true:
        discard waitFor transport.receiveMessage()
    except McpTransportClosedError:
      discard
  else:
    quit("unknown role " & role, 2)

if paramCount() >= 1 and paramStr(1).startsWith("--s"):
  runChild(paramStr(1))
  quit(0)

proc overStreams(input: string): tuple[transport: StdioTransport, output: StringStream] =
  let output = newStringStream()
  (newStdioTransport(newStringStream(input), output), output)

suite "stdio framing":

  test "Given two messages on two lines, when received, then each line is one message":
    let (transport, _) = overStreams("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n" &
                                     "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n")
    check (waitFor transport.receiveMessage())["id"].getInt() == 1
    check (waitFor transport.receiveMessage())["method"].getStr() == "notifications/initialized"

  test "Given blank lines between messages, when received, then they are skipped":
    let (transport, _) = overStreams("\n  \n{\"id\":1}\n\n{\"id\":2}\n")
    check (waitFor transport.receiveMessage())["id"].getInt() == 1
    check (waitFor transport.receiveMessage())["id"].getInt() == 2

  test "Given lines that end in CRLF, when received, then the messages parse":
    let (transport, _) = overStreams("{\"id\":1}\r\n{\"id\":2}\r\n")
    check (waitFor transport.receiveMessage())["id"].getInt() == 1
    check (waitFor transport.receiveMessage())["id"].getInt() == 2

  test "Given the end of input, when received, then the transport reports the peer closed it":
    let (transport, _) = overStreams("{\"id\":1}\n")
    discard waitFor transport.receiveMessage()
    expect McpTransportClosedError:
      discard waitFor transport.receiveMessage()

  test "Given a line that is not JSON, when a server receives it, then it answers a parse error with a null id and reads on":
    let (transport, output) = overStreams("{not json\n{\"id\":2}\n")
    check (waitFor transport.receiveMessage())["id"].getInt() == 2
    let written = parseJson(output.data.strip())
    check written["error"]["code"].getInt() == -32700
    check written["id"].kind == JNull

  test "Given a message, when sent, then it is written as one line":
    let (transport, output) = overStreams("")
    waitFor transport.sendNotification(newJsonRpcNotification("notifications/x", %*{"text": "a\nb"}))
    check output.data.count('\n') == 1
    check parseJson(output.data)["params"]["text"].getStr() == "a\nb"

suite "stdio with a child process":

  test "Given a server started as a child, when the client connects and calls a tool, then the call succeeds in the build's default version":
    let transport = newProcessTransport(getAppFilename(), ["--serve"])
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"))
    waitFor client.connect(transport)
    check client.negotiatedVersion == some(DefaultProtocolVersion)
    let response = waitFor client.sendRequest("tools/call",
      %*{"name": "echo", "arguments": {"text": "こんにちは"}})
    check response.result.get["content"][0]["text"].getStr() == "こんにちは"
    waitFor client.close()

  test "Given a child limited to 2024-11-05, when the client connects, then both settle on 2024-11-05":
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"))
    waitFor client.connect(newProcessTransport(getAppFilename(), ["--serve-legacy"]))
    check client.negotiatedVersion == some(mpv20241105)
    let response = waitFor client.sendRequest("tools/list", newJObject())
    check response.result.get["tools"][0]["name"].getStr() == "echo"
    waitFor client.close()

  test "Given a client, when it closes the transport, then the child process has exited":
    let transport = newProcessTransport(getAppFilename(), ["--serve"])
    let process = transport.process
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"))
    waitFor client.connect(transport)
    check process.running
    waitFor client.close()
    check not process.running

  test "Given a child that never answers, when the client connects, then the dispatcher keeps running and the wait can time out":
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"),
                              protocolVersion = LegacyDefault)
    let connecting = client.connect(newProcessTransport(getAppFilename(), ["--silent"]))
    check not (waitFor withTimeout(connecting, 300))
    waitFor client.close()

  test "Given a command that does not exist, when a process transport is made, then McpTransportError names the command":
    var message = ""
    try:
      discard newProcessTransport("/no/such/mcp-server-binary")
    except McpTransportError as e:
      message = e.msg
    check "/no/such/mcp-server-binary" in message
