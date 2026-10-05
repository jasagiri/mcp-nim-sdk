## Content blocks shared by tool results, prompt messages and sampling.

import asyncdispatch, json, options, sets
import ./client

type
  McpContentKind* = enum
    mckText, mckImage, mckAudio, mckResource, mckResourceLink, mckUnknown

  McpEmbeddedResource* = object
    uri*: string
    mimeType*: string
    text*: Option[string]
    blob*: Option[string]

  McpContentItem* = object
    case kind*: McpContentKind
    of mckText:
      text*: string
    of mckImage:
      imageData*: string
      imageMimeType*: string
    of mckAudio:
      audioData*: string
      audioMimeType*: string
    of mckResource:
      resource*: McpEmbeddedResource
    of mckResourceLink:
      linkUri*: string
      linkName*: string
      linkTitle*: Option[string]
      linkDescription*: Option[string]
      linkMimeType*: Option[string]
      linkSize*: Option[int]
    of mckUnknown:
      raw*: JsonNode
        ## A block whose type this client does not know, kept as received.

proc optionalString*(node: JsonNode, key: string): Option[string] =
  let value = node{key}
  if value.isNil or value.kind != JString: none(string) else: some(value.getStr())

proc requiredString*(node: JsonNode, key: string, context: string): string =
  ## Raises McpProtocolError when a field the specification requires is missing.
  let value = node{key}
  if value.isNil or value.kind != JString:
    raise newException(McpProtocolError, context & ": missing string field '" & key & "'")
  value.getStr()

proc requiredArray*(node: JsonNode, key: string, context: string): JsonNode =
  let value = node{key}
  if value.isNil or value.kind != JArray:
    raise newException(McpProtocolError, context & ": missing array field '" & key & "'")
  value

proc parseEmbeddedResource*(node: JsonNode, context: string): McpEmbeddedResource =
  if node.isNil or node.kind != JObject:
    raise newException(McpProtocolError, context & ": the resource is not an object")
  McpEmbeddedResource(
    uri: requiredString(node, "uri", context),
    mimeType: node{"mimeType"}.getStr(),
    text: optionalString(node, "text"),
    blob: optionalString(node, "blob"))

proc parseContentItem*(node: JsonNode, context: string): McpContentItem =
  if node.isNil or node.kind != JObject:
    raise newException(McpProtocolError, context & ": a content block is not an object")
  case node{"type"}.getStr()
  of "text":
    McpContentItem(kind: mckText, text: requiredString(node, "text", context))
  of "image":
    McpContentItem(kind: mckImage,
      imageData: requiredString(node, "data", context),
      imageMimeType: requiredString(node, "mimeType", context))
  of "audio":
    McpContentItem(kind: mckAudio,
      audioData: requiredString(node, "data", context),
      audioMimeType: requiredString(node, "mimeType", context))
  of "resource":
    McpContentItem(kind: mckResource,
      resource: parseEmbeddedResource(node{"resource"}, context))
  of "resource_link":
    McpContentItem(kind: mckResourceLink,
      linkUri: requiredString(node, "uri", context),
      linkName: requiredString(node, "name", context),
      linkTitle: optionalString(node, "title"),
      linkDescription: optionalString(node, "description"),
      linkMimeType: optionalString(node, "mimeType"),
      linkSize: (if node.hasKey("size"): some(node["size"].getInt()) else: none(int)))
  else:
    McpContentItem(kind: mckUnknown, raw: node)

proc toJson*(item: McpContentItem): JsonNode =
  case item.kind
  of mckText: result = %*{"type": "text", "text": item.text}
  of mckImage: result = %*{"type": "image", "data": item.imageData, "mimeType": item.imageMimeType}
  of mckAudio: result = %*{"type": "audio", "data": item.audioData, "mimeType": item.audioMimeType}
  of mckResource:
    var res = %*{"uri": item.resource.uri}
    if item.resource.mimeType.len > 0: res["mimeType"] = %item.resource.mimeType
    if item.resource.text.isSome: res["text"] = %item.resource.text.get
    if item.resource.blob.isSome: res["blob"] = %item.resource.blob.get
    result = %*{"type": "resource", "resource": res}
  of mckResourceLink:
    result = %*{"type": "resource_link", "uri": item.linkUri, "name": item.linkName}
    if item.linkDescription.isSome: result["description"] = %item.linkDescription.get
    if item.linkMimeType.isSome: result["mimeType"] = %item.linkMimeType.get
    if item.linkTitle.isSome: result["title"] = %item.linkTitle.get
    if item.linkSize.isSome: result["size"] = %item.linkSize.get
  of mckUnknown: result = item.raw

proc parseNextCursor*(reply: JsonNode): Option[string] =
  optionalString(reply, "nextCursor")

proc pageParams*(cursor: Option[string]): JsonNode =
  result = newJObject()
  if cursor.isSome:
    result["cursor"] = %cursor.get

proc allPages*[T](what: string,
    fetch: proc(cursor: Option[string]): Future[tuple[items: seq[T], next: Option[string]]]
    ): Future[seq[T]] {.async.} =
  ## Follow nextCursor to the last page. A server that repeats a cursor
  ## would loop forever, so that is a protocol error.
  var cursor = none(string)
  var seen = initHashSet[string]()
  while true:
    let page = await fetch(cursor)
    result.add page.items
    if page.next.isNone:
      return
    if page.next.get in seen:
      raise newException(McpProtocolError,
        what & ": the server repeated cursor '" & page.next.get & "'")
    seen.incl page.next.get
    cursor = page.next
