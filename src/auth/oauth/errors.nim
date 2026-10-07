## Errors of the OAuth client and resource-server helpers.
##
## Messages never contain tokens, authorization codes, code verifiers or
## client secrets: they end up in logs.

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
