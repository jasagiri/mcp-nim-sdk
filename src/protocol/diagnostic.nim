## Text that a peer chose, made fit for a diagnostic line on stderr.
##
## A peer decides what a request id, a method name, a cancellation reason or
## an error message says. Written as it came, it can end the log line and
## start a forged one (CR, LF), rewrite what an operator's terminal shows
## (ESC and the other C0 and C1 controls, the Unicode line separators and
## bidirectional overrides), or fill the log (any length).

import std/[strutils, unicode]
import ../compat/utf8

const DefaultPeerTextLength* = 200
  ## Bytes of peer text kept in one diagnostic: enough for an identifier or a
  ## sentence, short enough that no single message fills a log.

func isUnsafe(r: Rune): bool =
  let c = r.int
  c < 0x20 or c in 0x7F .. 0x9F or c in 0x2028 .. 0x2029 or
    c in 0x202A .. 0x202E or c in 0x2066 .. 0x2069 or c in 0x200E .. 0x200F or
    c == 0x061C

func peerText*(text: string, maxLen = DefaultPeerTextLength): string {.raises: [].} =
  ## `text` with control characters shown as escapes (`\n`, `\x1b`,
  ## `\u{202e}`), bytes that are not valid UTF-8 as `\xNN`, and cut to
  ## `maxLen` bytes at a character boundary, with the number of bytes left
  ## out noted.
  var i = 0
  while i < text.len:
    if result.len >= maxLen:
      result.add "...(" & $(text.len - i) & " more bytes)"
      return
    let byte = text[i].ord
    if byte < 0x80:
      case text[i]
      of '\n': result.add "\\n"
      of '\r': result.add "\\r"
      of '\t': result.add "\\t"
      of '\\': result.add "\\\\"
      of '\0' .. '\x08', '\x0b', '\x0c', '\x0e' .. '\x1f', '\x7f':
        result.add "\\x" & toHex(byte, 2).toLowerAscii()
      else: result.add text[i]
      inc i
      continue
    # A multi-byte sequence: valid only if it is a whole character.
    let width = utf8Width(text, i)
    if width == 0:
      result.add "\\x" & toHex(byte, 2).toLowerAscii()
      inc i
      continue
    var r: Rune
    fastRuneAt(text, i, r, doInc = false)
    if r.isUnsafe:
      result.add "\\u{" & toHex(r.int, 4).toLowerAscii() & "}"
    else:
      result.add text[i ..< i + width]
    i += width

func plainMessage*(e: ref CatchableError): string =
  ## The message the raiser wrote. A debug build of asyncdispatch appends
  ## "Async traceback:" to the message of an exception that passed through a
  ## future. That text is for the log, never for the peer, and it would
  ## swallow every failure joined after it.
  e.msg.split("\nAsync traceback:")[0]

