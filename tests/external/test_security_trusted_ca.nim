## A client that is told which certificate authorities to trust (`caFile`)
## uses them for each kind of https request, talks only to the server the URL
## names, and an icon fetch over https that gives up leaves no connection
## behind. Seen from outside: the
## test is the TLS server, and records what reached it.
##
## Needs `-d:ssl` (nimble test runs it so) and the `openssl` command, which
## makes a CA and the server certificates in a temporary directory.

import std/[unittest, asyncdispatch, asyncnet, json, net, os, osproc, strutils]
import mcp
import auth/client
import transport/http_compat

when not defined(ssl):
  suite "a client that trusts a given CA":
    test "Given a build without -d:ssl, then these tests cannot run":
      fail()
      echo "test_security_trusted_ca needs -d:ssl: nim c -r -d:ssl tests/external/test_security_trusted_ca.nim"
else:
  const Png = "\x89PNG\r\n\x1a\n" & "rest of a png"

  proc openssl(args: string) =
    let (output, code) = execCmdEx("openssl " & args)
    if code != 0:
      raise newException(OSError, "`openssl " & args & "` failed (" & $code & "): " & output)

  proc makeCa(dir: string): string =
    ## A self-signed CA; its certificate is what the client is told to trust.
    openssl("req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=test-ca -keyout " &
            (dir / "ca.key").quoteShell & " -out " & (dir / "ca.pem").quoteShell)
    dir / "ca.pem"

  proc makeServerCert(dir, name, altNames: string): tuple[cert, key: string] =
    ## A certificate signed by the CA of `dir`, valid for `altNames`
    ## ("DNS:localhost,IP:127.0.0.1").
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

  type TlsServer = ref object
    port: int
    requests: int
      ## Requests whose head arrived, that is, HTTP sent after a handshake.
    peerClosed: bool
      ## The client closed its end after the answer was sent.

  proc startTlsServer(cert, key: string, answerFor: proc(head: string): string,
                      delayMs = 0): TlsServer =
    ## Answers each request with `answerFor(head)` after `delayMs`, then waits
    ## for the client to close the connection.
    let server = TlsServer()
    let context = newContext(verifyMode = CVerifyNone, certFile = cert, keyFile = key)
    # A buffered TLS socket held back the answer: curl never received it.
    let socket = newAsyncSocket(buffered = false)
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(Port(0), "127.0.0.1")
    socket.listen()
    server.port = socket.getLocalAddr()[1].int
    proc serve(client: AsyncSocket) {.async.} =
      var head = ""
      try:
        while not head.contains("\c\L\c\L"):
          let data = await client.recv(4096)
          if data.len == 0:
            return
          head.add data
      except CatchableError:
        return # the handshake failed: the client refused the certificate
      inc server.requests
      await sleepAsync(delayMs)
      await client.send(answerFor(head))
      try:
        if (await client.recv(1)).len == 0:
          server.peerClosed = true
      except CatchableError:
        server.peerClosed = true
    proc acceptLoop() {.async.} =
      while true:
        let client = await socket.accept()
        context.wrapConnectedSocket(client, handshakeAsServer)
        asyncCheck serve(client)
    asyncCheck acceptLoop()
    server

  proc startTlsServer(cert, key: string, answer: string, delayMs = 0): TlsServer =
    ## Answers every request with `answer`.
    startTlsServer(cert, key, proc(head: string): string = answer, delayMs)

  proc waitUntil(condition: proc(): bool, limitMs = 3000) =
    var waited = 0
    while not condition() and waited < limitMs:
      poll(20)
      waited += 20

  proc notify(url, caFile: string): bool =
    ## Sends one notification over Streamable HTTP; true when it was accepted.
    let transport = newStreamableHttpTransport(url)
    transport.caFile = caFile
    try:
      waitFor transport.sendNotification(JsonRpcNotification(
        jsonrpc: "2.0", `method`: "notifications/initialized", params: newJObject()))
      result = true
    except CatchableError:
      result = false

  const Accepted = "HTTP/1.1 202 Accepted\c\LContent-Length: 0\c\L\c\L"

  let pki = getTempDir() / "mcp-trusted-ca-" & $getCurrentProcessId()
  createDir(pki)
  let caFile = makeCa(pki)
  let local = makeServerCert(pki, "local", "DNS:localhost,IP:127.0.0.1")
  let nameOnly = makeServerCert(pki, "nameonly", "DNS:localhost")
  let other = makeServerCert(pki, "other", "DNS:other.example")

  suite "a TLS server whose certificate names another host is refused":

    test "Given a certificate for the host the URL names, when a notification is sent, then it reaches the server":
      let server = startTlsServer(local.cert, local.key, Accepted)
      check notify("https://localhost:" & $server.port & "/mcp", caFile)
      check server.requests == 1

    test "Given a certificate for the IP address the URL names, when a notification is sent, then it reaches the server":
      let server = startTlsServer(local.cert, local.key, Accepted)
      check notify("https://127.0.0.1:" & $server.port & "/mcp", caFile)
      check server.requests == 1

    test "Given a certificate for another host, when a notification is sent, then it fails before any HTTP is sent":
      let server = startTlsServer(other.cert, other.key, Accepted)
      check not notify("https://localhost:" & $server.port & "/mcp", caFile)
      check server.requests == 0

    test "Given a certificate for a name only, when the URL names an IP address, then it fails before any HTTP is sent":
      let server = startTlsServer(nameOnly.cert, nameOnly.key, Accepted)
      check not notify("https://127.0.0.1:" & $server.port & "/mcp", caFile)
      check server.requests == 0

    test "Given no caFile, when the server's CA is not one the system trusts, then it fails before any HTTP is sent":
      let server = startTlsServer(local.cert, local.key, Accepted)
      check not notify("https://localhost:" & $server.port & "/mcp", "")
      check server.requests == 0

  proc iconFailure(origin: string, options: IconFetchOptions): string =
    try:
      discard waitFor fetchIcon(McpIcon(src: origin & "/icon.png"), origin, options)
    except McpIconError as e:
      return e.msg

  suite "an icon fetch over https that gives up leaves no connection behind":

    test "Given an answer that comes after the timeout, when the fetch has failed, then the client closes that connection":
      let server = startTlsServer(local.cert, local.key,
        "HTTP/1.1 200 OK\c\LContent-Type: image/png\c\LContent-Length: " & $Png.len & "\c\L\c\L" & Png,
        delayMs = 400)
      let origin = "https://127.0.0.1:" & $server.port
      check "no answer within" in iconFailure(origin, IconFetchOptions(timeoutMs: 100, caFile: caFile))
      waitUntil(proc(): bool = server.peerClosed)
      check server.requests == 1
      check server.peerClosed

    test "Given an answer that is not 200, when the fetch is refused, then the client closes the connection without reading the body":
      # The body is announced but never sent: a client that read it would
      # wait for it instead of closing.
      let server = startTlsServer(local.cert, local.key,
        "HTTP/1.1 404 Not Found\c\LContent-Type: image/png\c\LContent-Length: 100000\c\L\c\L")
      let origin = "https://127.0.0.1:" & $server.port
      check "404" in iconFailure(origin, IconFetchOptions(caFile: caFile))
      waitUntil(proc(): bool = server.peerClosed)
      check server.peerClosed

  proc eventuallyFails(attempt: Future[void] | Future[bool], limitMs = 2000): bool =
    ## Whether `attempt` ends with an error. Waits at most `limitMs`; one
    ## that is still running then has not failed.
    try:
      # withTimeout fails with the attempt
      if not waitFor withTimeout(attempt, limitMs):
        return false
    except CatchableError:
      return true
    attempt.failed

  const SseAnswer = "HTTP/1.1 200 OK\c\LContent-Type: text/event-stream\c\L\c\L" &
                    "event: endpoint\c\Ldata: /messages\c\L\c\L"
  proc sseOrAccepted(head: string): string =
    if head.startsWith("GET"): SseAnswer else: Accepted

  const NotFound = "HTTP/1.1 404 Not Found\c\LContent-Type: application/json\c\LContent-Length: 2\c\L\c\L{}"
  proc metadataUrl(server: TlsServer): string =
    "https://127.0.0.1:" & $server.port & "/.well-known/oauth-protected-resource"
  proc oauthClient(server: TlsServer, caFile: string): OAuthClient =
    var config = newOAuthClientConfig("https://127.0.0.1:" & $server.port & "/mcp",
      "http://127.0.0.1:8080/cb",
      proc(url: string): Future[seq[(string, string)]] {.async.} =
        doAssert false, "the user was sent to " & url)
    config.fetchPolicy.caFile = caFile
    newOAuthClient(config)

  suite "a client told which certificate authorities to trust uses them for every https request":

    test "Given caFile on an HTTP+SSE transport, when it connects, then its stream request reaches the server":
      let server = startTlsServer(local.cert, local.key, sseOrAccepted)
      let transport = newSseLegacyTransport("https://127.0.0.1:" & $server.port & "/sse")
      transport.caFile = caFile
      check not eventuallyFails(transport.sendNotification(JsonRpcNotification(
        jsonrpc: "2.0", `method`: "notifications/initialized", params: newJObject())))
      check server.requests >= 1
      waitFor transport.close()

    test "Given no caFile on an HTTP+SSE transport, when it connects, then it fails before any HTTP is sent":
      let server = startTlsServer(local.cert, local.key, sseOrAccepted)
      let transport = newSseLegacyTransport("https://127.0.0.1:" & $server.port & "/sse")
      check eventuallyFails(transport.sendNotification(JsonRpcNotification(
        jsonrpc: "2.0", `method`: "notifications/initialized", params: newJObject())))
      check server.requests == 0

    test "Given caFile in the icon options, when an icon is fetched, then it arrives":
      let server = startTlsServer(local.cert, local.key,
        "HTTP/1.1 200 OK\c\LContent-Type: image/png\c\LContent-Length: " & $Png.len & "\c\L\c\L" & Png)
      let origin = "https://127.0.0.1:" & $server.port
      let icon = waitFor fetchIcon(McpIcon(src: origin & "/icon.png"), origin,
                                   IconFetchOptions(caFile: caFile))
      check icon.bytes == Png

    test "Given no caFile in the icon options, when an icon is fetched, then it fails before any HTTP is sent":
      let server = startTlsServer(local.cert, local.key,
        "HTTP/1.1 200 OK\c\LContent-Type: image/png\c\LContent-Length: " & $Png.len & "\c\L\c\L" & Png)
      let origin = "https://127.0.0.1:" & $server.port
      check iconFailure(origin, IconFetchOptions()).len > 0
      check server.requests == 0

    test "Given caFile in the fetch policy of authorization, when a challenge names resource metadata, then the metadata request reaches the server":
      let server = startTlsServer(local.cert, local.key, NotFound)
      let client = oauthClient(server, caFile)
      discard eventuallyFails(client.handleChallenge(401,
        @["Bearer resource_metadata=\"" & server.metadataUrl & "\""]))
      check server.requests >= 1

    test "Given no caFile in the fetch policy of authorization, when a challenge names resource metadata, then it fails before any HTTP is sent":
      let server = startTlsServer(local.cert, local.key, NotFound)
      let client = oauthClient(server, "")
      check eventuallyFails(client.handleChallenge(401,
        @["Bearer resource_metadata=\"" & server.metadataUrl & "\""]))
      check server.requests == 0

  removeDir(pki)
