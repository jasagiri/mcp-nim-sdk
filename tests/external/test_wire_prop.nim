## What a client and a server put on the wire, as the base protocol fixes it,
## said as properties: every request carries a string id that is neither null
## nor empty nor used twice, whichever the method, and a result may be an
## object of any shape.

import std/[unittest, asyncdispatch, json, options, sets, strutils]
import propcheck
import client/client
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

# --- JSON of any shape -------------------------------------------------------------------------

proc leafOf(x: (int, (int, string))): JsonNode =
  case x[0]
  of 0: newJNull()
  of 1: %x[1][0]
  of 2: %(x[1][0].float / 4.0)
  of 3: %x[1][1]
  of 4: %(x[1][0] > 0)
  of 5: newJArray()
  else: newJObject()

let
  anyText = map(seqOf(pick(["", "a", "ü", "日本", "😀", "\"", "\\", "\n", "\t", "/", "\u0001", " "]), 0, 4),
    proc(pieces: seq[string]): string {.raises: [].} = pieces.join(""))
  anyKey = stringOf("abcxyz", 1, 5)
  anyLeaf = map(pair(intIn(0, 6), pair(intIn(-4_000_000_000, 4_000_000_000), anyText)),
    proc(x: (int, (int, string))): JsonNode {.raises: [].} = leafOf(x))

proc jsonOfDepth(depth: int): Gen[JsonNode] =
  ## Null, numbers, strings, booleans, arrays and objects, nested `depth` deep.
  if depth == 0:
    return anyLeaf
  let inner = jsonOfDepth(depth - 1)
  let arrays = map(seqOf(inner, 0, 3),
    proc(items: seq[JsonNode]): JsonNode {.raises: [].} =
      result = newJArray()
      for item in items: result.add item)
  let objects = map(seqOf(pair(anyKey, inner), 0, 3),
    proc(members: seq[(string, JsonNode)]): JsonNode {.raises: [].} =
      result = newJObject()
      for (key, value) in members: result[key] = value)
  map(pair(intIn(0, 2), pair(anyLeaf, pair(arrays, objects))),
    proc(x: (int, (JsonNode, (JsonNode, JsonNode)))): JsonNode {.raises: [].} =
      case x[0]
      of 0: x[1][0]
      of 1: x[1][1][0]
      else: x[1][1][1])

# --- ids of a client's requests (MCP-TRANSPORT-4) -----------------------------------------------

const
  ClientMethods = ["tools/list", "resources/list", "prompts/list", "resources/templates/list", "ping",
                   "tools/call", "resources/read", "prompts/get", "completion/complete",
                   "logging/setLevel", "resources/subscribe", "x/custom"]
  Everything = """{"tools": {}, "resources": {"subscribe": true}, "prompts": {}, "logging": {}, "completions": {}}"""

proc requestsOf(peer: client_peer.Peer): seq[JsonNode] =
  for message in peer.received:
    if message.hasKey("id") and message.hasKey("method"):
      result.add message

proc answerExceptSilent(peer: client_peer.Peer, message: JsonNode) =
  if message.hasKey("id") and message.hasKey("method") and
     message{"params"}{"cursor"}.getStr() != "silent":
    peer.reply(message["id"], %*{"tools": [], "resources": [], "prompts": []})

type
  ClientSends = object
    version: McpProtocolVersion
    requests: seq[(int, int)]   ## the method, and how it is sent: plain, with a progress callback, or unanswered and timed out

let
  anyClientSends = map(
    pair(pick(SupportedProtocolVersions), seqOf(pair(intIn(0, ClientMethods.len - 1), intIn(0, 2)), 1, 8)),
    proc(x: (McpProtocolVersion, seq[(int, int)])): ClientSends {.raises: [].} =
      ClientSends(version: x[0], requests: x[1]))

suite "ids of the requests a client sends":

  test "Given any requests a client makes, however it sends them, when they are sent, then every id is a string, none is empty and none is used twice":
    # Space: one to eight requests of twelve methods, in any version, each sent plainly, with
    # a progress callback, or unanswered until its timeout.
    let outcome = propcheck.check(anyClientSends,
      guarded(proc(s: ClientSends): bool =
        let peer = startPeer(answerExceptSilent, modern = isModern(s.version),
                             capabilities = parseJson(Everything))
        let client = peer.connectedClient(s.version)
        for (index, how) in s.requests:
          let name = ClientMethods[index]
          case how
          of 0:
            discard waitFor client.sendRequest(name, newJObject())
          of 1:
            discard waitFor client.sendRequest(name, newJObject(),
              McpRequestOptions(onProgress: proc(update: McpProgress) = discard))
          else:
            try:
              discard waitFor client.sendRequest(name, %*{"cursor": "silent"},
                McpRequestOptions(timeoutMs: some(5)))
            except McpTimeoutError:
              discard         # asked, and nobody answered: the id was spent all the same
        var seen = initHashSet[string]()
        let requests = peer.requestsOf()
        for request in requests:
          if request["id"].kind != JString or request["id"].getStr().len == 0:
            return false
          if request["id"].getStr() in seen:
            return false
          seen.incl request["id"].getStr()
        seen.len == requests.len))
    checkpoint describe(outcome)
    check outcome.passed

# --- ids of a server's requests (MCP-TRANSPORT-4) -----------------------------------------------

type
  ServerSends = object
    version: McpProtocolVersion
    requests: seq[(int, JsonNode)]   ## the method of the server's own asking, and its params

const ServerMethods = ["ping", "sampling/createMessage", "elicitation/create", "roots/list", "x/custom"]

suite "requests of a server":

  test "Given any requests a server sends to a client, when they leave, then every id is a string, none is empty and none is used twice":
    # Space: one to six requests of five methods with params of any JSON, in every version that
    # lets a server ask.
    let versions = versionsWith(ftServerInitiatedRequests)
    if versions.len == 0:
      skip()
    else:
      let anyServerSends = map(
        pair(pick(versions), seqOf(pair(intIn(0, ServerMethods.len - 1), jsonOfDepth(1)), 1, 6)),
        proc(x: (McpProtocolVersion, seq[(int, JsonNode)])): ServerSends {.raises: [].} =
          ServerSends(version: x[0], requests: x[1]))
      let outcome = propcheck.check(anyServerSends,
        guarded(proc(s: ServerSends): bool =
          let server = newServer(McpServerCapabilities())
          let t = server.attach()
          let peer = server.connect(t, s.version)
          var ids = initHashSet[string]()
          for (index, params) in s.requests:
            let pending = server.request(peer.session, ServerMethods[index], params)
            let asked = t.messagesOf(ServerMethods[index])
            let id = asked[^1].message{"id"}
            if id.isNil or id.kind != JString or id.getStr().len == 0 or id.getStr() in ids:
              return false
            ids.incl id.getStr()
            t.inject(peer.session, %*{"jsonrpc": "2.0", "id": id, "result": {}})
            discard waitFor pending
          ids.len == s.requests.len))
      checkpoint describe(outcome)
      check outcome.passed

# --- a result of any shape (MCP-TRANSPORT-7) ------------------------------------------------------

suite "results of a server":

  test "Given any object of members of any JSON type as a handler's result, when a client of any version asks, then every member arrives with the value the handler gave":
    # Space: zero to four members, named by short words, each holding JSON of any type nested
    # up to two deep: null, integers, fractions, strings with escapes and non-ASCII text,
    # booleans, arrays and objects.
    let anyObject = pair(pick(SupportedProtocolVersions),
      map(seqOf(pair(anyKey, jsonOfDepth(2)), 0, 4),
        proc(members: seq[(string, JsonNode)]): JsonNode {.raises: [].} =
          result = newJObject()
          for (key, value) in members: result[key] = value))
    let outcome = propcheck.check(anyObject,
      guarded(proc(x: (McpProtocolVersion, JsonNode)): bool =
        let given = x[1]
        let server = newServer(McpServerCapabilities())
        server.registerRequestHandler("x/custom",
          proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
            return newJsonRpcResponse(request.id, given))
        let answer = server.connect(server.attach(), x[0]).ask("x/custom")
        if not answer.hasKey("result") or answer.hasKey("error"):
          return false
        for key, value in given:
          if answer["result"]{key} != value:
            return false
        true))
    checkpoint describe(outcome)
    check outcome.passed
