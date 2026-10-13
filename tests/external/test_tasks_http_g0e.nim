## tasks/get and tasks/result of 2025-11-25 over Streamable HTTP on real
## sockets (127.0.0.1, a listener the test starts): tasks/get is answered
## without an event stream, and a client may drop the stream of tasks/get or
## tasks/result at any time without harming the task.

import std/[unittest, asyncnet, nativesockets, uri, asyncdispatch, httpcore, httpclient, json, options, strutils]
import transport/http_server
import server/server except McpRequestError
import server/tasks
import protocol/types
import protocol/tasks
import sse_reader

const TaskVersion = mpv20251125

type Rig = ref object
  url: string
  server: McpServer
  started: Future[void]
  goOn: Future[void]
  session: string
  store: TaskStore

proc startRig(): Rig =
  let transport = newHttpServerTransport(port = 0, protocolVersion = TaskVersion)
  transport.listen()
  asyncCheck transport.serve()
  let rig = Rig(started: newFuture[void]("started"), goOn: newFuture[void]("goOn"),
                url: "http://127.0.0.1:" & $transport.port & "/mcp")
  let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
    protocolVersion = TaskVersion,
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"name": "work", "inputSchema": {"type": "object"},
                               "execution": {"taskSupport": "optional"}}]))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    rig.started.complete()
    await rig.goOn
    return %*{"content": [{"type": "text", "text": "worked"}]})
  rig.store = server.enableTasks(TaskConfig(), newTaskStore(pollIntervalMs = some(5)))
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
      "protocolVersion": $TaskVersion, "capabilities": {},
      "clientInfo": {"name": "peer", "version": "0"}}),
    newHttpHeaders({"Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream"}))
  doAssert reply.code == Http200
  rig.session = $reply.headers["Mcp-Session-Id"]
  let initialized = sse_reader.open(rig.url, HttpPost,
    $(%*{"jsonrpc": "2.0", "method": "notifications/initialized"}), rig.headers)
  initialized.close()

proc post(rig: Rig, body: string): tuple[contentType: string, message: JsonNode] =
  ## The answer to a request that is answered at once, and how it came.
  let reply = sse_reader.open(rig.url, HttpPost, body, rig.headers)
  defer: reply.close()
  doAssert reply.code == Http200, $reply.code
  result.contentType = reply.contentType
  if "event-stream" in reply.contentType:
    let messages = reply.messages
    doAssert messages.len == 1, $messages
    result.message = messages[0]
  else:
    result.message = parseJson(waitFor reply.response.readAll(1_000_000))

proc sendAndHold(rig: Rig, body: string): AsyncSocket =
  ## Sends a request on a socket of its own and does not read the answer, so
  ## that the test can drop the connection while the server still serves it.
  let target = parseUri(rig.url)
  result = newAsyncSocket(buffered = false)
  waitFor result.connect("127.0.0.1", Port(parseInt(target.port)))
  var text = "POST " & target.path & " HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
    "Accept: application/json, text/event-stream\r\nContent-Type: application/json\r\n"
  for (name, value) in rig.headers:
    text.add name & ": " & value & "\r\n"
  text.add "Content-Length: " & $body.len & "\r\n\r\n" & body
  waitFor result.send(text)

proc createTask(rig: Rig): string =
  rig.post(rpc(2, "tools/call", %*{"name": "work", "arguments": {}, "task": {}})
          ).message["result"]["task"]["taskId"].getStr()

proc awaitStatus(rig: Rig, taskId, wanted: string) =
  for _ in 0 ..< 400:
    let answer = rig.post(rpc(9, "tasks/get", %*{"taskId": taskId}))
    if answer.message["result"]["status"].getStr() == wanted:
      return
    waitFor sleepAsync(5)
  doAssert false, "the task never was " & wanted

if isSupported(TaskVersion):
  suite "tasks/get over Streamable HTTP":

    test "Given a working task and a completed one, when tasks/get is asked, then the answer is not an event stream":
      let rig = startRig()
      rig.handshake()
      let taskId = rig.createTask()
      waitFor rig.started
      let working = rig.post(rpc(3, "tasks/get", %*{"taskId": taskId}))
      check working.message["result"]["status"].getStr() == "working"
      check "event-stream" notin working.contentType
      rig.goOn.complete()
      rig.awaitStatus(taskId, "completed")
      let done = rig.post(rpc(4, "tasks/get", %*{"taskId": taskId}))
      check done.message["result"]["status"].getStr() == "completed"
      check "event-stream" notin done.contentType

  suite "a client that drops the stream of a task request":

    test "Given a tasks/get request, when the client disconnects without reading the answer, then the task and the next requests are unharmed":
      let rig = startRig()
      rig.handshake()
      let taskId = rig.createTask()
      waitFor rig.started
      let dropped = rig.sendAndHold(rpc(5, "tasks/get", %*{"taskId": taskId}))
      dropped.close()
      waitFor sleepAsync(30)
      rig.goOn.complete()
      rig.awaitStatus(taskId, "completed")
      let result = rig.post(rpc(6, "tasks/result", %*{"taskId": taskId}))
      check result.message["result"]["content"][0]["text"].getStr() == "worked"

    test "Given a tasks/result request that waits, when the client disconnects, then the task goes on and a later tasks/result returns its result":
      let rig = startRig()
      rig.handshake()
      let taskId = rig.createTask()
      waitFor rig.started
      let waiting = rig.sendAndHold(rpc(7, "tasks/result", %*{"taskId": taskId}))
      for _ in 0 ..< 200:
        if rig.store.resultStream(taskId).len > 0:
          break
        waitFor sleepAsync(5)
      check rig.store.resultStream(taskId).len > 0
      waiting.close()
      waitFor sleepAsync(30)
      check rig.post(rpc(8, "tasks/get", %*{"taskId": taskId})).message["result"]["status"].getStr() == "working"
      rig.goOn.complete()
      rig.awaitStatus(taskId, "completed")
      let result = rig.post(rpc(10, "tasks/result", %*{"taskId": taskId}))
      check result.message["result"]["content"][0]["text"].getStr() == "worked"
