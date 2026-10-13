## An SVG icon can carry script. What the client does about it, said as a
## property over markup that opens in every way the specification allows:
## it does not fetch one unless the application says it can handle SVG, then
## hands the bytes over untouched, and never lets a label of another type
## get SVG through. Every icon is a data URI, so nothing reaches the network.

import std/[unittest, asyncdispatch, base64, strutils]
import client/icons
import protocol/types
import propcheck

proc guarded[T](body: proc(x: T): bool): Property[T] =
  ## A property whose body may raise what the SDK's setup raises: anything it raises
  ## is a counterexample, named by its type and message.
  result = proc(x: T): bool {.raises: [CatchableError].} =
    try:
      body(x)
    except CatchableError:
      raise
    except Exception as e:
      raise newException(CatchableError, "raised " & $e.name & ": " & e.msg)

const Origin = "https://icons.example"

type
  Icon = object
    markup: string
    label: string          ## the type the data URI says
    svgAllowed: bool       ## the application says it can handle SVG

proc dataUri(mime, body: string): string =
  "data:" & mime & ";base64," & encode(body)

proc refusal(icon: McpIcon, options: IconFetchOptions): string =
  ## Why the fetch was refused; empty when it was not.
  try:
    discard waitFor fetchIcon(icon, Origin, options)
  except McpIconError as e:
    return e.msg

let
  # Space: SVG that opens with, in the order XML allows, a byte order mark, an XML declaration,
  # a comment, a doctype and another comment, each there or not, with white space between or not,
  # then the root element with an attribute and a script or text inside, written in capitals or not;
  # labelled as SVG or as another image type; with SVG allowed by the application or not.
  anyIcon = map(
    pair(pair(seqOf(boolean(), 6, 6), pair(boolean(), boolean())),
         pair(stringOf("abc xyz", 0, 8), pair(intIn(0, 4), boolean()))),
    proc(x: ((seq[bool], (bool, bool)), (string, (int, bool)))): Icon {.raises: [].} =
      let flags = x[0][0]
      let text = x[1][0]
      var markup = ""
      if flags[0]: markup.add "\xEF\xBB\xBF"
      if flags[1]: markup.add "<?xml version=\"1.0\"?>"
      if flags[5]: markup.add " \n"
      if flags[2]: markup.add "<!-- " & text & " -->"
      if flags[3]: markup.add "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\">"
      if flags[4]: markup.add "\t"
      markup.add "<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"" & text & "\">" &
                 (if x[1][1][1]: "<script>" & text & "</script>" else: text) & "</svg>"
      if x[0][1][0]: markup = markup.toUpperAscii()
      Icon(markup: markup,
           label: ["image/svg+xml", "image/png", "image/jpeg", "image/webp", "application/octet-stream"][x[1][1][0]],
           svgAllowed: x[0][1][1]))

suite "An SVG icon":

  test "Given any SVG icon however its markup opens, when it is fetched, then it is refused naming image/svg+xml unless SVG is allowed, then its bytes come back as they are with the type SVG, and a label of another type gets it through in neither case":
    let outcome = propcheck.check(anyIcon,
      guarded(proc(i: Icon): bool =
        let options = if i.svgAllowed: IconFetchOptions(allowed: {itPng, itJpeg, itWebp, itSvg})
                      else: IconFetchOptions()
        let icon = McpIcon(src: dataUri(i.label, i.markup))
        if i.label != "image/svg+xml":
          return refusal(icon, options).len > 0
        if i.svgAllowed:
          let fetched = waitFor fetchIcon(icon, Origin, options)
          fetched.kind == itSvg and fetched.bytes == i.markup
        else:
          "image/svg+xml" in refusal(icon, options)))
    checkpoint describe(outcome)
    check outcome.passed
