## `x-mcp-header` of protocol version 2026-07-28: a tool may name properties
## of its `inputSchema` whose values travel in `Mcp-Param-{Name}` request
## headers of Streamable HTTP, so that intermediaries can route on them.
##
## Pure functions over JSON, shared by the client transport (which writes the
## headers), the server (which checks them against the body) and the server's
## `tools/list` (which must not publish an invalid declaration).
##
## Specification: basic/transports/streamable-http, "Custom Headers from Tool
## Parameters", and server/tools, "x-mcp-header".

import std/[json, options, strutils, sets, unicode]
import ./types
import ./modern

const
  ParamHeaderKeyword* = "x-mcp-header"
  ParamHeaderPrefix* = "Mcp-Param-"
  MaxSafeInteger* = 9_007_199_254_740_991'i64
    ## 2^53 - 1: integers beyond this do not survive IEEE 754 doubles.
  MaxQuotedValue = 64

type
  ParamKind* = enum
    pkString = "string"
    pkInteger = "integer"
    pkBoolean = "boolean"

  ParamBinding* = object
    ## One annotated property: which header carries it and where it sits in
    ## the call arguments.
    name*: string
      ## The `x-mcp-header` value, the name part of the header.
    path*: seq[string]
      ## The chain of `properties` keys from the schema root.
    kind*: ParamKind

  ParamDeclarations* = object
    bindings*: seq[ParamBinding]
    invalid*: Option[string]
      ## Why the tool definition is invalid; `bindings` is then empty.

func headerName*(binding: ParamBinding): string {.raises: [].} =
  ParamHeaderPrefix & binding.name

func isToken(name: string): bool {.raises: [].} =
  ## `1*tchar` of RFC 9110 section 5.6.2.
  if name.len == 0:
    return false
  for c in name:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9',
                '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'}:
      return false
  true

func pathText(path: seq[string]): string {.raises: [].} =
  if path.len == 0: "the schema root" else: "'" & path.join(".") & "'"

func hasStrayAnnotation(node: JsonNode): bool {.raises: [].} =
  ## An annotation somewhere other than a property reachable through
  ## `properties` keys only. A property that happens to be named
  ## `x-mcp-header` has an object as its value and is not one.
  case node.kind
  of JObject:
    for key, child in node.pairs:
      if key == ParamHeaderKeyword and child.kind != JObject:
        return true
      if hasStrayAnnotation(child):
        return true
    false
  of JArray:
    for child in node.elems:
      if hasStrayAnnotation(child):
        return true
    false
  else:
    false

func declaredParamHeaders*(inputSchema: JsonNode): ParamDeclarations {.raises: [].} =
  ## The annotations of a tool's `inputSchema`, or the reason the tool
  ## definition is invalid. A schema without annotations is valid and has no
  ## bindings.
  var bindings: seq[ParamBinding] = @[]
  var seen = initHashSet[string]()
  var reason = none(string)

  proc reject(message: string) {.raises: [].} =
    if reason.isNone:
      reason = some(message)

  proc walk(node: JsonNode, path: seq[string]) {.raises: [].} =
    if node.isNil or node.kind != JObject or reason.isSome:
      return
    for key, child in node.pairs:
      if key == ParamHeaderKeyword:
        continue
      if key == "properties" and child.kind == JObject:
        for name, property in child.pairs:
          walk(property, path & name)
      elif hasStrayAnnotation(child):
        reject(ParamHeaderKeyword & " appears under '" & key & "' of " &
               pathText(path) & ", which a header value cannot be taken from")
    if reason.isSome or not node.hasKey(ParamHeaderKeyword):
      return
    let annotation = node{ParamHeaderKeyword}
    if path.len == 0:
      reject(ParamHeaderKeyword & " is on the schema root, not on a property")
      return
    if annotation.kind != JString or annotation.getStr().len == 0:
      reject(ParamHeaderKeyword & " of " & pathText(path) & " must be a non-empty string")
      return
    let name = annotation.getStr()
    if not name.isToken:
      reject(ParamHeaderKeyword & " of " & pathText(path) &
             " is not an HTTP field-name token")
      return
    if name.toLowerAscii() in seen:
      reject(ParamHeaderKeyword & " value '" & name & "' is used twice")
      return
    let declared = node{"type"}
    var kind: ParamKind
    if declared.isNil or declared.kind != JString or declared.getStr() notin ["string", "integer", "boolean"]:
      reject(ParamHeaderKeyword & " of " & pathText(path) &
             " needs the type string, integer or boolean")
      return
    case declared.getStr()
    of "string": kind = pkString
    of "integer": kind = pkInteger
    else: kind = pkBoolean
    seen.incl name.toLowerAscii()
    bindings.add ParamBinding(name: name, path: path, kind: kind)

  walk(inputSchema, @[])
  if reason.isSome:
    ParamDeclarations(invalid: reason)
  else:
    ParamDeclarations(bindings: bindings)

func valueAt(arguments: JsonNode, path: seq[string]): JsonNode {.raises: [].} =
  ## The value at the property path; nil when absent or null (no header then).
  var current = arguments
  for key in path:
    if current.isNil or current.kind != JObject:
      return nil
    current = current{key}
  if current.isNil or current.kind == JNull: nil else: current

func paramHeadersFor*(bindings: openArray[ParamBinding], arguments: JsonNode,
                      headers: var seq[(string, string)]): Option[string] {.raises: [].} =
  ## Append the `Mcp-Param-*` headers a `tools/call` with `arguments` must
  ## carry. None on success; otherwise why a value cannot be mirrored (a
  ## value of the wrong type, or an integer beyond the safe range), with
  ## `headers` untouched.
  var found: seq[(string, string)] = @[]
  for binding in bindings:
    let value = valueAt(arguments, binding.path)
    if value.isNil:
      continue
    var text: string
    case binding.kind
    of pkString:
      if value.kind != JString:
        return some("argument '" & binding.path.join(".") & "' must be a string")
      text = value.getStr()
    of pkInteger:
      if value.kind != JInt:
        return some("argument '" & binding.path.join(".") & "' must be an integer")
      if value.getBiggestInt() > MaxSafeInteger or value.getBiggestInt() < -MaxSafeInteger:
        return some("argument '" & binding.path.join(".") &
                    "' is outside the range of safe integers")
      text = $value.getBiggestInt()
    of pkBoolean:
      if value.kind != JBool:
        return some("argument '" & binding.path.join(".") & "' must be a boolean")
      text = if value.getBool(): "true" else: "false"
    found.add (binding.headerName, encodeHeaderValue(text))
  headers.add found
  none(string)

func quoted(text: string): string {.raises: [].} =
  ## At most `MaxQuotedValue` characters of a value, for an error message.
  ## Counted in characters: a value can be any text, and a cut at a byte
  ## position would split a multi-byte character.
  if text.runeLen > MaxQuotedValue: text.runeSubStr(0, MaxQuotedValue) & "..." else: text

func mismatch(message: string): Option[JsonRpcError] {.raises: [].} =
  some(JsonRpcError(code: ErrHeaderMismatch, message: "Header mismatch: " & message))

func sameNumber(headerText: string, body: JsonNode): bool {.raises: [].} =
  ## "42.0" and 42 are the same integer.
  try:
    let fromHeader = parseFloat(headerText)
    let fromBody = if body.kind == JInt: float(body.getBiggestInt()) else: body.getFloat()
    fromHeader == fromBody
  except ValueError:
    false

func checkParamHeaders*(bindings: openArray[ParamBinding], arguments: JsonNode,
                        received: openArray[(string, string)]): Option[JsonRpcError] {.raises: [].} =
  ## Why the `Mcp-Param-*` headers of a `tools/call` disagree with its
  ## arguments, or none when they agree. `received` holds the request's
  ## headers (any, in any case): headers the tool did not declare are not
  ## this function's business, a declared one must be there exactly when its
  ## value is in the body and must decode to that value.
  for binding in bindings:
    let wanted = binding.headerName.toLowerAscii()
    var values: seq[string] = @[]
    for (name, value) in received:
      if name.toLowerAscii() == wanted:
        values.add value
    let body = valueAt(arguments, binding.path)

    if body.isNil:
      if values.len > 0:
        return mismatch(binding.headerName & " header is present but the argument is not")
      continue
    if values.len == 0:
      return mismatch(binding.headerName & " header is missing")
    if values.len > 1:
      return mismatch(binding.headerName & " header is sent more than once")

    let decoded = decodeHeaderValue(values[0])
    if decoded.isNone:
      return mismatch(binding.headerName & " header value is malformed")
    let text = decoded.get
    let agrees =
      case body.kind
      of JString: text == body.getStr()
      of JBool: text == (if body.getBool(): "true" else: "false")
      of JInt, JFloat: sameNumber(text, body)
      else: false
    if not agrees:
      return mismatch(binding.headerName & " header value '" & quoted(text) &
                      "' does not match the body")
  none(JsonRpcError)
