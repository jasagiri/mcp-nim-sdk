## HMAC-SHA256, a comparison that does not stop at the first difference, and
## a canonical text for a JSON value: what the sealed `requestState` and the
## signed webhook deliveries of the extensions both need.

import std/[algorithm, json]
import ../auth/oauth/sha256
import nim_secret   # foundation/nim-secret — constantTimeEquals

export nim_secret.constantTimeEquals

func toBytes*(text: string): seq[byte] {.raises: [].} =
  result = newSeq[byte](text.len)
  for i, c in text:
    result[i] = byte(c)

func hmacSha256*(key, message: string): Sha256Digest {.raises: [].} =
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

func canonicalJson*(node: JsonNode): string {.raises: [].} =
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
      result.add $(%member[0]) & ":" & canonicalJson(member[1])
    result.add '}'
  of JArray:
    result = "["
    for i, item in node.elems:
      if i > 0: result.add ','
      result.add canonicalJson(item)
    result.add ']'
  else:
    result = $node
