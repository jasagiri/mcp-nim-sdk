## A small HTTP/1.1 client whose response body can be read as it arrives.
##
## `std/httpclient` reads a body in blocks of 4000 bytes and hands over
## nothing before a block is full, so an event stream that sends a few short
## events and then waits stays unseen. The messages of an MCP server must
## reach the client when they are sent; this client reads from an unbuffered
## socket, decodes chunked bodies on the way, and returns whatever has
## arrived.
##
## One connection serves one request (`Connection: close`). `https` needs
## the program to be built with `-d:ssl`.

import std/[asyncdispatch, asyncnet, httpcore, strutils, uri]
import std/net except dial
import ./transport
import ./first_of
import ./deadline_watch

when defined(ssl):
  import std/openssl

  proc X509_check_ip_asc(cert: PX509, address: cstring, flags: cuint): cint
    {.cdecl, dynlib: DLLUtilName, importc.}
    ## `std/openssl` wraps `X509_check_host` but not its sibling for IP
    ## addresses; it is imported from the library `std/openssl` loads.

const
  DefaultConnectTimeoutMs* = 30_000
    ## For the connection: name resolution, TCP and, for https, the TLS
    ## handshake. Slower than any link a protocol client is used over, and
    ## far short of the minutes an operating system waits on its own. Nothing
    ## has been sent yet, so ending it loses no work.
  MaxHeadSize = 64 * 1024
  ReadSize = 16 * 1024
  MaxRedirects = 5

type
  BodyMode = enum
    bmNone, bmLength, bmChunked, bmUntilClose

  ChunkState = enum
    csSizeLine, csData, csDataEnd, csTrailers, csDone

  WireResponse* = ref object
    code*: HttpCode
    headers*: HttpHeaders
    socket: AsyncSocket
    pending: string        ## bytes read past the head, not yet decoded
    mode: BodyMode
    remaining: int         ## bytes left of a Content-Length body or of a chunk
    chunk: ChunkState
    line: string           ## the size line or trailer line being read
    finished: bool
    closed: bool
    cut: bool              ## `close` ended a read before the body did
    interrupt: Future[void]
      ## Of the read that waits on the socket now: `close` completes it. One
      ## per read, because a callback cannot be taken off a future again and
      ## a read happens for every chunk of the body.

proc httpFailure(message: string): ref McpTransportError =
  newException(McpTransportError, message)

when defined(ssl):
  proc verifyPeerName(socket: AsyncSocket, host: string) {.async.} =
    ## Raises unless the certificate the server presented is valid for `host`.
    ## `asyncnet.wrapConnectedSocket` sets the SNI name but never compares the
    ## certificate with it (Nim 2.2.8 lib/pure/asyncnet.nim:785-806; the
    ## comparison `checkCertName` exists only for the blocking sockets, in
    ## lib/pure/net.nim:833-854), so a certificate that chains to a trusted CA
    ## is accepted for any name. Called before anything is sent.
    # A write of no bytes completes the handshake and sends nothing.
    await socket.send(nil, 0)
    # The chain was verified by the handshake (CVerifyPeer); what is left is
    # whether it names `host`. `getPeerCertificates` is not used: it needs
    # SSL_get0_verified_chain, which the libraries this resolves to on some
    # systems (macOS ships LibreSSL 2.x as libssl.43) do not have.
    let certificate = SSL_get_peer_certificate(socket.sslHandle)
    if certificate.isNil:
      raise httpFailure("the server presented no certificate for " & host)
    let matched =
      if isIpAddress(host): X509_check_ip_asc(certificate, host.cstring, 0)
      else: X509_check_host(certificate, host.cstring, host.len.cint, 0, nil)
    X509_free(certificate)
    if matched != 1:
      raise httpFailure("the certificate of the server is not valid for " & host)

proc connect(url: Uri, connectTo, caFile: string): Future[AsyncSocket] {.async.} =
  let secure = url.scheme == "https"
  if url.scheme notin ["http", "https"]:
    raise httpFailure("unsupported URL scheme: " & url.scheme)
  let port = if url.port.len > 0: Port(parseInt(url.port))
             elif secure: Port(443)
             else: Port(80)
  let socket = await dial(if connectTo.len > 0: connectTo else: url.hostname, port,
                          buffered = false)
  if secure:
    when defined(ssl):
      let context = newContext(verifyMode = CVerifyPeer, caFile = caFile)
      context.wrapConnectedSocket(socket, handshakeAsClient, url.hostname)
      try:
        await socket.verifyPeerName(url.hostname)
      except CatchableError:
        socket.close()
        raise
    else:
      socket.close()
      raise httpFailure("https needs a build with -d:ssl")
  return socket

func hasControlCharacter(text: string, allowed: set[char] = {}): bool =
  ## A byte below SPACE (a line break, NUL), or DEL, other than `allowed`.
  for c in text:
    if (c < ' ' or c == '\x7f') and c notin allowed:
      return true

func isToken(name: string): bool =
  const tokenChars = {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'} +
                     Digits + Letters
  name.len > 0 and name.allCharsInSet(tokenChars)

proc checkRequestFields(url: Uri, headers: HttpHeaders) =
  ## What goes on the request line and into header lines must not be able to
  ## end the line: a CR, LF or NUL in the target, the host or a header would
  ## let whoever chose the URL or the value add headers or a second request.
  ## A tab may stay in a header value. Raises before anything is connected.
  if hasControlCharacter(url.path & url.query & url.hostname & url.port) or
     ' ' in url.path or ' ' in url.query:
    raise httpFailure("the URL contains a space, a line break or control character")
  if headers.isNil:
    return
  for name, value in headers:
    if not name.isToken:
      raise httpFailure("not a valid header name: " & name[0 ..< min(name.len, 40)].escape)
    if hasControlCharacter(value, {'\t'}):
      raise httpFailure("header " & name & " has a line break or control character in its value")

proc requestText(url: Uri, httpMethod: HttpMethod, headers: HttpHeaders,
                 body: string): string =
  var target = if url.path.len > 0: url.path else: "/"
  if url.query.len > 0:
    target.add "?" & url.query
  let hostPort = if url.port.len > 0: url.hostname & ":" & url.port else: url.hostname
  result = $httpMethod & " " & target & " HTTP/1.1\c\L"
  result.add "Host: " & hostPort & "\c\L"
  for name, value in headers:
    if name.toLowerAscii() notin ["host", "content-length", "connection"]:
      result.add name & ": " & value & "\c\L"
  if body.len > 0 or httpMethod == HttpPost:
    result.add "Content-Length: " & $body.len & "\c\L"
  result.add "Connection: close\c\L\c\L"
  result.add body

proc parseHead(r: WireResponse, head: string) =
  # A head is lines ended by CRLF. A bare LF or CR, a NUL or another control
  # character inside a line means the server and this client could read it
  # differently (`Location: /a\nSet-Cookie: x`), and the values are used
  # later (`Location`, `Mcp-Session-Id`), so such a head is refused.
  if hasControlCharacter(head.replace("\c\L", ""), {'\t'}):
    raise httpFailure("the response head has a line break or control character inside a line")
  let lines = head.split("\c\L")
  let status = lines[0].split(' ', maxsplit = 2)
  if status.len < 2 or not status[0].startsWith("HTTP/"):
    raise httpFailure("not an HTTP response: " & lines[0][0 ..< min(lines[0].len, 60)])
  var code = 0
  try:
    code = parseInt(status[1])
  except ValueError:
    raise httpFailure("bad HTTP status line: " & lines[0][0 ..< min(lines[0].len, 60)])
  if code < 100 or code > 599:
    raise httpFailure("bad HTTP status line: " & lines[0][0 ..< min(lines[0].len, 60)])
  r.code = HttpCode(code)
  r.headers = newHttpHeaders()
  for line in lines[1 .. ^1]:
    let colon = line.find(':')
    if colon > 0:
      r.headers.add(line[0 ..< colon].strip(), line[colon + 1 .. ^1].strip())

proc chooseBodyMode(r: WireResponse, httpMethod: HttpMethod) =
  let code = r.code.int
  if httpMethod == HttpHead or code < 200 or code in [204, 304]:
    r.mode = bmNone
  elif "chunked" in r.headers.getOrDefault("Transfer-Encoding").toLowerAscii():
    r.mode = bmChunked
  elif r.headers.hasKey("Content-Length"):
    r.mode = bmLength
    try:
      r.remaining = parseInt(r.headers["Content-Length"])
    except ValueError:
      raise httpFailure("bad Content-Length: " & $r.headers["Content-Length"])
    if r.remaining < 0:
      raise httpFailure("bad Content-Length: " & $r.headers["Content-Length"])
  else:
    r.mode = bmUntilClose
  r.finished = r.mode == bmNone or (r.mode == bmLength and r.remaining == 0)

proc close*(r: WireResponse) =
  ## Drop the connection; a body not read to its end is abandoned.
  r.finished = true
  r.closed = true
  if not r.interrupt.isNil and not r.interrupt.finished:
    r.interrupt.complete()
  if not r.socket.isNil and not r.socket.isClosed:
    r.socket.close()

proc receive(r: WireResponse): Future[tuple[data: string, interrupted: bool]] {.async.} =
  ## The next bytes from the socket; `interrupted` when `close` was called
  ## while waiting. A socket closed under a pending read never wakes it.
  if r.closed:
    return (data: "", interrupted: true)
  let pending = r.socket.recv(ReadSize)
  r.interrupt = newFuture[void]("WireResponse.interrupt")
  try:
    await firstOf(pending, r.interrupt)
  except OSError as e:
    r.close()
    raise httpFailure("reading the response failed: " & e.msg)
  # `close` closes the socket right after completing `interrupt`, and the
  # read waiting on it then fails with "Bad file descriptor" before this
  # continues: that failure is the interruption, not news.
  if r.closed or not pending.finished:
    return (data: "", interrupted: true)
  try:
    return (data: pending.read(), interrupted: false)
  except OSError as e:
    r.close()
    raise httpFailure("reading the response failed: " & e.msg)

type Connected* = proc(response: WireResponse) {.closure, gcsafe.}
  ## Called with the response object as soon as the connection exists, before
  ## the server has said anything: the caller can `close` it to abandon a
  ## request still waiting for its answer.

proc connectWithin(target: Uri, url, connectTo, caFile: string,
                   timeoutMs: int): Future[AsyncSocket] {.async.} =
  ## `connect`, ended after `timeoutMs` (none when it is not positive).
  let attempt = connect(target, connectTo, caFile)
  try:
    if timeoutMs > 0:
      if not await attempt.withLimit(timeoutMs):
        # The connection is still being made: whoever finishes it closes it,
        # and a failure of an attempt nobody waits for is not news.
        attempt.addCallback(proc() =
          if attempt.failed:
            discard attempt.readError()
          else:
            attempt.read().close())
        raise httpFailure("no connection to " & url & " within " & $timeoutMs & " ms")
    return await attempt
  except McpTransportError:
    raise
  except CatchableError as e:
    raise httpFailure("cannot connect to " & url & ": " & e.msg)

proc exchangeHead(response: WireResponse, url: string, httpMethod: HttpMethod,
                  target: Uri, headers: HttpHeaders, body: string) {.async.} =
  ## Send the request and read the response head into `response`.
  let sent = if headers.isNil: newHttpHeaders() else: headers
  await response.socket.send(requestText(target, httpMethod, sent, body))
  var head = ""
  while true:
    let at = head.find("\c\L\c\L")
    if at >= 0:
      response.pending = head[at + 4 .. ^1]
      head.setLen(at)
      break
    if head.len > MaxHeadSize:
      raise httpFailure("response head from " & url & " is too long")
    let (data, interrupted) = await response.receive()
    if interrupted:
      raise httpFailure("the request to " & url & " was abandoned")
    if data.len == 0:
      raise httpFailure("connection to " & url & " closed before the response")
    head.add data
  response.parseHead(head)
  response.chooseBodyMode(httpMethod)

proc requestOnce(url: string, httpMethod: HttpMethod, headers: HttpHeaders,
                 body: string, connected: Connected,
                 connectTo, caFile: string,
                 connectTimeoutMs, headerTimeoutMs: int): Future[WireResponse] {.async.} =
  let target = parseUri(url)
  checkRequestFields(target, headers)
  let response = WireResponse()
  response.socket = await connectWithin(target, url, connectTo, caFile, connectTimeoutMs)
  if not connected.isNil:
    connected(response)
  try:
    let exchange = response.exchangeHead(url, httpMethod, target, headers, body)
    if headerTimeoutMs > 0:
      if not await exchange.withLimit(headerTimeoutMs):
        # Closing wakes a read that waits (see `receive`); how the abandoned
        # exchange ends is of no interest, the caller is told of the timeout.
        response.close()
        exchange.addCallback(proc() =
          if exchange.failed:
            discard exchange.readError())
        raise httpFailure("no response from " & url & " within " & $headerTimeoutMs & " ms")
    await exchange
  except CatchableError as e:
    response.close()
    if e of McpTransportError:
      raise
    raise httpFailure("request to " & url & " failed: " & e.msg)
  return response

func isFinished*(r: WireResponse): bool = r.finished

func isRedirect(code: HttpCode, httpMethod: HttpMethod): bool =
  ## A 307 or 308 repeats the request as it was; the older codes turn a POST
  ## into a GET, which would drop the message, so they are not followed.
  code in [Http307, Http308] or
    (httpMethod == HttpGet and code in [Http301, Http302, Http303])

func sameOrigin(a, b: Uri): bool =
  a.scheme == b.scheme and a.hostname.toLowerAscii() == b.hostname.toLowerAscii() and
    a.port == b.port

proc request*(url: string, httpMethod: HttpMethod, headers: HttpHeaders = nil,
              body = "", connected: Connected = nil, followRedirects = true,
              connectTo = "", caFile = "",
              connectTimeoutMs = DefaultConnectTimeoutMs,
              headerTimeoutMs = 0): Future[WireResponse] {.async.} =
  ## Send the request and read the response head. The body is read with
  ## `readSome` / `readAll`. Redirects to the same server are followed (up
  ## to `MaxRedirects`); one to another server is an error, so that
  ## credentials in `headers` do not travel there. With `followRedirects`
  ## false none is followed: the redirect is returned as the response.
  ## `connectTo` is an address (not a name) to connect to instead of
  ## resolving the host of `url`, which still names the server in `Host` and,
  ## for https, in the TLS handshake: a caller that has checked an address
  ## connects to exactly that one. Raises McpTransportError when the server
  ## cannot be reached, does not answer in HTTP, or is too slow:
  ## `connectTimeoutMs` bounds the connection (including the TLS handshake),
  ## `headerTimeoutMs` the wait from the connection until the response head
  ## has arrived. A limit that is not positive means none. The default of
  ## `headerTimeoutMs` is none because the answer to a request may legitimately
  ## take as long as its caller is willing to wait (a tool call): the caller
  ## that owns such a wait (`McpClient` times a request out itself) must not
  ## be cut short from here. A caller with no timer of its own passes one.
  var current = url
  for hop in 0 .. MaxRedirects:
    let response = await requestOnce(current, httpMethod, headers, body, connected, connectTo, caFile,
                                         connectTimeoutMs, headerTimeoutMs)
    let location = response.headers.getOrDefault("Location")
    if not followRedirects or not isRedirect(response.code, httpMethod) or location.len == 0:
      return response
    let next = combine(parseUri(current), parseUri(location))
    response.close()
    if not sameOrigin(parseUri(current), next):
      raise httpFailure(current & " redirects to another server, " & $next)
    current = $next
  raise httpFailure("more than " & $MaxRedirects & " redirects from " & url)


proc chunkSize(text: string): int =
  ## A chunk size: hexadecimal digits only (no sign, no `0x`), few enough
  ## that the size fits in an int.
  if text.len == 0 or text.len > 15:
    raise httpFailure("bad chunk size: " & text[0 ..< min(text.len, 20)])
  for c in text:
    let digit =
      case c
      of '0' .. '9': ord(c) - ord('0')
      of 'a' .. 'f': ord(c) - ord('a') + 10
      of 'A' .. 'F': ord(c) - ord('A') + 10
      else: raise httpFailure("bad chunk size: " & text[0 ..< min(text.len, 20)])
    result = result * 16 + digit

proc decodeChunked(r: WireResponse, input: string): string =
  var i = 0
  while i < input.len and r.chunk != csDone:
    case r.chunk
    of csSizeLine:
      let c = input[i]
      inc i
      if c == '\n':
        let sizeText = r.line.strip().split(';')[0].strip()
        r.line = ""
        r.remaining = chunkSize(sizeText)
        r.chunk = if r.remaining == 0: csTrailers else: csData
      else:
        r.line.add c
        if r.line.len > 64:
          raise httpFailure("chunk size line is too long")
    of csData:
      let n = min(r.remaining, input.len - i)
      result.add input[i ..< i + n]
      i += n
      r.remaining -= n
      if r.remaining == 0:
        r.chunk = csDataEnd
    of csDataEnd:
      # The data ends with CRLF (or a bare LF); anything else there means the
      # size and the data disagree.
      let c = input[i]
      inc i
      if c == '\n':
        r.chunk = csSizeLine
        r.line = ""
      elif c == '\c' and r.line.len == 0:
        r.line = "\c"
      else:
        raise httpFailure("bytes after the data of a chunk")
    of csTrailers:
      let c = input[i]
      inc i
      if c == '\n':
        if r.line.len == 0:
          r.chunk = csDone
        r.line = ""
      elif c != '\c':
        r.line.add c
    of csDone:
      discard

proc readSome*(r: WireResponse): Future[string] {.async.} =
  ## The next part of the body, as soon as any of it has arrived; "" once the
  ## body has ended. Raises McpTransportError when the connection ends
  ## before the body does.
  while not r.finished:
    var data: string
    if r.pending.len > 0:
      data = move(r.pending)
      r.pending = ""
    else:
      let (received, interrupted) = await r.receive()
      if interrupted:
        r.cut = true
        return ""
      data = received
    case r.mode
    of bmNone:
      r.finished = true
    of bmLength:
      if data.len == 0:
        r.close()
        raise httpFailure("connection closed before the whole body arrived")
      let n = min(r.remaining, data.len)
      r.remaining -= n
      if r.remaining == 0:
        r.close()
      if n > 0:
        return data[0 ..< n]
    of bmUntilClose:
      if data.len == 0:
        r.close()
      else:
        return data
    of bmChunked:
      if data.len == 0:
        r.close()
        raise httpFailure("connection closed before the last chunk")
      let decoded = r.decodeChunked(data)
      if r.chunk == csDone:
        r.close()
      if decoded.len > 0:
        return decoded
  return ""

proc readAll*(r: WireResponse, maxSize: int): Future[string] {.async.} =
  ## The whole body. Raises McpTransportError past `maxSize` bytes, and when
  ## `close` ended the reading before the body did: what was read until then
  ## is not the body.
  while true:
    let part = await r.readSome()
    if part.len == 0:
      if r.cut:
        raise httpFailure("the response was closed before its whole body was read")
      break
    result.add part
    if result.len > maxSize:
      r.close()
      raise httpFailure("response body exceeds " & $maxSize & " bytes")

proc readPrefix*(r: WireResponse, limit: int): Future[string] {.async.} =
  ## At most the first `limit` bytes of the body, for a caller that decides by
  ## the status and wants the body only to show. A body that goes on past
  ## `limit` is not read further: the connection is closed.
  while true:
    let part = await r.readSome()
    if part.len == 0:
      if r.cut:
        raise httpFailure("the response was closed before its whole body was read")
      break
    result.add part
    if result.len > limit:
      r.close()
      result.setLen(limit)
      break
