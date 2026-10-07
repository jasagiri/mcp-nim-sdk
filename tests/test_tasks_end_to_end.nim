## Tasks between the SDK's own client and server over an in-process
## transport, in 2025-11-25: the two halves must agree on the wire, not only
## each with a hand-written peer.

import std/[asyncdispatch, json, options, unittest]
import server/server except McpRequestError
import server/tasks
import client/client
import client/content
import client/sampling
import client/elicitation
import client/roots
import server/elicit
import client/tools
import client/tasks
import protocol/types
import protocol/tasks
import ./loopback_transport

const TaskVersion = mpv20251125

proc textOf(text: string): JsonNode =
  %*{"content": [{"type": "text", "text": text}]}

proc taskServer(store: TaskStore): McpServer =
  let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[
      %*{"name": "report", "inputSchema": {"type": "object"},
         "execution": {"taskSupport": "optional"}},
      %*{"name": "ask", "inputSchema": {"type": "object"},
         "execution": {"taskSupport": "optional"}},
      %*{"name": "form", "inputSchema": {"type": "object"},
         "execution": {"taskSupport": "optional"}}]))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "ask":
      let answer = await ctx.createMessage(%*{
        "messages": [{"role": "user", "content": {"type": "text", "text": "name?"}}],
        "maxTokens": 5})
      return textOf("the client said " & answer["content"]["text"].getStr())
    of "form":
      let answer = await ctx.elicit("name?", %*{"type": "object",
        "properties": {"name": {"type": "string"}}})
      return textOf("the user said " & answer.content{"name"}.getStr())
    else:
      await sleepAsync(10)
      return textOf("report of " & arguments{"topic"}.getStr()))
  discard server.enableTasks(store = store)
  server

proc quickStore(): TaskStore =
  newTaskStore(pollIntervalMs = some(5))

proc connected(server: McpServer, configure: proc(client: McpClient) = nil): McpClient =
  let pair = newLoopbackPair()
  waitFor server.attachTransport(pair.server)
  let client = newMcpClient(McpClientInfo(name: "c", version: "1"), TaskVersion)
  if not configure.isNil:
    configure(client)
  waitFor client.connect(pair.client)
  client

if isSupported(TaskVersion):
  suite "tasks end to end":
    test "Given a server with tasks, when a client calls a tool as a task, then it learns the task and gets the result":
      let server = taskServer(quickStore())
      let client = server.connected()
      check client.negotiatedVersion == some(TaskVersion)
      check client.serverCapabilities.get.tasks.get.toolsCall
      let tools = waitFor client.listAllTools()
      let report = tools[0]
      let created = waitFor client.callToolAsTask(report, %*{"topic": "sales"}, some(60_000'i64))
      check created.task.status == tsWorking
      check created.task.ttlMs == some(60_000'i64)
      let finished = waitFor client.waitForTask(created.task.taskId)
      check finished.status == tsCompleted
      let payload = waitFor client.taskResult(created.task.taskId)
      check toolContentOf(payload).contentItems[0].text == "report of sales"
      check waitFor(client.listAllTasks()).len == 1

    test "Given a tool, when called with callToolWithTask, then the result is the same as a plain call":
      let server = taskServer(quickStore())
      let client = server.connected()
      let tools = waitFor client.listAllTools()
      let viaTask = waitFor client.callToolWithTask(tools[0], %*{"topic": "x"})
      let plain = waitFor client.callTool("report", %*{"topic": "x"})
      check viaTask.contentItems[0].text == plain.contentItems[0].text

    test "Given a task that cancels, when the client cancels it, then it is cancelled for both":
      let server = taskServer(quickStore())
      let client = server.connected()
      let tools = waitFor client.listAllTools()
      let created = waitFor client.callToolAsTask(tools[0], %*{"topic": "x"})
      let cancelled = waitFor client.cancelTask(created.task.taskId)
      check cancelled.status == tsCancelled
      check waitFor(client.getTask(created.task.taskId)).status == tsCancelled
      expect McpRequestError:
        discard waitFor client.taskResult(created.task.taskId)

    test "Given a tool that asks the client for sampling, when called with a task, then the client answers and the task completes":
      let server = taskServer(quickStore())
      let client = server.connected(proc(client: McpClient) =
        client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
          return McpSamplingResult(role: "assistant", model: "m",
            content: McpContentItem(kind: mckText, text: "Ada"))))
      let tools = waitFor client.listAllTools()
      let content = waitFor client.callToolWithTask(tools[1])
      check content.contentItems[0].text == "the client said Ada"

    test "Given a client that receives tasks, when the server asks for sampling as a task, then the answer is the handler's":
      let server = taskServer(quickStore())
      let client = server.connected(proc(client: McpClient) =
        client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
          await sleepAsync(10)
          return McpSamplingResult(role: "assistant", model: "m",
            content: McpContentItem(kind: mckText, text: "Grace")))
        discard client.enableClientTasks(store = quickStore()))
      discard client
      let answer = waitFor server.createMessageAsTask("", %*{
        "messages": [{"role": "user", "content": {"type": "text", "text": "name?"}}],
        "maxTokens": 5})
      check answer["content"]["text"].getStr() == "Grace"
      check answer["model"].getStr() == "m"

    test "Given a tool that elicits inside a task, when the user has not answered, then the task needs input and the question belongs to it":
      let server = taskServer(quickStore())
      let gate = newFuture[void]("answer")
      var seen: JsonNode
      let client = server.connected(proc(client: McpClient) =
        client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
          seen = request.raw
          await gate
          return McpElicitResult(action: eaAccept, content: %*{"name": "Ada"})))
      let tools = waitFor client.listAllTools()
      let created = waitFor client.callToolAsTask(tools[2])
      let taskId = created.task.taskId
      var waiting = false
      for _ in 0 ..< 100:
        if waitFor(client.getTask(taskId)).status == tsInputRequired:
          waiting = true
          break
        waitFor sleepAsync(5)
      check waiting
      # the question is delivered on the stream of tasks/result
      let fetching = client.taskResult(taskId)
      for _ in 0 ..< 100:
        if not seen.isNil: break
        waitFor sleepAsync(5)
      check seen{"_meta", RelatedTaskKey}{"taskId"}.getStr() == taskId
      gate.complete()
      let payload = waitFor fetching
      check toolContentOf(payload).contentItems[0].text == "the user said Ada"
      check waitFor(client.getTask(taskId)).status == tsCompleted

    test "Given a tool that asks the client for sampling or roots inside a task, when the client has answered, then the task is working again while the tool goes on":
      for asked in ["sample", "roots"]:
        let answered = newFuture[void]("answered")
        let hold = newFuture[void]("hold")
        let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
          capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
        server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
          return McpPage(items: @[
            %*{"name": "sample", "inputSchema": {"type": "object"},
               "execution": {"taskSupport": "optional"}},
            %*{"name": "roots", "inputSchema": {"type": "object"},
               "execution": {"taskSupport": "optional"}}]))
        server.onToolCall(proc(ctx: McpRequestContext, name: string,
                               arguments: JsonNode): Future[JsonNode] {.async.} =
          if name == "sample":
            discard await ctx.createMessage(%*{
              "messages": [{"role": "user", "content": {"type": "text", "text": "name?"}}],
              "maxTokens": 5})
          else:
            discard await ctx.listRoots()
          answered.complete()
          await hold
          return textOf("done"))
        discard server.enableTasks(store = quickStore())
        let client = server.connected(proc(client: McpClient) =
          client.setSamplingHandler(proc(request: McpSamplingRequest): Future[McpSamplingResult] {.async.} =
            return McpSamplingResult(role: "assistant", model: "m",
              content: McpContentItem(kind: mckText, text: "Ada")))
          client.setRootsProvider(proc(): Future[seq[McpRoot]] {.async.} =
            return @[McpRoot(uri: "file:///project")]))
        let tools = waitFor client.listAllTools()
        let created = waitFor client.callToolAsTask(tools[if asked == "sample": 0 else: 1])
        # the question reaches the client on the stream of tasks/result
        let fetching = client.taskResult(created.task.taskId)
        waitFor answered
        check waitFor(client.getTask(created.task.taskId)).status == tsWorking
        hold.complete()
        discard waitFor fetching
        check waitFor(client.getTask(created.task.taskId)).status == tsCompleted

    test "Given a client that receives tasks, when the server asks for elicitation as a task, then the answer is the handler's":
      let server = taskServer(quickStore())
      let client = server.connected(proc(client: McpClient) =
        client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
          await sleepAsync(10)
          return McpElicitResult(action: eaAccept, content: %*{"name": "Grace"}))
        discard client.enableClientTasks(ClientTaskConfig(sampling: false, elicitation: true),
                                         store = quickStore()))
      discard client
      let created = waitFor server.requestAsTask("", "elicitation/create", %*{
        "message": "name?", "requestedSchema": {"type": "object",
          "properties": {"name": {"type": "string"}}}})
      discard waitFor server.awaitClientTask("", created.taskId)
      let answer = waitFor server.clientTaskResult("", created.taskId)
      check answer["action"].getStr() == "accept"
      check answer["content"]["name"].getStr() == "Grace"
