## What `transport/http_wire` puts on the request line and in headers, and
## what it accepts from a response head: no line breaks or control
## characters smuggled in either direction.

import std/[unittest, asyncdispatch, asyncnet, httpcore, json, nativesockets, strutils]
import transport/http
import protocol/types
import transport/http_compat
from mcp import McpTransportError

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

# ---- mutation review, g2g-wire-e ----------------------------------------

const
  Message = """{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"x"}}"""
  ChunkedHead = "HTTP/1.1 200 OK\c\LTransfer-Encoding: chunked\c\L\c\L"
  SpeaksSessions = DefaultProtocolVersion >= mpv20250326

static:
  doAssert Message.len >= 80

proc paced(first, second: string, pauseMs = 150): Answer =
  ## Answers `first`, waits so that the client has read it on its own, then
  ## answers `second` and closes. The wait only separates the two reads; what
  ## the client must do does not depend on how long it is.
  result = proc (server: Scripted, client: AsyncSocket, index: int): Future[void] {.async.} =
    await client.send(first)
    await sleepAsync(pauseMs)
    await client.send(second)

proc requestLine(server: Scripted, index = 0): string =
  server.requests[index].split("\c\L")[0]

proc failure[T](future: Future[T]): ref Exception =
  ## What `future` failed with, nil when it did not fail (in time).
  discard outcome(future)
  if future.finished and future.failed: future.readError() else: nil

proc hex(n: int, width = 0, upper = false): string =
  ## `n` in hexadecimal digits, `width` of them when that is asked for.
  result = if width > 0: toHex(n, width) else: toHex(n).strip(trailing = false, chars = {'0'})
  if not upper:
    result = result.toLowerAscii

proc chunked(pieces: seq[(string, string)], last = "0\c\L\c\L"): string =
  ## A 200 answer in chunks: each piece is (size as written, data).
  result = ChunkedHead
  for (size, data) in pieces:
    result.add size & "\c\L" & data & "\c\L"
  result.add last

suite "the request line and the body headers (mutation review, g2g-wire-e)":

  test "Given URLs with no path, a path, and a path with a query, when a notification is sent, then the request line names the path and query, or / when there is none":
    for (path, line) in [("", "POST / HTTP/1.1"), ("/a", "POST /a HTTP/1.1"),
                         ("/a?b=1", "POST /a?b=1 HTTP/1.1")]:
      let server = startScripted(ending(plain))
      check outcome(transportTo(server.scriptedUrl(path)).notify()) == "ok"
      check server.requestLine == line

  when SpeaksSessions:
    test "Given a session on a version with the GET stream, when the stream is opened and the session ended, then neither the GET nor the DELETE carries a Content-Length":
      let server = startScripted(proc (server: Scripted, client: AsyncSocket, index: int): Future[void] {.async.} =
        let head = server.requests[index].split("\c\L")[0]
        if head.startsWith("POST"):
          let body = server.requests[index].split("\c\L\c\L", maxsplit = 1)[1]
          let id = if body.contains("\"id\""): parseJson(body)["id"] else: nil
          if id.isNil:
            await client.send("HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L")
          else:
            let answer = $(%*{"jsonrpc": "2.0", "id": id, "result": {}})
            await client.send("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\LMcp-Session-Id: s-1\c\L" &
                              "Content-Length: " & $answer.len & "\c\L\c\L" & answer)
        elif head.startsWith("GET"):
          await client.send("HTTP/1.1 405 Method Not Allowed\c\LAllow: POST, DELETE\c\LContent-Length: 0\c\L\c\L")
        else:
          await client.send(plain))
      let transport = transportTo(server.scriptedUrl("/mcp"))
      check outcome(transport.sendRequest(newJsonRpcRequest("1", "initialize", newJObject()))) == "ok"
      transport.protocolVersionNegotiated(mpv20250326)
      check outcome(transport.sendNotification(
        newJsonRpcNotification("notifications/initialized", newJObject()))) == "ok"
      settle(200)
      check outcome(transport.close()) == "ok"
      var seen: seq[string]
      for request in server.requests:
        let head = request.split("\c\L\c\L")[0].toLowerAscii()
        if not head.startsWith("post"):
          seen.add head.split("\c\L")[0].split(' ')[0]
          check "content-length" notin head
      check "get" in seen
      check "delete" in seen

suite "the response head and what has no body (mutation review, g2g-wire-e)":

  test "Given a status line without a reason phrase, when the head is read, then the response is taken":
    let server = startScripted(ending("HTTP/1.1 200\c\LContent-Length: 0\c\L\c\L"))
    check outcome(transportTo(server.scriptedUrl).notify()) == "ok"

  test "Given a status of 100 or of 599, when the head is read, then the request fails with that status":
    for code in [100, 599]:
      let server = startScripted(ending("HTTP/1.1 " & $code & " Odd\c\LContent-Length: 0\c\L\c\L"))
      let failed = failure(transportTo(server.scriptedUrl).notify())
      check failed of McpTransportError
      if failed of McpTransportError:
        check (ref McpTransportError)(failed).code == code

  test "Given a 204, when the server keeps the connection open, then the request succeeds at once and the client ends the connection":
    let server = startScripted(keeping("HTTP/1.1 204 No Content\c\L\c\L"))
    check outcome(transportTo(server.scriptedUrl).notify()) == "ok"
    settle(100)
    check server.ended[0]

  test "Given a 1xx or a 304, when the server keeps the connection open, then the request fails as an HTTP failure at once and the client ends the connection":
    for (code, reason) in [(100, "Continue"), (304, "Not Modified")]:
      let server = startScripted(keeping("HTTP/1.1 " & $code & " " & reason & "\c\L\c\L"))
      let failed = failure(transportTo(server.scriptedUrl).notify())
      check failed of McpTransportError
      settle(100)
      check server.ended[0]

suite "the limits and ends of a body (mutation review, g2g-wire-e)":

  proc headOf(length: int): string =
    ## A response head `length` bytes long, before its blank line.
    let start = "HTTP/1.1 200 OK\c\LContent-Length: 0\c\LX-Pad: "
    start & repeat('p', length - start.len)

  test "Given a head of exactly 65536 bytes still waiting for its blank line, when the blank line arrives, then the response is taken; one byte more is refused":
    let exact = startScripted(paced(headOf(65536), "\c\L\c\L"))
    check outcome(transportTo(exact.scriptedUrl).notify()) == "ok"
    let over = startScripted(proc (server: Scripted, client: AsyncSocket, index: int): Future[void] {.async.} =
      await client.send(headOf(65537))
      await holdUntilEnd(server, client, index))
    check failure(transportTo(over.scriptedUrl).notify()) of McpTransportError

  test "Given a chunk size line of 64 bytes and one of 65, when the body is read, then the first is accepted and the second refused":
    proc sized(lineLength: int): string =
      let size = hex(Message.len)
      chunked(@[(size & ";" & repeat('x', lineLength - 1 - size.len - 1), Message)])
    let accepted = startScripted(ending(sized(64)))
    check outcome(transportTo(accepted.scriptedUrl).notify()) == "ok"
    let refused = startScripted(ending(sized(65)))
    check failure(transportTo(refused.scriptedUrl).notify()) of McpTransportError

  test "Given chunk sizes written with lower case digits, upper case digits and fifteen digits, when the body is read, then the message arrives whole":
    var sizes: seq[int]
    for n in 10 .. 15:
      sizes.add n
    for (upper, label) in [(false, "lower"), (true, "upper")]:
      var pieces: seq[(string, string)]
      var at = 0
      for n in sizes:
        pieces.add (hex(n, upper = upper), Message[at ..< at + n])
        at += n
      pieces.add (hex(Message.len - at, 15, upper), Message[at .. ^1])
      let server = startScripted(ending(chunked(pieces)))
      let transport = transportTo(server.scriptedUrl)
      check outcome(transport.notify()) == "ok"
      let delivered = transport.receiveMessage()
      check outcome(delivered) == "ok"
      if delivered.finished and not delivered.failed:
        check delivered.read()["method"].getStr() == "notifications/message"

  test "Given one extra byte between a chunk's data and its line end, when the body is read, then the request fails":
    let server = startScripted(ending(chunked(@[(hex(Message.len), Message & "X")])))
    check failure(transportTo(server.scriptedUrl).notify()) of McpTransportError

  test "Given a last chunk and a trailer line, when the blank line never comes and the connection closes, then the request fails; with the blank line it succeeds":
    let trailer = "0\c\LX-Trailer: 1\c\L"
    let complete = startScripted(ending(chunked(@[(hex(Message.len), Message)], trailer & "\c\L")))
    check outcome(transportTo(complete.scriptedUrl).notify()) == "ok"
    let cut = startScripted(ending(chunked(@[(hex(Message.len), Message)], trailer)))
    check failure(transportTo(cut.scriptedUrl).notify()) of McpTransportError

  test "Given a chunk size line that arrives before its data, when the data follows, then the message is delivered":
    let server = startScripted(paced(ChunkedHead & hex(Message.len) & "\c\L",
                                     Message & "\c\L0\c\L\c\L"))
    let transport = transportTo(server.scriptedUrl)
    check outcome(transport.notify()) == "ok"
    let delivered = transport.receiveMessage()
    check outcome(delivered) == "ok"
    if delivered.finished and not delivered.failed:
      check delivered.read()["method"].getStr() == "notifications/message"

suite "giving up while a body arrives until the connection closes (mutation review, g2g-wire-e)":

  test "Given a JSON body without a length that has begun, when the client cancels the request, then sendRequest ends without an error and nothing is reported lost":
    let server = startScripted(keeping("HTTP/1.1 200 OK\c\LContent-Type: application/json\c\L\c\L{\"jsonrpc\": \"2.0\", "))
    let transport = transportTo(server.scriptedUrl)
    var lost: seq[string]
    transport.onRequestLost = proc(requestId: string, reason: string) = lost.add requestId
    let sending = transport.sendRequest(newJsonRpcRequest("r1", "tools/call", newJObject()))
    var waited = 0
    while (server.requests.len == 0 or server.requests[0].len == 0) and waited < 2000:
      poll(20)
      waited += 20
    settle(100)
    transport.cancelRequest("r1")
    check outcome(sending) == "ok"
    check lost.len == 0

suite "the answer to the stream request of the HTTP+SSE transport (mutation review, g2g-wire-e)":

  proc connectAttempt(url: string): Future[void] =
    newSseLegacyTransport(url).sendNotification(
      newJsonRpcNotification("notifications/initialized", newJObject()))

  test "Given an error answer whose body is cut short, when the stream request fails again and again, then no connection is left open":
    if not dirExists("/dev/fd"):
      skip()
    else:
      let cutLength = startScripted(ending("HTTP/1.1 500 Internal Server Error\c\LContent-Length: 100\c\L\c\Lshort"))
      let cutChunk = startScripted(ending("HTTP/1.1 500 Internal Server Error\c\LTransfer-Encoding: chunked\c\L\c\L5\c\Lab"))
      for server in [cutLength, cutChunk]:
        check failure(connectAttempt(server.scriptedUrl("/sse"))) of McpTransportError
      settle(100)
      let before = openDescriptors()
      for round in 1 .. 3:
        for server in [cutLength, cutChunk]:
          check failure(connectAttempt(server.scriptedUrl("/sse"))) of McpTransportError
      settle(200)
      check openDescriptors() == before

  test "Given an error answer whose body outgrows the limit and goes on, when the stream request is made, then it fails and the client closes the connection":
    let server = startScripted(keeping("HTTP/1.1 500 Internal Server Error\c\LContent-Length: 100000\c\L\c\L" &
                                       repeat('e', 2000)))
    check failure(connectAttempt(server.scriptedUrl("/sse"))) of McpTransportError
    settle(100)
    check server.ended[0]
