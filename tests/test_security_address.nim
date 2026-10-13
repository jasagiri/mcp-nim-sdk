## Which addresses the client may be sent to by a URL it learned from the
## network: judged on the address a host stands for, in whatever notation,
## and on what a name resolves to, never on the text of the URL.

import std/[unittest, asyncdispatch, asyncnet, httpcore, json, net, nativesockets, options, strutils]
import transport/address_policy
import transport/guarded_wire
import transport/http_wire as wire
import auth/client
import auth/oauth/[errors, fetch, urls]
import protocol/[version, features]

proc classOf(host: string): string =
  let class = classifyHost(host)
  if class.isSome: $class.get else: "name"

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

suite "the address a host stands for":

  test "Given a loopback address in any notation, when classified, then it is loopback":
    for host in ["127.0.0.1", "127.1", "2130706433", "0x7f.1", "0x7f000001", "0177.0.0.1",
                 "::1", "0:0:0:0:0:0:0:1", "[::1]", "::ffff:7f00:1", "::ffff:127.0.0.1",
                 "localhost", "LOCALHOST", "app.localhost", "127.255.255.254"]:
      check classOf(host) == "acLoopback"

  test "Given an unspecified or reserved address, when classified, then it is reserved":
    for host in ["0.0.0.0", "0", "::", "0:0:0:0:0:0:0:0", "224.0.0.1", "240.0.0.1",
                 "192.0.2.1", "198.18.0.1", "2001:db8::1", "ff02::1", "::ffff:0:0",
                 "fe80::1%eth0", "::zz"]:
      check classOf(host) == "acReserved"

  test "Given private and link-local addresses in any notation, when classified, then they are:":
    check classOf("10.1.2.3") == "acPrivate"
    check classOf("0xa.1.2.3") == "acPrivate"
    check classOf("172.16.0.1") == "acPrivate"
    check classOf("192.168.1.1") == "acPrivate"
    check classOf("100.64.0.1") == "acPrivate"
    check classOf("fd00::1") == "acPrivate"
    check classOf("::ffff:10.0.0.1") == "acPrivate"
    check classOf("169.254.169.254") == "acLinkLocal"
    check classOf("2852039166") == "acLinkLocal"
    check classOf("0xa9fea9fe") == "acLinkLocal"
    check classOf("fe80::1") == "acLinkLocal"
    check classOf("::ffff:a9fe:a9fe") == "acLinkLocal"

  test "Given public addresses and names, when classified, then they are public or a name":
    check classOf("8.8.8.8") == "acPublic"
    check classOf("2606:4700:4700::1111") == "acPublic"
    check classOf("example.com") == "name"
    check classOf("1.example.com") == "name"
    check classOf("1.de") == "name"

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

  test "Given a link-local or reserved address in another notation, when the policy allows loopback and private networks, then the URL is still refused":
    var policy = defaultFetchPolicy()
    policy.allowPrivateNetworks = true
    for host in ["2852039166", "0xa9fea9fe", "[::ffff:a9fe:a9fe]", "[::]", "0", "[fe80::1]"]:
      expect OAuthSecurityError:
        checkFetchUrl("https://" & host & "/x", policy, "t")

  test "Given plain http to a loopback address in another notation, when loopback is allowed, then the URL passes, and to a public one it does not":
    let policy = defaultFetchPolicy()
    checkFetchUrl("http://2130706433:8080/x", policy, "t")
    checkFetchUrl("http://[::ffff:7f00:1]:8080/x", policy, "t")
    expect OAuthSecurityError:
      checkFetchUrl("http://8.8.8.8/x", policy, "t")

suite "what a host name resolves to":

  test "Given a name that resolves to a loopback address, when the policy refuses loopback, then the request is refused before any connection":
    when HasChallengeVersion:
      var policy = defaultFetchPolicy()
      policy.allowLoopback = false
      policy.resolver = resolving({"rebind.example.test": @["127.0.0.1"]})
      check "loopback" in refusalOf(policy, RemoteServer, "https://rebind.example.test/x")
    else:
      skip()

  test "Given a name that resolves to a metadata service address, when the policy allows loopback and private networks, then the request is still refused":
    var policy = defaultFetchPolicy()
    policy.allowPrivateNetworks = true
    policy.resolver = resolving({"meta.example.test": @["169.254.169.254"]})
    check "link-local" in refused(getJson("https://meta.example.test/x", policy, "metadata"))

  test "Given a name that resolves to a public and a private address, when the policy refuses private networks, then the request is refused":
    var policy = defaultFetchPolicy()
    policy.resolver = resolving({"mixed.example.test": @["93.184.216.34", "10.0.0.5"]})
    check "private" in refused(getJson("https://mixed.example.test/x", policy, "metadata"))

  test "Given a name that does not resolve, when a request is made, then the request is refused":
    when HasChallengeVersion:
      var policy = defaultFetchPolicy()
      policy.resolver = resolving([])
      check "cannot resolve" in refusalOf(policy, RemoteServer, "https://nowhere.example.test/x")
    else:
      skip()

  test "Given a name that resolves to an allowed address, when a request is made, then the connection goes to that address":
    let listener = newAsyncSocket(buffered = false)
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let port = listener.getLocalAddr()[1].int
    proc serve() {.async.} =
      let client = await listener.accept()
      discard await client.recv(4096)
      let body = "{\"ok\":true}"
      await client.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\LContent-Length: " &
                        $body.len & "\c\L\c\L" & body)
      client.close()
    asyncCheck serve()
    var policy = defaultFetchPolicy()
    policy.resolver = resolving({"localhost": @["127.0.0.1"]})
    let reply = waitFor getJson("http://localhost:" & $port & "/x", policy, "metadata")
    check reply.code == 200
    check reply.document.get()["ok"].getBool()

suite "loopback only for a server the user chose":

  test "Given a policy and a server URL, when narrowed, then loopback stays allowed only for a loopback server":
    let policy = defaultFetchPolicy()
    check policy.narrowedTo("http://127.0.0.1:3000/mcp").allowLoopback
    check policy.narrowedTo("http://localhost:3000/mcp").allowLoopback
    check policy.narrowedTo("http://2130706433:3000/mcp").allowLoopback
    check not policy.narrowedTo("https://mcp.example.com/mcp").allowLoopback
    check not policy.narrowedTo("not a url").allowLoopback
    var strict = policy
    strict.allowLoopback = false
    check not strict.narrowedTo("http://127.0.0.1:3000/mcp").allowLoopback

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

suite "a guarded request (mutation review, g2f-ap-a)":

  test "Given a name that resolves to a private address, when plain http is asked for, then it is refused before any connection":
    # Plain http is for loopback only, whatever the policy lets through.
    var policy = DestinationPolicy(allowPrivateNetworks: true)
    let resolver = resolving({"lan.example.test": @["10.0.0.5"]})
    var message = ""
    try:
      discard waitFor guardedRequest("http://lan.example.test/x", HttpGet, policy, resolver,
                                     connectTimeoutMs = 200)
    except AddressNotAllowed as e:
      message = e.msg
    check "plain http" in message

  test "Given an answer that redirects, when no one asked for redirects to be followed, then the redirect is the answer":
    let listener = newAsyncSocket(buffered = false)
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let port = listener.getLocalAddr()[1].int
    proc serveOne(client: AsyncSocket) {.async.} =
      let request = await client.recv(4096)
      if request.startsWith("GET /moved "):
        await client.send("HTTP/1.1 302 Found\c\LLocation: /here\c\LContent-Length: 0\c\L\c\L")
      else:
        await client.send("HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L")
      client.close()
    proc serve() {.async.} =
      while true:
        asyncCheck serveOne(await listener.accept())
    asyncCheck serve()
    let policy = DestinationPolicy(allowLoopback: true)
    let url = "http://127.0.0.1:" & $port & "/moved"
    let unfollowed = waitFor guardedRequest(url, HttpGet, policy)
    check unfollowed.code == Http302
    unfollowed.close()
    let followed = waitFor guardedRequest(url, HttpGet, policy, followRedirects = true)
    check followed.code == Http200
    followed.close()

proc classOfAddress(text: string): string =
  $classifyAddress(parseIpAddress(text))

suite "the edges of the address blocks (mutation review, g2f-ap-b)":

  test "Given an IPv6 address inside NAT64 64:ff9b::/96, when classified, then the IPv4 address inside it decides":
    check classOfAddress("64:ff9b::7f00:1") == "acLoopback"
    check classOfAddress("64:ff9b::a00:1") == "acPrivate"
    check classOfAddress("64:ff9b::808:808") == "acPublic"

  test "Given an address in 64:ff9b:1::/48 or one that merely shares some bytes with NAT64, when classified, then only the first is reserved":
    # RFC 8215 sets 64:ff9b:1::/48 aside; the address inside it is not looked at.
    check classOfAddress("64:ff9b:1::808:808") == "acReserved"
    check classOfAddress("64:ff9b::1:808:808") == "acReserved"
    # The four bytes 00 64 ff 9b must all match, in place.
    check classOfAddress("2064:ff9b::1") == "acPublic"
    check classOfAddress("2606:ff9b::1") == "acPublic"
    check classOfAddress("2400:cb9b::1") == "acPublic"

  test "Given a 6to4 address 2002::/16, when classified, then the IPv4 address in bits 16 to 47 decides":
    check classOfAddress("2002:7f00:1::") == "acLoopback"
    check classOfAddress("2002:a00:1::") == "acPrivate"
    check classOfAddress("2002:808:808::") == "acPublic"
    check classOfAddress("2002:c000:200::") == "acReserved"

  test "Given an IPv4-mapped address whose IPv4 part is in a documentation /24, when classified, then the third octet counts":
    check classOfAddress("::ffff:192.0.2.1") == "acReserved"
    check classOfAddress("::ffff:198.51.100.1") == "acReserved"
    check classOfAddress("::ffff:203.0.113.1") == "acReserved"
    check classOfAddress("::ffff:192.0.3.1") == "acPublic"

  test "Given an address that has ff in bytes 10 or 11 but is not in ::ffff:0:0/96, when classified, then it is not read as IPv4-mapped":
    check classOfAddress("fd00::ffff:7f00:1") == "acPrivate"
    check classOfAddress("fd00::ff:7f00:1") == "acPrivate"

  test "Given an address in ::/96 other than ::1, when classified, then it is reserved":
    check classOfAddress("::1") == "acLoopback"
    check classOfAddress("::100:1") == "acReserved"
    check classOfAddress("::1:1") == "acReserved"
    check classOfAddress("::101") == "acReserved"
    check classOfAddress("::2") == "acReserved"

  test "Given the discard-only prefix 100::/64, when classified, then its edge is the 64th bit":
    check classOfAddress("100::") == "acReserved"
    check classOfAddress("100::1") == "acReserved"
    check classOfAddress("100::ffff:ffff:ffff:ffff") == "acReserved"
    # RFC 6666 sets aside 100::/64 only; the rest of 100::/8 is outside 2000::/3.
    check classOfAddress("100:0:0:1::") == "acReserved"

  test "Given the IETF protocol assignments 2001::/23, when classified, then the whole block is reserved and its neighbours are not":
    check classOfAddress("2001::1") == "acReserved"
    check classOfAddress("2001:2::1") == "acReserved"
    check classOfAddress("2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff") == "acReserved"
    check classOfAddress("2001:200::1") == "acPublic"
    check classOfAddress("2000::1") == "acPublic"
    check classOfAddress("2601::1") == "acPublic"

  test "Given the documentation prefix 2001:db8::/32, when classified, then it is reserved and its neighbours are not":
    check classOfAddress("2001:db8::1") == "acReserved"
    check classOfAddress("2001:db8:ffff:ffff:ffff:ffff:ffff:ffff") == "acReserved"
    check classOfAddress("2001:db7::1") == "acPublic"
    check classOfAddress("2001:db9::1") == "acPublic"
    check classOfAddress("2a01:db8::1") == "acPublic"
    check classOfAddress("2400:db8::1") == "acPublic"
    check classOfAddress("2400:1b8::1") == "acPublic"

  test "Given the documentation prefix 3fff::/20, when classified, then it is reserved and its neighbours are not":
    check classOfAddress("3fff::") == "acReserved"
    check classOfAddress("3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff") == "acReserved"
    check classOfAddress("3fff:1000::") == "acPublic"
    check classOfAddress("3ffe::1") == "acPublic"
    check classOfAddress("3f00::1") == "acPublic"
    check classOfAddress("26ff::1") == "acPublic"

  test "Given the link-local prefix fe80::/10, when classified, then its first and last address are link-local and a lookalike is not":
    check classOfAddress("fe80::") == "acLinkLocal"
    check classOfAddress("febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff") == "acLinkLocal"
    check classOfAddress("2680::1") == "acPublic"

  test "Given addresses of every class, when asked whether they are globally routable, then only the public ones are":
    check isGloballyRoutable(parseIpAddress("8.8.8.8"))
    check isGloballyRoutable(parseIpAddress("2606:4700:4700::1111"))
    for text in ["10.0.0.1", "127.0.0.1", "169.254.169.254", "192.0.2.1", "fd00::1", "::1"]:
      check not isGloballyRoutable(parseIpAddress(text))

suite "the notations of an IPv4 literal (mutation review, g2f-ap-b)":

  test "Given a literal at the top of the 32-bit range, when classified, then it is read, and one above it is a name":
    check classOf("4294967295") == "acReserved"
    check classOf("4294967296") == "name"

  test "Given hex digits in capitals, when classified, then they have their value":
    check classOf("0XA9FEA9FE") == "acLinkLocal"
    check classOf("0x7F.1") == "acLoopback"
    check classOf("0xAbCdEf01") == "acPublic"

  test "Given a digit that its base does not have, when classified, then the text is a name":
    check classOf("08.1.1.1") == "name"
    check classOf("1a.1.1.1") == "name"
    check classOf("0x1g.1.1.1") == "name"

  test "Given an empty part, when classified, then the text is a name":
    check classOf("1..2") == "name"
    check classOf("1.2.3.") == "name"
    check classOf("0x") == "name"
    check classOf("0x.1") == "name"

  test "Given a last part, when it is one more than the bytes left for it hold, then the text is a name":
    check classOf("127.16777215") == "acLoopback"
    check classOf("127.16777216") == "name"
    check classOf("1.2.65535") == "acPublic"
    check classOf("1.2.65536") == "name"
    check classOf("1.2.3.255") == "acPublic"
    check classOf("1.2.3.256") == "name"

  test "Given brackets that do not enclose the whole host, when it is read, then it is no address":
    check parseHostLiteral("[::1]").get == parseIpAddress("::1")
    check parseHostLiteral("[::1").isNone
    check parseHostLiteral("x::1]").isNone
    check classOf("x::1]") == "acReserved"

suite "what a destination is (mutation review, g2f-ap-b)":

  test "Given hosts that stand for loopback, public and mixed addresses, when a destination is chosen, then it is loopback-only exactly when every address is loopback":
    let policy = DestinationPolicy(allowLoopback: true, allowPrivateNetworks: true)
    let resolver = resolving({
      "both.example.test": @["127.0.0.1", "8.8.8.8"],
      "reversed.example.test": @["8.8.8.8", "127.0.0.1"],
      "loops.example.test": @["127.0.0.1", "::1"],
      "inside.example.test": @["10.0.0.5"]})
    check chooseDestination("127.0.0.1", policy).loopbackOnly
    check not chooseDestination("8.8.8.8", policy).loopbackOnly
    check chooseDestination("loops.example.test", policy, resolver).loopbackOnly
    check not chooseDestination("both.example.test", policy, resolver).loopbackOnly
    check not chooseDestination("reversed.example.test", policy, resolver).loopbackOnly
    check not chooseDestination("inside.example.test", policy, resolver).loopbackOnly
    check chooseDestination("both.example.test", policy, resolver).address ==
      parseIpAddress("127.0.0.1")

  # Addresses are written as numbers, which the system resolver reads without
  # asking any server.
  test "Given a host written as an address, when the system resolver is asked, then it answers with that address":
    check "127.0.0.1" in systemAddresses("127.0.0.1")
    check parseIpAddress("127.0.0.1") in resolveHost("127.0.0.1")
    check parseIpAddress("::1") in resolveHost("::1")

suite "the IPv6 space outside 2000::/3":

  test "Given an IPv6 address outside the global unicast block 2000::/3 and in no other class, when classified, then it is reserved":
    check classOfAddress("fec0::1") == "acReserved"
    check classOfAddress("::ff:7f00:1") == "acReserved"
    check classOfAddress("100:0:0:1::") == "acReserved"
    check classOfAddress("400::1") == "acReserved"
    check classOfAddress("1fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff") == "acReserved"
    check classOfAddress("4000::1") == "acReserved"
    check classOfAddress("8000::1") == "acReserved"
    check classOfAddress("e000::1") == "acReserved"
    check classOfAddress("fbff::1") == "acReserved"

  test "Given an address at either edge of 2000::/3, when classified, then it is public":
    check classOfAddress("2000::") == "acPublic"
    check classOfAddress("3ffe:ffff:ffff:ffff:ffff:ffff:ffff:ffff") == "acPublic"
    check classOfAddress("2606:4700:4700::1111") == "acPublic"

  test "Given an address outside 2000::/3 that another class already claims, when classified, then that class decides":
    check classOfAddress("fd00::1") == "acPrivate"
    check classOfAddress("fe80::1") == "acLinkLocal"
    check classOfAddress("::1") == "acLoopback"
    check classOfAddress("::ffff:10.0.0.1") == "acPrivate"
    check classOfAddress("64:ff9b::808:808") == "acPublic"
    check classOfAddress("ff02::1") == "acReserved"

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
