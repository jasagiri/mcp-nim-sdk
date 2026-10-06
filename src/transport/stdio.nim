## MCP stdio transport: one JSON-RPC message per line.
##
## A server reads its own stdin and writes its stdout (`newStdioTransport`).
## A client starts the server as a child process and talks to its pipes
## (`newProcessTransport`). Reads go through the async dispatcher, so timers
## and other transports keep running while a peer is silent.

import std/[asyncdispatch, asyncfile, json, options, osproc, posix, streams, strutils]
import ./transport
import ../protocol/types
import ../protocol/diagnostic

const
  DefaultMaxLineSize* = 16 * 1024 * 1024
  ReadChunkSize = 64 * 1024
  ExitPollMs = 20
  ExitGraceMs = 2000
    ## How long a server process gets to exit after its stdin is closed
    ## before it is terminated, and again before it is killed.
  ParseErrorReply = """{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"""

type
  LineSource = proc(): Future[Option[string]] {.closure.}
    ## The next line, or none at end of input.
  LineSink = proc(line: string): Future[void] {.closure.}

  StdioTransport* = ref object of McpTransport
    readLine: LineSource
    writeLine: LineSink
    closeStreams: proc() {.closure.}
    answersParseErrors: bool
      ## A server answers a line that is not JSON with a parse error; a
      ## client does not send errors to a server that printed noise.
    process*: Process
      ## The server process, for a transport made by newProcessTransport.

  AsyncLineReader = ref object
    file: AsyncFile
    buffer: string
    atEnd: bool
    maxLineSize: int

proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL)
  if flags == -1 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) == -1:
    raise newException(McpTransportError,
      "cannot make file descriptor " & $fd & " non-blocking: " & $strerror(errno))

proc takeLine(buffer: var string): Option[string] =
  let newline = buffer.find('\n')
  if newline < 0:
    return none(string)
  var line = buffer[0 ..< newline]
  buffer = buffer[newline + 1 .. ^1]
  line.removeSuffix('\r')
  some(line)

proc nextLine(reader: AsyncLineReader): Future[Option[string]] {.async.} =
  while true:
    let line = takeLine(reader.buffer)
    if line.isSome:
      return line
    if reader.atEnd:
      if reader.buffer.len == 0:
        return none(string)
      # A last line without a newline.
      let rest = reader.buffer
      reader.buffer = ""
      return some(rest)
    if reader.buffer.len > reader.maxLineSize:
      raise newException(McpTransportError,
        "a message exceeds " & $reader.maxLineSize & " bytes")
    let chunk = await reader.file.read(ReadChunkSize)
    if chunk.len == 0:
      reader.atEnd = true
    else:
      reader.buffer.add chunk

proc asyncReader(fd: cint, maxLineSize: int): AsyncLineReader =
  setNonBlocking(fd)
  AsyncLineReader(file: newAsyncFile(AsyncFD(fd)), maxLineSize: maxLineSize)

proc newStdioTransport*(maxLineSize = DefaultMaxLineSize): StdioTransport =
  ## The transport of a server process: this process's stdin and stdout.
  let reader = asyncReader(STDIN_FILENO, maxLineSize)
  StdioTransport(
    kind: mtkStdio,
    answersParseErrors: true,
    readLine: proc(): Future[Option[string]] = reader.nextLine(),
    writeLine: proc(line: string): Future[void] {.async.} =
      stdout.write(line & "\n")
      stdout.flushFile(),
    closeStreams: proc() = reader.file.close()
  )

proc newStdioTransport*(input: Stream, output: Stream): StdioTransport =
  ## A transport over ordinary streams. Reads block; meant for tests and
  ## for in-memory streams.
  StdioTransport(
    kind: mtkStdio,
    answersParseErrors: true,
    readLine: proc(): Future[Option[string]] {.async.} =
      var line = ""
      if input.readLine(line):
        return some(line)
      return none(string),
    writeLine: proc(line: string): Future[void] {.async.} =
      output.writeLine(line)
      output.flush(),
    closeStreams: proc() =
      input.close()
      output.close()
  )

proc forwardStderr(file: AsyncFile) {.async.} =
  ## A child that fills its stderr pipe would stall; pass its diagnostics on.
  while true:
    let chunk = await file.read(ReadChunkSize)
    if chunk.len == 0:
      break
    stderr.write(chunk)

proc newProcessTransport*(command: string, args: openArray[string] = [],
                          maxLineSize = DefaultMaxLineSize): StdioTransport =
  ## Start `command` as an MCP server and talk to it over its stdin and
  ## stdout. What it writes to stderr appears on this process's stderr.
  var process: Process
  try:
    process = startProcess(command, args = args, options = {poUsePath})
  except OSError as e:
    raise newException(McpTransportError,
      "cannot start MCP server '" & command & "': " & e.msg)

  # The process owns its pipe descriptors and closes them; here they are
  # only registered with the dispatcher, and unregistered again on close.
  let outFd = process.outputHandle.cint
  let errFd = process.errorHandle.cint
  let reader = asyncReader(outFd, maxLineSize)
  setNonBlocking(errFd)
  asyncCheck forwardStderr(newAsyncFile(AsyncFD(errFd)))
  let toChild = process.inputStream

  StdioTransport(
    kind: mtkStdio,
    answersParseErrors: false,
    process: process,
    readLine: proc(): Future[Option[string]] = reader.nextLine(),
    writeLine: proc(line: string): Future[void] {.async.} =
      try:
        toChild.writeLine(line)
        toChild.flush()
      except IOError, OSError:
        raise newException(McpTransportClosedError,
          "the MCP server process no longer reads its input"),
    closeStreams: proc() =
      unregister(AsyncFD(outFd))
      unregister(AsyncFD(errFd))
      # Closing its stdin is how a stdio server is asked to exit.
      toChild.close()
  )

method sendRequest*(t: StdioTransport, request: JsonRpcRequest): Future[void] {.async.} =
  await t.writeLine(encodeMessage(request))

method sendNotification*(t: StdioTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  await t.writeLine(encodeMessage(notification))

method sendResponse*(t: StdioTransport, response: JsonRpcResponse): Future[void] {.async.} =
  await t.writeLine(encodeMessage(response))

method receiveMessage*(t: StdioTransport): Future[JsonNode] {.async.} =
  while true:
    let line = await t.readLine()
    if line.isNone:
      raise newException(McpTransportClosedError, "EOF on input stream")
    if line.get.strip().len == 0:
      continue
    try:
      return parseJson(line.get)
    except JsonParsingError as e:
      stderr.writeLine("[mcp-stdio] ignoring a line that is not JSON: " & peerText(e.msg))
      if t.answersParseErrors:
        await t.writeLine(ParseErrorReply)

proc exitedWithin(process: Process, ms: int): Future[bool] {.async.} =
  var waited = 0
  while process.running:
    if waited >= ms:
      return false
    await sleepAsync(ExitPollMs)
    waited += ExitPollMs
  return true

method close*(t: StdioTransport): Future[void] {.async.} =
  t.closeStreams()
  if not t.process.isNil:
    if not await t.process.exitedWithin(ExitGraceMs):
      t.process.terminate()
      if not await t.process.exitedWithin(ExitGraceMs):
        t.process.kill()
        discard await t.process.exitedWithin(ExitGraceMs)
    t.process.close()
