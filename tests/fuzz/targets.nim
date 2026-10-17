## The places where text a peer chose is read, as fuzzing targets.
##
## Each target takes whatever bytes arrive and says what is wrong with how
## the library handled them: "" for nothing. A target catches the errors the
## library documents for malformed input, because a refusal is the right
## answer to most of what a fuzzer sends. Anything else that is raised, and
## any defect (an index out of range, an overflow), is a finding.
##
## Used by `fuzz_entrances.nim` (a fuzzing run, started by hand, with the
## fuzzer of ../nim-fuzz) and by `../internal/test_fuzz_regressions.nim` (the
## seeds and the inputs fuzzing found, run with the other tests through the
## same fuzzer's `replay`).
##
## The list was drawn up by reading the sources on 2026-10-07 and widened on
## 2026-10-18 to the places it named as missing: the HTTP response the client
## reads (http_wire_targets.nim), the JSON-RPC requests a server dispatches,
## the answers a client reads, the OAuth documents and stdio lines
## (peer_targets.nim). TODO: no person other than its writers has reviewed it
## (the release ledger's INP-02).
##
## Not here, because they can only be given bytes through a socket: the
## request line, headers and body framing a server reads. Those are parsed by
## std/asynchttpserver (or the copy in transport/vendor for Nim before 2.3.1);
## what the SDK reads from a request after that is here (clientAnswers runs
## validateModernRequest and checkRequestHeaders).

import std/[json, options, strutils]
import transport/[event_stream, address_policy]
import protocol/[trace_context, modern, diagnostic]
import jsonschema/[json_schema, json_schema_regex]
import auth/oauth/[urls, errors]
import bearer_challenge  # foundation/nim-bearer-challenge: parseChallenges
import server/pagination
import server/errors as server_errors
import ./inferred
import ./http_wire_targets, ./peer_targets

type
  Target* = proc(input: string): string {.raises: [CatchableError].}
  Entrance* = object
    name*: string
    target*: Target
    seeds*: seq[string]
    words*: seq[string]   ## words of the format, for the fuzzer's dictionary
    maxLen*: int

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
    words: @["\xe2\x80\xae", "\xc0", "\xf0", "\x7f", "\\", "\n"]),
  Entrance(name: "httpResponse", target: httpResponse, maxLen: 800,
    seeds: @["HTTP/1.1 200 OK\c\LContent-Type: application/json\c\LContent-Length: 2\c\L\c\L{}",
             "HTTP/1.1 200 OK\c\LTransfer-Encoding: chunked\c\L\c\L4\c\Ldata\c\L0\c\L\c\L",
             "HTTP/1.0 302 Found\c\LLocation: /next\c\L\c\L", "HTTP/1.1 204 No Content\c\L\c\L"],
    words: @["HTTP/1.1 ", "\c\L", "\c\L\c\L", "Content-Length: ", "Transfer-Encoding: chunked",
             "Mcp-Session-Id: ", "Location: ", ": ", "200", "-1"]),
  Entrance(name: "httpChunked", target: httpChunked, maxLen: 600,
    seeds: @["\x034\c\Ldata\c\L0\c\L\c\L", "\x07a;ext=1\c\L0123456789\c\L0\c\LTrailer: x\c\L\c\L",
             "\x01ffffffffffffffff\c\Lx\c\L0\c\L\c\L"],
    words: @["\c\L", "0\c\L\c\L", ";", "ffffffff", "7fffffffffffffff", "\n"]),
  Entrance(name: "serverDispatch", target: serverDispatch, maxLen: 800,
    seeds: @["""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}""",
             """{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"cursor":"x"}}""",
             """{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"t","arguments":{},"_meta":{"progressToken":1}}}""",
             """{"jsonrpc":"2.0","id":"a","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"""],
    words: @["\"jsonrpc\"", "\"2.0\"", "\"id\"", "\"method\"", "\"params\"", "\"_meta\"", "\"initialize\"",
             "\"tools/list\"", "\"tools/call\"", "\"resources/read\"", "\"prompts/get\"", "\"completion/complete\"",
             "\"logging/setLevel\"", "\"tasks/get\"", "\"server/discover\"", "null", "{", "}", "[", "]"]),
  Entrance(name: "clientAnswers", target: clientAnswers, maxLen: 800,
    seeds: @["""{"type":"text","text":"hi","annotations":{"audience":["user"]}}""",
             """{"type":"resource","resource":{"uri":"file:///a","mimeType":"text/plain","text":"x"}}""",
             """{"name":"s","version":"1","icons":[{"src":"https://x/i.png","sizes":["48x48"]}]}""",
             """{"taskId":"t","status":"working","createdAt":"2026-01-01T00:00:00Z","ttl":1000,"params":{"task":{"ttl":5}}}""",
             """{"action":"accept","content":{"n":1},"params":{"requestedSchema":{"type":"object","properties":{"n":{"type":"integer"}}}}}"""],
    words: @["\"type\"", "\"text\"", "\"image\"", "\"audio\"", "\"resource\"", "\"resource_link\"", "\"uri\"",
             "\"nextCursor\"", "\"icons\"", "\"taskId\"", "\"status\"", "\"action\"", "\"content\"",
             "\"requestedSchema\"", "\"params\"", "\"_meta\"", "{", "}", "[", "]"]),
  Entrance(name: "oauthDocuments", target: oauthDocuments, maxLen: 800,
    seeds: @["""{"resource":"https://rs.example/mcp","authorization_servers":["https://as.example"]}""",
             """{"issuer":"https://as.example","authorization_endpoint":"https://as.example/a","token_endpoint":"https://as.example/t","code_challenge_methods_supported":["S256"]}""",
             """{"access_token":"x","token_type":"Bearer","expires_in":3600,"scope":"read","refresh_token":"r"}"""],
    words: @["\"resource\"", "\"authorization_servers\"", "\"issuer\"", "\"authorization_endpoint\"",
             "\"token_endpoint\"", "\"access_token\"", "\"token_type\"", "\"expires_in\"", "\"scope\"",
             "https://", "http://127.0.0.1", "{", "}", "[", "]"]),
  Entrance(name: "stdioLines", target: stdioLines, maxLen: 800,
    seeds: @["{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n", "\n\r\n{}\r\nnot json\n[1,2]",
             "{\"a\":1e999999}\n", "\xef\xbb\xbf{}\n"],
    words: @["\n", "\r\n", "{", "}", "\"", "1e", "\\u"])]
