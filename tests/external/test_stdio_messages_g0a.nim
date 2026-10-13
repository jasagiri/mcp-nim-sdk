## What crosses the pipes of a stdio server: only JSON-RPC messages, in UTF-8,
## in both directions, and a server that ends its own session. The test binary
## starts itself with a role argument to act as the child (every role of this
## file starts with `--g`).

import std/[unittest, asyncdispatch, json, options, os, osproc, sequtils, streams,
            strutils, unicode]
import mcp
import ./client_peer

const SpeaksModern = isModern(DefaultProtocolVersion)

type
  TeeTransport = ref object of McpTransport
    ## A server's transport that keeps every line it reads, as it arrived.
    record: string

proc putLine(line: string) =
  stdout.writeLine(line)
  stdout.flushFile()

method receiveMessage(t: TeeTransport): Future[JsonNode] {.async.} =
  while true:
    var line = ""
    if not stdin.readLine(line):
      raise newException(McpTransportClosedError, "EOF on input stream")
    if line.len == 0:
      continue
    let record = open(t.record, fmAppend)
    record.writeLine(line)
    record.close()
    return parseJson(line)

method sendRequest(t: TeeTransport, request: JsonRpcRequest): Future[void] {.async.} =
  putLine(encodeMessage(request))

method sendNotification(t: TeeTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  putLine(encodeMessage(notification))

method sendResponse(t: TeeTransport, response: JsonRpcResponse): Future[void] {.async.} =
  putLine(encodeMessage(response))

method close(t: TeeTransport): Future[void] {.async.} =
  discard

proc childServer(transport: McpTransport) =
  let server = newMcpServer(McpServerInfo(name: "child", version: "1"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      return @[%*{"name": "echo", "inputSchema": {"type": "object"}},
               %*{"name": "slow", "inputSchema": {"type": "object"}},
               %*{"name": "fail", "inputSchema": {"type": "object"}},
               %*{"name": "bye", "inputSchema": {"type": "object"}}]
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      case name
      of "slow":
        await sleepAsync(1000)
      of "fail":
        raise newException(ValueError, "the tool failed")
      of "bye":
        # The server ends its own session: its output closes with the process.
        quit(0)
      else:
        discard
      return %*{"content": [{"type": "text", "text": arguments{"text"}.getStr()}],
                "isError": false}
  server.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))
  server.transport = transport
  stderr.writeLine("child diagnostics go to stderr")
  waitFor server.processMessages()

if paramCount() >= 1 and paramStr(1).startsWith("--g"):
  case paramStr(1)
  of "--gserve":
    childServer(newStdioTransport())
  of "--grecord":
    childServer(TeeTransport(kind: mtkStdio, record: paramStr(2)))
  else:
    quit("unknown role " & paramStr(1), 2)
  quit(0)

proc isMcpMessage(message: JsonNode): bool =
  ## A JSON-RPC 2.0 request, notification or response, by its members.
  if message.kind != JObject or message{"jsonrpc"}.getStr() != "2.0":
    return false
  let hasId = message.hasKey("id")
  if hasId and message["id"].kind notin {JString, JInt, JNull}:
    return false
  if message.hasKey("method"):
    return message["method"].kind == JString and
           (not hasId or message["id"].kind != JNull)
  hasId and (message.hasKey("result") != message.hasKey("error"))

proc isRequestOrNotification(message: JsonNode): bool =
  message.hasKey("method")

proc modernMeta(): JsonNode =
  %*{"io.modelcontextprotocol/protocolVersion": "2026-07-28",
     "io.modelcontextprotocol/clientInfo": {"name": "peer", "version": "0"},
     "io.modelcontextprotocol/clientCapabilities": {}}

const SettleMs = 1000
  ## How long the server is given to answer before its stdin is closed: a
  ## server that reaches the end of its input stops, with the answers it has
  ## not yet written.

proc runServer(stdinBytes: string): tuple[stdoutLines: seq[string], exitCode: int] =
  ## Writes `stdinBytes` to the stdin of a stdio server, closes it after
  ## `SettleMs`, and returns what the server wrote to its stdout.
  let child = startProcess(getAppFilename(), args = ["--gserve"], options = {})
  child.inputStream.write(stdinBytes)
  child.inputStream.flush()
  sleep(SettleMs)
  child.inputStream.close()
  result.exitCode = child.waitForExit(10_000)
  if result.exitCode == -1:
    child.kill()
  for line in child.outputStream.readAll().splitLines:
    if line.len > 0:
      result.stdoutLines.add line
  child.close()

suite "what a stdio server writes to its stdout":

  test "Given lines of every kind on its stdin, when a server reads them, then every line it writes to its stdout is a JSON-RPC message":
    let lines = [
      """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"p","version":"0"}}}""",
      """{"jsonrpc":"2.0","method":"notifications/initialized"}""",
      """{"jsonrpc":"2.0","id":2,"method":"tools/list"}""",
      """{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}""",
      """{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fail","arguments":{}}}""",
      """{"jsonrpc":"2.0","id":5,"method":"no/such/method"}""",
      """{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"_meta":""" & $modernMeta() &
        ""","name":"echo","arguments":{"text":"天気"}}}""",
      "{not json",
      "",
      "42",
      "[1,2]",
      "\"text\"",
      "\xFF\xFE",
      """{"jsonrpc":"2.0","id":7,"method":"ping"}"""]
    let (written, exitCode) = runServer(lines.join("\n") & "\n")
    check exitCode == 0
    check written.len >= 6
    for line in written:
      var message: JsonNode = nil
      try:
        message = parseJson(line)
      except JsonParsingError:
        checkpoint "not JSON: " & line
        fail()
      if not message.isNil:
        checkpoint "not a JSON-RPC message: " & line
        check isMcpMessage(message)

  test "Given a line that is not JSON, when a server reads it, then what it writes in answer is a parse error with a null id":
    let (written, _) = runServer("{not json\n")
    check written.len == 1
    let message = parseJson(written[0])
    check isMcpMessage(message)
    check message["error"]["code"].getInt() == -32700
    check message["id"].kind == JNull

  test "Given a server that answers a call, when its stdout is read, then the answer is the only thing on it and it is a response to that call":
    let init = if SpeaksModern: "" else:
      """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"p","version":"0"}}}""" & "\n" &
      """{"jsonrpc":"2.0","method":"notifications/initialized"}""" & "\n"
    let call =
      if SpeaksModern:
        """{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"_meta":""" & $modernMeta() &
          ""","name":"echo","arguments":{"text":"hi"}}}""" & "\n"
      else:
        """{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}""" & "\n"
    let (written, _) = runServer(init & call)
    let responses = written.mapIt(parseJson(it)).filterIt(it.hasKey("result") and it["id"].getInt() == 3)
    check responses.len == 1
    check responses[0]["result"]["content"][0]["text"].getStr() == "hi"

suite "what a stdio client writes to its server's stdin":

  test "Given a session that connects, lists, calls, gives up on a slow call and closes, when its server records stdin, then every line is a JSON-RPC request or notification":
    let record = getTempDir() / "mcp-g0a-stdin-" & $getCurrentProcessId()
    removeFile(record)
    defer: removeFile(record)
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"))
    waitFor client.connect(newProcessTransport(getAppFilename(), ["--grecord", record]))
    discard waitFor client.sendRequest("tools/list", newJObject())
    discard waitFor client.sendRequest("tools/call",
      %*{"name": "echo", "arguments": {"text": "こんにちは"}})
    expect McpTimeoutError:
      discard waitFor client.sendRequest("tools/call", %*{"name": "slow", "arguments": {}},
                                         McpRequestOptions(timeoutMs: some(100)))
    waitFor client.close()
    let recorded = readFile(record).splitLines.filterIt(it.len > 0)
    check recorded.len >= 4
    for line in recorded:
      var message: JsonNode = nil
      try:
        message = parseJson(line)
      except JsonParsingError:
        checkpoint "not JSON: " & line
        fail()
      if not message.isNil:
        checkpoint "not a JSON-RPC request or notification: " & line
        check isMcpMessage(message)
        check isRequestOrNotification(message)

suite "UTF-8 on a stdio transport":

  test "Given strings of every script, when a message is sent, then the bytes written are valid UTF-8 and read back as the same strings":
    for text in ["", "plain ascii", "日本語", "é", "😀", "mixed 日本 é 😀 end",
                 "a b", "tab\tand\nnewline"]:
      let output = newStringStream()
      let transport = newStdioTransport(newStringStream(""), output)
      waitFor transport.sendNotification(
        newJsonRpcNotification("x", %*{"text": text}))
      checkpoint "text: " & text.escape
      check validateUtf8(output.data) == -1
      check parseJson(output.data)["params"]["text"].getStr() == text

  test "Given a line of UTF-8 bytes, when a transport reads it, then the strings are the characters the bytes encode":
    let line = "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":{\"text\":\"" &
               "日本語 😀" & "\"}}\n"
    let transport = newStdioTransport(newStringStream(line), newStringStream())
    check (waitFor transport.receiveMessage())["params"]["text"].getStr() == "日本語 😀"

suite "a server that ends its own session":

  test "Given a server that exits while a call is waiting, when the client waits, then the call fails as a closed connection and closing the client succeeds":
    let transport = newProcessTransport(getAppFilename(), ["--gserve"])
    let process = transport.process
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"))
    waitFor client.connect(transport)
    expect McpConnectionClosedError:
      discard waitFor client.sendRequest("tools/call", %*{"name": "bye", "arguments": {}})
    waitFor client.close()
    check not process.running

suite "a client over stdio and x-mcp-header":

  test "Given a 2026-07-28 server over stdio that lists a tool whose x-mcp-header is invalid, when the client lists tools and calls it, then the tool is listed and the call is sent":
    if not SpeaksModern:
      skip()
    else:
      let tools = %*[
        {"name": "bad", "inputSchema": {"type": "object", "properties": {
          "ratio": {"type": "number", "x-mcp-header": "Ratio"}}}},
        {"name": "good", "inputSchema": {"type": "object"}}]
      let peer = startPeer(proc(peer: Peer, message: JsonNode) =
        case message{"method"}.getStr()
        of "tools/list":
          peer.reply(message["id"], %*{"tools": tools})
        of "tools/call":
          peer.reply(message["id"], %*{"content": [{"type": "text", "text": "ok"}]})
        else:
          discard, modern = true, kind = mtkStdio)
      let client = peer.connectedClient()
      let listed = waitFor client.listAllTools()
      check listed.mapIt(it.name) == @["bad", "good"]
      discard waitFor client.callTool("bad", %*{"ratio": 0.5})
      check peer.requestsFor("tools/call").len == 1
