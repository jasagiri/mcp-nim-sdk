## The stdio transport: line framing over streams, and a client talking to a
## server it started as a child process.
##
## The test binary starts itself with a role argument to act as the child.

import std/[sequtils, unittest, asyncdispatch, json, monotimes, options, os, osproc, posix, streams, strtabs, strutils, times]
import transport/transport
import transport/stdio
import server/server
import client/client
import protocol/types

const
  LegacyDefault = min(DefaultProtocolVersion, mpv20251125)
  FloodBytes = 300_000

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
  of "--serve", "--serve-legacy", "--sflood":
    let server = echoServer(if role == "--serve-legacy": mpv20241105 else: DefaultProtocolVersion)
    server.transport = newStdioTransport()
    stderr.writeLine("child diagnostics go to stderr")
    if role == "--sflood":
      # More than a pipe holds: the child stalls here unless its parent drains stderr.
      stderr.write('x'.repeat(FloodBytes))
    waitFor server.processMessages()
  of "--sframes":
    # Echoes what arrives on its stdin and says how the input ended and what close released.
    let transport = newStdioTransport(maxLineSize = parseInt(paramStr(2)))
    try:
      while true:
        let message = waitFor transport.receiveMessage()
        waitFor transport.sendNotification(newJsonRpcNotification("echo", message))
    except McpTransportClosedError:
      waitFor transport.sendNotification(newJsonRpcNotification("closed", newJObject()))
    except McpTransportError as e:
      waitFor transport.sendNotification(newJsonRpcNotification("failed", %*{"reason": e.msg}))
    waitFor transport.close()
    waitFor transport.sendNotification(newJsonRpcNotification("released",
      %*{"stdinClosed": fcntl(STDIN_FILENO, F_GETFL) == -1}))
  of "--snoise":
    # A server that prints noise, then records what its client sends it.
    stdout.writeLine("this line is not JSON")
    stdout.writeLine("""{"jsonrpc":"2.0","method":"hello"}""")
    stdout.flushFile()
    writeFile(paramStr(2), stdin.readAll())
  of "--sstubborn", "--sdeaf":
    # Does not exit when its stdin closes; --sdeaf also ignores SIGTERM.
    if role == "--sdeaf":
      discard signal(SIGTERM, SIG_IGN)
    stdout.writeLine("""{"jsonrpc":"2.0","method":"ready"}""")
    stdout.flushFile()
    sleep(60_000)
  of "--senv":
    # Says what it was started with: its directory and the variables the test looks at.
    stdout.writeLine($(%*{"jsonrpc": "2.0", "method": "env", "params": {
      "cwd": getCurrentDir(), "given": getEnv("MCP_TEST_GIVEN"), "secret": existsEnv("MCP_TEST_SECRET")}}))
    stdout.flushFile()
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

proc runFrames(chunks: openArray[string], maxLineSize = 1024, pauseMs = 0):
    tuple[messages: seq[JsonNode], exitCode: int] =
  ## Writes `chunks` to the stdin of a child that reads it with the
  ## transport over its own descriptors, closes its stdin, and collects
  ## what the child answers.
  let child = startProcess(getAppFilename(), args = ["--sframes", $maxLineSize],
                            options = {})
  for chunk in chunks:
    child.inputStream.write(chunk)
    child.inputStream.flush()
    sleep(pauseMs)
  child.inputStream.close()
  result.exitCode = child.waitForExit(10_000)
  if result.exitCode == -1:
    child.kill()
  for line in child.outputStream.readAll().splitLines:
    if line.len > 0:
      result.messages.add parseJson(line)
  child.close()

proc methods(messages: seq[JsonNode]): seq[string] =
  for message in messages:
    result.add message["method"].getStr()

proc redirectStderrTo(path: string): proc() =
  ## Sends this process's stderr to `path`; the returned proc restores it.
  let saved = dup(STDERR_FILENO)
  let file = open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o644)
  doAssert saved != -1 and file != -1
  doAssert dup2(file, STDERR_FILENO) != -1
  discard close(file)
  result = proc() =
    doAssert dup2(saved, STDERR_FILENO) != -1
    discard close(saved)

var closedStreams {.threadvar.}: seq[string]
  ## What the streams of a transport under test were told to close.

var flushedData {.threadvar.}: string
  ## What a stream under test held when it was last flushed.

proc descriptorIsOpen(fd: cint): bool =
  fcntl(fd, F_GETFL) != -1

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

  test "Given a transport over streams, when it is closed, then both streams are closed":
    let input = newStringStream("")
    let output = newStringStream()
    input.closeImpl = proc(s: Stream) = closedStreams.add "input"
    output.closeImpl = proc(s: Stream) = closedStreams.add "output"
    closedStreams = @[]
    waitFor newStdioTransport(input, output).close()
    check closedStreams == @["input", "output"]

  test "Given a message sent over a stream, when the send completes, then the stream has been flushed":
    let output = newStringStream()
    output.flushImpl = proc(s: Stream) = flushedData = StringStream(s).data
    flushedData = ""
    let transport = newStdioTransport(newStringStream(""), output)
    waitFor transport.sendNotification(newJsonRpcNotification("notifications/x", newJObject()))
    check flushedData.len > 0
    check flushedData == output.data

  test "Given a line that is not JSON, when a server reads it, then the diagnostic names the line as ignored on stderr":
    let record = getTempDir() / "mcp-stdio-diag-" & $getCurrentProcessId()
    defer: removeFile(record)
    let restore = redirectStderrTo(record)
    try:
      let (transport, _) = overStreams("{not json\n{\"id\":2}\n")
      discard waitFor transport.receiveMessage()
    finally:
      restore()
    check "ignoring a line that is not JSON" in readFile(record)

suite "stdio over the descriptors of a server process":

  test "Given blank lines, CRLF, several lines in one write and a last line without a newline, when a server reads its stdin, then each line is one message in order and the end of input is reported":
    let (messages, exitCode) = runFrames(["\n\r\n{\"id\":1}\r\n{\"id\":2}\n\n{\"id\":3}"])
    check messages.methods == @["echo", "echo", "echo", "closed", "released"]
    check messages[0..2].mapIt(it["params"]["id"].getInt()) == @[1, 2, 3]
    check exitCode == 0

  test "Given a message of exactly the size limit that is completed by its newline only later, when read, then it is accepted":
    const limit = 40
    let prefix = "{\"id\":1,\"pad\":\""
    let message = prefix & 'x'.repeat(limit - prefix.len - 2) & "\"}"
    check message.len == limit
    let (messages, exitCode) = runFrames([message, "\n"], maxLineSize = limit, pauseMs = 300)
    check messages.methods == @["echo", "closed", "released"]
    check exitCode == 0

  test "Given more than the size limit without a newline, when read, then the transport fails and names the limit":
    let (messages, exitCode) = runFrames(['x'.repeat(100)], maxLineSize = 40, pauseMs = 300)
    check messages.methods[0] == "failed"
    check "40" in messages[0]["params"]["reason"].getStr()
    check exitCode == 0

  test "Given a line that is not JSON on a server's stdin, when it reads, then it answers a parse error with a null id and reads on":
    let (messages, exitCode) = runFrames(["{not json\n{\"id\":2}\n"])
    check messages[0]["error"]["code"].getInt() == -32700
    check messages[0]["id"].kind == JNull
    check messages[1]["method"].getStr() == "echo"
    check messages[1]["params"]["id"].getInt() == 2
    check exitCode == 0

  test "Given a server that closed its transport, when it looks at its stdin descriptor, then it is released":
    let (messages, _) = runFrames(["{\"id\":1}\n"])
    check messages[^1]["method"].getStr() == "released"
    check messages[^1]["params"]["stdinClosed"].getBool()

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

  test "Given a server that prints a line that is not JSON, when the client reads on, then it does not answer the noise to the server":
    let record = getTempDir() / "mcp-stdio-noise-" & $getCurrentProcessId()
    defer: removeFile(record)
    let transport = newProcessTransport(getAppFilename(), ["--snoise", record])
    check (waitFor transport.receiveMessage())["method"].getStr() == "hello"
    waitFor transport.close()
    check readFile(record) == ""

  test "Given a child that fills its stderr, when the client connects, then the child is not stalled and its diagnostics appear on the client's stderr":
    let record = getTempDir() / "mcp-stdio-stderr-" & $getCurrentProcessId()
    defer: removeFile(record)
    let restore = redirectStderrTo(record)
    var connected = false
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"))
    try:
      let connecting = client.connect(newProcessTransport(getAppFilename(), ["--sflood"]))
      connected = waitFor withTimeout(connecting, 10_000)
      waitFor client.close()
    finally:
      restore()
    check connected
    let forwarded = readFile(record)
    check "child diagnostics go to stderr" in forwarded
    check forwarded.count('x') >= FloodBytes - 100_000

  test "Given a child that exits when its stdin closes, when the client closes the transport, then the child ends by itself within the grace period":
    let transport = newProcessTransport(getAppFilename(), ["--serve"])
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"))
    waitFor client.connect(transport)
    let started = getMonoTime()
    waitFor client.close()
    check (getMonoTime() - started) < initDuration(milliseconds = 1500)
    check transport.process.peekExitCode == 0

  test "Given a child that ignores the closing of its stdin, when the client closes the transport, then the child is terminated":
    let transport = newProcessTransport(getAppFilename(), ["--sstubborn"])
    discard waitFor transport.receiveMessage()
    waitFor transport.close()
    check transport.process.peekExitCode == 128 + SIGTERM

  test "Given a child that also ignores SIGTERM, when the client closes the transport, then the child is killed":
    let transport = newProcessTransport(getAppFilename(), ["--sdeaf"])
    discard waitFor transport.receiveMessage()
    waitFor transport.close()
    let code = transport.process.peekExitCode
    if code == -1: transport.process.kill()
    check code == 128 + SIGKILL

  test "Given a client, when it closes the transport, then the descriptors of the child's pipes are released":
    let transport = newProcessTransport(getAppFilename(), ["--serve"])
    let handles = [transport.process.inputHandle.cint, transport.process.outputHandle.cint,
                   transport.process.errorHandle.cint]
    let client = newMcpClient(McpClientInfo(name: "parent", version: "1"))
    waitFor client.connect(transport)
    check handles.allIt(descriptorIsOpen(it))
    waitFor client.close()
    check not handles.anyIt(descriptorIsOpen(it))

suite "the environment and directory of a server process":

  proc started(env: StringTableRef = nil, workingDir = ""): JsonNode =
    let transport = newProcessTransport(getAppFilename(), ["--senv"], env = env, workingDir = workingDir)
    result = (waitFor transport.receiveMessage())["params"]
    waitFor transport.close()

  test "Given an environment and a directory, when a server is started, then it sees only that environment and runs there":
    putEnv("MCP_TEST_SECRET", "parent only")
    let dir = getTempDir().expandFilename
    let p = started(newStringTable({"MCP_TEST_GIVEN": "given"}, modeCaseSensitive), dir)
    check p["given"].getStr == "given"
    check not p["secret"].getBool
    check p["cwd"].getStr == dir
    delEnv("MCP_TEST_SECRET")

  test "Given no environment, when a server is started, then it inherits this process's environment and directory":
    putEnv("MCP_TEST_SECRET", "parent only")
    let p = started()
    check p["secret"].getBool
    check p["cwd"].getStr == getCurrentDir()
    delEnv("MCP_TEST_SECRET")

  test "Given this process's environment, when the default server environment is made, then only the basic variables pass and the given ones win":
    putEnv("MCP_TEST_SECRET", "parent only")
    let env = defaultServerEnvironment({"MCP_TEST_GIVEN": "given", "HOME": "/elsewhere"})
    check env["PATH"] == getEnv("PATH")
    check env["HOME"] == "/elsewhere"
    check env["MCP_TEST_GIVEN"] == "given"
    check not env.hasKey("MCP_TEST_SECRET")
    delEnv("MCP_TEST_SECRET")

  test "Given a directory that does not exist, when a server is started there, then McpTransportError names it":
    try:
      discard newProcessTransport(getAppFilename(), ["--senv"], workingDir = "/no/such/directory")
      check false
    except McpTransportError as e:
      check "/no/such/directory" in e.msg
