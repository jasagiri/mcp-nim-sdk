## Fields of an authorization server's metadata that `metadata.nim` does not
## model, read from the document it kept. The document came from the network,
## so a field of the wrong type is an error and not "absent".

import std/[json, options]
import ./errors
import ./metadata

func metadataStrings*(md: AuthorizationServerMetadata, field: string): Option[seq[string]]
                     {.raises: [OAuthError].} =
  ## The array of strings at `field`; none when the document has no such
  ## field (or has null).
  if md.document.isNil:
    return none(seq[string])
  let node = md.document{field}
  if node.isNil or node.kind == JNull:
    return none(seq[string])
  if node.kind != JArray:
    raise newException(OAuthError, "metadata field " & field & " is not an array")
  var values: seq[string]
  for item in node:
    if item.kind != JString:
      raise newException(OAuthError, "metadata field " & field & " has a non-string entry")
    values.add item.getStr()
  some(values)

func supports*(md: AuthorizationServerMetadata, field, value: string): bool
              {.raises: [OAuthError].} =
  ## Whether the array at `field` lists `value`.
  let values = md.metadataStrings(field)
  values.isSome and value in values.get
