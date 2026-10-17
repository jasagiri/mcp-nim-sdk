## URL rules shared by every OAuth exchange: which URLs may be fetched,
## where well-known documents live, and how a resource is named.

import std/[uri, strutils, options]
import ./errors
import ../../transport/address_policy

export address_policy.HostResolver

type
  FetchPolicy* = object
    ## What the client may fetch or send users to, when the URL came from
    ## the network (a `resource_metadata` parameter, a metadata document).
    allowLoopback*: bool
      ## Plain http to localhost and loopback addresses, and https to them.
      ## The specification allows localhost redirect URIs, and development
      ## servers use it. It is the most that may be allowed: a client narrows
      ## it with `narrowedTo`, so that loopback is reachable only when the
      ## user pointed the client at a loopback server, never because some
      ## remote server's metadata said so.
    allowPrivateNetworks*: bool
      ## Addresses in 10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7, as
      ## literals and as what a name resolves to. Link-local addresses
      ## (cloud metadata services) and reserved ones are always refused.
    maxBodySize*: int
    timeoutMs*: int
    resolver*: HostResolver
      ## How a host name is resolved before it is connected to; nil: the
      ## system resolver (blocking). Replaced in tests.
    caFile*: string
      ## A PEM file of the certificate authorities to trust for https,
      ## instead of the system's: a private CA, or one in front of the server.
      ## Empty: the system's. The certificate still has to name the host.

func destinationPolicy*(policy: FetchPolicy): DestinationPolicy {.raises: [].} =
  DestinationPolicy(allowLoopback: policy.allowLoopback,
                    allowPrivateNetworks: policy.allowPrivateNetworks)

func defaultFetchPolicy*(): FetchPolicy {.raises: [].} =
  FetchPolicy(allowLoopback: true, allowPrivateNetworks: false,
              maxBodySize: 256 * 1024, timeoutMs: 10_000)

func isLoopbackHost*(host: string): bool {.raises: [].} =
  ## `localhost`, or an address in any notation that is a loopback address
  ## (`127.0.0.1`, `127.1`, `2130706433`, `::1`, `::ffff:7f00:1`).
  let class = classifyHost(host)
  class.isSome and class.get == acLoopback

func narrowedTo*(policy: FetchPolicy, chosenUrl: string): FetchPolicy {.raises: [].} =
  ## `policy`, with loopback allowed only when `chosenUrl` is itself on a
  ## loopback host. `chosenUrl` is a URL the user picked (the MCP server to
  ## connect to, the AI Catalog to read). What it leads to (metadata,
  ## endpoints, a card) was named by a remote party, and a remote party
  ## that says "fetch http://localhost:6379/" is not talking to the user's own
  ## development server. Private networks are not narrowed: a server on an
  ## intranet legitimately sends the client to its neighbours.
  result = policy
  let host =
    try: parseUri(chosenUrl).hostname
    except CatchableError: ""
  result.allowLoopback = policy.allowLoopback and host.len > 0 and isLoopbackHost(host)

proc checkFetchUrl*(url: string, policy: FetchPolicy, what: string) {.raises: [OAuthSecurityError].} =
  ## Refuses a URL this client should not request, judging the text of the
  ## URL: a host written as an address is classified in any notation the
  ## resolver accepts. A host name is judged when it is resolved, by
  ## `httpExchange` (a name can name any address). `what` names the URL in
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
  let loopback = hostClass.isSome and hostClass.get == acLoopback
  case uri.scheme.toLowerAscii()
  of "https":
    discard
  of "http":
    if not (policy.allowLoopback and loopback):
      raise newException(OAuthSecurityError,
        what & " must be https (http is accepted for loopback only): " & url)
  else:
    raise newException(OAuthSecurityError, what & " has an unsupported scheme: " & url)
  if hostClass.isNone:
    return
  case hostClass.get
  of acLinkLocal:
    raise newException(OAuthSecurityError, what & " names a link-local address: " & url)
  of acReserved:
    raise newException(OAuthSecurityError, what & " names a reserved address: " & url)
  of acPrivate:
    if not policy.allowPrivateNetworks:
      raise newException(OAuthSecurityError,
        what & " names a private network address: " & url)
  of acLoopback:
    if not policy.allowLoopback:
      raise newException(OAuthSecurityError, what & " names a loopback address: " & url)
  of acPublic:
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
