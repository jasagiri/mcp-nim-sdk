## The places where text a peer chose is read, as fuzzing targets.
##
## Each target takes whatever bytes arrive and says what is wrong with how
## the library handled them: "" for nothing. A target catches the errors the
## library documents for malformed input, because a refusal is the right
## answer to most of what a fuzzer sends. Anything else that is raised, and
## any defect (an index out of range, an overflow), is a finding.
##
## Used by `fuzz_entrances.nim` (a fuzzing run, started by hand, with the
## fuzzer of ../nim-fuzz) and by `../test_fuzz_regressions.nim` (the seeds
## and the inputs fuzzing found, run with the other tests, with nothing but
## the standard library).
##
## TODO: this list was drawn up by reading the sources on 2026-10-07 and has
## not been reviewed by a person. Places that read a peer's text and are not
## here: the HTTP request and response of transport/http_wire and
## transport/http_server (they read from a socket), the JSON-RPC messages a
## server and a client dispatch, the OAuth metadata documents, stdio lines.

import std/[json, options, strutils]
import transport/[event_stream, address_policy]
import protocol/[trace_context, modern, diagnostic]
import jsonschema/[json_schema, json_schema_regex]
import auth/oauth/[challenge, urls, errors]
import server/pagination
import server/errors as server_errors

type
  Target* = proc(input: string): string {.raises: [CatchableError].}
  Entrance* = object
    name*: string
    target*: Target
    seeds*: seq[string]
    words*: seq[string]   ## words of the format, for the fuzzer's dictionary
    maxLen*: int

template inferred(body: untyped) =
  ## Runs a proc whose raises list the compiler infers as `Exception` (it
  ## recurses) under this file's `raises: [CatchableError]`. A defect and a
  ## catchable error pass through as they are; there is nothing else.
  try:
    body
  except CatchableError as e:
    raise e
  except Defect as e:
    raise e
  except Exception as e:
    raise newException(CatchableError, "neither catchable nor a defect: " & e.msg)

proc eventsOf(text: string, cut: int): seq[SseEvent] {.raises: [SseLimitError].} =
  var parser = initSseParser(maxLineBytes = 512, maxEventBytes = 1024)
  result.add parser.feed(text[0 ..< cut])
  result.add parser.feed(text[cut .. ^1])

proc eventStream*(input: string): string {.raises: [CatchableError].} =
  ## The events of a stream do not depend on where its chunks end.
  if input.len == 0: return ""
  let cut = ord(input[0]) mod input.len
  let body = input[1 .. ^1]
  var whole, parts: seq[SseEvent]
  var wholeOver, partsOver = false
  try: whole = eventsOf(body, 0)
  except SseLimitError: wholeOver = true
  try: parts = eventsOf(body, min(cut, body.len))
  except SseLimitError: partsOver = true
  if wholeOver != partsOver: return "a limit was reached for one cut of the stream and not for another"
  if not wholeOver and whole != parts: return "the events depend on where the chunk ends"
  ""

proc traceContext*(input: string): string {.raises: [CatchableError].} =
  discard validateTraceparent(input)
  discard validateTracestate(input)
  discard validateBaggage(input)
  ""

proc regex*(input: string): string {.raises: [CatchableError].} =
  ## A pattern and a text, one per line. Compiling and matching either
  ## answer or raise RegexError; a budget bounds the match.
  let parts = input.split('\n', maxsplit = 1)
  try:
    inferred:
      let compiled = compileRegex(parts[0])
      discard compiled.isMatch(if parts.len > 1: parts[1] else: "", maxSteps = 200_000)
  except RegexError:
    discard   # malformed, unsupported or over a limit: the documented refusal
  ""

proc schema*(input: string): string {.raises: [CatchableError].} =
  ## A JSON document `{"schema": ..., "instance": ...}`.
  var document: JsonNode
  try:
    document = parseJson(input)
  except JsonParsingError, ValueError:
    return ""   # not JSON: nothing reaches the validator
  if document.kind != JObject or not document.hasKey("schema") or not document.hasKey("instance"):
    return ""
  try:
    inferred:
      discard validate(document["schema"], document["instance"])
  except InvalidSchemaError:
    discard   # a schema that cannot be checked, or a limit: the documented refusal
  ""

proc hosts*(input: string): string {.raises: [CatchableError].} =
  discard parseHostLiteral(input)
  discard classifyHost(input)
  ""

proc headerValue*(input: string): string {.raises: [CatchableError].} =
  ## Any value decodes or is refused, and what is encoded decodes to itself.
  discard decodeHeaderValue(input)
  let back = decodeHeaderValue(encodeHeaderValue(input))
  if back.isNone: return "a value that was encoded is refused when decoded"
  if back.get != input: return "a value that was encoded decodes to another"
  ""

proc challenges*(input: string): string {.raises: [CatchableError].} =
  discard parseChallenges(input)
  discard bearerChallenge([input])
  ""

proc urlsAndForms*(input: string): string {.raises: [CatchableError].} =
  discard formDecode(input)
  discard queryOf(input)
  discard originOf(input)
  discard isLoopbackHost(input)
  try:
    discard canonicalResource(input)
  except OAuthError:
    discard   # not a URL a resource can have: the documented refusal
  ""

proc cursor*(input: string): string {.raises: [CatchableError].} =
  ## A cursor names a page or is invalid params.
  let items = @[%1, %2, %3, %4, %5]
  try:
    let page = pageOf(items, some(input), 2)
    if page.items.len == 0: return "a cursor was accepted and its page is empty"
  except McpRequestError as e:
    if e.code != -32602: return "a cursor was refused with the code " & $e.code
  ""

proc logText*(input: string): string {.raises: [CatchableError].} =
  ## Text made fit for a log has no control character left in it.
  let shown = peerText(input)
  for c in shown:
    if c < ' ' or c == '\x7f': return "a control character is left in the text"
  ""

const Entrances* = [
  Entrance(name: "eventStream", target: eventStream, maxLen: 600,
    seeds: @["\x05data: hello\n\n", "\x09event: message\r\nid: 7\r\ndata: a\r\ndata: b\r\n\r\n",
             "\x03: comment\nretry: 3000\n\ndata\n\n"],
    words: @["data:", "event:", "id:", "retry:", "\r\n", "\n\n", ": "]),
  Entrance(name: "traceContext", target: traceContext, maxLen: 600,
    seeds: @["00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
             "vendor=opaque,rojo=00f067aa0ba902b7", "userId=alice,serverNode=DF%2028;prop=1"],
    words: @["00-", "-01", "=", ",", ";", "%20", "@"]),
  Entrance(name: "regex", target: regex, maxLen: 200,
    seeds: @["^[a-z]+(\\d{2,4})?$\nabc123", "(a|b)*c\\b\naabbc", "^(?=.*\\d)(?!.*\\s).{8,}$\npassw0rd",
             "\\p{L}+\\u00e9\ncafé"],
    words: @["(?=", "(?!", "(?:", "{2,}", "\\b", "\\B", "\\d", "\\w", "\\s", "\\p{L}", "\\u", "[^", "]", "|", "*?", "+?"]),
  Entrance(name: "schema", target: schema, maxLen: 800,
    seeds: @["""{"schema":{"type":"object","properties":{"n":{"type":"integer","minimum":0}},"required":["n"]},"instance":{"n":3}}""",
             """{"schema":{"$defs":{"a":{"type":"string","pattern":"^a+$"}},"$ref":"#/$defs/a"},"instance":"aaa"}""",
             """{"schema":{"anyOf":[{"type":"array","items":{"enum":[1,"x",null]}},{"const":true}]},"instance":[1,"x"]}"""],
    words: @["\"$ref\"", "\"$defs\"", "\"$schema\"", "\"allOf\"", "\"anyOf\"", "\"oneOf\"", "\"not\"", "\"pattern\"",
             "\"items\"", "\"properties\"", "\"additionalProperties\"", "\"type\"", "\"#\"", "\"#/$defs/a\"", "{", "}", "[", "]"]),
  Entrance(name: "hosts", target: hosts, maxLen: 120,
    seeds: @["127.0.0.1", "[::1]", "::ffff:10.0.0.1", "example.com", "0x7f.1", "fe80::1%eth0", "169.254.169.254"],
    words: @["::", "::ffff:", "0x", ".", "%", "[", "]", "localhost"]),
  Entrance(name: "headerValue", target: headerValue, maxLen: 300,
    seeds: @["plain", "=?base64?aGVsbG8=?=", "=?base64?\rN0x?=", "caf\xc3\xa9"],
    words: @["=?base64?", "?=", "=", "\r", "\n"]),
  Entrance(name: "challenges", target: challenges, maxLen: 400,
    seeds: @["Bearer realm=\"mcp\", error=\"invalid_token\", error_description=\"expired\"",
             "Basic realm=\"x\", Bearer resource_metadata=\"https://rs.example/.well-known/oauth-protected-resource\", scope=\"a b\"",
             "Bearer"],
    words: @["Bearer ", "realm=", "error=", "scope=", "resource_metadata=", "\"", "\\\"", ", ", "="]),
  Entrance(name: "urlsAndForms", target: urlsAndForms, maxLen: 400,
    seeds: @["https://rs.example:8443/mcp?x=1#frag", "code=abc&state=xyz%201&iss=https%3A%2F%2Fas.example",
             "http://[::1]:8080/", "https://user:pw@host/path/../x"],
    words: @["https://", "http://", "://", "%", "&", "=", "#", "?", "@", ":", "[", "]", "+"]),
  Entrance(name: "cursor", target: cursor, maxLen: 80,
    seeds: @["b2Zmc2V0OjI=", "b2Zmc2V0OjQ=", "\rN0x", "", "b2Zmc2V0OjI"],
    words: @["b2Zmc2V0Oj", "=", "==", "\r", " "]),
  Entrance(name: "logText", target: logText, maxLen: 400,
    seeds: @["plain text", "line\nbreak\ttab\\", "\x1b[31mred", "\xe2\x80\xaeright to left", "\xff\xfe\x80", "\xf0\x9f\x98\x80"],
    words: @["\xe2\x80\xae", "\xc0", "\xf0", "\x7f", "\\", "\n"])]
