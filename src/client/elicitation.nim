## Elicitation: a server asks the user for input through the client
## (elicitation/create, 2025-06-18 to 2025-11-25). The application shows the
## request and returns what the user did; this module declares the capability,
## checks both directions against the payload rules in `protocol/elicitation`,
## and does the wire work.

import std/[asyncdispatch, json, options, sets]
import ./client
import ../protocol/types
import ../protocol/elicitation

export elicitation

type
  McpElicitRequest* = object
    message*: string
    raw*: JsonNode
      ## The params as received, for fields this type does not model.
    case mode*: ElicitMode
    of emForm:
      requestedSchema*: JsonNode
    of emUrl:
      elicitationId*: string
        ## Opaque to the client; `notifications/elicitation/complete` names it.
      url*: string

  McpElicitationHandler* = proc(request: McpElicitRequest): Future[McpElicitResult] {.closure.}

proc parseElicitRequest(params: JsonNode): McpElicitRequest =
  ## `params` has passed `elicitationParamsProblems`.
  case elicitationModeOf(params)
  of emForm:
    McpElicitRequest(mode: emForm, message: params["message"].getStr(), raw: params,
                     requestedSchema: params["requestedSchema"])
  of emUrl:
    McpElicitRequest(mode: emUrl, message: params["message"].getStr(), raw: params,
                     elicitationId: params["elicitationId"].getStr(),
                     url: params["url"].getStr())

proc setElicitationHandler*(client: McpClient, handler: McpElicitationHandler,
                            modes: set[ElicitMode] = {emForm},
                            onComplete: proc(elicitationId: string) {.closure.} = nil) =
  ## Declare the elicitation capability for `modes` and answer
  ## elicitation/create from `handler`. A request in a mode that was not
  ## declared, or that breaks the payload rules, is answered with invalid
  ## params; an answer of `handler` that does not match the request is the
  ## handler's defect and the server is told "Internal error". To refuse,
  ## raise McpRequestError, or answer with the action decline or cancel.
  ## The url mode (2025-11-25) opens a page for the user: the handler must
  ## show the host and get consent first, and accept means the user agreed,
  ## not that the interaction is done. `onComplete` runs when the server
  ## says (notifications/elicitation/complete) that the interaction of an
  ## accepted URL request is over; notifications for other ids are ignored.
  ## Call before connect().
  client.requireNotConnected("the elicitation handler")
  client.capabilities.elicitation = some(McpElicitationCapability(
    form: emForm in modes, url: emUrl in modes))
  var awaitingCompletion = initHashSet[string]()
  client.registerRequestHandler("elicitation/create",
    proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
      let problems = elicitationParamsProblems(request.params, client.negotiatedVersion.get)
      if problems.len > 0:
        return newJsonRpcErrorResponse(request.id, -32602,
          "elicitation/create: " & problems[0])
      let parsed = parseElicitRequest(request.params)
      if parsed.mode notin modes:
        return newJsonRpcErrorResponse(request.id, -32602,
          "elicitation/create: this client did not declare the " & $parsed.mode & " mode")
      let answer = elicitationResultJson(await handler(parsed))
      let faults = elicitationResultProblems(answer, request.params)
      if faults.len > 0:
        stderr.writeLine("[mcp-client] the elicitation handler's answer was not sent: " & faults[0])
        return newJsonRpcErrorResponse(request.id, -32603,
          "the elicitation handler answered with something that does not match the request")
      if parsed.mode == emUrl and answer{"action"}.getStr() == "accept":
        awaitingCompletion.incl parsed.elicitationId
      return newJsonRpcResponse(request.id, answer))
  if emUrl in modes:
    client.registerNotificationHandler("notifications/elicitation/complete",
      proc(notification: JsonRpcNotification): Future[void] {.async.} =
        let id = notification.params{"elicitationId"}
        if id.isNil or id.kind != JString or id.getStr() notin awaitingCompletion:
          return
        awaitingCompletion.excl id.getStr()
        if not onComplete.isNil:
          onComplete(id.getStr()))

proc urlElicitationsRequired*(client: McpClient,
                              error: ref McpRequestError): Option[seq[McpElicitRequest]] =
  ## The URL mode requests a -32042 error asks the user to do before the
  ## failed request is retried; none for any other error. Raises
  ## McpProtocolError when the data does not have the specified shape in the
  ## version this client speaks.
  if error.code != UrlElicitationRequiredCode:
    return none(seq[McpElicitRequest])
  let problems = urlElicitationRequiredProblems(error.data, client.negotiatedVersion.get)
  if problems.len > 0:
    raise newException(McpProtocolError, "the URL elicitation required error: " & problems[0])
  var required: seq[McpElicitRequest]
  for entry in error.data["elicitations"]:
    required.add parseElicitRequest(entry)
  some(required)
