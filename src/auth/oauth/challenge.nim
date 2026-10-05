## `WWW-Authenticate` challenges (RFC 9110 11.6.1, RFC 6750 3, RFC 9728 5.1).

import std/[options, strutils]

type
  AuthChallenge* = object
    scheme*: string
    params*: seq[(string, string)]
      ## Parameter names are lower-cased; values are unquoted.

  BearerChallenge* = object
    ## The parameters of a Bearer challenge that matter to an OAuth client.
    resourceMetadata*: Option[string]
    scope*: Option[string]
    error*: Option[string]
    errorDescription*: Option[string]
    realm*: Option[string]

const TokenChars = {'A'..'Z', 'a'..'z', '0'..'9', '!', '#', '$', '%', '&', '\'',
                    '*', '+', '-', '.', '^', '_', '`', '|', '~'}

func param*(c: AuthChallenge, name: string): Option[string] {.raises: [].} =
  for (k, v) in c.params:
    if k == name:
      return some(v)
  none(string)

func parseChallenges*(header: string): seq[AuthChallenge] {.raises: [].} =
  ## Every challenge in one header value. Input that does not parse yields
  ## whatever challenges came before the problem.
  var i = 0
  template skipSeparators() =
    while i < header.len and header[i] in {' ', '\t', ','}:
      inc i
  template readToken(): string =
    let start = i
    while i < header.len and header[i] in TokenChars:
      inc i
    header[start ..< i]
  while true:
    skipSeparators()
    if i >= header.len:
      break
    let word = readToken()
    if word.len == 0:
      inc i  # a stray character; move on rather than loop forever
      continue
    while i < header.len and header[i] in {' ', '\t'}:
      inc i
    if i < header.len and header[i] == '=' and result.len > 0:
      inc i
      if i < header.len and header[i] == '=':
        # token68 padding ("Basic YWJj=="), not a parameter
        while i < header.len and header[i] == '=':
          inc i
        continue
      while i < header.len and header[i] in {' ', '\t'}:
        inc i
      var value = ""
      if i < header.len and header[i] == '"':
        inc i
        while i < header.len and header[i] != '"':
          if header[i] == '\\' and i + 1 < header.len:
            inc i
          value.add header[i]
          inc i
        inc i  # the closing quote
      else:
        value = readToken()
      result[^1].params.add (word.toLowerAscii(), value)
    else:
      result.add AuthChallenge(scheme: word)

func bearerChallenge*(headers: openArray[string]): Option[BearerChallenge] {.raises: [].} =
  ## The first Bearer challenge among the values of the `WWW-Authenticate`
  ## header lines of a response.
  for header in headers:
    for challenge in parseChallenges(header):
      if challenge.scheme.toLowerAscii() == "bearer":
        return some(BearerChallenge(
          resourceMetadata: challenge.param("resource_metadata"),
          scope: challenge.param("scope"),
          error: challenge.param("error"),
          errorDescription: challenge.param("error_description"),
          realm: challenge.param("realm")))
  none(BearerChallenge)

func formatBearerChallenge*(params: openArray[(string, string)]): string {.raises: [ValueError].} =
  ## `Bearer name="value", ...`. A value with a control character is
  ## refused: it could split the header.
  result = "Bearer"
  var first = true
  for (name, value) in params:
    for c in name & value:
      if c < ' ' or c == '\x7f':
        raise newException(ValueError, "control character in WWW-Authenticate parameter " & name)
    result.add(if first: " " else: ", ")
    first = false
    result.add name & "=\"" & value.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
