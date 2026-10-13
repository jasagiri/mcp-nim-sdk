## An SVG icon can carry script ("Consumers SHOULD take appropriate
## precautions when consuming SVGs", schema Icon.src of 2025-11-25 and
## 2026-07-28). What the client does about it: it does not fetch one unless
## the application says it can handle SVG, and then hands the bytes over
## untouched. Every icon here is a data URI, so nothing reaches the network.

import std/[unittest, asyncdispatch, base64, strutils]
import client/icons
import protocol/types

const
  Origin = "https://icons.example"
  Script = "<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"alert(1)\">" &
           "<script>alert(2)</script></svg>"
  Png = "\x89PNG\r\n\x1a\n" & "rest of a png"
  ## Every way the specification's markup can open: bare, after an XML
  ## declaration, a comment, a doctype, and after a byte order mark and space.
  Openings = [
    Script,
    "<?xml version=\"1.0\"?>" & Script,
    "<!-- an icon -->" & Script,
    "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\">" & Script,
    "\xEF\xBB\xBF \n" & Script,
    Script.toUpperAscii()]

proc dataUri(mime, body: string): string =
  "data:" & mime & ";base64," & encode(body)

proc refusal(icon: McpIcon, options = IconFetchOptions()): string =
  ## Why the fetch was refused; empty when it was not.
  try:
    discard waitFor fetchIcon(icon, Origin, options)
  except McpIconError as e:
    return e.msg

suite "An SVG icon":

  test "Given an application that allows SVG, when an SVG icon is fetched, then its bytes come back as they are, with the type SVG":
    let options = IconFetchOptions(allowed: {itPng, itSvg})
    for opening in Openings:
      let icon = waitFor fetchIcon(McpIcon(src: dataUri("image/svg+xml", opening)), Origin, options)
      check icon.kind == itSvg
      check icon.bytes == opening   # the script is still there: the application is told what it has

  test "Given an application that allows SVG, when a PNG is fetched, then it is still a PNG":
    let icon = waitFor fetchIcon(McpIcon(src: dataUri("image/png", Png)), Origin,
                                 IconFetchOptions(allowed: {itPng, itSvg}))
    check icon.kind == itPng
