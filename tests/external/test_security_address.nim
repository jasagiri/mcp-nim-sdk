## Which addresses the client may be sent to by a URL it learned from the
## network: judged on the address a host stands for, in whatever notation,
## and on what a name resolves to, never on the text of the URL.

import std/[unittest, asyncdispatch, net, nativesockets, options, strutils]
import auth/client
import auth/oauth/errors
import protocol/[version, features]

proc resolving(table: openArray[(string, seq[string])]): HostResolver =
  ## A resolver with a fixed answer for each name.
  var known: seq[(string, seq[IpAddress])]
  for (name, addresses) in table:
    var parsed: seq[IpAddress]
    for address in addresses:
      parsed.add parseIpAddress(address)
    known.add (name, parsed)
  result = proc(host: string): seq[IpAddress] {.closure, gcsafe, raises: [CatchableError].} =
    for (name, addresses) in known:
      if name == host:
        return addresses
    raise newException(OSError, "cannot resolve " & host)

proc refused[T](action: Future[T]): string =
  ## The message of the security error `action` fails with, "" when it does not.
  try:
    discard waitFor action
  except OAuthSecurityError as e:
    return e.msg
  except CatchableError:
    return ""

const
  ChallengeVersion = block:
    ## The newest version of the build that reads the metadata URL of a
    ## challenge: 2025-03-26 looks at the server's own origin instead and
    ## 2024-11-05 has no authorization. None where the build speaks no such
    ## version; the tests that need one are skipped there.
    var found = none(McpProtocolVersion)
    for v in SupportedProtocolVersions:
      if v.has(ftProtectedResourceMetadata):
        found = some(v)
    found
  HasChallengeVersion = ChallengeVersion.isSome
  RemoteServer = "https://mcp.example.test/mcp"
    ## A server that is not on loopback: its challenge cannot lead to loopback.
  LoopbackServer = "http://127.0.0.1:1/mcp"
    ## The user's own development server, where nothing listens.

proc refusalOf(policy: FetchPolicy, serverUrl, advertised: string): string =
  ## The message of the security error the client answers a 401 with when the
  ## challenge names `advertised` as the URL of the resource metadata, ""
  ## when the answer is any other failure.
  let authorize: UserAuthorizer = proc(url: string): Future[seq[(string, string)]] {.async.} =
    raise newException(OAuthError, "no user in this test")
  var config = newOAuthClientConfig(serverUrl, "http://127.0.0.1:53682/callback", authorize,
                                    ChallengeVersion.get)
  config.fetchPolicy = policy
  refused(newOAuthClient(config).handleChallenge(401,
    @["Bearer resource_metadata=\"" & advertised & "\""]))


suite "what a URL may name":

  test "Given a loopback address in another notation, when the policy refuses loopback, then the URL is refused":
    when HasChallengeVersion:
      var policy = defaultFetchPolicy()
      policy.allowLoopback = false
      for host in ["2130706433", "0x7f.1", "[::ffff:7f00:1]", "[0:0:0:0:0:0:0:1]", "[::]", "0.0.0.0"]:
        checkpoint host
        check refusalOf(policy, LoopbackServer, "https://" & host & "/x").len > 0
    else:
      skip()


suite "what a host name resolves to":

  test "Given a name that resolves to a loopback address, when the policy refuses loopback, then the request is refused before any connection":
    when HasChallengeVersion:
      var policy = defaultFetchPolicy()
      policy.allowLoopback = false
      policy.resolver = resolving({"rebind.example.test": @["127.0.0.1"]})
      check "loopback" in refusalOf(policy, RemoteServer, "https://rebind.example.test/x")
    else:
      skip()


  test "Given a name that does not resolve, when a request is made, then the request is refused":
    when HasChallengeVersion:
      var policy = defaultFetchPolicy()
      policy.resolver = resolving([])
      check "cannot resolve" in refusalOf(policy, RemoteServer, "https://nowhere.example.test/x")
    else:
      skip()


suite "loopback only for a server the user chose":


  # The client is made for the build's default version. The metadata URL of a
  # challenge is read from 2025-06-18 on: 2025-03-26 looks at the server's own
  # origin instead and 2024-11-05 has no authorization.
  if DefaultProtocolVersion.has(ftProtectedResourceMetadata):
    test "Given a remote server that names a loopback metadata URL, when the client answers its 401, then OAuthSecurityError is raised and nothing is requested":
      let authorize: UserAuthorizer = proc(url: string): Future[seq[(string, string)]] {.async.} =
        raise newException(OAuthError, "no user in this test")
      let oauth = newOAuthClient(newOAuthClientConfig(
        "https://mcp.example.test/mcp", "http://127.0.0.1:53682/callback", authorize))
      check "loopback" in refused(oauth.handleChallenge(401,
        @["Bearer resource_metadata=\"http://127.0.0.1:1/.well-known/oauth-protected-resource\""]))


# The class a client gives an address is read here from what the client says
# when it refuses a metadata URL: the refusal names the class. The policy lets
# only public addresses through, and the name always resolves to a second,
# link-local address, which no policy allows. So every request is refused
# before any connection, and a first address that was let through shows as a
# refusal that names the second.

const
  NeverAllowed = "169.254.0.1"
  ProbeName = "probe.example.test"

proc publicOnly(resolver: HostResolver): FetchPolicy =
  result = defaultFetchPolicy()
  result.allowLoopback = false
  result.allowPrivateNetworks = false
  result.timeoutMs = 200
  result.resolver = resolver

proc classIn(refusal: string): string =
  ## The class a refusal names.
  for (words, class) in {"a loopback address": "loopback", "a private network address": "private",
                         "a link-local address": "link-local", "a reserved address": "reserved"}:
    if words in refusal:
      return class
  "no class in: " & refusal

proc seenClass(address: string): string =
  ## What a client makes of `address` when a name resolves to it.
  let refusal = refusalOf(publicOnly(resolving({ProbeName: @[address, NeverAllowed]})),
                          RemoteServer, "https://" & ProbeName & "/x")
  if "(" & NeverAllowed & ")" in refusal: "public" else: classIn(refusal)

proc seenHost(host: string): string =
  ## What a client makes of `host` written in a URL: "name" when it asks the
  ## resolver for it, else the class of the address it read.
  var asked: seq[string]
  let resolver: HostResolver = proc(name: string): seq[IpAddress] {.closure, gcsafe, raises: [CatchableError].} =
    asked.add name
    @[parseIpAddress(NeverAllowed)]
  let refusal = refusalOf(publicOnly(resolver), RemoteServer, "https://" & host & "/x")
  if asked == @[host]: "name"
  elif asked.len > 0: "asked " & $asked
  else: classIn(refusal)

when HasChallengeVersion:
  suite "the edges of the address blocks, seen through the public entries":

    test "Given a name that resolves into NAT64 64:ff9b::/96, when a client is sent to it, then the IPv4 address inside it decides":
      check seenClass("64:ff9b::7f00:1") == "loopback"
      check seenClass("64:ff9b::a00:1") == "private"
      check seenClass("64:ff9b::808:808") == "public"

    test "Given a name that resolves into 64:ff9b:1::/48 or to an address that shares some bytes with NAT64, when a client is sent to it, then only the first is reserved":
      check seenClass("64:ff9b:1::808:808") == "reserved"
      check seenClass("64:ff9b::1:808:808") == "reserved"
      check seenClass("2064:ff9b::1") == "public"
      check seenClass("2606:ff9b::1") == "public"
      check seenClass("2400:cb9b::1") == "public"

    test "Given a name that resolves into 6to4 2002::/16, when a client is sent to it, then the IPv4 address in bits 16 to 47 decides":
      check seenClass("2002:7f00:1::") == "loopback"
      check seenClass("2002:a00:1::") == "private"
      check seenClass("2002:808:808::") == "public"
      check seenClass("2002:c000:200::") == "reserved"

    test "Given a name that resolves to an IPv4-mapped address, when a client is sent to it, then the IPv4 address inside it decides, to the third octet of a documentation block":
      check seenClass("::ffff:192.0.2.1") == "reserved"
      check seenClass("::ffff:198.51.100.1") == "reserved"
      check seenClass("::ffff:203.0.113.1") == "reserved"
      check seenClass("::ffff:192.0.3.1") == "public"
      check seenClass("::ffff:10.0.0.1") == "private"

    test "Given a name that resolves to an address with ff in bytes 10 or 11 outside ::ffff:0:0/96, when a client is sent to it, then it is not read as IPv4-mapped":
      check seenClass("fd00::ffff:7f00:1") == "private"
      check seenClass("fd00::ff:7f00:1") == "private"

    test "Given a name that resolves into ::/96, when a client is sent to it, then only ::1 is loopback and the rest is reserved":
      check seenClass("::1") == "loopback"
      for address in ["::100:1", "::1:1", "::101", "::2"]:
        checkpoint address
        check seenClass(address) == "reserved"

    test "Given a name that resolves into the discard prefix 100::/64 or next to it, when a client is sent to it, then it is reserved":
      for address in ["100::", "100::1", "100::ffff:ffff:ffff:ffff", "100:0:0:1::"]:
        checkpoint address
        check seenClass(address) == "reserved"

    test "Given a name that resolves into the protocol assignments 2001::/23, when a client is sent to it, then the whole block is reserved and its neighbours are public":
      check seenClass("2001::1") == "reserved"
      check seenClass("2001:2::1") == "reserved"
      check seenClass("2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff") == "reserved"
      check seenClass("2001:200::1") == "public"
      check seenClass("2000::1") == "public"
      check seenClass("2601::1") == "public"

    test "Given a name that resolves into the documentation prefix 2001:db8::/32, when a client is sent to it, then it is reserved and its neighbours are public":
      check seenClass("2001:db8::1") == "reserved"
      check seenClass("2001:db8:ffff:ffff:ffff:ffff:ffff:ffff") == "reserved"
      for address in ["2001:db7::1", "2001:db9::1", "2a01:db8::1", "2400:db8::1", "2400:1b8::1"]:
        checkpoint address
        check seenClass(address) == "public"

    test "Given a name that resolves into the documentation prefix 3fff::/20, when a client is sent to it, then it is reserved and its neighbours are public":
      check seenClass("3fff::") == "reserved"
      check seenClass("3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff") == "reserved"
      for address in ["3fff:1000::", "3ffe::1", "3f00::1", "26ff::1"]:
        checkpoint address
        check seenClass(address) == "public"

    test "Given a name that resolves to the first or the last address of fe80::/10, when a client is sent to it, then it is link-local and a lookalike is public":
      check seenClass("fe80::") == "link-local"
      check seenClass("febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff") == "link-local"
      check seenClass("2680::1") == "public"

    test "Given names that resolve to an address of every class, when a client is sent to them, then only the public ones are let through":
      check seenClass("8.8.8.8") == "public"
      check seenClass("2606:4700:4700::1111") == "public"
      check seenClass("10.0.0.1") == "private"
      check seenClass("127.0.0.1") == "loopback"
      check seenClass("169.254.169.254") == "link-local"
      check seenClass("192.0.2.1") == "reserved"
      check seenClass("fd00::1") == "private"
      check seenClass("::1") == "loopback"

  suite "the notations of an IPv4 literal, seen through the public entries":

    test "Given a literal at the top of the 32-bit range, when a URL names it, then it is read as an address, and one above it is a name":
      check seenHost("4294967295") == "reserved"
      check seenHost("4294967296") == "name"

    test "Given hex digits in capitals, when a URL names the host, then they have their value":
      # 169.254.169.254, 127.0.0.1, 172.31.0.1 (the last private /16 of
      # 172.16/12) and 192.0.2.1 (documentation): a digit read with another
      # value lands in another class.
      check seenHost("0XA9FEA9FE") == "link-local"
      check seenHost("0x7F.1") == "loopback"
      check seenHost("0XAC.0x1F.1") == "private"
      check seenHost("0xC0000201") == "reserved"

    test "Given a digit that its base does not have, when a URL names the host, then the text is a name":
      for host in ["08.1.1.1", "1a.1.1.1", "0x1g.1.1.1"]:
        checkpoint host
        check seenHost(host) == "name"

    test "Given an empty part, when a URL names the host, then the text is a name":
      for host in ["1..2", "1.2.3.", "0x", "0x.1"]:
        checkpoint host
        check seenHost(host) == "name"

    test "Given the last part of a host in a URL, when it is one more than the bytes left for it hold, then the text is a name":
      check seenHost("127.16777215") == "loopback"
      check seenHost("127.16777216") == "name"
      check seenHost("10.2.65535") == "private"
      check seenHost("10.2.65536") == "name"
      check seenHost("10.2.3.255") == "private"
      check seenHost("10.2.3.256") == "name"

  suite "the IPv6 space outside 2000::/3, seen through the public entries":

    test "Given a name that resolves outside 2000::/3 to an address no other class claims, when a client is sent to it, then it is reserved":
      for address in ["fec0::1", "::ff:7f00:1", "100:0:0:1::", "400::1",
                      "1fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "4000::1", "8000::1", "e000::1",
                      "fbff::1"]:
        checkpoint address
        check seenClass(address) == "reserved"

    test "Given a host outside 2000::/3 written as an address, when a URL names it and the policy allows loopback and private networks, then it is still refused as reserved":
      var policy = defaultFetchPolicy()
      policy.allowPrivateNetworks = true
      policy.timeoutMs = 200
      policy.resolver = resolving([])
      for host in ["[fec0::1]", "[::ff:7f00:1]", "[100:0:0:1::]"]:
        checkpoint host
        check "a reserved address" in refusalOf(policy, LoopbackServer, "https://" & host & "/x")

    test "Given a name that resolves to either edge of 2000::/3, when a client is sent to it, then it is public":
      check seenClass("2000::") == "public"
      check seenClass("3ffe:ffff:ffff:ffff:ffff:ffff:ffff:ffff") == "public"
      check seenClass("2606:4700:4700::1111") == "public"

    test "Given a name that resolves outside 2000::/3 to an address another class claims, when a client is sent to it, then that class decides":
      check seenClass("fd00::1") == "private"
      check seenClass("fe80::1") == "link-local"
      check seenClass("::1") == "loopback"
      check seenClass("::ffff:10.0.0.1") == "private"
      check seenClass("64:ff9b::808:808") == "public"
      check seenClass("ff02::1") == "reserved"

proc answering(asked: ref seq[string], address: string): HostResolver =
  ## A resolver that notes each name it is asked for and answers `address`.
  result = proc(name: string): seq[IpAddress] {.closure, gcsafe, raises: [CatchableError].} =
    asked[].add name
    @[parseIpAddress(address)]

when HasChallengeVersion:
  import std/asyncnet   # here only: a build without such a version would import it unused
  suite "plain http and redirects, seen through the public entries":

    test "Given a name that resolves to a private address the policy allows, when its metadata URL is plain http, then it is refused and the name is not even resolved":
      let asked = new seq[string]
      var policy = defaultFetchPolicy()
      policy.allowPrivateNetworks = true
      policy.timeoutMs = 200
      policy.resolver = answering(asked, "10.0.0.5")
      check "http is accepted for loopback only" in
        refusalOf(policy, LoopbackServer, "http://lan.example.test/x")
      check asked[].len == 0

    test "Given a metadata URL that answers with a redirect, when the client reads it, then the redirect is reported and its target is not requested":
      let listener = newAsyncSocket(buffered = false)
      listener.setSockOpt(OptReuseAddr, true)
      listener.bindAddr(Port(0), "127.0.0.1")
      listener.listen()
      let port = listener.getLocalAddr()[1].int
      var requested: seq[string]
      proc serveOne(client: AsyncSocket) {.async.} =
        let request = await client.recv(4096)
        requested.add request.splitLines()[0]
        if request.startsWith("GET /moved "):
          await client.send("HTTP/1.1 302 Found\c\LLocation: /here\c\LContent-Length: 0\c\L\c\L")
        else:
          await client.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\LContent-Length: 2\c\L\c\L{}")
        client.close()
      proc serve() {.async.} =
        while true:
          asyncCheck serveOne(await listener.accept())
      asyncCheck serve()
      let authorize: UserAuthorizer = proc(url: string): Future[seq[(string, string)]] {.async.} =
        raise newException(OAuthError, "no user in this test")
      let server = "http://127.0.0.1:" & $port
      let oauth = newOAuthClient(newOAuthClientConfig(
        server & "/mcp", "http://127.0.0.1:53682/callback", authorize, ChallengeVersion.get))
      var message = ""
      try:
        discard waitFor oauth.handleChallenge(401, @["Bearer resource_metadata=\"" & server & "/moved\""])
      except OAuthError as e:
        message = e.msg
      check "redirected (HTTP 302)" in message
      check requested == @["GET /moved HTTP/1.1"]

when HasChallengeVersion:
  suite "plain http to a name that stands for loopback, seen through the public entries":

    proc plainHttpTo(addresses: seq[string]): string =
      ## How the client of a loopback server is refused a plain http metadata
      ## URL on localhost, when localhost resolves to `addresses` and the
      ## policy allows loopback and private networks; "" when it is not
      ## refused. Nothing listens on the port.
      var policy = defaultFetchPolicy()
      policy.allowPrivateNetworks = true
      policy.timeoutMs = 200
      policy.resolver = resolving({"localhost": addresses})
      refusalOf(policy, LoopbackServer, "http://localhost:1/x")

    test "Given localhost resolves to loopback addresses only, when a plain http URL names it, then the request is not refused":
      check plainHttpTo(@["127.0.0.1", "::1"]) == ""

    test "Given localhost resolves to a loopback and a private address, when a plain http URL names it, then it is refused as plain http, in either order":
      check "plain http" in plainHttpTo(@["127.0.0.1", "10.0.0.5"])
      check "plain http" in plainHttpTo(@["10.0.0.5", "127.0.0.1"])

    test "Given a host written as a loopback address, when a URL names it, then it is judged as that address and no resolver is asked":
      check seenHost("127.0.0.1") == "loopback"
      check seenHost("[::1]") == "loopback"
