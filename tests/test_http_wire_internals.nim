## Facts about `transport/http_wire` that the network does not show: the text
## of a request when the URL names no port (the default port cannot be bound
## here), and how a read starts on a response that is already closed. The
## module is included so that its private procs can be called; the rest of
## the wire is tested over sockets in test_security_wire_*.

import std/[unittest, asyncdispatch, asyncnet, httpcore, strutils, uri]
include transport/http_wire

suite "request text and read ends of http_wire (mutation review, g2g-hc-c)":

  test "Given a URL without a port, when the request is written, then Host names the host alone; with a port, host and port":
    check requestText(parseUri("http://wire.example/x"), HttpGet, newHttpHeaders(), "").startsWith(
      "GET /x HTTP/1.1\c\LHost: wire.example\c\L")
    check requestText(parseUri("http://wire.example:8080/x"), HttpGet, newHttpHeaders(), "").startsWith(
      "GET /x HTTP/1.1\c\LHost: wire.example:8080\c\L")

  test "Given a response that has been closed, when a read is started, then it ends as interrupted without reading":
    let response = WireResponse(socket: newAsyncSocket(buffered = false), mode: bmUntilClose)
    response.close()
    let read = waitFor response.receive()
    check read.interrupted
    check read.data == ""
