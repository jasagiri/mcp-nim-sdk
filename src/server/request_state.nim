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

import std/[base64, json, options, strutils, times]
import ./errors
import ../auth/oauth/sha256
import ../protocol/hmac

const
  MinKeyBytes* = 16
  DefaultStateTtlSeconds* = 300

func digestOf(salient: JsonNode): string {.raises: [].} =
  sha256(canonicalJson(salient)).toHex

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
  if not constantTimeEquals(sign(key, body), state[dot + 1 .. ^1]):
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
