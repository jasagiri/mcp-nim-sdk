## SHA-256 against the FIPS 180-4 / RFC 6234 test vectors.

import std/[unittest, strutils]
import auth/oauth/sha256

suite "SHA-256":
  test "Given the empty message, when hashed, then it is the FIPS 180-4 empty digest":
    check sha256("").toHex ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  test "Given 'abc', when hashed, then it is the FIPS 180-4 one-block vector":
    check sha256("abc").toHex ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  test "Given the 448-bit message, when hashed, then it is the two-block vector":
    check sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq").toHex ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

  test "Given the 896-bit message, when hashed, then it is the long vector":
    check sha256("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn" &
                 "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu").toHex ==
      "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"

  test "Given one million 'a', when hashed, then it is the RFC 6234 million-a vector":
    check sha256('a'.repeat(1_000_000)).toHex ==
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

  test "Given messages around the padding boundaries, when hashed, then each differs and has the right length":
    # 55, 56 and 64 bytes exercise one, two and two blocks of padding.
    check sha256('a'.repeat(55)).toHex ==
      "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
    check sha256('a'.repeat(56)).toHex ==
      "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
    check sha256('a'.repeat(64)).toHex ==
      "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
