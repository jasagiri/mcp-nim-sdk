## Which addresses the client may be sent to by a URL it learned from the
## network: judged on the address a host stands for, in whatever notation,
## and on what a name resolves to, never on the text of the URL.

import std/[unittest, asyncdispatch, asyncnet, json, net, nativesockets, options, strutils]
import transport/address_policy
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
    var policy = defaultFetchPolicy()
    policy.allowLoopback = false
    for host in ["2130706433", "0x7f.1", "[::ffff:7f00:1]", "[0:0:0:0:0:0:0:1]", "[::]", "0.0.0.0"]:
      expect OAuthSecurityError:
        checkFetchUrl("https://" & host & "/x", policy, "t")

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
    var policy = defaultFetchPolicy()
    policy.allowLoopback = false
    policy.resolver = resolving({"rebind.example.test": @["127.0.0.1"]})
    check "loopback" in refused(getJson("https://rebind.example.test/x", policy, "metadata"))

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
    var policy = defaultFetchPolicy()
    policy.resolver = resolving([])
    check "cannot resolve" in refused(getJson("https://nowhere.example.test/x", policy, "metadata"))

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
