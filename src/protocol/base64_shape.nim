## The shape of base64 text, checked before it is decoded.
##
## Text that reaches `std/base64.decode` from a peer is checked here first.
## The decoder skips characters outside the alphabet, and in Nim up to 2.2.8
## it read past the end of its input when it did (nim-lang/Nim#25530): four
## bytes from a peer, `"\rN0x"`, were an IndexDefect. Text of the shapes below
## has no such character in it, whatever compiler built the decoder.

import std/strutils

const Base64Alphabet = {'A'..'Z', 'a'..'z', '0'..'9', '+', '/'}

func bodyOf(text: string): string {.raises: [].} =
  text.strip(leading = false, chars = {'='})

func isPaddedBase64*(text: string): bool {.raises: [].} =
  ## RFC 4648 section 4 with its padding: whole groups of four, `=` only at
  ## the end and at most twice. What `base64.encode` writes.
  if text.len mod 4 != 0:
    return false
  let body = bodyOf(text)
  if text.len - body.len > 2:
    return false
  body.allCharsInSet(Base64Alphabet)

func isBase64Text*(text: string): bool {.raises: [].} =
  ## The alphabet of RFC 4648 section 4 and at most two `=` at the end, with
  ## or without the padding that completes the last group. What a data URI of
  ## another implementation may carry.
  let body = bodyOf(text)
  text.len - body.len <= 2 and body.allCharsInSet(Base64Alphabet)
