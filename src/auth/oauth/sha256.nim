## SHA-256 for PKCE's S256 method and the digests the SDK and its extensions
## name; `Sha256Digest` is also what protocol/hmac returns. The standard
## library has no SHA-256, so nimcrypto computes it; this module is the one
## place the SDK names it.

import nimcrypto/[hash, sha2]

type Sha256Digest* = array[32, byte]

proc sha256*(data: openArray[byte]): Sha256Digest {.raises: [].} =
  sha2.sha256.digest(data).data

proc sha256*(data: string): Sha256Digest {.raises: [].} =
  sha2.sha256.digest(data.toOpenArrayByte(0, data.high)).data

func toHex*(digest: Sha256Digest): string {.raises: [].} =
  const digits = "0123456789abcdef"
  for b in digest:
    result.add digits[b shr 4]
    result.add digits[b and 0x0f]
