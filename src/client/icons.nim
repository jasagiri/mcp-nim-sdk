## Fetching an icon (2025-11-25, basic/index, Icons: security considerations).
##
## `safeIcons` in `content` screens the URIs. This module does what the
## specification asks of the one who then fetches: the icon is fetched
## without credentials, from the origin of the server only, with redirects
## that stay on that origin, within a size limit, and its bytes are checked
## against a strict allowlist of image types by their magic bytes, the MIME
## type being advisory.
##
## What is not done: limits on dimensions or frames ("MAY set limits"), which
## need an image decoder, and sanitizing SVG. SVG can carry script, so it is
## not allowed unless the caller adds `itSvg` to `allowed`, and it is then
## returned as bytes for the caller to sanitize or render in isolation. That
## SVG is off by default is this module's choice: the specification only
## says consumers MAY disallow file types.

import std/[asyncdispatch, base64, httpcore, options, strutils, uri]
import ./client
import ./content
import ../protocol/base64_shape
import ../transport/transport
import ../transport/http_wire as wire
import ../transport/address_policy
export address_policy.HostResolver  # the type of `IconFetchOptions.resolver`
import ../transport/guarded_wire

type
  IconType* = enum
    itPng = "image/png"
    itJpeg = "image/jpeg"
    itWebp = "image/webp"
    itSvg = "image/svg+xml"

  McpIconError* = object of McpError
    ## The icon was not fetched, or what came back is not an icon this client
    ## accepts.

  McpFetchedIcon* = object
    kind*: IconType
      ## What the bytes are, as found in them, not as anyone said.
    bytes*: string

  IconGet* = proc(url: string, headers: HttpHeaders): Future[WireResponse] {.closure, gcsafe.}
    ## How the bytes are asked for: the GET of `wire.request` by default.
    ## Replaced in tests, which have no https server.

  IconFetchOptions* = object
    maxBytes*: int = 256 * 1024
    timeoutMs*: int = 10_000
    allowed*: set[IconType] = {itPng, itJpeg, itWebp}
    get*: IconGet
    allowPrivateNetworks*: bool
      ## Fetch from a private network address when the server's name
      ## resolves to one. A server the user addressed by a private IP literal,
      ## or by a loopback address, may always have its icons fetched from
      ## there; a server addressed by a name that resolves to such an address
      ## has to be allowed here. Link-local and reserved addresses never are.
    resolver*: HostResolver
      ## How the server's name is resolved; nil: the system resolver.

func sniffIcon*(bytes: string): Option[IconType] =
  ## The image type the first bytes say, none for anything else.
  if bytes.len >= 8 and bytes[0 ..< 8] == "\x89PNG\r\n\x1a\n":
    return some(itPng)
  if bytes.len >= 3 and bytes[0 ..< 3] == "\xFF\xD8\xFF":
    return some(itJpeg)
  if bytes.len >= 12 and bytes[0 ..< 4] == "RIFF" and bytes[8 ..< 12] == "WEBP":
    return some(itWebp)
  let head = bytes[0 ..< min(bytes.len, 1024)].toLowerAscii.strip(trailing = false,
    chars = {' ', '\t', '\r', '\n', '\xEF', '\xBB', '\xBF'})
  if head.startsWith("<svg") or
     ((head.startsWith("<?xml") or head.startsWith("<!--") or head.startsWith("<!doctype")) and
      "<svg" in head):
    return some(itSvg)
  none(IconType)

func normalizedMime(mime: string): string =
  let base = mime.split(';')[0].strip().toLowerAscii()
  if base == "image/jpg": "image/jpeg" else: base

func isGeneric(mime: string): bool =
  mime in ["", "application/octet-stream", "binary/octet-stream"]

proc accepted(bytes, declared: string, options: IconFetchOptions): McpFetchedIcon =
  ## `declared` is advisory: bytes of a type that is not allowed, of no known
  ## type, or of another type than a declared one, are refused.
  if bytes.len == 0:
    raise newException(McpIconError, "the icon is empty")
  let found = sniffIcon(bytes)
  if found.isNone:
    raise newException(McpIconError, "the icon's bytes are not of a known image type")
  if found.get notin options.allowed:
    raise newException(McpIconError, "icons of type " & $found.get & " are not allowed")
  let said = normalizedMime(declared)
  if not said.isGeneric and said != $found.get:
    raise newException(McpIconError,
      "the icon says it is " & said & " but its bytes are " & $found.get)
  McpFetchedIcon(kind: found.get, bytes: bytes)

proc iconFromDataUri(src: string, options: IconFetchOptions): McpFetchedIcon =
  # isSafeIconUri has seen to `data:image/...;base64,`
  if src.len > options.maxBytes * 2 + 128:
    raise newException(McpIconError, "the icon exceeds " & $options.maxBytes & " bytes")
  let parts = src[5 .. ^1].split(',', maxsplit = 1)
  if parts.len != 2:
    raise newException(McpIconError, "the data URI has no data")
  if not isBase64Text(parts[1]):
    raise newException(McpIconError, "the data URI is not valid base64")
  var bytes: string
  try:
    bytes = decode(parts[1])
  except ValueError as e:
    raise newException(McpIconError, "the data URI is not valid base64: " & e.msg)
  if bytes.len > options.maxBytes:
    raise newException(McpIconError, "the icon exceeds " & $options.maxBytes & " bytes")
  accepted(bytes, parts[0].split(';')[0], options)

proc guardedGet(serverOrigin: string, options: IconFetchOptions): IconGet =
  ## The GET of `wire.request` to an address that `address_policy` allows. The
  ## server was chosen by the user, so what the user's own spelling of it
  ## says (loopback, private) stays allowed; what its name merely resolves to
  ## has to be public. The connection closes when it takes longer than the
  ## fetch is allowed to.
  let hostClass = classifyHost(parseUri(serverOrigin).hostname)
  let policy = DestinationPolicy(
    allowLoopback: hostClass == some(acLoopback),
    allowPrivateNetworks: options.allowPrivateNetworks or hostClass == some(acPrivate))
  let timeoutMs = options.timeoutMs
  let resolver = options.resolver
  result = proc(url: string, headers: HttpHeaders): Future[WireResponse] {.closure, gcsafe.} =
    guardedRequest(url, HttpGet, policy, resolver, headers, followRedirects = true,
                   connectTimeoutMs = timeoutMs, headerTimeoutMs = timeoutMs)

proc fetchIcon*(icon: McpIcon, serverOrigin: string,
                options: IconFetchOptions = IconFetchOptions()): Future[McpFetchedIcon] {.async.} =
  ## The bytes of `icon`, checked. `serverOrigin` is `https://host[:port]` of
  ## the server the icon belongs to: an https icon from another origin is
  ## refused, and a redirect that leaves the origin (or changes the scheme)
  ## fails. Nothing but an Accept header is sent: no cookies, no
  ## Authorization, none of the client's credentials. Raises McpIconError.
  let src = icon.src
  if src.toLowerAscii.startsWith("data:"):
    if not isSafeIconUri(src):
      raise newException(McpIconError, "only base64 image data URIs are accepted")
    return iconFromDataUri(src, options)
  if serverOrigin.len == 0:
    raise newException(McpIconError,
      "the origin of the server is needed to fetch an icon from a URL")
  if not isSafeIconUri(src, serverOrigin):
    raise newException(McpIconError,
      "the icon URI is not an https URI of " & serverOrigin)
  let headers = newHttpHeaders({"Accept": "image/png, image/jpeg, image/webp"})
  var fetcher: IconGet = options.get
  if fetcher.isNil:
    fetcher = guardedGet(serverOrigin, options)
  var response: WireResponse
  try:
    let asked = fetcher(src, headers)
    if not await asked.withTimeout(options.timeoutMs):
      # The request is still going on. Whatever it ends in, nobody will use
      # it: an answer that comes later is closed, a failure is already
      # reported here as the timeout.
      asked.addCallback(proc() =
        if asked.failed:
          discard asked.readError()
        else:
          asked.read().close())
      raise newException(McpIconError, "no answer within " & $options.timeoutMs & " ms")
    response = asked.read()
  except McpTransportError as e:
    raise newException(McpIconError, "the icon could not be fetched: " & e.msg)
  except AddressNotAllowed as e:
    raise newException(McpIconError, "the icon could not be fetched: " & e.msg)
  defer: response.close()
  if response.code != Http200:
    raise newException(McpIconError, "the icon was answered with " & $response.code)
  let declared = response.headers.getOrDefault("Content-Type")
  var bytes: string
  try:
    let reading = response.readAll(options.maxBytes)
    if not await reading.withTimeout(options.timeoutMs):
      raise newException(McpIconError, "the icon took longer than " & $options.timeoutMs & " ms")
    bytes = reading.read()
  except McpTransportError as e:
    raise newException(McpIconError, "the icon could not be read: " & e.msg)
  # The server's type, but where it is missing or generic the icon's own
  # (the specification: "if the server's type is missing or generic").
  let said = if normalizedMime(declared).isGeneric and icon.mimeType.isSome:
               icon.mimeType.get else: declared
  return accepted(bytes, said, options)
