## Which network addresses a client may be talked into connecting to.
##
## A URL that came from the network (an OAuth metadata document, an AI
## Catalog, an icon, a webhook callback) can name an internal host: the
## address of a cloud metadata service, a router, a database on localhost.
## Judging the text of the URL is not enough, because the same address has
## many spellings (`2130706433`, `0x7f.1`, `::ffff:7f00:1`) and a DNS name
## can resolve to any of them. So the judgment is made on addresses: the
## host is parsed as an address the way the system resolver would
## (`classifyHost`), or resolved (`chooseDestination`), every address is
## classified (`classifyAddress`), and the connection is then made to the
## address that was judged, not to the name again (`http_wire.request`'s
## `connectTo`), so that a second answer from DNS cannot change the target.
##
## Resolution is the blocking `getaddrinfo`: a deployment that cannot accept
## that supplies a `HostResolver`.

import std/[net, nativesockets, options, strutils]

type
  AddressClass* = enum
    acPublic      ## globally routable
    acLoopback    ## 127.0.0.0/8, ::1
    acPrivate     ## RFC 1918, 100.64.0.0/10 (shared address space), fc00::/7
    acLinkLocal   ## 169.254.0.0/16 (cloud metadata services), fe80::/10
    acReserved    ## everything else the IANA special-purpose registries set
                  ## aside: unspecified (`0.0.0.0`, `::`), documentation,
                  ## benchmarking, multicast, reserved. Never a destination.

  DestinationPolicy* = object
    ## What a destination may be besides a public address. Link-local and
    ## reserved addresses are never allowed.
    allowLoopback*: bool
    allowPrivateNetworks*: bool

  Destination* = object
    address*: IpAddress
      ## The address to connect to: the first of what the host resolves to.
    loopbackOnly*: bool
      ## Every address the host resolves to is a loopback address.

  HostResolver* = proc(host: string): seq[IpAddress] {.closure, gcsafe, raises: [CatchableError].}
    ## The addresses of a host name. May raise OSError when it does not
    ## resolve; an empty answer means the same.

  AddressNotAllowed* = object of CatchableError
    ## The host is not a destination the policy allows, or does not resolve.

func v4(a, b, c, d: int): uint32 {.raises: [].} =
  (uint32(a) shl 24) or (uint32(b) shl 16) or (uint32(c) shl 8) or uint32(d)

func inBlock(value, network: uint32, bits: int): bool {.raises: [].} =
  let mask = if bits == 0: 0'u32 else: not 0'u32 shl (32 - bits)
  (value and mask) == (network and mask)

func classifyV4(value: uint32): AddressClass {.raises: [].} =
  const reserved = [
    (v4(0, 0, 0, 0), 8), (v4(192, 0, 0, 0), 24), (v4(192, 0, 2, 0), 24),
    (v4(192, 88, 99, 0), 24), (v4(198, 18, 0, 0), 15), (v4(198, 51, 100, 0), 24),
    (v4(203, 0, 113, 0), 24), (v4(224, 0, 0, 0), 4), (v4(240, 0, 0, 0), 4)]
  const private = [
    (v4(10, 0, 0, 0), 8), (v4(100, 64, 0, 0), 10), (v4(172, 16, 0, 0), 12),
    (v4(192, 168, 0, 0), 16)]
  if inBlock(value, v4(127, 0, 0, 0), 8):
    return acLoopback
  if inBlock(value, v4(169, 254, 0, 0), 16):
    return acLinkLocal
  for (network, bits) in private:
    if inBlock(value, network, bits):
      return acPrivate
  for (network, bits) in reserved:
    if inBlock(value, network, bits):
      return acReserved
  acPublic

func embeddedV4(a: array[16, uint8], at: int): uint32 {.raises: [].} =
  v4(int(a[at]), int(a[at + 1]), int(a[at + 2]), int(a[at + 3]))

func classifyAddress*(ip: IpAddress): AddressClass {.raises: [].} =
  ## The class of an address. An IPv6 address that embeds an IPv4 one
  ## (mapped, NAT64, 6to4) is classified by the IPv4 address inside it. An
  ## IPv6 address in no other class is public only inside 2000::/3.
  case ip.family
  of IpAddressFamily.IPv4:
    return classifyV4(v4(int(ip.address_v4[0]), int(ip.address_v4[1]),
                         int(ip.address_v4[2]), int(ip.address_v4[3])))
  of IpAddressFamily.IPv6:
    let a = ip.address_v6
    var zeroTo10 = true
    for i in 0 ..< 10:
      zeroTo10 = zeroTo10 and a[i] == 0
    # ::ffff:0:0/96 is judged by the address inside it.
    if zeroTo10 and a[10] == 0xff and a[11] == 0xff:
      return classifyV4(embeddedV4(a, 12))
    let zeroTo11 = zeroTo10 and a[10] == 0 and a[11] == 0
    if zeroTo11:
      # ::1 is loopback; :: and the deprecated IPv4-compatible block are not
      # destinations.
      var rest = true
      for i in 12 ..< 15:
        rest = rest and a[i] == 0
      return if rest and a[15] == 1: acLoopback else: acReserved
    # 64:ff9b::/96 (NAT64) is judged by the IPv4 address inside it;
    # 64:ff9b:1::/48 (local-use NAT64) is not a destination.
    if a[0] == 0x00 and a[1] == 0x64 and a[2] == 0xff and a[3] == 0x9b:
      var rest = true
      for i in 4 ..< 12:
        rest = rest and a[i] == 0
      return if rest: classifyV4(embeddedV4(a, 12)) else: acReserved
    # 2002::/16 (6to4): the IPv4 address in bits 16..47.
    if a[0] == 0x20 and a[1] == 0x02:
      return classifyV4(embeddedV4(a, 2))
    # 100::/64 discard-only.
    if a[0] == 0x01 and a[1] == 0x00:
      var discard64 = true
      for i in 2 ..< 8:
        discard64 = discard64 and a[i] == 0
      if discard64:
        return acReserved
    # 2001::/23 IETF protocol assignments (Teredo, benchmarking, ORCHID) is
    # refused whole although part of it is reachable; 2001:db8::/32 and
    # 3fff::/20 are documentation.
    if a[0] == 0x20 and a[1] == 0x01 and (a[2] and 0xfe'u8) == 0:
      return acReserved
    if a[0] == 0x20 and a[1] == 0x01 and a[2] == 0x0d and a[3] == 0xb8:
      return acReserved
    if a[0] == 0x3f and a[1] == 0xff and (a[2] and 0xf0'u8) == 0:
      return acReserved
    if (a[0] and 0xfe'u8) == 0xfc:
      return acPrivate
    if a[0] == 0xfe and (a[1] and 0xc0'u8) == 0x80:
      return acLinkLocal
    if a[0] == 0xff:
      return acReserved
    # Only 2000::/3 is allocated as global unicast. The rest (fec0::/10, the
    # unlisted parts of ::/8 and 100::/8, ...) is IETF-reserved, so a name that
    # resolves there is refused rather than called public.
    if (a[0] and 0xe0'u8) != 0x20:
      return acReserved
    acPublic

func isGloballyRoutable*(ip: IpAddress): bool {.raises: [].} =
  ## Whether `ip` is in no special-purpose block: the default test of a
  ## webhook destination.
  classifyAddress(ip) == acPublic

func parseNumberPart(part: string): Option[uint64] {.raises: [].} =
  ## One part of an IPv4 literal as `inet_aton` reads it: decimal, `0x` hex
  ## or leading-0 octal.
  var text = part
  var base = 10'u64
  if text.len > 1 and text[0] == '0':
    if text[1] in {'x', 'X'}:
      base = 16
      text = text[2 .. ^1]
    else:
      base = 8
      text = text[1 .. ^1]
  if text.len == 0 or text.len > 16:
    return none(uint64)
  var value = 0'u64
  for c in text:
    let digit =
      if c in Digits: uint64(ord(c) - ord('0'))
      elif c in {'a' .. 'f'}: uint64(ord(c) - ord('a') + 10)
      elif c in {'A' .. 'F'}: uint64(ord(c) - ord('A') + 10)
      else: return none(uint64)
    if digit >= base:
      return none(uint64)
    value = value * base + digit
    if value > 0xFFFF_FFFF'u64:
      return none(uint64)
  some(value)

func parseHostLiteral*(host: string): Option[IpAddress] {.raises: [].} =
  ## The address a host written as an address stands for, or none when it is
  ## a name. IPv4 is read as the system resolver reads it (`inet_aton`): one
  ## to four parts, each decimal, hex (`0x7f`) or octal (`0177`), the last
  ## part filling the remaining bytes, so `2130706433`, `0x7f.1` and `127.1`
  ## all are 127.0.0.1. Brackets around an IPv6 address are accepted.
  var text = host
  if text.len > 1 and text[0] == '[' and text[^1] == ']':
    text = text[1 .. ^2]
  if text.len == 0:
    return none(IpAddress)
  if ':' in text:
    try:
      return some(parseIpAddress(text))
    except ValueError:
      return none(IpAddress)
  let parts = text.split('.')
  if parts.len > 4:
    return none(IpAddress)
  var numbers: seq[uint64]
  for part in parts:
    let number = parseNumberPart(part)
    if number.isNone:
      return none(IpAddress)
    numbers.add number.get
  for i in 0 ..< numbers.len - 1:
    if numbers[i] > 255:
      return none(IpAddress)
  let remainingBytes = 5 - numbers.len
  if numbers[^1] >= (1'u64 shl (8 * remainingBytes)):
    return none(IpAddress)
  var value = numbers[^1]
  for i in 0 ..< numbers.len - 1:
    value = value or (numbers[i] shl (8 * (3 - i)))
  var address = IpAddress(family: IpAddressFamily.IPv4)
  for i in 0 ..< 4:
    address.address_v4[i] = uint8((value shr (8 * (3 - i))) and 0xFF)
  some(address)

func isMalformedAddress(host: string): bool {.raises: [].} =
  ## A host with a colon is an IPv6 address or nothing: it is no name to
  ## look up. (Other spellings the resolver might read as an address are not
  ## guessed at: a name is resolved and the addresses it gives are judged.)
  ':' in host and parseHostLiteral(host).isNone

func classifyHost*(host: string): Option[AddressClass] {.raises: [].} =
  ## The class of a host written as an address in any notation the resolver
  ## accepts; `localhost` is loopback. None for any other name, which has to
  ## be resolved. A malformed address is `acReserved`.
  let lowered = host.toLowerAscii()
  if lowered == "localhost" or lowered.endsWith(".localhost"):
    return some(acLoopback)
  let literal = parseHostLiteral(host)
  if literal.isSome:
    return some(classifyAddress(literal.get))
  if isMalformedAddress(host):
    return some(acReserved)
  none(AddressClass)

proc systemAddresses*(host: string): seq[string] {.nimcall, gcsafe, raises: [OSError].} =
  ## What the system resolver gives for `host`, as texts, IPv4 then IPv6. It
  ## blocks while it works. A plain procedure that touches nothing but its
  ## arguments, so that a caller who cannot afford to block may run it on a
  ## thread of its own. Raises OSError when the name does not resolve.
  for family in [Domain.AF_INET, Domain.AF_INET6]:
    var info: ptr AddrInfo
    try:
      info = getAddrInfo(host, Port(0), family)
    except OSError:
      continue
    try:
      var current = info
      while not current.isNil:
        let text =
          try:
            getAddrString(current.ai_addr)
          except IOError as e:
            raise newException(OSError, "cannot read an address of " & host & ": " & e.msg)
        if text notin result:
          result.add text
        current = current.ai_next
    finally:
      freeAddrInfo(info)
  if result.len == 0:
    raise newException(OSError, "cannot resolve " & host)

proc resolveHost*(host: string): seq[IpAddress] =
  ## The system resolver. It blocks while it works. Raises OSError when the
  ## name does not resolve.
  for text in systemAddresses(host):
    try:
      result.add parseIpAddress(text)
    except ValueError:
      discard  # an address family this build cannot represent is no candidate
  if result.len == 0:
    raise newException(OSError, "cannot resolve " & host)

func permits*(policy: DestinationPolicy, class: AddressClass): bool {.raises: [].} =
  case class
  of acPublic: true
  of acLoopback: policy.allowLoopback
  of acPrivate: policy.allowPrivateNetworks
  of acLinkLocal, acReserved: false

proc chooseDestination*(host: string, policy: DestinationPolicy,
                        resolver: HostResolver = nil): Destination
                       {.raises: [AddressNotAllowed].} =
  ## The address to connect to for `host`, or AddressNotAllowed. A host
  ## written as an address is judged as it is; a name is resolved, and is
  ## refused unless *every* address it resolves to is allowed (a name that
  ## answers with a public and an internal address is the shape of a rebinding
  ## attack). The caller connects to `address` itself, not to `host`.
  var addresses: seq[IpAddress]
  let literal = parseHostLiteral(host)
  if literal.isSome:
    addresses = @[literal.get]
  elif isMalformedAddress(host):
    raise newException(AddressNotAllowed, host & " is a malformed address")
  else:
    try:
      addresses = if resolver.isNil: resolveHost(host) else: resolver(host)
    except CatchableError as e:
      raise newException(AddressNotAllowed, "cannot resolve " & host & ": " & e.msg)
    if addresses.len == 0:
      raise newException(AddressNotAllowed, "cannot resolve " & host)
  result.loopbackOnly = true
  for address in addresses:
    let class = classifyAddress(address)
    if not policy.permits(class):
      raise newException(AddressNotAllowed,
        host & " is " & (case class
                         of acLoopback: "a loopback address"
                         of acPrivate: "a private network address"
                         of acLinkLocal: "a link-local address"
                         of acReserved: "a reserved address"
                         of acPublic: "public") & " (" & $address & ")")
    result.loopbackOnly = result.loopbackOnly and class == acLoopback
  result.address = addresses[0]
