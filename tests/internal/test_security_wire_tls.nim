## A TLS connection made by `transport/http_wire` is to the server it names:
## the certificate has to be valid for the host of the URL.
##
## Needs `-d:ssl` (nimble test runs it so) and the `openssl` command, which
## makes a CA and a server certificate in a temporary directory.

import std/[unittest, asyncdispatch, asyncnet, httpcore, net, os, osproc, strutils]
import transport/http_wire

when not defined(ssl):
  suite "TLS host name verification":
    test "Given a build without -d:ssl, then these tests cannot run":
      fail()
      echo "test_security_wire_tls needs -d:ssl: nim c -r -d:ssl tests/internal/test_security_wire_tls.nim"
else:
  type Pki = object
    dir: string
    caFile: string

  proc openssl(args: string) =
    let (output, code) = execCmdEx("openssl " & args)
    if code != 0:
      raise newException(OSError, "`openssl " & args & "` failed (" & $code & "): " & output)

  proc makeCa(dir: string): string =
    ## A self-signed CA; its certificate is the trust anchor of the tests.
    openssl("req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=test-ca -keyout " &
            (dir / "ca.key").quoteShell & " -out " & (dir / "ca.pem").quoteShell)
    dir / "ca.pem"

  proc makeServerCert(dir, name, altNames: string): tuple[cert, key: string] =
    ## A certificate signed by the CA of `dir`, valid for `altNames`
    ## ("DNS:a.example,IP:127.0.0.1").
    let key = dir / (name & ".key")
    let request = dir / (name & ".csr")
    let cert = dir / (name & ".pem")
    let extensions = dir / (name & ".ext")
    writeFile(extensions, "[ext]\nsubjectAltName=" & altNames & "\n")
    openssl("req -newkey rsa:2048 -nodes -subj /CN=" & name & " -keyout " & key.quoteShell &
            " -out " & request.quoteShell)
    openssl("x509 -req -days 2 -in " & request.quoteShell & " -CA " & (dir / "ca.pem").quoteShell &
            " -CAkey " & (dir / "ca.key").quoteShell & " -CAcreateserial -extfile " &
            extensions.quoteShell & " -extensions ext -out " & cert.quoteShell)
    (cert, key)

  proc freePort(): int =
    let probe = newSocket()
    probe.bindAddr(Port(0), "127.0.0.1")
    result = probe.getLocalAddr()[1].int
    probe.close()

  proc serve(certFile, keyFile: string): tuple[port: int, process: Process] =
    ## `openssl s_server -www` on a free loopback port: it answers any GET
    ## with 200 once the handshake has succeeded. Waits until it accepts.
    result.port = freePort()
    result.process = startProcess("openssl", args = ["s_server", "-accept", $result.port,
      "-cert", certFile, "-key", keyFile, "-www"], options = {poUsePath, poStdErrToStdOut})
    for attempt in 0 ..< 100:
      let probe = newSocket()
      try:
        probe.connect("127.0.0.1", Port(result.port))
        probe.close()
        return
      except OSError:
        probe.close()
        sleep(50)
    result.process.kill()
    raise newException(OSError, "openssl s_server did not start")

  proc outcome(pending: Future[WireResponse]): string =
    ## "ok" when the request is answered, otherwise the message of the failure.
    let deadline = 8000
    var waited = 0
    while not pending.finished and waited < deadline:
      poll(20)
      waited += 20
    if not pending.finished:
      return "pending"
    if pending.failed:
      return pending.readError().msg
    pending.read().close()
    "ok"

  proc outcome(url, caFile: string, connectTo = ""): string =
    outcome(request(url, HttpGet, caFile = caFile, connectTo = connectTo))

  suite "TLS host name verification":
    var pki: Pki

    setup:
      pki.dir = getTempDir() / ("mcp-wire-tls-" & $getCurrentProcessId())
      createDir(pki.dir)
      try:
        pki.caFile = makeCa(pki.dir)
      except OSError as e:
        fail()
        echo "cannot run: " & e.msg

    teardown:
      removeDir(pki.dir)

    test "Given a certificate for the host named in the URL, when the request is sent, then it is answered":
      let (cert, key) = makeServerCert(pki.dir, "named", "DNS:wire.example")
      let (port, server) = serve(cert, key)
      defer:
        server.kill()
        server.close()
      check outcome("https://wire.example:" & $port & "/", pki.caFile, "127.0.0.1") == "ok"

    test "Given a certificate for another host than the URL names, when the request is sent, then it is refused":
      let (cert, key) = makeServerCert(pki.dir, "other", "DNS:other.example")
      let (port, server) = serve(cert, key)
      defer:
        server.kill()
        server.close()
      let result = outcome("https://wire.example:" & $port & "/", pki.caFile, "127.0.0.1")
      check "is not valid for" in result

    test "Given a certificate for the IP address in the URL, when the request is sent, then it is answered":
      let (cert, key) = makeServerCert(pki.dir, "address", "IP:127.0.0.1")
      let (port, server) = serve(cert, key)
      defer:
        server.kill()
        server.close()
      check outcome("https://127.0.0.1:" & $port & "/", pki.caFile) == "ok"

    test "Given a certificate for a name only, when the URL names an IP address, then it is refused":
      let (cert, key) = makeServerCert(pki.dir, "nameonly", "DNS:wire.example")
      let (port, server) = serve(cert, key)
      defer:
        server.kill()
        server.close()
      let result = outcome("https://127.0.0.1:" & $port & "/", pki.caFile)
      check "is not valid for" in result

  suite "TLS connection timeout":

    test "Given a server that accepts the connection and never speaks TLS, when the connect timeout passes, then the request fails":
      let silent = newSocket()
      silent.bindAddr(Port(0), "127.0.0.1")
      silent.listen()
      defer: silent.close()
      let port = silent.getLocalAddr()[1].int
      let attempt = request("https://127.0.0.1:" & $port & "/", HttpGet, connectTimeoutMs = 300)
      check "no connection" in outcome(attempt)

  # ---- mutation review, g2g-hc-c ----------------------------------------

  proc openDescriptors(): int =
    for _ in walkDir("/dev/fd"):
      inc result

  proc settle(limitMs: int) =
    ## Runs the event loop for `limitMs`; an empty loop has nothing to run,
    ## and `poll` refuses one, so the time then just passes.
    var waited = 0
    while waited < limitMs:
      if hasPendingOperations():
        poll(20)
      else:
        sleep(20)
      waited += 20

  type Delayed = ref object
    ## Forwards each connection to `upstream` after `delayMs`, so that a
    ## handshake is slower than a connect timeout; records whether the client
    ## ended the connection.
    socket: AsyncSocket
    port: int
    clientEnded: bool

  proc pump(source, sink: AsyncSocket) {.async.} =
    ## Copies until `source` ends. The other direction closes both sockets
    ## when its side ends; a read or write that was waiting then fails, which
    ## ends this one too.
    try:
      while true:
        let data = await source.recv(4096)
        if data.len == 0:
          break
        await sink.send(data)
    except OSError:
      discard

  proc startDelayed(upstream, delayMs: int): Delayed =
    let forwarder = Delayed(socket: newAsyncSocket(buffered = false))
    forwarder.socket.bindAddr(Port(0), "127.0.0.1")
    forwarder.socket.listen()
    forwarder.port = forwarder.socket.getLocalAddr()[1].int
    proc relay(client: AsyncSocket) {.async.} =
      await sleepAsync(delayMs)
      let onward = newAsyncSocket(buffered = false)
      await onward.connect("127.0.0.1", Port(upstream))
      asyncCheck pump(onward, client)
      await pump(client, onward)
      forwarder.clientEnded = true
      onward.close()
      client.close()
    proc acceptLoop() {.async.} =
      while true:
        asyncCheck relay(await forwarder.socket.accept())
    asyncCheck acceptLoop()
    forwarder

  suite "connections that do not become a response (mutation review, g2g-hc-c)":
    var pki: Pki

    setup:
      pki.dir = getTempDir() / ("mcp-wire-tls-g2g-hc-c-" & $getCurrentProcessId())
      createDir(pki.dir)
      try:
        pki.caFile = makeCa(pki.dir)
      except OSError as e:
        fail()
        echo "cannot run: " & e.msg

    teardown:
      removeDir(pki.dir)

    test "Given a certificate for another host, when requests are refused again and again, then no connection is left open":
      if not dirExists("/dev/fd"):
        skip()
      else:
        let (cert, key) = makeServerCert(pki.dir, "refused", "DNS:other.example")
        let (port, server) = serve(cert, key)
        defer:
          server.kill()
          server.close()
        let url = "https://wire.example:" & $port & "/"
        check "is not valid for" in outcome(url, pki.caFile, "127.0.0.1")
        settle(200)
        let before = openDescriptors()
        for attempt in 1 .. 3:
          check "is not valid for" in outcome(url, pki.caFile, "127.0.0.1")
        settle(300)
        check openDescriptors() == before

    test "Given a handshake that ends after the connect timeout, when it ends, then the connection is closed by the client":
      let (cert, key) = makeServerCert(pki.dir, "late", "DNS:wire.example")
      let (port, server) = serve(cert, key)
      defer:
        server.kill()
        server.close()
      let delayed = startDelayed(port, 800)
      let attempt = request("https://wire.example:" & $delayed.port & "/", HttpGet,
                            caFile = pki.caFile, connectTo = "127.0.0.1", connectTimeoutMs = 200)
      check "no connection" in outcome(attempt)
      settle(2500)
      check delayed.clientEnded
