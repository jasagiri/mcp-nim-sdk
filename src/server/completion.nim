## `completion/complete`: suggestions for the argument of a prompt or of a
## resource template.

import std/[json, options, tables]
import ./errors
import ../protocol/completion as completionTypes

export completionTypes

const MaxCompletionValues* = 100
  ## What the specification allows in one result.

type
  McpCompletionRequest* = object
    reference*: McpCompletionRef
    argumentName*: string
    argumentValue*: string
      ## What the user has typed so far.
    resolved*: Table[string, string]
      ## The other arguments already filled in (`context.arguments`, from
      ## 2025-06-18).

proc requiredString(node: JsonNode, key, where: string): string {.raises: [McpRequestError].} =
  let value = if node.isNil or node.kind != JObject: nil else: node{key}
  if value.isNil or value.kind != JString:
    raise newInvalidParams(where & " requires a string " & key)
  value.getStr()

proc parseCompletionRequest*(params: JsonNode,
                             withContext: bool): McpCompletionRequest {.raises: [McpRequestError].} =
  ## `withContext` is whether the protocol version has `context`; an older
  ## client does not send it.
  let reference = if params.isNil or params.kind != JObject: nil else: params{"ref"}
  if reference.isNil or reference.kind != JObject:
    raise newInvalidParams("completion/complete requires a ref object")
  case requiredString(reference, "type", "ref")
  of "ref/prompt":
    result.reference = McpCompletionRef(kind: mcrPrompt,
      promptName: requiredString(reference, "name", "ref/prompt"))
  of "ref/resource":
    result.reference = McpCompletionRef(kind: mcrResourceTemplate,
      uriTemplate: requiredString(reference, "uri", "ref/resource"))
  else:
    raise newInvalidParams("ref.type must be ref/prompt or ref/resource")

  let argument = params{"argument"}
  if argument.isNil or argument.kind != JObject:
    raise newInvalidParams("completion/complete requires an argument object")
  result.argumentName = requiredString(argument, "name", "argument")
  result.argumentValue = requiredString(argument, "value", "argument")

  if withContext:
    let context = params{"context"}
    if not context.isNil:
      if context.kind != JObject:
        raise newInvalidParams("context must be an object")
      let arguments = context{"arguments"}
      if not arguments.isNil:
        if arguments.kind != JObject:
          raise newInvalidParams("context.arguments must be an object")
        for key, value in arguments.pairs:
          if value.kind != JString:
            raise newInvalidParams("context.arguments." & key & " must be a string")
          result.resolved[key] = value.getStr()

func toJson*(completion: McpCompletion): JsonNode {.raises: [].} =
  ## The `completion` object of the result. More than 100 values are cut to
  ## 100 and `hasMore` says so: the specification forbids a longer list.
  var values = completion.values
  var hasMore = completion.hasMore
  if values.len > MaxCompletionValues:
    values.setLen(MaxCompletionValues)
    hasMore = some(true)
  result = %*{"values": values}
  if completion.total.isSome:
    result["total"] = %completion.total.get
  if hasMore.isSome:
    result["hasMore"] = %hasMore.get
