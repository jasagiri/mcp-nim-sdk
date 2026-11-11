## UTF-8 as RFC 3629 section 4 has it.
##
## `std/unicode.validateUtf8` checks the layout of a sequence (a lead byte
## and its continuation bytes) and one overlong form, C0 and C1. It lets
## through the overlong forms of three and four bytes (E0 80..9F, F0 80..8F),
## the surrogates (ED A0..BF), and what lies above U+10FFFF (F4 90.., F5..F7).
## Seen on Nim 2.2.12 and 2.2.14.
##
## Delete this module, and call `validateUtf8` again, once the oldest Nim this
## package builds with has a `validateUtf8` that refuses those sequences.
## TODO: propose that to nim-lang/Nim; no fix exists upstream yet.

func utf8Width*(text: string, at: Natural): int {.raises: [].} =
  ## The number of bytes of the character that starts at `text[at]`, or 0
  ## when no well-formed UTF-8 sequence starts there.
  if at >= text.len:
    return 0
  let lead = text[at].ord
  var width: int
  var second = 0x80 .. 0xBF     # what the byte after the lead may be
  case lead
  of 0x00 .. 0x7F: return 1
  of 0xC2 .. 0xDF: width = 2
  of 0xE0: width = 3; second = 0xA0 .. 0xBF
  of 0xED: width = 3; second = 0x80 .. 0x9F
  of 0xE1 .. 0xEC, 0xEE .. 0xEF: width = 3
  of 0xF0: width = 4; second = 0x90 .. 0xBF
  of 0xF1 .. 0xF3: width = 4
  of 0xF4: width = 4; second = 0x80 .. 0x8F
  else: return 0
  if at + width > text.len or text[at + 1].ord notin second:
    return 0
  for i in at + 2 ..< at + width:
    if text[i].ord notin 0x80 .. 0xBF:
      return 0
  width

func isUtf8*(text: string): bool {.raises: [].} =
  ## Whether `text` is well-formed UTF-8 from its first byte to its last.
  var i = 0
  while i < text.len:
    let width = utf8Width(text, i)
    if width == 0:
      return false
    i += width
  true
