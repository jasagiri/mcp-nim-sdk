## Fuzzing targets for how the HTTP client reads a response
## (transport/http_wire). Its readers are private and read from a socket; the
## module is included, as tests/internal/test_http_wire_internals.nim does, so
## that the parsers behind the socket can be given bytes directly.

import std/[strutils]
include transport/http_wire
import ./inferred

proc decodedBody(body: string, cut: int): tuple[data: string, refused: bool]
    {.raises: [CatchableError].} =
  ## A chunked body fed in two pieces, split at `cut`.
  let r = WireResponse(mode: bmChunked)
  try:
    inferred:
      result.data = r.decodeChunked(body[0 ..< cut])
      result.data.add r.decodeChunked(body[cut .. ^1])
  except McpTransportError:
    result.refused = true

proc httpChunked*(input: string): string {.raises: [CatchableError].} =
  ## A chunked body decodes to the same bytes however the network cuts it,
  ## and never to more bytes than arrived.
  if input.len == 0: return ""
  let body = input[1 .. ^1]
  let cut = ord(input[0]) mod (body.len + 1)
  let whole = decodedBody(body, 0)
  let parts = decodedBody(body, cut)
  if whole.refused != parts.refused: return "refused for one cut of the body and not for another"
  if not whole.refused and whole.data != parts.data: return "the body depends on where it was cut"
  if whole.data.len > body.len: return "decoded more bytes than arrived"
  ""

proc httpResponse*(input: string): string {.raises: [CatchableError].} =
  ## A response head is read or refused, and a body mode chosen; a chunked
  ## body after it decodes as in `httpChunked`.
  let blank = input.find("\c\L\c\L")
  let head = if blank < 0: input else: input[0 ..< blank]
  let r = WireResponse(mode: bmNone)
  try:
    inferred:
      r.parseHead(head)
      r.chooseBodyMode(HttpGet)
  except McpTransportError:
    return ""   # not a response this client reads: the documented refusal
  if r.mode == bmLength and r.remaining < 0: return "a negative Content-Length was accepted"
  if r.mode == bmChunked and blank >= 0:
    return httpChunked("\0" & input[blank + 4 .. ^1])
  ""
