## What a client keeps between requests: tokens, and the client credentials
## an authorization server issued. Where they live is the application's
## decision, so both go through a `Store` it can replace; the default keeps
## them in memory only.

import std/[options, tables, times]

type
  TokenSet* = object
    accessToken*: string
    refreshToken*: Option[string]
    expiresAt*: Option[Time]
    scopes*: seq[string]
      ## What the server granted, or what was requested when it did not say.
    issuer*: string
      ## The authorization server that issued the tokens.

  ClientCredentials* = object
    ## A client's identity at one authorization server (RFC 6749 2.2: client
    ## identifiers are unique to the server that issued them).
    issuer*: string
    clientId*: string
    clientSecret*: Option[string]
    authMethod*: string
      ## "none", "client_secret_basic" or "client_secret_post".
    redirectUris*: seq[string]

  Store*[T] = object
    ## Persistence the application supplies. Keys are chosen by the client.
    load*: proc(key: string): Option[T] {.closure, gcsafe, raises: [].}
    save*: proc(key: string, value: T) {.closure, gcsafe, raises: [].}
    remove*: proc(key: string) {.closure, gcsafe, raises: [].}

  TokenStore* = Store[TokenSet]
  CredentialStore* = Store[ClientCredentials]

proc newMemoryStore*[T](): Store[T] =
  let entries = new(Table[string, T])
  entries[] = initTable[string, T]()
  Store[T](
    load: proc(key: string): Option[T] {.closure, gcsafe, raises: [].} =
      if entries[].hasKey(key): some(entries[].getOrDefault(key)) else: none(T),
    save: proc(key: string, value: T) {.closure, gcsafe, raises: [].} =
      entries[][key] = value,
    remove: proc(key: string) {.closure, gcsafe, raises: [].} =
      entries[].del(key))

func isExpired*(tokens: TokenSet, now: Time, skew = initDuration(seconds = 30)): bool
               {.raises: [].} =
  ## Whether the access token should not be sent any more. A token without
  ## an expiry is assumed valid; the server's 401 corrects that.
  tokens.expiresAt.isSome and tokens.expiresAt.get - skew <= now
