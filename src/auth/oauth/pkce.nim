## PKCE (RFC 7636) and the random values an authorization request needs.

import std/[base64, sysrand, strutils]
import ./sha256

const
  VerifierBytes = 32
    ## 32 random bytes encode to 43 characters, the minimum RFC 7636 allows;
    ## 256 bits are as much as the S256 hash can carry.

func base64UrlNoPad*(bytes: openArray[byte]): string {.raises: [].} =
  result = base64.encode(bytes, safe = true)
  result.removeSuffix('=')

proc randomUrlToken*(byteCount = 32): string {.raises: [OSError].} =
  ## An unguessable string for `state`, `nonce` and the like.
  base64UrlNoPad(urandom(byteCount))

proc newCodeVerifier*(): string {.raises: [OSError].} =
  base64UrlNoPad(urandom(VerifierBytes))

func codeChallengeS256*(verifier: string): string {.raises: [].} =
  base64UrlNoPad(sha256(verifier))
