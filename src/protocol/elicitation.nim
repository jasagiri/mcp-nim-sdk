## The payloads of elicitation/create (2025-06-18 onward): the restricted
## schema a form may ask for, the request, and the check of a response.
##
## Everything here takes and returns JSON and knows nothing of how it
## travels, so a request of the server (before 2026-07-28) and an input
## request (2026-07-28) share it. A check returns the problems it found; the
## `...Params` builders and `parseElicitationResult` raise `McpPayloadError`
## instead, because their caller has nothing to send or use.
##
## The rules follow `schema/<version>/schema.ts` of the specification. A
## keyword the schema does not define is not checked (JSON Schema ignores
## what it does not know), `pattern` among them: it is not enforced.

import std/[json, math, strutils, times, unicode]
import ./version
import ./features
import ./payload
import ./types

export payload

type
  ElicitMode* = enum
    emForm = "form"
    emUrl = "url"

  ElicitAction* = enum
    eaAccept = "accept"
    eaDecline = "decline"
    eaCancel = "cancel"

  McpElicitResult* = object
    action*: ElicitAction
    content*: JsonNode
      ## The submitted form data; nil unless the action is accept and the
      ## request was a form.

const StringFormats = ["email", "uri", "date", "date-time"]

func isInteger(node: JsonNode): bool =
  case node.kind
  of JInt: true
  of JFloat: node.getFloat() == node.getFloat().floor()
  else: false

func isNumber(node: JsonNode): bool =
  node.kind in {JInt, JFloat}

func isString(node: JsonNode, key: string): bool =
  not node{key}.isNil and node{key}.kind == JString

func has(node: JsonNode, key: string): bool =
  not node{key}.isNil

func isEmailLike(text: string): bool =
  let at = text.find('@')
  at > 0 and at == text.rfind('@') and at < text.high and
    not text.contains({' ', '\t', '\n'})

func isUriLike(text: string): bool =
  ## RFC 3986: a scheme, a colon, and something after it.
  let colon = text.find(':')
  if colon < 1 or colon == text.high or text.contains({' ', '\t', '\n'}):
    return false
  if text[0] notin Letters:
    return false
  for c in text[0 ..< colon]:
    if c notin Letters + Digits + {'+', '-', '.'}:
      return false
  true

func isDate(text: string): bool =
  ## YYYY-MM-DD naming a day that exists.
  if text.len != 10 or text[4] != '-' or text[7] != '-':
    return false
  for i in [0, 1, 2, 3, 5, 6, 8, 9]:
    if text[i] notin Digits:
      return false
  let year = parseInt(text[0 .. 3])
  let month = parseInt(text[5 .. 6])
  let day = parseInt(text[8 .. 9])
  month in 1 .. 12 and day in 1 .. getDaysInMonth(Month(month), year)

func isDateTime(text: string): bool =
  ## RFC 3339: a date, T, HH:MM:SS with optional fraction, and Z or an offset.
  let t = text.find({'T', 't'})
  if t != 10 or not isDate(text[0 ..< t]):
    return false
  let time = text[t + 1 .. ^1]
  if time.len < 9:
    return false
  for i in [0, 1, 3, 4, 6, 7]:
    if time[i] notin Digits:
      return false
  if time[2] != ':' or time[5] != ':':
    return false
  if parseInt(time[0 .. 1]) > 23 or parseInt(time[3 .. 4]) > 59 or
     parseInt(time[6 .. 7]) > 60:
    return false
  var rest = time[8 .. ^1]
  if rest.len > 0 and rest[0] == '.':
    var digits = 0
    while digits + 1 < rest.len and rest[digits + 1] in Digits:
      inc digits
    if digits == 0:
      return false
    rest = rest[digits + 1 .. ^1]
  if rest in ["Z", "z"]:
    return true
  rest.len == 6 and rest[0] in {'+', '-'} and rest[3] == ':' and
    rest[1] in Digits and rest[2] in Digits and rest[4] in Digits and
    rest[5] in Digits and parseInt(rest[1 .. 2]) <= 23 and parseInt(rest[4 .. 5]) <= 59

func formatProblem(format, value: string): bool =
  ## Whether `value` breaks `format`.
  case format
  of "email": not isEmailLike(value)
  of "uri": not isUriLike(value)
  of "date": not isDate(value)
  of "date-time": not isDateTime(value)
  else: false

func boundsProblems(prop: JsonNode, lowKey, highKey, subject: string): seq[string] =
  for key in [lowKey, highKey]:
    if prop.has(key) and not prop[key].isNumber:
      result.add subject & ": " & key & " is not a number"
  if result.len == 0 and prop.has(lowKey) and prop.has(highKey) and
     prop[lowKey].getFloat() > prop[highKey].getFloat():
    result.add subject & ": " & lowKey & " is above " & highKey

func plainEnumProblems(prop: JsonNode, subject: string): seq[string] =
  let values = prop["enum"]
  if values.kind != JArray or values.len == 0:
    return @[subject & ": enum is not a non-empty array"]
  for v in values:
    if v.kind != JString:
      return @[subject & ": enum holds a value that is not a string"]
  if prop.has("enumNames"):
    let names = prop["enumNames"]
    if names.kind != JArray or names.len != values.len:
      result.add subject & ": enumNames does not pair with enum"
    else:
      for n in names:
        if n.kind != JString:
          result.add subject & ": enumNames holds a name that is not a string"
          break

func propertyProblems(name: string, prop: JsonNode,
                      version: McpProtocolVersion): seq[string] =
  let subject = "property '" & name & "'"
  if prop.kind != JObject:
    return @[subject & " is not an object"]
  if not prop.isString("type"):
    return @[subject & ": type is missing"]
  case prop["type"].getStr()
  of "string":
    if prop.has("enum"):
      result.add plainEnumProblems(prop, subject)
    else:
      result.add boundsProblems(prop, "minLength", "maxLength", subject)
      if prop.has("format"):
        if prop["format"].kind != JString or prop["format"].getStr() notin StringFormats:
          result.add subject & ": format is not one of " & StringFormats.join(", ")
  of "number", "integer":
    result.add boundsProblems(prop, "minimum", "maximum", subject)
  of "boolean":
    discard
  of "array":
    result.add subject & ": array properties are not supported"
  else:
    result.add subject & ": type '" & prop["type"].getStr() & "' is not supported"
  if prop.has("default") and prop["type"].getStr() != "boolean":
    result.add subject & ": default is not allowed here"

func requestedSchemaProblems*(schema: JsonNode,
                              version: McpProtocolVersion): seq[string] =
  ## What keeps `schema` from being a requestedSchema of `version`: it must
  ## be a flat object whose properties are primitives.
  if schema.isNil or schema.kind != JObject:
    return @["requestedSchema is not an object"]
  if schema{"type"}.isNil or schema["type"] != %"object":
    result.add "requestedSchema: type must be \"object\""
  let properties = schema{"properties"}
  if properties.isNil or properties.kind != JObject:
    result.add "requestedSchema: properties is missing"
    return
  for name, prop in properties.pairs:
    result.add propertyProblems(name, prop, version)
  let required = schema{"required"}
  if not required.isNil:
    if required.kind != JArray:
      result.add "requestedSchema: required is not an array"
    else:
      for entry in required:
        if entry.kind != JString or not properties.hasKey(entry.getStr()):
          result.add "requestedSchema: required names '" & $entry &
                     "', which is not a property"

func elicitationModeOf*(params: JsonNode): ElicitMode =
  ## The mode of elicitation/create params; a request without one is a form.
  let mode = if params.isNil: nil else: params{"mode"}
  if mode.isNil:
    return emForm
  if mode.kind == JString and mode.getStr() == "form":
    return emForm
  raise newPayloadError("elicitation/create", @["mode " & $mode & " is not an elicitation mode"])

func elicitationParamsProblems*(params: JsonNode,
                                version: McpProtocolVersion): seq[string] =
  ## What is wrong with the params of an elicitation/create request.
  if not version.has(ftElicitation):
    return @["protocol version " & $version & " has no elicitation"]
  if params.isNil or params.kind != JObject:
    return @["params is not an object"]
  if not params.isString("message") or params["message"].getStr().len == 0:
    result.add "message is missing"
  var mode = emForm
  try:
    mode = elicitationModeOf(params)
  except McpPayloadError as e:
    return result & e.problems
  case mode
  of emForm:
    result.add requestedSchemaProblems(params{"requestedSchema"}, version)
  of emUrl:
    discard

func formElicitationParams*(message: string, requestedSchema: JsonNode,
                            version: McpProtocolVersion): JsonNode =
  ## The params of a form-mode elicitation/create for `version`. 2025-11-25
  ## names the mode; 2025-06-18 has none to name.
  result = %*{"message": message, "requestedSchema": requestedSchema}
  if version.has(ftUrlElicitation):
    result["mode"] = %"form"
  raiseIfAny("elicitation/create", elicitationParamsProblems(result, version))

func modeSupported*(capability: McpElicitationCapability, mode: ElicitMode): bool =
  case mode
  of emForm: capability.form
  of emUrl: capability.url

func valueProblems(name: string, prop, value: JsonNode): seq[string] =
  let subject = "content '" & name & "'"
  case prop{"type"}.getStr()
  of "string":
    if value.kind != JString:
      return @[subject & " is not a string"]
    let text = value.getStr()
    if prop.has("enum"):
      var known = false
      for v in prop["enum"]:
        known = known or v == value
      if not known:
        result.add subject & " is not one of the enum values"
    let length = text.runeLen
    if prop.has("minLength") and length < prop["minLength"].getInt():
      result.add subject & " is shorter than minLength"
    if prop.has("maxLength") and length > prop["maxLength"].getInt():
      result.add subject & " is longer than maxLength"
    if prop.isString("format") and formatProblem(prop["format"].getStr(), text):
      result.add subject & " is not a valid " & prop["format"].getStr()
  of "number", "integer":
    if not value.isNumber:
      return @[subject & " is not a number"]
    if prop["type"].getStr() == "integer" and not value.isInteger:
      return @[subject & " is not an integer"]
    if prop.has("minimum") and value.getFloat() < prop["minimum"].getFloat():
      result.add subject & " is below minimum"
    if prop.has("maximum") and value.getFloat() > prop["maximum"].getFloat():
      result.add subject & " is above maximum"
  of "boolean":
    if value.kind != JBool:
      result.add subject & " is not a boolean"
  else:
    discard

func contentProblems*(requestedSchema, content: JsonNode): seq[string] =
  ## Whether `content` matches `requestedSchema`: required properties are
  ## there and each given value fits its property. Properties the schema does
  ## not list are allowed, as JSON Schema allows them.
  if content.isNil or content.kind != JObject:
    return @["content is not an object"]
  let properties = requestedSchema{"properties"}
  let required = requestedSchema{"required"}
  if not required.isNil and required.kind == JArray:
    for entry in required:
      if not content.hasKey(entry.getStr()):
        result.add "content lacks the required '" & entry.getStr() & "'"
  if properties.isNil or properties.kind != JObject:
    return
  for name, value in content.pairs:
    if properties.hasKey(name):
      result.add valueProblems(name, properties[name], value)

func elicitationResultProblems*(answer, params: JsonNode): seq[string] =
  ## What is wrong with `result`, the answer to a request with `params`.
  if answer.isNil or answer.kind != JObject:
    return @["the result is not an object"]
  if not answer.isString("action") or answer["action"].getStr() notin ["accept", "decline", "cancel"]:
    return @["action is not accept, decline or cancel"]
  let mode =
    try: elicitationModeOf(params)
    except McpPayloadError as e: return e.problems
  if answer["action"].getStr() != "accept":
    if answer.has("content"):
      return @["content is only present when the action is accept"]
    return
  case mode
  of emForm:
    if not answer.has("content"):
      return @["an accepted form has no content"]
    result.add contentProblems(params{"requestedSchema"}, answer["content"])
  of emUrl:
    discard

func parseElicitationResult*(node, params: JsonNode): McpElicitResult =
  ## The answer to a request with `params`, checked against it.
  raiseIfAny("elicitation/create result", elicitationResultProblems(node, params))
  for action in ElicitAction:
    if $action == node["action"].getStr():
      result.action = action
  if node.has("content"):
    result.content = node["content"]

func elicitationResultJson*(answer: McpElicitResult): JsonNode =
  result = %*{"action": $answer.action}
  if answer.action == eaAccept and not answer.content.isNil:
    result["content"] = answer.content
