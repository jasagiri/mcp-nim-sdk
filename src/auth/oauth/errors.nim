## Errors of the OAuth client and resource-server helpers.
##
## Messages never contain tokens, authorization codes, code verifiers or
## client secrets: they end up in logs.

import std/strutils

type
  OAuthError* = object of CatchableError
    ## Something failed during an OAuth exchange (network, malformed
    ## metadata, a refused request).

  OAuthSecurityError* = object of OAuthError
    ## A check that protects the user failed: an insecure URL, a `state` or
    ## `iss` mismatch, a metadata document that names another issuer. The
    ## exchange has to stop; retrying with the same input cannot help.

  OAuthServerError* = object of OAuthError
    ## The authorization server answered with an OAuth error response
    ## (RFC 6749 5.2).
    error*: string
      ## e.g. "invalid_grant"
    description*: string

func plainMessage*(e: ref CatchableError): string =
  ## The message the raiser wrote. A debug build of asyncdispatch appends
  ## "Async traceback:" to the message of an exception that passed through a
  ## future, and that text would swallow every failure joined after it.
  e.msg.split("\nAsync traceback:")[0]
