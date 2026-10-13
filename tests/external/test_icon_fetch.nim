## Fetching an icon (2025-11-25, basic/index, Icons: security considerations):
## no credentials, the server's origin only, a size limit, and the bytes
## against an allowlist by their magic bytes. There is no https server here:
## the fetch is pointed at a plain local one through `IconFetchOptions.get`,
## which only rewrites the address; everything else is the real code.

import std/[unittest, asyncdispatch, asynchttpserver, httpcore, base64,
            options, strutils, nativesockets]
import client/icons
import protocol/types

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

suite "fetching an icon":


  test "Given a fetch without the server's origin, when asked for a URL, then it is refused":
    discard startServer(Seen())
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
    # A data URI never reaches the network: the fetch runs with the default `get`.
    let uri = "data:image/png;base64," & encode(Png)
    check waitFor(fetchIcon(McpIcon(src: uri), Origin,
                            IconFetchOptions(maxBytes: Png.len))).kind == itPng
    var refusal = ""
    try:
      discard waitFor fetchIcon(McpIcon(src: uri), Origin,
                                IconFetchOptions(maxBytes: Png.len - 1))
    except McpIconError as e:
      refusal = e.msg
    check "exceeds" in refusal
