## Content blocks shared by tool results, prompt messages and sampling.

import asyncdispatch, json, options, sets, strutils, uri
import ./client
import ../protocol/types
import ../protocol/content as wire
export types.McpIcon, types.McpIconTheme

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
      linkIcons*: seq[McpIcon]
    of mckUnknown:
      raw*: JsonNode
        ## A block whose type this client does not know, kept as received.

proc optionalString*(node: JsonNode, key: string, context: string): Option[string] =
  ## The string field `key`, none when it is absent. Raises McpProtocolError
  ## when it is there and not a string: the specification types these fields,
  ## and a value of another type is the peer's defect, not an absent field.
  let value = node{key}
  if value.isNil: return none(string)
  if value.kind != JString:
    raise newException(McpProtocolError,
      context & ": '" & key & "' must be a string, not " & $value.kind)
  some(value.getStr())

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

proc iconsOf*(node: JsonNode, context: string): seq[McpIcon] =
  ## The `icons` of a listed item or content block; a malformed field is a
  ## protocol error.
  try:
    wire.iconsOf(node)
  except McpShapeError as e:
    raise newException(McpProtocolError, context & ": " & e.msg)

proc parseEmbeddedResource*(node: JsonNode, context: string): McpEmbeddedResource =
  if node.isNil or node.kind != JObject:
    raise newException(McpProtocolError, context & ": the resource is not an object")
  McpEmbeddedResource(
    uri: requiredString(node, "uri", context),
    mimeType: node{"mimeType"}.getStr(),
    text: optionalString(node, "text", context),
    blob: optionalString(node, "blob", context))

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
      linkTitle: optionalString(node, "title", context),
      linkDescription: optionalString(node, "description", context),
      linkMimeType: optionalString(node, "mimeType", context),
      linkSize: (if node.hasKey("size"): some(node["size"].getInt()) else: none(int)),
      linkIcons: iconsOf(node, context))
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
    if item.linkIcons.len > 0:
      result["icons"] = newJArray()
      for icon in item.linkIcons:
        result["icons"].add icon.toJson
  of mckUnknown: result = item.raw

proc parseNextCursor*(reply: JsonNode, context: string): Option[string] =
  optionalString(reply, "nextCursor", context)

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

proc originOf(url: Uri): string =
  ## scheme://host[:port] with the default port left out and case folded.
  let scheme = url.scheme.toLowerAscii
  let defaultPort = if scheme == "https": "443" else: ""
  result = scheme & "://" & url.hostname.toLowerAscii
  if url.port.len > 0 and url.port != defaultPort:
    result.add ":" & url.port

proc isSafeIconUri*(src: string, serverOrigin = ""): bool =
  ## Whether a client may fetch or show the icon at `src` (2025-11-25,
  ## basic/index, Icons: security considerations): an https URL or a base64
  ## image `data:` URI, never another scheme. When `serverOrigin` is given
  ## (`https://host[:port]`), an https icon must come from that origin.
  ## This screens the URI only; `fetchIcon` (client/icons) does the fetching
  ## the specification asks for.
  if src.toLowerAscii.startsWith("data:"):
    let header = src[5 .. ^1].split(',', maxsplit = 1)[0].toLowerAscii
    return header.startsWith("image/") and header.endsWith(";base64")
  let url = parseUri(src)
  if url.scheme.toLowerAscii != "https" or url.hostname.len == 0:
    return false
  serverOrigin.len == 0 or originOf(url) == originOf(parseUri(serverOrigin))

proc safeIcons*(icons: seq[McpIcon], serverOrigin = ""): seq[McpIcon] =
  ## The icons whose URI passes `isSafeIconUri`.
  for icon in icons:
    if isSafeIconUri(icon.src, serverOrigin):
      result.add icon
