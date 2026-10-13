## A task belongs to the principal the access token names (2025-11-25 tasks,
## Security: "When an authorization context is provided, receivers MUST bind
## tasks to said context"), not to the transport session: a second principal
## that has the session id still cannot see it. Over real sockets with the
## resource server's authorization.

import std/[unittest, asyncdispatch, httpclient, json, options, strutils]
import transport/http_server
import server/server except McpRequestError
import server/tasks
import auth/resource_server
import protocol/types
import protocol/tasks

const TaskVersion = mpv20251125

type Rig = ref object
  url: string
  seenPrincipals: seq[Option[string]]

proc startRig(withAuth: bool): Rig =
  let transport = newHttpServerTransport(port = 0, protocolVersion = TaskVersion)
  transport.listen()
  asyncCheck transport.serve()
  let rig = Rig(url: "http://127.0.0.1:" & $transport.port & "/mcp")
  if withAuth:
    transport.auth = newResourceServerAuth(ResourceServerConfig(
      resource: rig.url, authorizationServers: @["https://auth.example.com"],
      version: TaskVersion,
      verify: proc(token, resource: string): Future[TokenVerdict] {.async.} =
        if token.startsWith("token-"):
          return TokenVerdict(kind: tvValid, principal: some(token[6 .. ^1]))
        return TokenVerdict(kind: tvInvalid)))
  let server = newMcpServer(McpServerInfo(name: "s", version: "1"),
    protocolVersion = TaskVersion,
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"name": "work", "inputSchema": {"type": "object"},
                               "execution": {"taskSupport": "optional"}}]))
  server.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    rig.seenPrincipals.add ctx.principal
    return %*{"content": [{"type": "text", "text": "done"}]})
  discard server.enableTasks(store = newTaskStore(pollIntervalMs = some(5)))
  waitFor server.attachTransport(transport)
  rig

proc post(rig: Rig, token: string, session: string, body: JsonNode): tuple[headers: HttpHeaders, body: JsonNode] =
  let http = newAsyncHttpClient()
  defer: http.close()
  let headers = newHttpHeaders({"Content-Type": "application/json",
    "Accept": "application/json, text/event-stream"})
  if token.len > 0:
    headers["Authorization"] = "Bearer " & token
  if session.len > 0:
    headers["Mcp-Session-Id"] = session
    headers["MCP-Protocol-Version"] = $TaskVersion
  let response = waitFor http.request(rig.url, HttpPost, $body, headers)
  let text = waitFor response.body
  var parsed = newJNull()
  for line in text.splitLines:
    let data = if line.startsWith("data:"): line[5 .. ^1].strip() else: ""
    if data.len > 0:
      parsed = parseJson(data)
  if parsed.kind == JNull and text.strip().startsWith("{"):
    parsed = parseJson(text)
  (response.headers, parsed)

proc rpc(id: int, name: string, params: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "method": name, "params": params}

proc handshake(rig: Rig, token: string): string =
  let reply = rig.post(token, "", rpc(1, "initialize", %*{
    "protocolVersion": $TaskVersion, "capabilities": {},
    "clientInfo": {"name": "peer", "version": "0"}}))
  result = $reply.headers["Mcp-Session-Id"]
  discard rig.post(token, result, %*{"jsonrpc": "2.0", "method": "notifications/initialized"})

if isSupported(TaskVersion):
  suite "tasks bound to the principal":
    test "Given a task made by one principal, when another with the same session id asks for it, then it is unknown to them":
      let rig = startRig(withAuth = true)
      let session = rig.handshake("token-alice")
      let created = rig.post("token-alice", session, rpc(2, "tools/call",
        %*{"name": "work", "arguments": {}, "task": {}}))
      let taskId = created.body["result"]["task"]["taskId"].getStr()
      check rig.post("token-alice", session, rpc(3, "tasks/get", %*{"taskId": taskId})
                    ).body["result"]["taskId"].getStr() == taskId
      # The transport binds the session to alice (MCP-SEC-HTTP-2): bob does
      # not get as far as the task store, which binds tasks to a principal
      # as well; this test no longer reaches that layer.
      let bob = rig.post("token-bob", session, rpc(4, "tasks/get", %*{"taskId": taskId}))
      check bob.body["error"]["code"].getInt() == -32600
      check rig.post("token-bob", session, rpc(5, "tasks/cancel", %*{"taskId": taskId})
                    ).body.hasKey("error")
      check rig.post("token-bob", session, rpc(6, "tasks/list", newJObject())
                    ).body.hasKey("error")
      check rig.post("token-alice", session, rpc(7, "tasks/list", newJObject())
                    ).body["result"]["tasks"].len == 1

    test "Given a task made by one principal, when another asks for it by its id in a session of their own, then the task store does not show it":
      # Past the transport: bob's session is his, so what refuses him here is
      # the store, which keeps a task for the principal that made it.
      let rig = startRig(withAuth = true)
      let alice = rig.handshake("token-alice")
      let created = rig.post("token-alice", alice, rpc(2, "tools/call",
        %*{"name": "work", "arguments": {}, "task": {}}))
      let taskId = created.body["result"]["task"]["taskId"].getStr()
      let bob = rig.handshake("token-bob")
      check rig.post("token-bob", bob, rpc(3, "tasks/get", %*{"taskId": taskId})
                    ).body["error"]["code"].getInt() == -32602
      check rig.post("token-bob", bob, rpc(4, "tasks/cancel", %*{"taskId": taskId})
                    ).body["error"]["code"].getInt() == -32602
      check rig.post("token-bob", bob, rpc(5, "tasks/list", newJObject())
                    ).body["result"]["tasks"].len == 0
      check rig.post("token-alice", alice, rpc(6, "tasks/get", %*{"taskId": taskId})
                    ).body["result"]["taskId"].getStr() == taskId

    test "Given an authorized request, when a tool runs, then ctx.principal is the subject of the token":
      let rig = startRig(withAuth = true)
      let session = rig.handshake("token-alice")
      discard rig.post("token-alice", session, rpc(2, "tools/call",
        %*{"name": "work", "arguments": {}}))
      check rig.seenPrincipals == @[some("alice")]

    test "Given an endpoint without authorization, when a tool runs, then ctx.principal is none and tasks belong to the session":
      let rig = startRig(withAuth = false)
      let session = rig.handshake("")
      let created = rig.post("", session, rpc(2, "tools/call",
        %*{"name": "work", "arguments": {}, "task": {}}))
      let taskId = created.body["result"]["task"]["taskId"].getStr()
      check rig.post("", session, rpc(3, "tasks/get", %*{"taskId": taskId})
                    ).body["result"]["taskId"].getStr() == taskId
      let other = rig.handshake("")
      check rig.post("", other, rpc(4, "tasks/get", %*{"taskId": taskId})
                    ).body.hasKey("error")
      check rig.seenPrincipals == @[none(string)]
