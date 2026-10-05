## Multi round-trip requests on the server (2026-07-28): a handler of
## `tools/call`, `prompts/get` or `resources/read` that needs the client's
## input asks for it and finishes when the client retries with the answers.
##
## Nothing is kept between the attempts: the handler is called again from
## the start with `ctx.inputResponses` and `ctx.requestState` filled in, so
## it asks for what is still missing and carries anything it needs to
## remember in the `requestState` it returns (see `server/request_state`
## for sealing it).
##
##   let login = ctx.requireInput("github_login", "elicitation/create", %*{
##     "message": "Please provide your GitHub username",
##     "requestedSchema": {"type": "object", "properties": {"name": {"type": "string"}}}})
##   # reached only on the retry; `login` is the client's ElicitResult
##
## The request is checked against what the client declared: asking for
## something it did not declare is answered with the missing-capability
## error, not sent.

import std/[json, options, tables]
import ./server
import ../protocol/mrtr

export mrtr

func newInputRequired*(requests: openArray[InputRequestSpec] = [],
                       requestState = none(string)): ref McpInputRequired =
  ## The exception that makes the server answer `input_required`. At least
  ## one request or a state is needed; a handler that raises it with neither
  ## is a defect.
  result = (ref McpInputRequired)(msg: "input required", requestState: requestState)
  if requests.len > 0:
    result.inputRequests = requestsToJson(requests)

proc inputResponse*(ctx: McpRequestContext, key: string): Option[JsonNode] =
  ## The client's answer to the request the server named `key`, when this
  ## is a retry that carries it.
  if ctx.inputResponses.isNil:
    return none(JsonNode)
  let response = ctx.inputResponses{key}
  if response.isNil: none(JsonNode) else: some(response)

proc requireInputs*(ctx: McpRequestContext, requests: openArray[InputRequestSpec],
                    requestState = none(string)): Table[string, JsonNode] =
  ## The client's answers to all of `requests`. When some are missing this
  ## raises `McpInputRequired` for those only, so the handler stops there and
  ## the client is asked again, as the specification asks.
  var missing: seq[InputRequestSpec]
  for request in requests:
    let answer = ctx.inputResponse(request.key)
    if answer.isSome:
      result[request.key] = answer.get
    else:
      missing.add request
  if missing.len > 0:
    raise newInputRequired(missing, requestState)

proc requireInput*(ctx: McpRequestContext, key, methodName: string, params: JsonNode,
                   requestState = none(string)): JsonNode =
  ## The client's answer to one request; raises `McpInputRequired` when it
  ## is not there yet. `methodName` is `elicitation/create`,
  ## `sampling/createMessage` or `roots/list`.
  ctx.requireInputs([(key: key, methodName: methodName, params: params)],
                    requestState)[key]
