## Multi Round-Trip Requests (2026-07-28, basic/patterns/mrtr): a server that
## needs more from the client answers `tools/call`, `prompts/get` or
## `resources/read` with `resultType: "input_required"` and the requests it
## needs answered; the client retries the same request with `inputResponses`
## and the server's opaque `requestState`.
##
## Pure functions over JSON, shared by the server and the client. The
## payloads of the individual requests (elicitation, sampling, roots) are
## passed through as JSON.

import std/[json, options, tables]
import ./types

const
  MrtrMethods* = ["tools/call", "prompts/get", "resources/read"]
    ## The only requests a server may answer with `input_required`.

  ElicitationMethod* = "elicitation/create"
  SamplingMethod* = "sampling/createMessage"
  RootsMethod* = "roots/list"
  InputRequestMethods* = [ElicitationMethod, SamplingMethod, RootsMethod]

  ErrInvalidParams = -32602

type
  InputRequestSpec* = tuple[key, methodName: string, params: JsonNode]
    ## One request of an `inputRequests` map.

  InputRequired* = object
    ## A parsed `InputRequiredResult`.
    inputRequests*: JsonNode
      ## Key -> request object; nil when the result carries none.
    requestState*: Option[string]

func supportsInputRequired*(methodName: string): bool {.raises: [].} =
  methodName in MrtrMethods

func capabilityFor*(inputMethod: string): string {.raises: [].} =
  ## The client capability a request of `inputRequests` needs; empty for a
  ## method that is not an input request.
  case inputMethod
  of ElicitationMethod: "elicitation"
  of SamplingMethod: "sampling"
  of RootsMethod: "roots"
  else: ""

func requestsToJson*(requests: openArray[InputRequestSpec]): JsonNode {.raises: [].} =
  ## The `inputRequests` object of `requests`.
  result = newJObject()
  for request in requests:
    result[request.key] = %*{"method": request.methodName,
                             "params": if request.params.isNil: newJObject() else: request.params}

func validateInputRequests*(requests: JsonNode): Option[string] {.raises: [].} =
  ## Why `requests` is not an `InputRequests` map, or none when it is.
  if requests.kind != JObject:
    return some("inputRequests must be an object")
  for key, request in requests.pairs:
    if request.kind != JObject:
      return some("inputRequests[\"" & key & "\"] must be an object")
    let methodNode = request{"method"}
    if methodNode.isNil or methodNode.kind != JString or
       methodNode.getStr() notin InputRequestMethods:
      return some("inputRequests[\"" & key & "\"].method must be one of " &
                  ElicitationMethod & ", " & SamplingMethod & ", " & RootsMethod)
    let params = request{"params"}
    if not params.isNil and params.kind != JObject:
      return some("inputRequests[\"" & key & "\"].params must be an object")
  none(string)

func inputRequiredPayload*(requests: JsonNode,
                           requestState: Option[string]): JsonNode {.raises: [].} =
  ## The result object of an `InputRequiredResult`; `requests` may be nil.
  result = %*{"resultType": "input_required"}
  if not requests.isNil:
    result["inputRequests"] = requests
  if requestState.isSome:
    result["requestState"] = %requestState.get

func invalidInputRequired*(requests: JsonNode,
                           requestState: Option[string]): Option[string] {.raises: [].} =
  ## Why these parts do not make an `InputRequiredResult`: at least one of
  ## the two must be present and the requests must be well formed.
  if (requests.isNil or requests.len == 0) and requestState.isNone:
    return some("an input_required result needs inputRequests or requestState")
  if not requests.isNil:
    return validateInputRequests(requests)
  none(string)

func parseInputRequired*(resultNode: JsonNode): tuple[parsed: InputRequired,
                                                       problem: Option[string]] {.raises: [].} =
  ## The `InputRequiredResult` in `resultNode`, or why it is not one.
  let requests = resultNode{"inputRequests"}
  let state = resultNode{"requestState"}
  if not state.isNil and state.kind != JString:
    return (InputRequired(), some("requestState must be a string"))
  if not requests.isNil and requests.kind != JNull:
    result.parsed.inputRequests = requests
  if not state.isNil:
    result.parsed.requestState = some(state.getStr())
  result.problem = invalidInputRequired(result.parsed.inputRequests,
                                        result.parsed.requestState)

func missingCapabilities*(requests: JsonNode, clientCapabilities: JsonNode): JsonNode {.raises: [].} =
  ## The capabilities `requests` need that `clientCapabilities` (an object,
  ## or nil) does not declare, as the `requiredCapabilities` of the
  ## missing-capability error; an empty object when all are declared.
  result = newJObject()
  if requests.isNil or requests.kind != JObject:
    return
  for _, request in requests.pairs:
    let needed = capabilityFor(request{"method"}.getStr())
    if needed.len == 0:
      continue
    let declaredNode =
      if clientCapabilities.isNil or clientCapabilities.kind != JObject: nil
      else: clientCapabilities{needed}
    if declaredNode.isNil or declaredNode.kind != JObject:
      result[needed] = newJObject()

func inputResponsesOf*(params: JsonNode): JsonNode {.raises: [].} =
  ## The `inputResponses` object of a request, empty when it carries none or
  ## carries something that is not an object (`rejectInvalidInputParams`
  ## reports that).
  if params.isNil or params.kind != JObject:
    return newJObject()
  let node = params{"inputResponses"}
  if node.isNil or node.kind != JObject: newJObject() else: node

func requestStateOf*(params: JsonNode): Option[string] {.raises: [].} =
  if params.isNil or params.kind != JObject:
    return none(string)
  let node = params{"requestState"}
  if node.isNil or node.kind != JString: none(string) else: some(node.getStr())

func rejectInvalidInputParams*(params: JsonNode): Option[JsonRpcError] {.raises: [].} =
  ## The invalid-params error for `inputResponses` or `requestState` of a
  ## request that are not the types the specification gives. Keys the server
  ## did not ask for are not an error: it ignores them.
  if params.isNil or params.kind != JObject:
    return none(JsonRpcError)
  let responses = params{"inputResponses"}
  if not responses.isNil:
    if responses.kind != JObject:
      return some(JsonRpcError(code: ErrInvalidParams,
        message: "inputResponses must be an object"))
    for key, response in responses.pairs:
      if response.kind != JObject:
        return some(JsonRpcError(code: ErrInvalidParams,
          message: "inputResponses[\"" & key & "\"] must be an object"))
  let state = params{"requestState"}
  if not state.isNil and state.kind != JString:
    return some(JsonRpcError(code: ErrInvalidParams,
      message: "requestState must be a string"))
  none(JsonRpcError)

func retryParams*(original, inputResponses: JsonNode,
                  requestState: Option[string]): JsonNode {.raises: [].} =
  ## The params of the retry of a request that was answered with
  ## `input_required`: the original params with the responses, and the
  ## server's state echoed exactly. A state the server did not send is not
  ## included. The original is not changed.
  result =
    if original.isNil or original.kind != JObject: newJObject()
    else: original.copy()
  for key in ["inputResponses", "requestState"]:
    result.fields.del(key)
  if not inputResponses.isNil and inputResponses.len > 0:
    result["inputResponses"] = inputResponses
  if requestState.isSome:
    result["requestState"] = %requestState.get
