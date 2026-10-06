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
