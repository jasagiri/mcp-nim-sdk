## What a program sees of the HTTP server transport when it also serves HTTP
## with `std/asynchttpserver` itself. On a Nim whose `asynchttpserver` does
## not keep header lines whole the SDK runs on its own copy of that module,
## whose types are not the standard library's; none of them may be part of
## what `import mcp` offers, or such a program could not use what it is
## given.

import std/[unittest, asyncdispatch, asynchttpserver]
import mcp

suite "a program that also uses std/asynchttpserver":

  test "Given a program that imports std/asynchttpserver and mcp, when it makes an HTTP server transport and a server of its own, then both compile and serve side by side":
    let own = newAsyncHttpServer()
    own.listen(Port(0))
    let transport = newHttpServerTransport(port = 0)
    transport.listen()
    check own.getPort.int > 0
    check transport.port > 0
    check own.getPort.int != transport.port
    waitFor transport.close()
    own.close()

  test "Given an HTTP server transport, then the asynchttpserver it serves with is not one of its fields":
    let transport = newHttpServerTransport(port = 0)
    check not compiles(transport.server)

  test "Given import mcp, then the procs that write an event stream to an asynchttpserver request are not offered":
    check not declared(serveStream)
    check not declared(writeHead)
