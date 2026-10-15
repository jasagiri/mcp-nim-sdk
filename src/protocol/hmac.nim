## HMAC-SHA256, a comparison that does not stop at the first difference, and
## a canonical text for a JSON value: what the sealed `requestState` and the
## signed webhook deliveries of the extensions both need.

import std/[algorithm, json]
import nimcrypto/[hmac, sha2]
import ../auth/oauth/sha256
import nim_secret   # foundation/nim-secret — constantTimeEquals

export nim_secret.constantTimeEquals

func hmacSha256*(key, message: string): Sha256Digest {.raises: [].} =
  sha2.sha256.hmac(key, message).data

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
