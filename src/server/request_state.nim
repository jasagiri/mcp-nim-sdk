## Sealing the `requestState` of a multi round-trip request (2026-07-28).
##
## The state passes through the client, so the server must treat what comes
## back as attacker-controlled: it is signed (HMAC-SHA256) and bound to the
## things the specification suggests, which are verified on receipt: the
## method and a digest of the request's salient parameters, the
## authenticated principal, and a short expiry. This does not make a state
## single-use; a server that needs that must enforce it itself.
##
##   let state = sealRequestState(key, %*{"step": 2}, "tools/call",
##                                salient = %*{"name": name, "arguments": arguments},
##                                principal = user)
##   ...
##   let kept = openRequestState(key, ctx.requestState.get, "tools/call",
##                               salient = %*{"name": name, "arguments": arguments},
##                               principal = user)

import std/[algorithm, base64, json, options, strutils, times]
import ./errors
import ../auth/oauth/sha256

const
  MinKeyBytes* = 16
  DefaultStateTtlSeconds* = 300

func toBytes(text: string): seq[byte] {.raises: [].} =
  result = newSeq[byte](text.len)
  for i, c in text:
    result[i] = byte(c)

func hmacSha256(key, message: string): Sha256Digest {.raises: [].} =
  const BlockSize = 64
  var keyBytes = toBytes(key)
  if keyBytes.len > BlockSize:
    keyBytes = @(sha256(keyBytes))
  keyBytes.setLen(BlockSize)
  var inner = newSeq[byte](BlockSize)
  var outer = newSeq[byte](BlockSize)
  for i in 0 ..< BlockSize:
    inner[i] = keyBytes[i] xor 0x36
    outer[i] = keyBytes[i] xor 0x5c
  inner.add toBytes(message)
  outer.add @(sha256(inner))
  sha256(outer)

func canonical(node: JsonNode): string {.raises: [].} =
  ## The same text for the same value, whatever order the keys arrived in.
  if node.isNil:
    return "null"
  case node.kind
  of JObject:
    var members: seq[(string, JsonNode)]
    for key, value in node.pairs:
      members.add (key, value)
    members.sort(proc(a, b: (string, JsonNode)): int = cmp(a[0], b[0]))
    result = "{"
    for i, member in members:
      if i > 0: result.add ','
      result.add $(%member[0]) & ":" & canonical(member[1])
    result.add '}'
  of JArray:
    result = "["
    for i, item in node.elems:
      if i > 0: result.add ','
      result.add canonical(item)
    result.add ']'
  else:
    result = $node

func digestOf(salient: JsonNode): string {.raises: [].} =
  sha256(canonical(salient)).toHex

func sign(key, body: string): string {.raises: [].} =
  base64.encode(hmacSha256(key, body), safe = true)

func sealRequestState*(key: string, payload: JsonNode, methodName: string,
                       salient: JsonNode = nil, principal = "",
                       ttlSeconds = DefaultStateTtlSeconds,
                       now = epochTime()): string {.raises: [ValueError].} =
  ## A signed state carrying `payload`, valid for `ttlSeconds` for this
  ## method, these salient parameters and this principal. Raises ValueError
  ## for a key shorter than `MinKeyBytes`.
  if key.len < MinKeyBytes:
    raise newException(ValueError,
      "the key of a request state must be at least " & $MinKeyBytes & " bytes")
  let envelope = %*{"p": payload, "m": methodName, "d": digestOf(salient),
                    "u": principal, "x": int64(now) + ttlSeconds}
  let body = base64.encode($envelope, safe = true)
  body & "." & sign(key, body)

func sameText(a, b: string): bool {.raises: [].} =
  ## Without stopping at the first difference.
  if a.len != b.len:
    return false
  var difference = 0
  for i in 0 ..< a.len:
    difference = difference or (ord(a[i]) xor ord(b[i]))
  difference == 0

proc verifyRequestState*(key, state, methodName: string, salient: JsonNode = nil,
                         principal = "", now = epochTime()
                        ): tuple[payload: JsonNode, problem: Option[string]] {.raises: [].} =
  ## The payload sealed into `state`, or why the state is not acceptable
  ## here: not signed by this key, expired, or presented for another method,
  ## other parameters or another principal.
  proc failure(why: string): tuple[payload: JsonNode, problem: Option[string]] =
    (nil, some(why))
  let dot = state.rfind('.')
  if dot <= 0 or key.len < MinKeyBytes:
    return failure("malformed")
  let body = state[0 ..< dot]
  if not sameText(sign(key, body), state[dot + 1 .. ^1]):
    return failure("signature does not verify")
  var envelope: JsonNode
  try:
    envelope = parseJson(base64.decode(body))
  except ValueError, JsonParsingError, IOError, OSError:
    return failure("malformed")
  if envelope.kind != JObject:
    return failure("malformed")
  if envelope{"x"}.getBiggestInt() < int64(now):
    return failure("expired")
  if envelope{"m"}.getStr() != methodName:
    return failure("issued for another method")
  if envelope{"d"}.getStr() != digestOf(salient):
    return failure("issued for other parameters")
  if envelope{"u"}.getStr() != principal:
    return failure("issued for another principal")
  (envelope{"p"}, none(string))

proc openRequestState*(key, state, methodName: string, salient: JsonNode = nil,
                       principal = "", now = epochTime()): JsonNode =
  ## Like `verifyRequestState`, for a handler: a state that is not
  ## acceptable raises the invalid-params error (the reason goes to stderr,
  ## not to the peer).
  let checked = verifyRequestState(key, state, methodName, salient, principal, now)
  if checked.problem.isSome:
    stderr.writeLine("[mcp-server] " & methodName & ": requestState rejected: " &
                     checked.problem.get)
    raise newInvalidParams("Invalid requestState")
  checked.payload
