## URL rules shared by every OAuth exchange: which URLs may be fetched,
## where well-known documents live, and how a resource is named.

import std/[uri, strutils, options]
import ./errors

type
  FetchPolicy* = object
    ## What the client may fetch or send users to, when the URL came from
    ## the network (a `resource_metadata` parameter, a metadata document).
    allowLoopback*: bool
      ## Plain http to localhost, 127.0.0.1 and ::1. The specification
      ## allows localhost redirect URIs, and development servers use it.
    allowPrivateNetworks*: bool
      ## Literal addresses in 10/8, 172.16/12, 192.168/16, fc00::/7.
      ## Link-local addresses (cloud metadata services) are always refused.
    maxBodySize*: int
    timeoutMs*: int

func defaultFetchPolicy*(): FetchPolicy {.raises: [].} =
  FetchPolicy(allowLoopback: true, allowPrivateNetworks: false,
              maxBodySize: 256 * 1024, timeoutMs: 10_000)

type HostClass = enum hcName, hcLoopback, hcPrivate, hcLinkLocal, hcPublicAddress

func parseV4(host: string): Option[array[4, int]] {.raises: [].} =
  let parts = host.split('.')
  if parts.len != 4:
    return none(array[4, int])
  var octets: array[4, int]
  for i, p in parts:
    if p.len == 0 or p.len > 3 or not p.allCharsInSet(Digits):
      return none(array[4, int])
    octets[i] = (p[0].ord - '0'.ord)
    for c in p[1 .. ^1]:
      octets[i] = octets[i] * 10 + (c.ord - '0'.ord)
    if octets[i] > 255:
      return none(array[4, int])
  some(octets)

func classifyV4(o: array[4, int]): HostClass {.raises: [].} =
  if o[0] == 127: hcLoopback
  elif o[0] == 169 and o[1] == 254: hcLinkLocal
  elif o[0] == 10 or (o[0] == 172 and o[1] in 16 .. 31) or
       (o[0] == 192 and o[1] == 168) or o[0] == 0: hcPrivate
  else: hcPublicAddress

func classifyHost(rawHost: string): HostClass {.raises: [].} =
  ## `parseUri` leaves the brackets off IPv6 hosts.
  let host = rawHost.toLowerAscii()
  if host == "localhost":
    return hcLoopback
  let v4 = parseV4(host)
  if v4.isSome:
    return classifyV4(v4.get)
  if ':' in host:
    if host == "::1":
      return hcLoopback
    if host.startsWith("::ffff:"):
      let mapped = parseV4(host["::ffff:".len .. ^1])
      if mapped.isSome:
        return classifyV4(mapped.get)
    if host.startsWith("fe8") or host.startsWith("fe9") or
       host.startsWith("fea") or host.startsWith("feb"):
      return hcLinkLocal
    if host.startsWith("fc") or host.startsWith("fd"):
      return hcPrivate
    return hcPublicAddress
  hcName

func isLoopbackHost*(host: string): bool {.raises: [].} =
  classifyHost(host) == hcLoopback

proc checkFetchUrl*(url: string, policy: FetchPolicy, what: string) {.raises: [OAuthSecurityError].} =
  ## Refuses a URL this client should not request. `what` names the URL in
  ## the error ("authorization endpoint").
  var uri: Uri
  try:
    uri = parseUri(url)
  except CatchableError:
    raise newException(OAuthSecurityError, what & " is not a valid URL")
  if uri.hostname.len == 0 or uri.scheme.len == 0:
    raise newException(OAuthSecurityError, what & " is not an absolute URL: " & url)
  if uri.anchor.len > 0:
    raise newException(OAuthSecurityError, what & " has a fragment: " & url)
  if uri.username.len > 0 or uri.password.len > 0:
    raise newException(OAuthSecurityError, what & " carries credentials")
  let hostClass = classifyHost(uri.hostname)
  case uri.scheme.toLowerAscii()
  of "https":
    discard
  of "http":
    if not (policy.allowLoopback and hostClass == hcLoopback):
      raise newException(OAuthSecurityError,
        what & " must be https (http is accepted for loopback only): " & url)
  else:
    raise newException(OAuthSecurityError, what & " has an unsupported scheme: " & url)
  case hostClass
  of hcLinkLocal:
    raise newException(OAuthSecurityError, what & " names a link-local address: " & url)
  of hcPrivate:
    if not policy.allowPrivateNetworks:
      raise newException(OAuthSecurityError,
        what & " names a private network address: " & url)
  of hcLoopback:
    if not policy.allowLoopback:
      raise newException(OAuthSecurityError, what & " names a loopback address: " & url)
  of hcName, hcPublicAddress:
    discard

func originOf*(url: string): string {.raises: [].} =
  ## "https://host:port" of an absolute URL; "" when it has no host.
  let uri = parseUri(url)
  if uri.hostname.len == 0:
    return ""
  result = uri.scheme.toLowerAscii() & "://"
  result.add(if ':' in uri.hostname: "[" & uri.hostname & "]"
             else: uri.hostname.toLowerAscii())
  if uri.port.len > 0:
    result.add ":" & uri.port

func pathWithoutTrailingSlash(url: string): string {.raises: [].} =
  result = parseUri(url).path
  while result.len > 0 and result[^1] == '/':
    result.setLen(result.len - 1)

func wellKnownUrl*(identifier, suffix: string): string {.raises: [].} =
  ## RFC 8414 3.1 / RFC 9728 3.1: `/.well-known/<suffix>` goes between the
  ## host and the path of the identifier, and a trailing slash of the path is
  ## removed first.
  originOf(identifier) & "/.well-known/" & suffix & pathWithoutTrailingSlash(identifier)

func canonicalResource*(url: string): string {.raises: [OAuthError].} =
  ## The resource identifier of an MCP server as RFC 8707 2 and the MCP
  ## specification want it: absolute, no fragment, lowercase scheme and
  ## host, and no trailing slash on a bare origin.
  let uri =
    try: parseUri(url)
    except CatchableError: raise newException(OAuthError, "not a valid URL: " & url)
  if uri.scheme.len == 0 or uri.hostname.len == 0:
    raise newException(OAuthError, "resource must be an absolute URL with a host: " & url)
  if uri.anchor.len > 0:
    raise newException(OAuthError, "resource must not contain a fragment: " & url)
  result = originOf(url)
  if uri.path.len > 0 and uri.path != "/":
    result.add uri.path
  if uri.query.len > 0:
    result.add "?" & uri.query

func formEncode*(fields: openArray[(string, string)]): string {.raises: [].} =
  ## application/x-www-form-urlencoded with %20 for spaces.
  encodeQuery(fields, usePlus = false)

proc formDecode*(query: string): seq[(string, string)] {.raises: [].} =
  for (k, v) in decodeQuery(query):
    result.add (k, v)

proc queryOf*(url: string): seq[(string, string)] {.raises: [].} =
  formDecode(parseUri(url).query)
