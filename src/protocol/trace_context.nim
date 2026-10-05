## OpenTelemetry trace context in `_meta` (2026-07-28): `traceparent`,
## `tracestate` and `baggage` are reserved keys whose values follow the W3C
## Trace Context and W3C Baggage formats.
##
## Pure functions over JSON, shared by the server and the client. Only a
## version that `has(ftTraceContext)` carries these keys; the callers decide
## that, not this module.

import std/[json, options, strutils]
import ./types

const
  MetaTraceparent* = "traceparent"
  MetaTracestate* = "tracestate"
  MetaBaggage* = "baggage"

  MaxTracestateMembers = 32
  MaxBaggageMembers = 64
  MaxBaggageBytes = 8192

type
  TraceContext* = object
    ## The trace context of one request, as it appears in `_meta`.
    traceparent*: Option[string]
    tracestate*: Option[string]
    baggage*: Option[string]

func isEmpty*(context: TraceContext): bool {.raises: [].} =
  context.traceparent.isNone and context.tracestate.isNone and context.baggage.isNone

func isLowerHex(text: string): bool {.raises: [].} =
  text.len > 0 and text.allCharsInSet({'0'..'9', 'a'..'f'})

func isAllZero(text: string): bool {.raises: [].} =
  text.allCharsInSet({'0'})

func validateTraceparent*(value: string): Option[string] {.raises: [].} =
  ## Why `value` is not a W3C `traceparent`, or none when it is. A version
  ## other than 00 may carry fields after the flags; version 00 may not.
  let fields = value.split('-')
  if fields.len < 4:
    return some("traceparent needs version, trace-id, parent-id and flags")
  let version = fields[0]
  if version.len != 2 or not isLowerHex(version) or version == "ff":
    return some("traceparent version must be two lowercase hex digits other than ff")
  if fields[1].len != 32 or not isLowerHex(fields[1]) or isAllZero(fields[1]):
    return some("traceparent trace-id must be 32 lowercase hex digits, not all zero")
  if fields[2].len != 16 or not isLowerHex(fields[2]) or isAllZero(fields[2]):
    return some("traceparent parent-id must be 16 lowercase hex digits, not all zero")
  if fields[3].len != 2 or not isLowerHex(fields[3]):
    return some("traceparent flags must be two lowercase hex digits")
  if version == "00" and fields.len != 4:
    return some("traceparent of version 00 has exactly four fields")
  none(string)

func isTracestateKey(key: string): bool {.raises: [].} =
  const Tail = {'a'..'z', '0'..'9', '_', '-', '*', '/'}
  let at = key.find('@')
  if at < 0:
    return key.len in 1 .. 256 and key[0] in {'a'..'z'} and key.allCharsInSet(Tail)
  let tenant = key[0 ..< at]
  let system = key[at + 1 .. ^1]
  tenant.len in 1 .. 241 and tenant[0] in {'a'..'z', '0'..'9'} and
    tenant.allCharsInSet(Tail) and
    system.len in 1 .. 14 and system[0] in {'a'..'z'} and system.allCharsInSet(Tail)

func isTracestateValue(value: string): bool {.raises: [].} =
  value.len <= 256 and (value.len == 0 or value[^1] != ' ') and
    value.allCharsInSet({'\x20'..'\x7E'} - {',', '='})

func validateTracestate*(value: string): Option[string] {.raises: [].} =
  ## Why `value` is not a W3C `tracestate`, or none when it is.
  let members = value.split(',')
  if members.len > MaxTracestateMembers:
    return some("tracestate has more than " & $MaxTracestateMembers & " members")
  var seen: seq[string]
  for raw in members:
    let member = raw.strip(chars = {' ', '\t'})
    let eq = member.find('=')
    if eq < 0:
      return some("tracestate member '" & member & "' is not key=value")
    let key = member[0 ..< eq]
    if not isTracestateKey(key):
      return some("tracestate key '" & key & "' is not valid")
    if not isTracestateValue(member[eq + 1 .. ^1]):
      return some("tracestate value of '" & key & "' is not valid")
    if key in seen:
      return some("tracestate repeats key '" & key & "'")
    seen.add key
  none(string)

func trimmed(text: string): string {.raises: [].} =
  text.strip(chars = {' ', '\t'})

func isToken(text: string): bool {.raises: [].} =
  ## An RFC 7230 token.
  text.len > 0 and text.allCharsInSet(
    {'a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%', '&', '\'', '*', '+',
     '-', '.', '^', '_', '`', '|', '~'})

func isBaggageValue(text: string): bool {.raises: [].} =
  ## Percent-encoded baggage octets (W3C Baggage): visible ASCII except
  ## double quote, comma, semicolon and backslash.
  text.allCharsInSet({'\x21', '\x23'..'\x2B', '\x2D'..'\x3A', '\x3C'..'\x5B', '\x5D'..'\x7E'})

func validateBaggage*(value: string): Option[string] {.raises: [].} =
  ## Why `value` is not a W3C `baggage` header value, or none when it is.
  if value.len > MaxBaggageBytes:
    return some("baggage is longer than " & $MaxBaggageBytes & " bytes")
  let members = value.split(',')
  if members.len > MaxBaggageMembers:
    return some("baggage has more than " & $MaxBaggageMembers & " members")
  for raw in members:
    let member = trimmed(raw)
    let parts = member.split(';')
    let pair = trimmed(parts[0])
    let eq = pair.find('=')
    if eq < 0:
      return some("baggage member '" & member & "' is not key=value")
    if not isToken(trimmed(pair[0 ..< eq])):
      return some("baggage key in '" & member & "' is not a token")
    if not isBaggageValue(trimmed(pair[eq + 1 .. ^1])):
      return some("baggage value in '" & member & "' is not valid")
    for i in 1 ..< parts.len:
      let property = trimmed(parts[i])
      let propEq = property.find('=')
      if propEq < 0:
        if not isToken(property):
          return some("baggage property '" & property & "' is not valid")
      elif not isToken(trimmed(property[0 ..< propEq])) or
           not isBaggageValue(trimmed(property[propEq + 1 .. ^1])):
        return some("baggage property '" & property & "' is not valid")
  none(string)

func metaOf(params: JsonNode): JsonNode {.raises: [].} =
  if params.isNil or params.kind != JObject:
    return nil
  let meta = params{"_meta"}
  if meta.isNil or meta.kind != JObject: nil else: meta

func stringIn(meta: JsonNode, key: string): Option[string] {.raises: [].} =
  let node = meta{key}
  if node.isNil or node.kind != JString: none(string) else: some(node.getStr())

func traceContextOf*(params: JsonNode): TraceContext {.raises: [].} =
  ## What `params._meta` carries; a key that is not a string is not read
  ## (`rejectInvalidTraceContext` reports it).
  let meta = metaOf(params)
  if meta.isNil:
    return
  TraceContext(traceparent: meta.stringIn(MetaTraceparent),
               tracestate: meta.stringIn(MetaTracestate),
               baggage: meta.stringIn(MetaBaggage))

func validate*(context: TraceContext): Option[string] {.raises: [].} =
  ## Why a value of `context` breaks its W3C format, or none.
  if context.traceparent.isSome:
    let problem = validateTraceparent(context.traceparent.get)
    if problem.isSome: return problem
  if context.tracestate.isSome:
    let problem = validateTracestate(context.tracestate.get)
    if problem.isSome: return problem
  if context.baggage.isSome:
    let problem = validateBaggage(context.baggage.get)
    if problem.isSome: return problem
  none(string)

func rejectInvalidTraceContext*(params: JsonNode): Option[JsonRpcError] {.raises: [].} =
  ## The invalid-params error for a trace context key of `params._meta`
  ## that is not a string or breaks its format; none when all are fine.
  let meta = metaOf(params)
  if meta.isNil:
    return none(JsonRpcError)
  for key in [MetaTraceparent, MetaTracestate, MetaBaggage]:
    let node = meta{key}
    if not node.isNil and node.kind != JString:
      return some(JsonRpcError(code: -32602,
        message: "_meta." & key & " must be a string"))
  let problem = traceContextOf(params).validate
  if problem.isSome:
    return some(JsonRpcError(code: -32602, message: "_meta: " & problem.get))
  none(JsonRpcError)

func meta*(context: TraceContext): JsonNode {.raises: [].} =
  ## The `_meta` entries of `context`.
  result = newJObject()
  if context.traceparent.isSome: result[MetaTraceparent] = %context.traceparent.get
  if context.tracestate.isSome: result[MetaTracestate] = %context.tracestate.get
  if context.baggage.isSome: result[MetaBaggage] = %context.baggage.get

func withTraceContext*(params: JsonNode, context: TraceContext): JsonNode {.raises: [].} =
  ## A copy of `params` whose `_meta` gains the keys of `context`; its other
  ## `_meta` keys stay.
  result =
    if params.isNil or params.kind != JObject: newJObject()
    else: params.copy()
  if context.isEmpty:
    return
  var merged = result{"_meta"}
  if merged.isNil or merged.kind != JObject:
    merged = newJObject()
    result["_meta"] = merged
  for key, value in context.meta.pairs:
    merged[key] = value
