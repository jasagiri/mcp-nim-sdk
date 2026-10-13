## The rules of what a server's handler may hand to a client, said as
## properties over every value the rule speaks of: the images and embedded
## resources of a prompt, the blob of a resource, the arguments of a prompt,
## and a resource handler that raises. Values are made as correct or as
## incorrect on purpose, so the verdict never depends on how the server
## checks them.

import std/[unittest, asyncdispatch, json, options, strutils, base64]
import propcheck
import ./server_harness


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

# --- inputs ----------------------------------------------------------------

type
  Bytes = seq[int]

proc binary(bytes: Bytes): string =
  for b in bytes:
    result.add char(b)

let
  anyBytes = seqOf(intIn(0, 255), 0, 12)
  anyVersion = pick(SupportedProtocolVersions)
  label = stringOf("abcdefghij", 1, 6)

proc validBase64(bytes: Bytes): string =
  ## RFC 4648 base64, padded: what encoding bytes gives.
  encode(binary(bytes))

const NotInTheAlphabet = "!@#$%^&*()-_.,:;<>?[]{}|~`\"'\\"

type
  BadBase64 = object
    shape: int      ## 0: a character outside the alphabet, 1: padding before more data, 2: one character too many
    bytes: Bytes
    more: Bytes
    at: int
    stray: int

let
  anyBadBase64 = map(
    pair(pair(intIn(0, 2), anyBytes), pair(pair(seqOf(intIn(0, 255), 1, 6), intIn(0, 40)), intIn(0, NotInTheAlphabet.len - 1))),
    proc(x: ((int, Bytes), ((Bytes, int), int))): BadBase64 {.raises: [].} =
      BadBase64(shape: x[0][0], bytes: x[0][1], more: x[1][0][0], at: x[1][0][1], stray: x[1][1]))

proc render(bad: BadBase64): string =
  ## A string that is not base64, however it is read.
  case bad.shape
  of 0:
    let good = validBase64(bad.bytes)
    let at = bad.at mod (good.len + 1)
    good[0 ..< at] & NotInTheAlphabet[bad.stray] & good[at .. ^1]
  of 1:
    # a group that ends in padding, with more after it
    validBase64(@[65]) & validBase64(bad.more)
  else:
    # a whole number of groups and one character: no byte count gives that
    validBase64(bad.bytes) & "A"

proc isError(reply: JsonNode, code: int): bool =
  reply.hasKey("error") and reply.errorCode == code

proc promptServer(message: JsonNode): McpServer =
  result = newServer(McpServerCapabilities(
    prompts: some(McpPromptsCapability()), resources: some(McpResourcesCapability())))
  result.onPromptGet(proc(ctx: McpRequestContext, name: string,
                          arguments: JsonNode): Future[JsonNode] {.async.} =
    return %*{"messages": [{"role": "user", "content": message}]})
  result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    return @[message])

proc gotPrompt(message: JsonNode, v: McpProtocolVersion): JsonNode =
  let server = promptServer(message)
  server.connect(server.attach(), v).ask("prompts/get", %*{"name": "p"})

proc readResource(contents: JsonNode, v: McpProtocolVersion): JsonNode =
  let server = promptServer(contents)
  server.connect(server.attach(), v).ask("resources/read", %*{"uri": "file:///b"})

proc sentAsGiven(reply: JsonNode, given: JsonNode, path: openArray[string]): bool =
  if not reply.hasKey("result"): return false
  var at = reply["result"]
  for step in path:
    at = if step.len > 0 and step[0] in {'0' .. '9'}: at[parseInt(step)] else: at{step}
    if at.isNil: return false
  at == given

# --- a resource handler that raises (MCP-RESOURCES-15) ------------------------

type
  Failure = object
    version: McpProtocolVersion
    onRead: bool        ## resources/read, else resources/list
    kind: int           ## which exception type the handler raises
    cause: string       ## what it says

const FailureKinds = ["ValueError", "IOError", "OSError", "KeyError", "CatchableError", "EOFError"]

proc raiseKind(kind: int, cause: string) {.raises: [CatchableError].} =
  case kind
  of 0: raise newException(ValueError, cause)
  of 1: raise newException(IOError, cause)
  of 2: raise newException(OSError, cause)
  of 3: raise newException(KeyError, cause)
  of 4: raise newException(CatchableError, cause)
  else: raise newException(EOFError, cause)

let anyFailure = map(
  pair(pair(anyVersion, boolean()), pair(intIn(0, FailureKinds.len - 1), stringOf("abc XYZ019:/", 0, 24))),
  proc(x: ((McpProtocolVersion, bool), (int, string))): Failure {.raises: [].} =
    Failure(version: x[0][0], onRead: x[0][1], kind: x[1][0], cause: "cause<" & x[1][1] & ">"))

suite "a resource handler that raises, whatever it raises (every version)":

  test "Given any exception a resources/list or resources/read handler raises, when a client lists or reads, then the answer is -32603, carries no result and does not name the cause":
    # Space: the version, list or read, the exception type, and any message the handler writes.
    let outcome = propcheck.check(anyFailure,
      guarded(proc(f: Failure): bool =
        let server = newServer(McpServerCapabilities(resources: some(McpResourcesCapability())))
        server.onResourcesList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
          raiseKind(f.kind, f.cause))
        server.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
          raiseKind(f.kind, f.cause))
        let peer = server.connect(server.attach(), f.version)
        let reply = if f.onRead: peer.ask("resources/read", %*{"uri": "file:///a"})
                    else: peer.ask("resources/list")
        reply.isError(-32603) and not reply.hasKey("result") and
          f.cause notin $reply and FailureKinds[f.kind] notin $reply))
    checkpoint describe(outcome)
    check outcome.passed

# --- an image of a prompt (MCP-CONTENT-FIELDS-13) ---------------------------------

type
  Image = object
    version: McpProtocolVersion
    block0: JsonNode
    wellFormed: bool    ## made as a correct image, or as an incorrect one

let
  anyImage = map(
    pair(pair(anyVersion, intIn(0, 4)),
         pair(pair(anyBytes, anyBadBase64), pair(label, intIn(0, 99)))),
    proc(x: ((McpProtocolVersion, int), ((Bytes, BadBase64), (string, int)))): Image {.raises: [].} =
      let good = validBase64(x[1][0][0])
      let mime = "image/" & x[1][1][0]
      let bad = render(x[1][0][1])
      var node: JsonNode
      var ok = false
      case x[0][1]
      of 0:                     # base64 with a mimeType
        node = %*{"type": "image", "data": good, "mimeType": mime}; ok = true
      of 1:                     # data that is not base64
        node = %*{"type": "image", "data": bad, "mimeType": mime}
      of 2:                     # no mimeType
        node = %*{"type": "image", "data": good}
      of 3:                     # data that is not a string
        node = %*{"type": "image", "data": x[1][1][1], "mimeType": mime}
      else:                     # no data
        node = %*{"type": "image", "mimeType": mime}
      Image(version: x[0][0], block0: node, wellFormed: ok))

suite "the image of a prompt, whatever it holds (every version)":

  test "Given any image block a prompt handler returns, when a client sends prompts/get, then it is sent as given if it is base64 with a mimeType and is an internal error otherwise":
    # Space: images made correct (base64 data and a mimeType) and incorrect (data that is
    # not base64 in three shapes, data that is not a string, no data, no mimeType).
    let outcome = propcheck.check(anyImage,
      guarded(proc(i: Image): bool =
        let reply = gotPrompt(i.block0, i.version)
        if i.wellFormed: reply.sentAsGiven(i.block0, ["messages", "0", "content"])
        else: reply.isError(-32603) and not reply.hasKey("result")))
    checkpoint describe(outcome)
    check outcome.passed

# --- an embedded resource of a prompt (MCP-CONTENT-FIELDS-14) --------------------------

type
  Embedded = object
    version: McpProtocolVersion
    block0: JsonNode
    wellFormed: bool

let
  anyEmbedded = map(
    pair(pair(anyVersion, intIn(0, 5)),
         pair(pair(anyBytes, stringOf("abc /:", 0, 10)), pair(label, label))),
    proc(x: ((McpProtocolVersion, int), ((Bytes, string), (string, string)))): Embedded {.raises: [].} =
      let uri = "file:///" & x[1][1][0]
      let mime = "text/" & x[1][1][1]
      let text = x[1][0][1]
      let blob = validBase64(x[1][0][0])
      var resource: JsonNode
      var ok = false
      case x[0][1]
      of 0: resource = %*{"uri": uri, "mimeType": mime, "text": text}; ok = true
      of 1: resource = %*{"uri": uri, "mimeType": mime, "blob": blob}; ok = true
      of 2: resource = %*{"mimeType": mime, "text": text}                 # no uri
      of 3: resource = %*{"uri": uri, "text": text}                       # no mimeType
      of 4: resource = %*{"uri": uri, "mimeType": mime}                   # neither text nor blob
      else: resource = %*{"mimeType": mime, "blob": blob}                 # no uri, with a blob
      Embedded(version: x[0][0], block0: %*{"type": "resource", "resource": resource}, wellFormed: ok))

suite "the embedded resource of a prompt, whatever it holds (every version)":

  test "Given any embedded resource a prompt handler returns, when a client sends prompts/get, then it is sent as given if it has a uri, a mimeType and text or blob and is an internal error otherwise":
    # Space: embedded resources with text or with a blob, and with the uri, the mimeType or both
    # the text and the blob left out.
    let outcome = propcheck.check(anyEmbedded,
      guarded(proc(e: Embedded): bool =
        let reply = gotPrompt(e.block0, e.version)
        if e.wellFormed: reply.sentAsGiven(e.block0, ["messages", "0", "content"])
        else: reply.isError(-32603) and not reply.hasKey("result")))
    checkpoint describe(outcome)
    check outcome.passed

# --- the blob of a resource (MCP-RESOURCES-17) ----------------------------------------

type
  Contents = object
    version: McpProtocolVersion
    node: JsonNode
    wellFormed: bool

let
  anyContents = map(
    pair(pair(anyVersion, intIn(0, 3)),
         pair(pair(anyBytes, anyBadBase64), label)),
    proc(x: ((McpProtocolVersion, int), ((Bytes, BadBase64), string))): Contents {.raises: [].} =
      let uri = "file:///b"
      let mime = "image/" & x[1][1]
      var node: JsonNode
      var ok = false
      case x[0][1]
      of 0: node = %*{"uri": uri, "mimeType": mime, "blob": validBase64(x[1][0][0])}; ok = true
      of 1: node = %*{"uri": uri, "mimeType": "text/plain", "text": x[1][1]}; ok = true
      of 2: node = %*{"uri": uri, "mimeType": mime, "blob": render(x[1][0][1])}
      else: node = %*{"uri": uri, "mimeType": mime, "blob": x[1][0][0].len}    # a number
      Contents(version: x[0][0], node: node, wellFormed: ok))

suite "the blob of a resource, whatever it holds (every version)":

  test "Given any contents a resource handler returns, when a client sends resources/read, then they are sent as given if a blob is base64 and the read is an internal error otherwise":
    # Space: contents with a base64 blob of any bytes, with text, and with a blob that is not
    # base64 (three shapes) or not a string.
    let outcome = propcheck.check(anyContents,
      guarded(proc(c: Contents): bool =
        let reply = readResource(c.node, c.version)
        if c.wellFormed: reply.sentAsGiven(c.node, ["contents", "0"])
        else: reply.isError(-32603) and not reply.hasKey("result")))
    checkpoint describe(outcome)
    check outcome.passed

# --- the arguments of a prompt (MCP-PROMPTS-6) ----------------------------------------

type
  ListedArgument = object
    name: string
    required: bool
    supplied: bool
    value: string
  PromptCall = object
    version: McpProtocolVersion
    listed: seq[ListedArgument]
    omitted: bool       ## the call has no "arguments" member at all

let
  anyPromptCall = map(
    pair(pair(anyVersion, boolean()),
         seqOf(pair(pair(boolean(), boolean()), stringOf("abcxyz", 0, 5)), 0, 4)),
    proc(x: ((McpProtocolVersion, bool), seq[((bool, bool), string)])): PromptCall {.raises: [].} =
      var listed: seq[ListedArgument]
      for i, a in x[1]:
        listed.add ListedArgument(name: "arg" & $i, required: a[0][0], supplied: a[0][1], value: a[1])
      PromptCall(version: x[0][0], listed: listed, omitted: x[0][1]))

suite "the arguments of a prompt (every version)":

  test "Given any prompt that lists arguments, when it is got with any of them left out, then the handler runs exactly when no required argument is missing":
    # Space: a prompt of up to four listed arguments, each required or optional, a call that
    # supplies any of them with any string value, with the "arguments" member given or left out
    # when nothing is supplied.
    let outcome = propcheck.check(anyPromptCall,
      guarded(proc(c: PromptCall): bool =
        var ran = 0
        var seen = newJObject()
        let server = newServer(McpServerCapabilities(prompts: some(McpPromptsCapability())))
        var arguments = newJArray()
        for a in c.listed:
          arguments.add %*{"name": a.name, "required": a.required}
        server.onPromptsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
          return McpPage(items: @[%*{"name": "greet", "arguments": arguments}]))
        server.onPromptGet(proc(ctx: McpRequestContext, name: string,
                                arguments: JsonNode): Future[JsonNode] {.async.} =
          inc ran
          seen = if arguments.isNil: newJObject() else: arguments
          return %*{"messages": []})
        var given = newJObject()
        var missing = false
        for a in c.listed:
          if a.supplied: given[a.name] = %a.value
          elif a.required: missing = true
        var params = %*{"name": "greet"}
        if not (c.omitted and given.len == 0):
          params["arguments"] = given
        let reply = server.connect(server.attach(), c.version).ask("prompts/get", params)
        if missing:
          reply.isError(-32602) and ran == 0
        else:
          reply.hasKey("result") and ran == 1 and (given.len == 0 or seen == given)))
    checkpoint describe(outcome)
    check outcome.passed
