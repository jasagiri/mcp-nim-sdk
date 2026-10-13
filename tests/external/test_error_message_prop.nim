## "The message SHOULD be limited to a concise single sentence" (schema
## JSONRPCError). Said as properties over failures made on purpose: whatever
## request a server, an HTTP server or a client cannot serve, the message of
## its error is one concise sentence, and a handler that fails with a message
## of its own is told to the peer as "Internal error", without that message.

import std/[unittest, asyncdispatch, httpclient, json, options, strutils, nativesockets]
import propcheck
import transport/http_server
import ./server_harness
import ./client_peer

proc guarded[T](body: proc(x: T): bool): Property[T] =
  ## A property whose body may raise what the SDK's setup raises: anything it raises
  ## is a counterexample, named by its type and message.
  result = proc(x: T): bool {.raises: [CatchableError].} =
    try:
      body(x)
    except CatchableError:
      raise
    except Exception as e:
      raise newException(CatchableError, "raised " & $e.name & ": " & e.msg)

const
  MostWords = 12
    ## "Concise": few words.

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

let
  anyWord = stringOf("abcxyz", 1, 6)
  anyJson = map(pair(intIn(0, 5), pair(intIn(-5, 5), anyWord)),
    proc(x: (int, (int, string))): JsonNode {.raises: [].} =
      case x[0]
      of 0: %x[1][0]
      of 1: %x[1][1]
      of 2: %(x[1][0] > 0)
      of 3: newJNull()
      of 4: %*[x[1][0], x[1][1]]
      else: %*{"k": x[1][1]})

# --- the server (every version) ----------------------------------------------------------

type
  Failing = object
    version: McpProtocolVersion
    methodName: string
    params: JsonNode

proc failingServer(): McpServer =
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return McpPage(items: @[%*{"name": "t", "inputSchema": {
      "type": "object", "properties": {"n": {"type": "integer"}}, "required": ["n"]}}]))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    raise newUnknownTool(name))

let
  # Space: a method nobody serves, and the methods every server has, called without what they
  # need, with it of the wrong type, with params that are not an object, with a tool that is
  # not there and with arguments that are not an object.
  anyFailing = map(
    pair(pair(pick(SupportedProtocolVersions), intIn(0, 8)), pair(anyWord, anyJson)),
    proc(x: ((McpProtocolVersion, int), (string, JsonNode))): Failing {.raises: [].} =
      let (kind, word, value) = (x[0][1], x[1][0], x[1][1])
      let (m, p) =
        case kind
        of 0: ("zz" & word & "/" & word, newJObject())
        of 1: ("tools/call", newJObject())
        of 2: ("tools/call", %*{"name": %*[value]})       # a name that is no string
        of 3: ("tools/call", %*{"name": "no" & word})     # a tool that is not there
        of 4: ("tools/call", %*{"name": "t", "arguments": %*[value, 1]})   # arguments that are no object
        of 5: ("tools/call", %*[word, 1])                  # params that are no object
        of 6: ("resources/read", %*{"uri": %*[value]})
        of 7: ("resources/read", newJObject())
        else: ("prompts/get", %*{"name": %*[value]})
      Failing(version: x[0][0], methodName: m, params: p))

suite "The errors a server writes (every version)":

  test "Given any request the server cannot serve, when it answers, then the message of the error is one concise sentence":
    let outcome = propcheck.check(anyFailing,
      guarded(proc(f: Failing): bool =
        let server = failingServer()
        let reply = server.connect(server.attach(), f.version).ask(f.methodName, f.params)
        reply.hasKey("error") and isOneConciseSentence(reply["error"]["message"].getStr())))
    checkpoint describe(outcome)
    check outcome.passed

  test "Given any message of its own that a handler fails with, when the server answers, then the peer is told 'Internal error' and nothing the handler wrote":
    # Space: an exception of one of four types, with a message of up to five pieces: words,
    # line breaks, sentences, a path.
    let anyHandlerMessage = map(
      pair(pair(pick(SupportedProtocolVersions), intIn(0, 3)),
           seqOf(pick(["a", "line\n", ". Second sentence ", "/private/path", " ", "x y z w v u t"]), 1, 5)),
      proc(x: ((McpProtocolVersion, int), seq[string])): (McpProtocolVersion, int, string) {.raises: [].} =
        var text = "handler-says:"
        for piece in x[1]: text.add piece
        (x[0][0], x[0][1], text))
    let outcome = propcheck.check(anyHandlerMessage,
      guarded(proc(f: (McpProtocolVersion, int, string)): bool =
        let (version, kind, text) = f
        let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
        server.onToolCall(proc(ctx: McpRequestContext, name: string,
                               arguments: JsonNode): Future[JsonNode] {.async.} =
          case kind
          of 0: raise newException(ValueError, text)
          of 1: raise newException(IOError, text)
          of 2: raise newException(KeyError, text)
          else: raise newException(OSError, text))
        let reply = server.connect(server.attach(), version).ask("tools/call", %*{"name": "breaks"})
        reply.hasKey("error") and reply.errorCode == -32603 and
          reply["error"]["message"].getStr() == "Internal error" and
          "handler-says" notin $reply and text notin $reply and
          # nor a part of it: every piece the text is made of, wherever it stood
          "line" notin $reply and "Second sentence" notin $reply and
          "/private/path" notin $reply and "x y z w v u t" notin $reply))
    checkpoint describe(outcome)
    check outcome.passed

# --- an HTTP server ----------------------------------------------------------------------

proc startHttp(): string =
  let transport = newHttpServerTransport(port = 0)
  transport.listen()
  asyncCheck transport.serve()
  let server = failingServer()
  waitFor server.attachTransport(transport)
  "http://127.0.0.1:" & $transport.port & "/mcp"

suite "The errors an HTTP server writes":

  test "Given any body that is not a request, when posted, then the answer carries one concise sentence":
    # Space: text that is not JSON, and JSON that is no request: a number, a string, a boolean,
    # null, arrays and objects without a method.
    let url = startHttp()
    let http = newAsyncHttpClient()
    defer: http.close()
    let anyBody = map(pair(intIn(0, 4), pair(anyWord, anyJson)),
      proc(x: (int, (string, JsonNode))): string {.raises: [].} =
        case x[0]
        of 0: "{" & x[1][0]                          # cut off: not JSON
        of 1: x[1][0] & " " & x[1][0]                # words: not JSON
        of 2: $(%*[1, 2, x[1][0].len])               # an array of numbers
        of 3: $(%*{"k": x[1][1]})                    # an object that names no method
        else: $x[1][1])                              # any JSON value by itself
    let outcome = propcheck.check(anyBody,
      guarded(proc(body: string): bool =
        let response = waitFor http.request(url, HttpPost, body)
        let reply = parseJson(waitFor response.body)
        reply.hasKey("error") and isOneConciseSentence(reply["error"]["message"].getStr())))
    checkpoint describe(outcome)
    check outcome.passed

# --- a client ------------------------------------------------------------------------------

suite "The errors a client writes":

  test "Given any request the client cannot serve, when it answers the server, then the message of the error is one concise sentence":
    # Space: a method nobody serves, and a request for a sample or an elicitation with params of
    # any JSON type, to a client that has no handler for them.
    var versions: seq[McpProtocolVersion]
    for v in SupportedProtocolVersions:
      if not isModern(v): versions.add v
    if versions.len == 0:
      skip()
    else:
      let anyUnserved = map(pair(pair(pick(versions), intIn(0, 2)), pair(anyWord, anyJson)),
        proc(x: ((McpProtocolVersion, int), (string, JsonNode))): (McpProtocolVersion, string, JsonNode) {.raises: [].} =
          case x[0][1]
          of 0: (x[0][0], "zz" & x[1][0] & "/" & x[1][0], newJObject())
          of 1: (x[0][0], "sampling/createMessage", %*{"maxTokens": x[1][1]})
          else: (x[0][0], "elicitation/create", %*{"message": x[1][1]}))
      let outcome = propcheck.check(anyUnserved,
        guarded(proc(r: (McpProtocolVersion, string, JsonNode)): bool =
          let peer = startPeer(nil)
          discard peer.connectedClient(r[0])
          peer.ask(%"a", r[1], r[2])
          waitFor sleepAsync(5)
          for message in peer.received:
            if message.hasKey("error"):
              return isOneConciseSentence(message["error"]["message"].getStr())
          false))
      checkpoint describe(outcome)
      check outcome.passed
