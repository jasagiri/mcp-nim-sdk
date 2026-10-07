## The shapes of base64 text that may reach the decoder.

import std/[unittest, base64, random, strutils]
import protocol/base64_shape

const Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

proc anyBytes(r: var Rand, most: int): string =
  for _ in 0 ..< r.rand(0 .. most):
    result.add char(r.rand(0 .. 255))

proc nearBase64(r: var Rand): string =
  ## Base64 with, most of the time, one byte of it replaced by any byte.
  result = encode(anyBytes(r, 18))
  if result.len > 0 and r.rand(3) > 0:
    result[r.rand(result.high)] = char(r.rand(0 .. 255))
  if r.rand(4) == 0:
    result = result.strip(leading = false, chars = {'='})

suite "the shape of base64 text":

  test "Given what base64.encode writes, when its shape is checked, then it is padded base64":
    var r = initRand(20261007)
    for _ in 1 .. 2000:
      let text = encode(anyBytes(r, 40))
      check isPaddedBase64(text)
      check isBase64Text(text)

  test "Given padded base64 without its padding, when its shape is checked, then it is base64 text and not padded base64":
    check isBase64Text("b2Zmc2V0OjE")
    check not isPaddedBase64("b2Zmc2V0OjE")
    check decode("b2Zmc2V0OjE") == "offset:1"

  test "Given a character outside the alphabet, when the shape is checked, then it is neither":
    for bad in ["\rN0x", " AAAA", "AAAA ", "AA\nAA", "AA-A", "AA_A", "AAA\x00", "A=AA", "=AAA"]:
      check not isPaddedBase64(bad)
      check not isBase64Text(bad)

  test "Given more than two pad characters, when the shape is checked, then it is neither":
    check not isPaddedBase64("A===")
    check not isBase64Text("A===")
    check not isBase64Text("AAAA====")

  test "Given the empty text, when the shape is checked, then it is both":
    check isPaddedBase64("")
    check isBase64Text("")

  test "Given text of either shape, when it is decoded, then the decoder raises nothing but ValueError":
    # The claim the callers rely on. `"\rN0x"` and its like, which Nim 2.2.8
    # answers with an IndexDefect, are among what `nearBase64` makes; none of
    # them has the shape.
    var r = initRand(25530)
    var shaped, refused = 0
    for _ in 1 .. 200_000:
      let text = if r.rand(1) == 0: nearBase64(r) else: anyBytes(r, 12)
      if not isBase64Text(text):
        check not isPaddedBase64(text)
        inc refused
        continue
      inc shaped
      try:
        discard decode(text)
      except ValueError:
        discard
    check shaped > 10_000
    check refused > 10_000
