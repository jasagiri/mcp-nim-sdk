## What `transport/http_wire` puts on the request line and in headers, and
## what it accepts from a response head: no line breaks or control
## characters smuggled in either direction.

import std/[unittest, asyncdispatch, asyncnet, httpcore, nativesockets, strutils]
import transport/http_wire

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

suite "line breaks and control characters in HTTP":

  test "Given a header value with a line break, when a request is sent, then it is refused and nothing is connected":
    let peer = startPeer(plain)
    let headers = newHttpHeaders({"X-Note": "a\c\LX-Injected: yes"})
    check "line break or control" in outcome(request(peer.url, HttpGet, headers))
    check peer.connections == 0

  test "Given a bare LF or a NUL in a header value, when a request is sent, then it is refused":
    let peer = startPeer(plain)
    check "line break or control" in outcome(request(peer.url, HttpGet, newHttpHeaders({"X-Note": "a\LX: b"})))
    check "line break or control" in outcome(request(peer.url, HttpGet, newHttpHeaders({"X-Note": "a\x00b"})))
    check peer.connections == 0

  test "Given a header name that is not a token, when a request is sent, then it is refused":
    let peer = startPeer(plain)
    check "header name" in outcome(request(peer.url, HttpGet, newHttpHeaders({"X Bad": "1"})))
    check "header name" in outcome(request(peer.url, HttpGet, newHttpHeaders({"X-Bad\c\LX-Injected": "1"})))
    check peer.connections == 0

  test "Given a URL whose path carries a line break, when a request is sent, then it is refused":
    let peer = startPeer(plain)
    check "line break or control" in outcome(request(peer.url("/a\c\LX-Injected: yes"), HttpGet))
    check peer.connections == 0

  test "Given ordinary headers including a tab in a value, when a request is sent, then it is answered":
    let peer = startPeer(plain)
    check outcome(request(peer.url("/a?b=c"), HttpGet, newHttpHeaders({"X-Note": "a\tb"}))) == "ok"
    check peer.received.startsWith("GET /a?b=c HTTP/1.1\c\L")
    check "x-note: a\tb\c\L" in peer.received.toLowerAscii()

  test "Given a response header with a bare LF, when the head is read, then the response is refused":
    let peer = startPeer("HTTP/1.1 302 Found\c\LLocation: /next\LSet-Cookie: stolen=1\c\L\c\L")
    check "line break or control" in outcome(request(peer.url, HttpGet, followRedirects = false))

  test "Given a response header with a NUL or a bare CR, when the head is read, then the response is refused":
    let nul = startPeer("HTTP/1.1 200 OK\c\LMcp-Session-Id: a\x00b\c\LContent-Length: 0\c\L\c\L")
    check "line break or control" in outcome(request(nul.url, HttpGet))
    let cr = startPeer("HTTP/1.1 200 OK\c\LMcp-Session-Id: a\c" & "b\c\LContent-Length: 0\c\L\c\L")
    check "line break or control" in outcome(request(cr.url, HttpGet))

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

proc finishedBy(future: Future[WireResponse], limitMs = 3000): WireResponse =
  var waited = 0
  while not future.finished and waited < limitMs:
    poll(20)
    waited += 20
  doAssert future.finished, "the request did not end within " & $limitMs & " ms"
  future.read()

proc settle(limitMs: int) =
  var waited = 0
  while waited < limitMs:
    poll(20)
    waited += 20

proc openDescriptors(): int =
  for _ in walkDir("/dev/fd"):
    inc result

proc closeAfter(response: WireResponse, delayMs: int) {.async.} =
  await sleepAsync(delayMs)
  response.close()

proc abandoningAfter(delayMs: int): Connected =
  ## Closes the response `delayMs` after the connection exists.
  result = proc (response: WireResponse) {.closure, gcsafe.} =
    asyncCheck closeAfter(response, delayMs)

proc bodyOrError(response: WireResponse, maxSize = 1000, limitMs = 2000): string =
  ## The whole body, "error: " and the message when reading fails, or
  ## "pending" when it did not end within `limitMs`.
  let reading = response.readAll(maxSize)
  var waited = 0
  while not reading.finished and waited < limitMs:
    poll(20)
    waited += 20
  if not reading.finished: "pending"
  elif reading.failed: "error: " & reading.readError().msg
  else: reading.read()

const
  chunkedHead = "HTTP/1.1 200 OK\c\LTransfer-Encoding: chunked\c\L\c\L"
  MaxHead = 64 * 1024
  PauseMs = 500

proc sending(parts: varargs[string]): Answer =
  ## Sends each of `parts`, with a pause after every one but the last, then
  ## keeps the connection open until the client ends it.
  let pieces = @parts
  result = proc (server: Scripted, client: AsyncSocket, index: int): Future[void] {.async.} =
    for n, piece in pieces:
      if n > 0:
        await sleepAsync(PauseMs)
      await client.send(piece)
    await holdUntilEnd(server, client, index)

suite "closing a response while it is read (mutation review, g2g-hc-c)":

  test "Given a response that is closed while its body is awaited, when the read wakes, then it returns the end of the body and does not fail":
    let server = startScripted(sending("HTTP/1.1 200 OK\c\LContent-Length: 100\c\L\c\L"))
    let response = request(server.scriptedUrl, HttpGet).finishedBy
    let part = response.readSome()
    settle(100)
    check not part.finished
    response.close()
    check part.outcome == "ok"
    check part.read() == ""

  test "Given a response that is closed while its head is awaited, when the request wakes, then it fails as abandoned":
    let server = startScripted(sending(""))
    let attempt = request(server.scriptedUrl, HttpGet, connected = abandoningAfter(150))
    check "was abandoned" in attempt.outcome

suite "a Content-Length that cannot be a length (mutation review, g2g-hc-c)":

  test "Given a negative Content-Length, when the head is read, then the response is refused":
    let server = startScripted(ending("HTTP/1.1 200 OK\c\LContent-Length: -5\c\L\c\Labcde"))
    check "bad Content-Length" in outcome(request(server.scriptedUrl, HttpGet))
