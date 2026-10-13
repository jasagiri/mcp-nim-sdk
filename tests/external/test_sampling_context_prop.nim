## includeContext of a sampling request, said as properties: thisServer and
## allServers go only to a client that declared sampling.context; none, or no
## includeContext at all, go to any client that declared sampling.

import std/[unittest, asyncdispatch, json, options]
import propcheck
import ./server_harness
import server/mrtr

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

let Hello = %*{"type": "text", "text": "hello"}

type
  Ask = object
    version: McpProtocolVersion
    include0: string    ## "" is includeContext left out
    declaresContext: bool
    declaresTools: bool

proc anyAsk(versions: seq[McpProtocolVersion]): Gen[Ask] =
  # Space: a version from 2025-11-25 on, includeContext left out or none or thisServer or
  # allServers, and a client that declared sampling with or without context, with or without tools.
  map(pair(pair(pick(versions), pick(["", "none", "thisServer", "allServers"])), pair(boolean(), boolean())),
    proc(x: ((McpProtocolVersion, string), (bool, bool))): Ask {.raises: [].} =
      Ask(version: x[0][0], include0: x[0][1], declaresContext: x[1][0], declaresTools: x[1][1]))

proc clientDeclares(a: Ask): JsonNode =
  var sampling = newJObject()
  if a.declaresContext: sampling["context"] = newJObject()
  if a.declaresTools: sampling["tools"] = newJObject()
  %*{"sampling": sampling}

proc params(a: Ask): JsonNode =
  result = %*{"messages": [{"role": "user", "content": Hello}], "maxTokens": 10}
  if a.include0 != "":
    result["includeContext"] = %a.include0

proc mayBeSent(a: Ask): bool =
  ## The rule: thisServer and allServers need the client to have declared sampling.context.
  a.include0 in ["", "none"] or a.declaresContext

suite "includeContext needs sampling.context":

  test "Given any client that declared sampling and any includeContext, when the server asks, then it raises and sends nothing if the context is asked for without sampling.context, and otherwise the request is sent":
    var versions: seq[McpProtocolVersion]
    for v in versionsWith(ftSamplingTools):
      if v.has(ftServerInitiatedRequests):
        versions.add v
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyAsk(versions),
        guarded(proc(a: Ask): bool =
          let server = newServer(McpServerCapabilities())
          let t = server.attach()
          discard server.connect(t, a.version, session = "s", clientCapabilities = a.clientDeclares)
          let pending = server.createMessage("s", a.params)
          settle()
          if a.mayBeSent:
            t.messagesOf("sampling/createMessage").len == 1 and not pending.failed
          else:
            pending.failed and t.messagesOf("sampling/createMessage").len == 0))
      checkpoint describe(outcome)
      check outcome.passed

  test "Given any client that declared sampling and any includeContext a handler asks with, when the tool is called, then the answer is an error and not input_required if the context is asked for without sampling.context, and otherwise it is input_required":
    let versions = versionsWith(ftMultiRoundTripRequests)
    if versions.len == 0:
      skip()
    else:
      let outcome = propcheck.check(anyAsk(versions),
        guarded(proc(a: Ask): bool =
          let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
          server.onToolCall(proc(ctx: McpRequestContext, name: string,
                                 arguments: JsonNode): Future[JsonNode] {.async.} =
            discard ctx.requireInput("ask", "sampling/createMessage", a.params)
            return %*{"content": []})
          let reply = server.connect(server.attach(), a.version).ask("tools/call", %*{"name": "t"},
            meta = %*{"io.modelcontextprotocol/clientCapabilities": a.clientDeclares})
          if a.mayBeSent:
            reply.hasKey("result") and reply["result"]{"resultType"}.getStr() == "input_required"
          else:
            reply.hasKey("error") and not reply.hasKey("result")))
      checkpoint describe(outcome)
      check outcome.passed
