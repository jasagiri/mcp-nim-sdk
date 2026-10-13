## "The message SHOULD be limited to a concise single sentence" (schema
## JSONRPCError of 2025-06-18 and the error types of 2025-11-25 and
## 2026-07-28). The messages this SDK writes itself for the failures every
## peer meets (parse error, invalid request, method not found, invalid
## params, internal error) are one line and short, and a defect in the
## application's handler is told to the peer as "Internal error", not as the
## exception's text.

import std/[unittest, asyncdispatch, httpclient, json, options, strutils, nativesockets]
import transport/http_server
import ./server_harness
import ./client_peer

const
  MostWords = 12
    ## "Concise": the longest of the SDK's own messages is a sentence of this
    ## many words once the name of the thing it is about is counted as one.

proc isOneConciseSentence(message: string): bool =
  ## One line, no full stop, question or exclamation mark inside it, and
  ## few words.
  if message.len == 0 or message.len > 120:
    return false
  if '\n' in message or '\r' in message:
    return false
  for stop in [". ", "? ", "! "]:
    if stop in message:
      return false
  message.splitWhitespace().len <= MostWords

proc defectiveServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"name": "t", "inputSchema": {
      "type": "object", "properties": {"n": {"type": "integer"}}, "required": ["n"]}}]))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    case name
    of "breaks":
      raise newException(ValueError, "line one\nline two. a second sentence about /private/path")
    else:
      raise newUnknownTool(name))

suite "The errors a server writes (every version)":
  test "Given requests that fail in each standard way, when the server answers, then every message is one concise sentence":
    for v in SupportedProtocolVersions:
      let server = defectiveServer()
      let peer = server.connect(server.attach(), v)
      var seen = 0
      for (methodName, params) in [("nosuch/method", %*{}),
                                   ("tools/call", %*{}),
                                   ("tools/call", %*{"name": 5}),
                                   ("tools/call", %*{"name": "nope"}),
                                   ("tools/call", %*{"name": "t", "arguments": 3}),
                                   ("tools/call", %*{"name": "breaks"}),
                                   ("resources/read", %*{"uri": "file:///x"}),
                                   ("prompts/get", %*{"name": "x"})]:
        let reply = peer.ask(methodName, params)
        if reply.hasKey("error"):
          inc seen
          let message = reply["error"]["message"].getStr()
          check isOneConciseSentence(message)
          if not isOneConciseSentence(message):
            echo "  not concise: ", v, " ", methodName, " ", message
      check seen == 8

  test "Given a handler that fails with a long message of its own, when the server answers, then the peer is told 'Internal error' and nothing the handler wrote":
    for v in SupportedProtocolVersions:
      let server = defectiveServer()
      let reply = server.connect(server.attach(), v).ask("tools/call", %*{"name": "breaks"})
      check reply.errorCode == -32603
      check reply["error"]["message"].getStr() == "Internal error"
      check "line one" notin $reply
      check "private" notin $reply

proc startHttp(): tuple[transport: HttpServerTransport, url: string] =
  let transport = newHttpServerTransport(port = 0)
  transport.listen()
  asyncCheck transport.serve()
  let server = defectiveServer()
  waitFor server.attachTransport(transport)
  (transport, "http://127.0.0.1:" & $transport.port & "/mcp")

suite "The errors an HTTP server writes":
  test "Given bodies that are not requests, when posted, then each answer carries one concise sentence":
    let (_, url) = startHttp()
    let http = newAsyncHttpClient()
    defer: http.close()
    var seen = 0
    for body in ["{not json", "[1, 2]", "42", "\"text\"", "null", "{}"]:
      let response = waitFor http.request(url, HttpPost, body)
      let text = waitFor response.body
      let reply = parseJson(text)
      check reply.hasKey("error")
      if reply.hasKey("error"):
        inc seen
        let message = reply["error"]["message"].getStr()
        check isOneConciseSentence(message)
        if not isOneConciseSentence(message):
          echo "  not concise: ", body, " ", message
    check seen == 6

suite "The errors a client writes":
  test "Given requests the client cannot serve, when it answers the server, then every message is one concise sentence":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let peer = startPeer(nil)
      discard peer.connectedClient(v)
      peer.ask(%"a", "nosuch/method")
      peer.ask(%"b", "sampling/createMessage", %*{"maxTokens": 1})
      peer.ask(%"c", "elicitation/create", %*{"message": "?"})
      waitFor sleepAsync(10)
      var seen = 0
      for message in peer.received:
        if message.hasKey("error"):
          inc seen
          check isOneConciseSentence(message["error"]["message"].getStr())
      check seen == 3
