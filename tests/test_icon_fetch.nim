## Fetching an icon (2025-11-25, basic/index, Icons: security considerations):
## no credentials, the server's origin only, a size limit, and the bytes
## against an allowlist by their magic bytes. There is no https server here:
## the fetch is pointed at a plain local one through `IconFetchOptions.get`,
## which only rewrites the address; everything else is the real code.

import std/[unittest, asyncdispatch, asynchttpserver, httpcore, base64,
            options, strutils, nativesockets]
import client/icons
import protocol/types
import transport/http_wire as wire

const
  Png = "\x89PNG\r\n\x1a\n" & "rest of a png"
  Jpeg = "\xFF\xD8\xFF\xE0" & "rest of a jpeg"
  Webp = "RIFF\x00\x00\x00\x00WEBPVP8 "
  Svg = "<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>"
  Origin = "https://icons.example"

type Seen = ref object
  headers: seq[HttpHeaders]

proc startServer(seen: Seen, otherPort: int = 0): int =
  let server = newAsyncHttpServer()
  server.listen(Port(0))
  let port = int(server.getPort)
  proc handler(req: Request) {.async, gcsafe.} =
    {.gcsafe.}:
      seen.headers.add req.headers
    case req.url.path
    of "/icon.png": await req.respond(Http200, Png, newHttpHeaders({"Content-Type": "image/png"}))
    of "/icon.jpg": await req.respond(Http200, Jpeg, newHttpHeaders({"Content-Type": "image/jpg"}))
    of "/icon.webp": await req.respond(Http200, Webp, newHttpHeaders({"Content-Type": "image/webp"}))
    of "/icon.svg": await req.respond(Http200, Svg, newHttpHeaders({"Content-Type": "image/svg+xml"}))
    of "/lies.png": await req.respond(Http200, Jpeg, newHttpHeaders({"Content-Type": "image/png"}))
    of "/generic.png": await req.respond(Http200, Png, newHttpHeaders({"Content-Type": "application/octet-stream"}))
    of "/unknown": await req.respond(Http200, "GIF89a....", newHttpHeaders({"Content-Type": "image/gif"}))
    of "/text": await req.respond(Http200, "hello", newHttpHeaders({"Content-Type": "text/plain"}))
    of "/big.png": await req.respond(Http200, Png & repeat('x', 5000), newHttpHeaders({"Content-Type": "image/png"}))
    of "/missing": await req.respond(Http404, "no", newHttpHeaders())
    of "/hop": await req.respond(Http302, "", newHttpHeaders({"Location": "/icon.png"}))
    of "/away": await req.respond(Http302, "", newHttpHeaders({"Location": "http://127.0.0.2:1/icon.png"}))
    else: await req.respond(Http404, "", newHttpHeaders())
  asyncCheck server.serve(Port(port), handler, address = "127.0.0.1")
  port

proc local(port: int): IconGet =
  ## Asks the local server for what the https URL names.
  result = proc(url: string, headers: HttpHeaders): Future[WireResponse] =
    wire.request("http://127.0.0.1:" & $port & url[Origin.len .. ^1], HttpGet, headers)

proc fetch(port: int, src: string, mime = none(string),
           options = IconFetchOptions()): McpFetchedIcon =
  var chosen = options
  chosen.get = local(port)
  waitFor fetchIcon(McpIcon(src: src, mimeType: mime), Origin, chosen)

proc refused(port: int, src: string, mime = none(string),
             options = IconFetchOptions()): string =
  try:
    discard port.fetch(src, mime, options)
  except McpIconError as e:
    return e.msg
  ""

suite "fetching an icon":
  test "Given an icon of an allowed type, when fetched, then the bytes and the type found in them are returned":
    let seen = Seen()
    let port = startServer(seen)
    let png = port.fetch(Origin & "/icon.png")
    check png.kind == itPng
    check png.bytes == Png
    check port.fetch(Origin & "/icon.jpg").kind == itJpeg   # image/jpg is jpeg
    check port.fetch(Origin & "/icon.webp").kind == itWebp

  test "Given a fetch, when the request goes out, then it carries no credentials":
    let seen = Seen()
    let port = startServer(seen)
    discard port.fetch(Origin & "/icon.png")
    check seen.headers.len == 1
    for name in ["Authorization", "Cookie", "Proxy-Authorization"]:
      check not seen.headers[0].hasKey(name)

  test "Given an icon whose Content-Type disagrees with its bytes, when fetched, then it is refused":
    let port = startServer(Seen())
    check "image/png" in port.refused(Origin & "/lies.png")

  test "Given a generic Content-Type, when the icon's own mimeType disagrees with the bytes, then it is refused; when it agrees, accepted":
    let port = startServer(Seen())
    check "image/jpeg" in port.refused(Origin & "/generic.png", some("image/jpeg"))
    check port.fetch(Origin & "/generic.png", some("image/png")).kind == itPng
    check port.fetch(Origin & "/generic.png").kind == itPng

  test "Given bytes of no allowed image type, when fetched, then they are refused whatever the type says":
    let port = startServer(Seen())
    check port.refused(Origin & "/unknown").len > 0
    check port.refused(Origin & "/text").len > 0

  test "Given an SVG, when fetched, then it is refused unless the caller allows it":
    let port = startServer(Seen())
    check "not allowed" in port.refused(Origin & "/icon.svg")
    check port.fetch(Origin & "/icon.svg", options = IconFetchOptions(
      allowed: {itPng, itSvg})).kind == itSvg

  test "Given a body over the limit, when fetched, then it is refused":
    let port = startServer(Seen())
    check port.refused(Origin & "/big.png", options = IconFetchOptions(maxBytes: 1024)).len > 0
    check port.fetch(Origin & "/big.png", options = IconFetchOptions(maxBytes: 10_000)).kind == itPng

  test "Given an answer other than 200, when fetched, then it is refused":
    let port = startServer(Seen())
    check "404" in port.refused(Origin & "/missing")

  test "Given a redirect inside the origin, when fetched, then it is followed; to another origin, refused":
    let port = startServer(Seen())
    check port.fetch(Origin & "/hop").kind == itPng
    check "another server" in port.refused(Origin & "/away")

  test "Given an icon of another origin or scheme, when fetched, then nothing is sent":
    let seen = Seen()
    let port = startServer(seen)
    check port.refused("https://evil.example/icon.png").len > 0
    check port.refused("http://icons.example/icon.png").len > 0
    check port.refused("file:///etc/passwd").len > 0
    check seen.headers.len == 0

  test "Given a data URI, when fetched, then the bytes are checked like any others":
    let port = startServer(Seen())
    check port.fetch("data:image/png;base64," & encode(Png)).kind == itPng
    check port.refused("data:image/png;base64," & encode(Jpeg)).len > 0
    check port.refused("data:text/html;base64," & encode("<script>")).len > 0
    check port.refused("data:image/png;base64,@@@").len > 0

  test "Given a data URI whose data is not base64, when fetched, then it is refused":
    # The first made std/base64.decode of Nim 2.2.8 read past the end of its
    # input (nim-lang/Nim#25530). The others carry white space, which a data
    # URI does not.
    let port = startServer(Seen())
    let png = encode(Png)
    check port.refused("data:image/png;base64,\rN0x").len > 0
    check port.refused("data:image/png;base64, " & png).len > 0
    check port.refused("data:image/png;base64," & png & "\n").len > 0
    check port.refused("data:image/png;base64," & png[0 .. 3] & "\n" & png[4 .. ^1]).len > 0

  test "Given a data URI whose base64 has no padding, when fetched, then the icon is read":
    let port = startServer(Seen())
    check port.fetch("data:image/png;base64," & encode(Png).strip(leading = false, chars = {'='})).kind == itPng

  test "Given a fetch without the server's origin, when asked for a URL, then it is refused":
    let port = startServer(Seen())
    var failed = false
    try:
      discard waitFor fetchIcon(McpIcon(src: Origin & "/icon.png"), "")
    except McpIconError:
      failed = true
    check failed

suite "fetching an icon (mutation review, g2f-ap-a)":
  test "Given nothing but the signature of an image type, when sniffed, then the type is the one the signature says":
    check sniffIcon("\x89PNG\r\n\x1a\n") == some(itPng)
    check sniffIcon("\xFF\xD8\xFF") == some(itJpeg)
    check sniffIcon("RIFF\x00\x00\x00\x00WEBP") == some(itWebp)

  test "Given a signature cut short, when sniffed, then there is no type":
    check sniffIcon("\x89PNG\r\n\x1a").isNone
    check sniffIcon("\xFF\xD8").isNone
    check sniffIcon("RIFF\x00\x00\x00\x00WEB").isNone
    check sniffIcon("").isNone

  test "Given markup that opens with a comment or a doctype, when it holds an svg element, then it is an SVG":
    check sniffIcon("<!-- an icon --><svg xmlns=\"http://www.w3.org/2000/svg\"/>") == some(itSvg)
    check sniffIcon("<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\"><svg/>") == some(itSvg)
    check sniffIcon("\xEF\xBB\xBF \n<svg/>") == some(itSvg)

  test "Given markup that holds no svg element at its start, when sniffed, then it is not an SVG":
    check sniffIcon("<?xml version=\"1.0\"?><rss version=\"2.0\"/>").isNone
    check sniffIcon("<html><body><svg/></body></html>").isNone
    check sniffIcon("<!-- a page --><html/>").isNone

  test "Given a data URI icon of exactly the allowed size, when fetched, then it is read; one byte more, refused":
    let port = startServer(Seen())
    let uri = "data:image/png;base64," & encode(Png)
    check port.fetch(uri, options = IconFetchOptions(maxBytes: Png.len)).kind == itPng
    check "exceeds" in port.refused(uri, options = IconFetchOptions(maxBytes: Png.len - 1))
