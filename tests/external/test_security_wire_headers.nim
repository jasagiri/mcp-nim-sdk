## What `transport/http_wire` puts on the request line and in headers, and
## what it accepts from a response head: no line breaks or control
## characters smuggled in either direction.

import std/[unittest, asyncdispatch, asyncnet, httpcore, json, nativesockets, strutils]
import transport/http
import protocol/types

proc notify(t: StreamableHttpTransport): Future[void] =
  ## What a transport puts on the wire, as a caller sees it: one POST.
  t.sendNotification(newJsonRpcNotification("notifications/roots/list_changed", newJObject()))

proc transportTo(url: string, headers: HttpHeaders = nil): StreamableHttpTransport =
  result = newStreamableHttpTransport(url)
  if not headers.isNil:
    result.headers = headers

type Peer = ref object
  socket: AsyncSocket
  port: int
  answer: string
  connections: int
  received: string

proc startPeer(answer: string): Peer =
  ## A server that answers every connection with `answer` as it is.
  let peer = Peer(socket: newAsyncSocket(buffered = false), answer: answer)
  peer.socket.setSockOpt(OptReuseAddr, true)
  peer.socket.bindAddr(Port(0), "127.0.0.1")
  peer.socket.listen()
  peer.port = peer.socket.getLocalAddr()[1].int
  proc acceptLoop() {.async.} =
    while true:
      let client = await peer.socket.accept()
      inc peer.connections
      proc serve() {.async.} =
        while not peer.received.contains("\c\L\c\L"):
          let data = await client.recv(4096)
          if data.len == 0:
            break
          peer.received.add data
        await client.send(peer.answer)
        client.close()
      asyncCheck serve()
  asyncCheck acceptLoop()
  peer

proc url(peer: Peer, path = "/"): string =
  "http://127.0.0.1:" & $peer.port & path

proc outcome[T](future: Future[T]): string =
  ## "ok", or the message of what the future failed with.
  var waited = 0
  while not future.finished and waited < 5000:
    poll(20)
    waited += 20
  if not future.finished: "pending"
  elif future.failed: future.readError().msg
  else: "ok"

const plain = "HTTP/1.1 200 OK\c\LContent-Length: 0\c\L\c\L"

# ---- mutation review, g2g-hc-c ------------------------------------------

import std/os

type
  Scripted = ref object
    ## A server whose answer a test writes, connection by connection.
    socket: AsyncSocket
    port: int
    requests: seq[string]    ## head and body of the request of each connection
    ended: seq[bool]         ## whether the client ended connection n (see `holdUntilEnd`)
  Answer = proc (server: Scripted, client: AsyncSocket, index: int): Future[void]

proc contentLengthOf(head: string): int =
  for line in head.split("\c\L"):
    if line.toLowerAscii().startsWith("content-length:"):
      return parseInt(line.split(':')[1].strip())

proc startScripted(answer: Answer): Scripted =
  let server = Scripted(socket: newAsyncSocket(buffered = false))
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.bindAddr(Port(0), "127.0.0.1")
  server.socket.listen()
  server.port = server.socket.getLocalAddr()[1].int
  proc serve(client: AsyncSocket, index: int) {.async.} =
    var request = ""
    while not request.contains("\c\L\c\L"):
      let data = await client.recv(4096)
      if data.len == 0:
        client.close()
        return
      request.add data
    let bodyStart = request.find("\c\L\c\L") + 4
    let wanted = bodyStart + contentLengthOf(request[0 ..< bodyStart])
    while request.len < wanted:
      let data = await client.recv(4096)
      if data.len == 0:
        break
      request.add data
    server.requests[index] = request
    await answer(server, client, index)
    client.close()
  proc acceptLoop() {.async.} =
    while true:
      let client = await server.socket.accept()
      server.requests.add ""
      server.ended.add false
      asyncCheck serve(client, server.requests.high)
  asyncCheck acceptLoop()
  server

proc scriptedUrl(server: Scripted, path = "/"): string =
  "http://127.0.0.1:" & $server.port & path

proc holdUntilEnd(server: Scripted, client: AsyncSocket, index: int, limitMs = 2000) {.async.} =
  ## Keeps the connection open and records whether the client ends it.
  let read = client.recv(1)
  var waited = 0
  while not read.finished and waited < limitMs:
    await sleepAsync(20)
    waited += 20
  server.ended[index] = read.finished and not read.failed and read.read().len == 0

proc ending(response: string): Answer =
  ## Answers `response` and closes.
  result = proc (server: Scripted, client: AsyncSocket, index: int): Future[void] {.async.} =
    await client.send(response)

proc keeping(response: string): Answer =
  ## Answers `response` and keeps the connection open until the client ends it.
  result = proc (server: Scripted, client: AsyncSocket, index: int): Future[void] {.async.} =
    await client.send(response)
    await holdUntilEnd(server, client, index)

proc settle(limitMs: int) =
  var waited = 0
  while waited < limitMs:
    poll(20)
    waited += 20

proc openDescriptors(): int =
  for _ in walkDir("/dev/fd"):
    inc result

suite "line breaks and control characters in HTTP":

  test "Given a header value with a line break, when a request is sent, then it is refused and nothing is connected":
    let peer = startPeer(plain)
    let headers = newHttpHeaders({"X-Note": "a\c\LX-Injected: yes"})
    check "line break or control" in outcome(transportTo(peer.url, headers).notify())
    check peer.connections == 0

  test "Given a bare LF or a NUL in a header value, when a request is sent, then it is refused":
    let peer = startPeer(plain)
    check "line break or control" in outcome(transportTo(peer.url, newHttpHeaders({"X-Note": "a\LX: b"})).notify())
    check "line break or control" in outcome(transportTo(peer.url, newHttpHeaders({"X-Note": "a\x00b"})).notify())
    check peer.connections == 0

  test "Given a header name that is not a token, when a request is sent, then it is refused":
    let peer = startPeer(plain)
    check "header name" in outcome(transportTo(peer.url, newHttpHeaders({"X Bad": "1"})).notify())
    check "header name" in outcome(transportTo(peer.url, newHttpHeaders({"X-Bad\c\LX-Injected": "1"})).notify())
    check peer.connections == 0

  test "Given a URL whose path carries a line break, when a request is sent, then it is refused":
    let peer = startPeer(plain)
    check "line break or control" in outcome(transportTo(peer.url("/a\c\LX-Injected: yes")).notify())
    check peer.connections == 0


  test "Given a response header with a bare LF, when the head is read, then the response is refused":
    let peer = startPeer("HTTP/1.1 302 Found\c\LLocation: /next\LSet-Cookie: stolen=1\c\L\c\L")
    check "line break or control" in outcome(transportTo(peer.url).notify())

  test "Given a response header with a NUL or a bare CR, when the head is read, then the response is refused":
    let nul = startPeer("HTTP/1.1 200 OK\c\LMcp-Session-Id: a\x00b\c\LContent-Length: 0\c\L\c\L")
    check "line break or control" in outcome(transportTo(nul.url).notify())
    let cr = startPeer("HTTP/1.1 200 OK\c\LMcp-Session-Id: a\c" & "b\c\LContent-Length: 0\c\L\c\L")
    check "line break or control" in outcome(transportTo(cr.url).notify())

suite "the request on the wire (mutation review, g2g-hc-c)":

  test "Given a header name with digits, when a request is sent, then it is accepted and sent":
    let server = startScripted(ending(plain))
    let headers = newHttpHeaders({"X-Request-Id-2": "abc", "H2": "x"})
    check outcome(transportTo(server.scriptedUrl, headers).notify()) == "ok"
    let sent = server.requests[0].toLowerAscii()
    check "x-request-id-2: abc\c\L" in sent
    check "h2: x\c\L" in sent

  test "Given a header with an empty name, when a request is sent, then it is refused and nothing is connected":
    let server = startScripted(ending(plain))
    let headers = newHttpHeaders({"": "x"})
    check "header name" in outcome(transportTo(server.scriptedUrl, headers).notify())
    check server.requests.len == 0

  test "Given a path with a NUL but no space, or a space but no control character, when a request is sent, then it is refused":
    let server = startScripted(ending(plain))
    check "line break or control" in outcome(transportTo(server.scriptedUrl("/a\x00b")).notify())
    check "line break or control" in outcome(transportTo(server.scriptedUrl("/a\c\Lb")).notify())
    check "line break or control" in outcome(transportTo(server.scriptedUrl("/a b")).notify())
    check "line break or control" in outcome(transportTo(server.scriptedUrl("/a?b c")).notify())
    check "line break or control" in outcome(transportTo(server.scriptedUrl("/a?b\x00c")).notify())
    check server.requests.len == 0


  test "Given a Host header and a Content-Length of the caller, when a request is sent, then the SDK's own are the only ones":
    let server = startScripted(ending(plain))
    let headers = newHttpHeaders({"Host": "evil.example", "Content-Length": "999", "Connection": "keep-alive"})
    check outcome(transportTo(server.scriptedUrl, headers).notify()) == "ok"
    let sent = server.requests[0].toLowerAscii()
    check sent.count("host:") == 1
    check "host: 127.0.0.1:" & $server.port & "\c\L" in sent
    check sent.count("content-length:") == 1
    check sent.count("connection:") == 1
    check "connection: close\c\L" in sent

  test "Given a URL with no port, when a request is sent, then the connection is attempted (the URL is not refused as malformed)":
    let attempt = outcome(transportTo("http://127.0.0.1/").notify())
    check "invalid integer" notin attempt

  test "Given a host that does not resolve and a server on loopback, when a request is sent, then the host named in the URL is the one that is connected to":
    let server = startScripted(ending(plain))
    let attempt = outcome(transportTo("http://no-such-host.invalid:" & $server.port & "/").notify())
    check attempt != "ok"
    check server.requests.len == 0

when not defined(ssl):
  suite "https without TLS support (mutation review, g2g-hc-c)":

    test "Given a build without -d:ssl, when https URLs are refused again and again, then no connection is left open":
      if not dirExists("/dev/fd"):
        skip()
      else:
        let server = startScripted(ending(plain))
        let url = "https://127.0.0.1:" & $server.port & "/"
        check "https needs a build with -d:ssl" in outcome(transportTo(url).notify())
        settle(100)
        let before = openDescriptors()
        for attempt in 1 .. 3:
          check "https needs a build with -d:ssl" in outcome(transportTo(url).notify())
        settle(200)
        check openDescriptors() == before

suite "the response head (mutation review, g2g-hc-c)":


  test "Given a status line that does not start with HTTP/, or has no status, when the head is read, then it is refused":
    let wrong = startScripted(ending("FOO/1.1 200 OK\c\LContent-Length: 0\c\L\c\L"))
    check "not an HTTP response" in outcome(transportTo(wrong.scriptedUrl).notify())
    let bare = startScripted(ending("HTTP/1.1\c\LContent-Length: 0\c\L\c\L"))
    check "not an HTTP response" in outcome(transportTo(bare.scriptedUrl).notify())

  test "Given a head of nothing but the blank line, when it is read, then it is refused as not HTTP":
    let server = startScripted(ending("\c\L\c\L"))
    check "not an HTTP response" in outcome(transportTo(server.scriptedUrl).notify())


  test "Given an answer that is not HTTP, when the request fails, then the connection is closed":
    let server = startScripted(keeping("FOO\c\L\c\L"))
    check "not an HTTP response" in outcome(transportTo(server.scriptedUrl).notify())
    settle(100)
    check server.ended[0]


suite "redirects (mutation review, g2g-hc-c)":

  proc redirecting(location: string): Answer =
    ## The first connection is answered with a 307 to `location` ({port} is
    ## the port of this server) and kept open until the client ends it; later
    ## ones with 200.
    result = proc (server: Scripted, client: AsyncSocket, index: int): Future[void] {.async.} =
      if index == 0:
        await client.send("HTTP/1.1 307 Temporary Redirect\c\LLocation: " & location.replace("{port}", $server.port) &
                          "\c\LContent-Length: 0\c\L\c\L")
        await holdUntilEnd(server, client, index)
      else:
        await client.send(plain)

  test "Given a redirect within the server, when it is followed, then the connection that gave it is closed":
    let server = startScripted(redirecting("/two"))
    check outcome(transportTo(server.scriptedUrl("/one")).notify()) == "ok"
    settle(100)
    check server.requests.len == 2
    check server.ended[0]

  test "Given a redirect to another server, when it is refused, then the connection that gave it is closed":
    let server = startScripted(redirecting("http://evil.example/steal"))
    check "redirects to another server" in outcome(transportTo(server.scriptedUrl("/one")).notify())
    settle(100)
    check server.ended[0]

  test "Given a redirect to another host name on the same port, when a request is sent, then it is refused and nothing is sent there":
    let server = startScripted(redirecting("http://localhost:{port}/two"))
    let headers = newHttpHeaders({"Authorization": "Bearer secret"})
    check "redirects to another server" in outcome(transportTo(server.scriptedUrl("/one"), headers).notify())
    check server.requests.len == 1

  test "Given a redirect to the same host and port under another scheme, when a request is sent, then it is refused":
    let server = startScripted(redirecting("https://127.0.0.1:{port}/two"))
    check "redirects to another server" in outcome(transportTo(server.scriptedUrl("/one")).notify())
    check server.requests.len == 1

suite "what a server may send and how long (mutation review, g2g-hc-c)":

  test "Given a connect timeout of 0, when a request is sent, then there is no limit and the server is reached":
    let server = startScripted(ending(plain))
    let transport = transportTo(server.scriptedUrl)
    transport.connectTimeoutMs = 0
    check outcome(transport.notify()) == "ok"


suite "a Content-Length that cannot be a length (mutation review, g2g-hc-c)":

  test "Given a negative Content-Length, when the head is read, then the response is refused":
    let server = startScripted(ending("HTTP/1.1 200 OK\c\LContent-Length: -5\c\L\c\Labcde"))
    check "bad Content-Length" in outcome(transportTo(server.scriptedUrl).notify())
