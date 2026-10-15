## HMAC-SHA256 against the test vectors of RFC 4231 section 4.

import std/[unittest, strutils]
import auth/oauth/sha256
import protocol/hmac

func bytesText(first, last: int): string =
  for b in first .. last:
    result.add char(b)

suite "HMAC-SHA256 (RFC 4231)":
  test "Given test case 1, when the MAC is computed, then it is the RFC 4231 value":
    check hmacSha256(repeat('\x0b', 20), "Hi There").toHex ==
      "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"

  test "Given test case 2 (a key shorter than the output), when the MAC is computed, then it is the RFC 4231 value":
    check hmacSha256("Jefe", "what do ya want for nothing?").toHex ==
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"

  test "Given test case 3 (50 bytes of 0xdd), when the MAC is computed, then it is the RFC 4231 value":
    check hmacSha256(repeat('\xaa', 20), repeat('\xdd', 50)).toHex ==
      "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"

  test "Given test case 4 (a 25-byte key), when the MAC is computed, then it is the RFC 4231 value":
    check hmacSha256(bytesText(0x01, 0x19), repeat('\xcd', 50)).toHex ==
      "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"

  test "Given test case 5, when the MAC is computed, then its first 128 bits are the RFC 4231 value":
    check hmacSha256(repeat('\x0c', 20), "Test With Truncation").toHex[0 ..< 32] ==
      "a3b6167473100ee06e0c796c2955552b"

  test "Given test case 6 (a key longer than the block), when the MAC is computed, then the key is hashed first":
    check hmacSha256(repeat('\xaa', 131),
                     "Test Using Larger Than Block-Size Key - Hash Key First").toHex ==
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"

  test "Given test case 7 (a key and data longer than the block), when the MAC is computed, then it is the RFC 4231 value":
    check hmacSha256(repeat('\xaa', 131),
                     "This is a test using a larger than block-size key and a larger " &
                     "than block-size data. The key needs to be hashed before being " &
                     "used by the HMAC algorithm.").toHex ==
      "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"
