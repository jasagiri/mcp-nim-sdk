## Fetching an icon does not leave a connection behind when it gives up, and
## does not connect to an address the server's name should not lead to.

import std/[unittest, asyncdispatch, asyncnet, httpcore, net, nativesockets, strutils]
import client/icons
import protocol/types
import transport/address_policy
import transport/http_wire as wire

const Png = "\x89PNG\r\n\x1a\n" & "rest of a png"

type LateServer = ref object
  socket: AsyncSocket
  port: int
  peerClosed: bool
    ## The client closed its end after the answer was sent.

proc startLateServer(delayMs: int, status = "200 OK"): LateServer =
  ## Answers every request with a PNG after `delayMs` (with `status`), then
  ## waits for the client to close the connection.
  let server = LateServer(socket: newAsyncSocket(buffered = false))
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.bindAddr(Port(0), "127.0.0.1")
  server.socket.listen()
  server.port = server.socket.getLocalAddr()[1].int
  proc serve(client: AsyncSocket) {.async.} =
    var request = ""
    while not request.contains("\c\L\c\L"):
      let data = await client.recv(4096)
      if data.len == 0:
        return
      request.add data
    await sleepAsync(delayMs)
    await client.send("HTTP/1.1 " & status & "\c\LContent-Type: image/png\c\LConnection: close\c\L" &
                      "Content-Length: " & $Png.len & "\c\L\c\L" & Png)
    # Nothing more is sent; the client closes, or never does.
    let rest = await client.recv(1)
    if rest.len == 0:
      server.peerClosed = true
  proc acceptLoop() {.async.} =
    while true:
      asyncCheck serve(await server.socket.accept())
  asyncCheck acceptLoop()
  server

proc resolving(address: string): HostResolver =
  result = proc(host: string): seq[IpAddress] {.closure, gcsafe, raises: [CatchableError].} =
    @[parseIpAddress(address)]

proc failure(options: IconFetchOptions, origin = "https://icons.example.test"): string =
  try:
    discard waitFor fetchIcon(McpIcon(src: origin & "/icon.png"), origin, options)
  except McpIconError as e:
    return e.msg

suite "an icon fetch that gives up":

  test "Given an answer that comes after the timeout, when the fetch has failed, then the connection is closed":
    let server = startLateServer(delayMs = 400)
    var options = IconFetchOptions(timeoutMs: 100)
    let port = server.port
    options.get = proc(url: string, headers: HttpHeaders): Future[WireResponse] {.closure, gcsafe.} =
      wire.request("http://127.0.0.1:" & $port & "/icon.png", HttpGet, headers)
    check "no answer within" in failure(options)
    var waited = 0
    while not server.peerClosed and waited < 3000:
      poll(20)
      waited += 20
    check server.peerClosed

suite "the address an icon is fetched from":

  test "Given a server whose name resolves to a loopback address, when its icon is fetched, then the fetch is refused":
    var options = IconFetchOptions()
    options.resolver = resolving("127.0.0.1")
    check "loopback" in failure(options)

  test "Given a server whose name resolves to a metadata service address, when its icon is fetched, then the fetch is refused":
    var options = IconFetchOptions()
    options.resolver = resolving("169.254.169.254")
    check "link-local" in failure(options)

  test "Given a server whose name resolves to a private address, when its icon is fetched, then it is refused unless private networks are allowed":
    var options = IconFetchOptions()
    options.resolver = resolving("10.1.2.3")
    check "private" in failure(options)
    options.allowPrivateNetworks = true
    # Allowed, so the address is tried; nothing listens there, and the failure is not a refusal.
    options.timeoutMs = 200
    let outcome = failure(options)
    check outcome.len > 0
    check "private" notin outcome

suite "an icon fetch that ends (mutation review, g2f-ap-a)":

  test "Given an answer that is not 200, when the fetch is refused, then the connection is closed":
    let server = startLateServer(delayMs = 0, status = "404 Not Found")
    var options = IconFetchOptions()
    let port = server.port
    options.get = proc(url: string, headers: HttpHeaders): Future[WireResponse] {.closure, gcsafe.} =
      wire.request("http://127.0.0.1:" & $port & "/icon.png", HttpGet, headers)
    check "404" in failure(options)
    var waited = 0
    while not server.peerClosed and waited < 3000:
      poll(20)
      waited += 20
    check server.peerClosed
