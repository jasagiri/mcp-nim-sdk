## What a task of 2025-11-25 says while it runs, over Streamable HTTP on real
## sockets: the stream of the `tools/call` that created it has ended with the
## CreateTaskResult, so progress, logs and the tool's questions to the user
## must find another stream: the one of a waiting `tasks/result`, or the GET
## stream. A question that needs an answer waits for `tasks/result`, as the
## specification's input_required flow has it.

import std/[times, unittest, asyncdispatch, httpcore, httpclient, json, options, strutils]
import transport/http_server
import server/server except McpRequestError
import server/tasks
import server/elicit
import protocol/types
import protocol/tasks
import protocol/log_level
import sse_reader

const TaskVersion = mpv20251125

type Rig = ref object
  url: string
  server: McpServer
  started: Future[void]
    ## completes when the tool has begun
  goOn: Future[void]
    ## the tool waits for it before it reports anything
  asked: Future[void]
    ## the tool waits for it after it has the user's answer
  session: string
  store: TaskStore

proc startRig(maxHeld = 32): Rig =
  let transport = newHttpServerTransport(port = 0, protocolVersion = TaskVersion)
  transport.listen()
  asyncCheck transport.serve()
  let rig = Rig(started: newFuture[void]("started"), goOn: newFuture[void]("goOn"),
                asked: newFuture[void]("asked"),
                url: "http://127.0.0.1:" & $transport.port & "/mcp")
  let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
    protocolVersion = TaskVersion,
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability()),
                                         logging: some(McpLoggingCapability())))
  server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"name": "work", "inputSchema": {"type": "object"},
                               "execution": {"taskSupport": "optional"}}]))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    rig.started.complete()
    await rig.goOn
    await ctx.reportProgress(1.0, some(2.0), "half")
    await ctx.log(mllInfo, %"working")
    let answer = await ctx.elicit("name?", %*{"type": "object",
      "properties": {"name": {"type": "string"}}})
    return %*{"content": [{"type": "text", "text": "hello " & answer.content{"name"}.getStr()}]})
  rig.store = server.enableTasks(TaskConfig(maxQueuedMessages: maxHeld),
                                 newTaskStore(pollIntervalMs = some(5)))
  waitFor server.attachTransport(transport)
  rig.server = server
  rig

proc headers(rig: Rig): seq[(string, string)] =
  @[("Mcp-Session-Id", rig.session), ("MCP-Protocol-Version", $TaskVersion)]

proc rpc(id: int, name: string, params: JsonNode): string =
  $(%*{"jsonrpc": "2.0", "id": id, "method": name, "params": params})

proc handshake(rig: Rig) =
  let http = newAsyncHttpClient()
  defer: http.close()
  let reply = waitFor http.request(rig.url, HttpPost, rpc(1, "initialize", %*{
      "protocolVersion": $TaskVersion,
      "capabilities": {"elicitation": {"form": {}}},
      "clientInfo": {"name": "peer", "version": "0"}}),
    newHttpHeaders({"Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream"}))
  doAssert reply.code == Http200
  rig.session = $reply.headers["Mcp-Session-Id"]
  let initialized = sse_reader.open(rig.url, HttpPost,
    $(%*{"jsonrpc": "2.0", "method": "notifications/initialized"}), rig.headers)
  initialized.close()

proc postOnce(rig: Rig, body: string): JsonNode =
  ## A request answered at once: the answer is plain JSON, or an event stream
  ## of one message.
  let reply = sse_reader.open(rig.url, HttpPost, body, rig.headers)
  defer: reply.close()
  doAssert reply.code == Http200, $reply.code
  if "event-stream" in reply.contentType:
    let messages = reply.messages
    doAssert messages.len == 1, $messages
    return messages[0]
  parseJson(waitFor reply.response.readAll(1_000_000))

proc callAsTask(rig: Rig): string =
  ## Creates the task; its own stream ends with the CreateTaskResult.
  rig.postOnce(rpc(2, "tools/call", %*{
    "name": "work", "arguments": {}, "task": {},
    "_meta": {"progressToken": "p"}}))["result"]["task"]["taskId"].getStr()

proc awaitStatus(rig: Rig, taskId: string, wanted: TaskStatus) =
  for _ in 0 ..< 200:
    let answer = rig.postOnce(rpc(9, "tasks/get", %*{"taskId": taskId}))
    if answer["result"]["status"].getStr() == $wanted:
      return
    waitFor sleepAsync(5)
  doAssert false, "the task never was " & $wanted

proc startResultStream(rig: Rig, taskId: string): Future[Events] =
  ## A `tasks/result` request, in progress on the server when this returns;
  ## its headers come with its first event, so the stream is the future.
  let opening = openAsync(rig.url, HttpPost, rpc(3, "tasks/result", %*{"taskId": taskId}),
                          rig.headers)
  for _ in 0 ..< 200:
    if rig.store.resultStream(taskId).len > 0:
      break
    waitFor sleepAsync(5)
  doAssert rig.store.resultStream(taskId).len > 0, "tasks/result never arrived"
  opening

proc heardWithin(stream: Events, ms: int): string =
  ## Everything the stream says in `ms` milliseconds.
  let deadline = epochTime() + ms.float / 1000
  while epochTime() < deadline:
    let read = stream.response.readSome()
    if not waitFor withTimeout(read, max(1, int((deadline - epochTime()) * 1000))):
      break
    result.add read.read()

proc nextOn(stream: Events, wanted: string): JsonNode =
  ## The next message of `stream` that is `wanted`, skipping nothing else.
  var event = stream.next()
  while event.isSome and event.get.data.len == 0:
    event = stream.next()  # an event without data only primes the stream
  doAssert event.isSome, "the stream ended before " & wanted
  result = parseJson(event.get.data)
  doAssert result{"method"}.getStr() == wanted, "expected " & wanted & ", got " & $result

if isSupported(TaskVersion):
  suite "tasks over Streamable HTTP":

    test "Given a task and no tasks/result, when the tool reports progress and logs, then they are on the GET stream and the task goes on":
      let rig = startRig()
      rig.handshake()
      let taskId = rig.callAsTask()
      let listen = sse_reader.open(rig.url, HttpGet, "", rig.headers)
      waitFor rig.started
      rig.goOn.complete()
      let heard = listen.heardWithin(500)
      check "notifications/progress" in heard
      check "notifications/message" in heard
      check taskId in heard
      check "elicitation/create" notin heard
      listen.close()


    test "Given a task whose held questions are limited, when the tool asks beyond the limit, then the question is refused and the task fails":
      let rig = startRig(maxHeld = 0)
      rig.handshake()
      let taskId = rig.callAsTask()
      waitFor rig.started
      rig.goOn.complete()
      rig.awaitStatus(taskId, tsFailed)
