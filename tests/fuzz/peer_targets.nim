## Fuzzing targets for the messages a peer sends: JSON-RPC requests a server
## dispatches, answers a client reads, OAuth documents, and stdio lines.

import std/[json, options, streams, times, asyncdispatch, httpcore]
import protocol/[types, version, modern, tasks, subscriptions, mrtr, elicitation,
                 sampling_tools, payload]
import protocol/content as protocolContent
import client/content as clientContent
import client/client
import server/server
import transport/[transport, stdio]
import auth/oauth/[errors, urls, metadata, authcode, fetch]
import ./inferred

proc jsonOf(input: string): Option[JsonNode] {.raises: [].} =
  try:
    some(parseJson(input))
  except CatchableError:
    none(JsonNode)   # not JSON: nothing reaches the code under test

proc serverDispatch*(input: string): string {.raises: [CatchableError].} =
  ## A request reaches a fresh server without a transport. Whatever it holds,
  ## the answer is a response; an exception escaping the dispatch is a
  ## finding. `subscriptions/listen` is left out: it streams until cancelled.
  let message = jsonOf(input)
  if message.isNone or message.get.kind != JObject: return ""
  if message.get{"method"}.getStr == "subscriptions/listen": return ""
  try:
    inferred:
      let server = newMcpServer(McpServerInfo(name: "fuzz", version: "0"),
        capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
      discard waitFor server.handleRequest(decodeRequest(message.get))
  except CatchableError as e:
    return "an exception escaped handleRequest: " & $e.name & ": " & e.msg
  ""

proc clientAnswers*(input: string): string {.raises: [CatchableError].} =
  ## The parsers that read what a peer answered or asked for. Each reads the
  ## document or refuses it with the error it documents.
  let doc = jsonOf(input)
  if doc.isNone: return ""
  let node = doc.get
  let params = if node.kind == JObject: node{"params"} else: nil
  template refusedBy(errors: typedesc, body: untyped) =
    try:
      inferred:
        body
    except errors:
      discard   # the documented refusal
  refusedBy(McpProtocolError): discard parseContentItem(node, "fuzz")
  refusedBy(McpProtocolError): discard parseEmbeddedResource(node, "fuzz")
  refusedBy(McpProtocolError): discard parseNextCursor(node, "fuzz")
  refusedBy(McpProtocolError): discard iconsOf(node, "fuzz")
  refusedBy(McpShapeError): discard parseServerInfo(node)
  refusedBy(McpShapeError): discard parseClientInfo(node)
  refusedBy(McpShapeError): discard parseIcons(node)
  refusedBy(McpTaskError): discard taskFromJson(node)
  refusedBy(McpTaskError): discard parseTaskParam(node)
  refusedBy(McpPayloadError): discard parseElicitationResult(node, params)
  refusedBy(McpPayloadError): discard elicitationResultProblems(node, params)
  refusedBy(McpPayloadError):
    discard createMessageResultProblems(node, params, DefaultProtocolVersion)
  discard parseSubscriptionFilter(node)
  discard validateInputRequests(node)
  discard rejectInvalidInputParams(node)
  discard validateModernRequest(node, SupportedProtocolVersions)
  if node.kind == JObject:
    discard checkRequestHeaders(some(node{"v"}.getStr), some(node{"m"}.getStr),
                                some(node{"n"}.getStr), node{"method"}.getStr, params)
  ""

proc oauthDocuments*(input: string): string {.raises: [CatchableError].} =
  ## Metadata documents and a token response, as an authorization server or
  ## a resource server sends them. Each is read or refused with OAuthError.
  let policy = defaultFetchPolicy()
  let doc = jsonOf(input)
  if doc.isSome:
    try:
      discard parseProtectedResourceMetadata(doc.get, "https://rs.example/mcp", policy)
    except OAuthError:
      discard
    try:
      discard parseAuthorizationServerMetadata(doc.get, "https://as.example", policy)
    except OAuthError:
      discard
  try:
    discard parseTokenResponse(HttpReply(code: 200, headers: newHttpHeaders(), body: input),
                               "https://as.example", @["read"], none(string), fromUnix(0))
  except OAuthError:
    discard
  ""

proc stdioLines*(input: string): string {.raises: [CatchableError].} =
  ## Lines as a stdio peer writes them. Each line is a message, skipped, or
  ## the end of the stream; nothing else escapes.
  let t = newStdioTransport(newStringStream(input), newStringStream())
  for _ in 0 .. input.len:
    try:
      inferred:
        discard waitFor t.receiveMessage()
    except McpTransportClosedError:
      return ""
    except McpTransportError:
      return ""   # a line over the limit: the documented refusal
    except CatchableError as e:
      return "an exception escaped receiveMessage: " & $e.name & ": " & e.msg
  "receiveMessage did not reach the end of the input"
