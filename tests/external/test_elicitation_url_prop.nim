## The url of a URL elicitation, said as a property over strings made as URLs
## and as non-URLs on purpose: a URL is sent as given, anything else makes the
## server raise (before 2026-07-28) or answer an internal error (from it),
## and nothing is sent to the client.

import std/[unittest, asyncdispatch, json, options, strutils]
import server/elicit
import server/mrtr
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

let
  BothModes = %*{"elicitation": {"form": {}, "url": {}}}
  Id = "550e8400-e29b-41d4-a716-446655440000"

proc askingVersions(feature: McpFeature): seq[McpProtocolVersion] =
  ## The versions in which the server asks the client itself, and that have `feature`.
  for v in versionsWith(feature):
    if v.has(ftServerInitiatedRequests):
      result.add v

proc awaitRequest(t: SessionedTransport, methodName: string, session = ""): Sent =
  untilTrue("the server's " & methodName, proc(): bool =
    for s in t.messagesOf(methodName):
      if s.session == session:
        return true
    false)
  for s in t.messagesOf(methodName):
    if s.session == session:
      return s

proc caps(capabilities: JsonNode): JsonNode =
  %*{"io.modelcontextprotocol/clientCapabilities": capabilities}

proc urlServer(): McpServer =
  ## A tool that needs the user to visit the url it is given.
  result = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
  result.onToolCall(proc(ctx: McpRequestContext, name: string,
                         arguments: JsonNode): Future[JsonNode] {.async.} =
    discard ctx.requireInput("visit", "elicitation/create",
      %*{"mode": "url", "message": "Provide your key", "elicitationId": Id,
         "url": arguments["url"].getStr()})
    return %*{"content": []})

# --- the strings -------------------------------------------------------------------

type
  Link = object
    version: McpProtocolVersion
    text: string
    isUrl: bool       ## made as a URL (RFC 3986: a scheme, a colon, the rest), or as something that is not one

const
  Letters = "abcdefghijklmnopqrstuvwxyz"
  SchemeRest = "abcdefghijklmnopqrstuvwxyz0123456789+-."
  PathChars = "abcdefghijklmnopqrstuvwxyz0123456789-._~/"

let
  scheme = map(pair(stringOf(Letters, 1, 1), stringOf(SchemeRest, 0, 6)),
    proc(x: (string, string)): string {.raises: [].} = x[0] & x[1])
  anyLinkText = map(
    pair(pair(intIn(0, 6), scheme),
         pair(stringOf(Letters, 1, 8), pair(stringOf(PathChars, 0, 10), stringOf("!@# _*()", 1, 3)))),
    proc(x: ((int, string), (string, (string, string)))): (string, bool) {.raises: [].} =
      let (shape, sch) = x[0]
      let (host, (path, odd)) = x[1]
      case shape
      of 0: (sch & "://" & host & "/" & path, true)
      of 1: (sch & ":" & host & path, true)                  # a URI with no authority
      of 2: ("", false)                                       # empty
      of 3: (host & " " & path.strip(chars = {'/'}) & odd, false)   # no colon at all: no scheme
      of 4: ($host.len & sch & "://" & host, false)           # a scheme that starts with a digit
      of 5: (sch & odd & ":" & host, false)                   # a character a scheme cannot hold, before the colon
      else: ("://" & host, false))                            # the scheme left out

suite "the url of a URL elicitation sent before 2026-07-28":

  test "Given any string, when the server asks in url mode, then it raises and sends nothing if it is not a URL and the request carries it as given if it is":
    # Space: URLs with an authority and without, and strings that are not: empty, without a
    # scheme, with a scheme that starts with a digit, with a character a scheme cannot
    # hold, and with the scheme left out.
    let versions = askingVersions(ftUrlElicitation)
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(map(pair(pick(versions), anyLinkText),
          proc(x: (McpProtocolVersion, (string, bool))): Link {.raises: [].} =
            Link(version: x[0], text: x[1][0], isUrl: x[1][1])),
        guarded(proc(l: Link): bool =
          let server = newServer(McpServerCapabilities())
          let t = server.attach()
          discard server.connect(t, l.version, clientCapabilities = BothModes)
          if l.isUrl:
            let pending = server.elicitUrl("", "Provide your key", Id, l.text)
            let asked = t.awaitRequest("elicitation/create")
            t.inject("", %*{"jsonrpc": "2.0", "id": asked.message["id"], "result": {"action": "decline"}})
            discard waitFor pending
            asked.message["params"]["url"].getStr() == l.text
          else:
            let pending = server.elicitUrl("", "Provide your key", Id, l.text)
            settle()
            if not pending.finished:
              return false          # the server is waiting for an answer: it asked
            var raised = false
            try:
              discard waitFor pending
            except McpPayloadError:
              raised = true
            raised and t.messagesOf("elicitation/create").len == 0))
      checkpoint describe(outcome)
      check outcome.passed

suite "the url of a URL elicitation asked for from 2026-07-28":

  test "Given any string a tool handler gives as the url, when the tool is called, then it is an internal error and nothing is asked if it is not a URL, and the answer asks for it as given if it is":
    # Space: the same strings as above, in every version that has input requests.
    let versions = versionsWith(ftMultiRoundTripRequests)
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(map(pair(pick(versions), anyLinkText),
          proc(x: (McpProtocolVersion, (string, bool))): Link {.raises: [].} =
            Link(version: x[0], text: x[1][0], isUrl: x[1][1])),
        guarded(proc(l: Link): bool =
          let server = urlServer()
          let peer = server.connect(server.attach(), l.version)
          let reply = peer.ask("tools/call", %*{"name": "visit", "arguments": {"url": l.text}},
                               meta = caps(BothModes))
          if l.isUrl:
            reply.hasKey("result") and reply["result"]{"resultType"}.getStr() == "input_required" and
              reply["result"]["inputRequests"]["visit"]["params"]["url"].getStr() == l.text
          else:
            reply.hasKey("error") and reply.errorCode == -32603 and not reply.hasKey("result")))
      checkpoint describe(outcome)
      check outcome.passed
