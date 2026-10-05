## Reading fields of JSON that came from the network. `node{"key"}` is nil
## for a missing key, so every read has to look at the kind first.

import std/[json, options]

func strField*(node: JsonNode, key: string): Option[string] {.raises: [].} =
  ## The string at `key`; none when it is missing or of another type.
  if node.isNil or node.kind != JObject:
    return none(string)
  let value = node{key}
  if value.isNil or value.kind != JString:
    return none(string)
  some(value.getStr())

func intField*(node: JsonNode, key: string): Option[int] {.raises: [].} =
  if node.isNil or node.kind != JObject:
    return none(int)
  let value = node{key}
  if value.isNil or value.kind != JInt:
    return none(int)
  some(value.getInt())
