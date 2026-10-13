## Sealed request state (2026-07-28): what the server does with a state whose
## signature is valid but whose body is not what it seals. A state like that
## can only be made with the signing primitive, which is not a public entry.

import std/[unittest, base64, options]
import server/request_state
import protocol/hmac

const
  Key = "0123456789abcdef-secret-key"

proc signedBy(key, body: string): string =
  ## A state with an arbitrary body and a valid signature, as only the key's
  ## holder could make it.
  body & "." & base64.encode(hmacSha256(key, body), safe = true)

suite "sealed request state":

  test "Given a state that has no signature part, an empty body or a body that is not what the server seals, when verified, then it is malformed and never accepted":
    for state in ["", "nodot", ".abc", signedBy(Key, "@@@@"),
                  signedBy(Key, base64.encode("not json", safe = true)),
                  signedBy(Key, base64.encode("[1]", safe = true))]:
      check verifyRequestState(Key, state, "tools/call").problem == some("malformed")
