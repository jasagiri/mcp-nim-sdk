## The token endpoint requests the authorization extensions are built from,
## and the JWTs they carry (src/auth/oauth/jwt.nim and grants.nim). Nothing
## here is MCP: a fake token endpoint that authenticates clients strictly.

import std/unittest
import ext/auth_client_credentials

suite "JWTs":

  test "Given the algorithm none or an empty signer, when a signer is made, then it is refused":
    let nothing = proc(input: string): string {.closure, gcsafe, raises: [].} = "x"
    expect ValueError:
      discard newJwtSigner("none", nothing)
    expect ValueError:
      discard newJwtSigner("NoNe", nothing)
    expect ValueError:
      discard newJwtSigner("", nothing)
    expect ValueError:
      discard newJwtSigner("RS256", nil)
