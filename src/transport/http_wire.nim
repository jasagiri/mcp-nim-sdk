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

const
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

proc httpFailure(message: string): ref McpTransportError =
  newException(McpTransportError, message)

proc connect(url: Uri): Future[AsyncSocket] {.async.} =
  let secure = url.scheme == "https"
  if url.scheme notin ["http", "https"]:
    raise httpFailure("unsupported URL scheme: " & url.scheme)
  let port = if url.port.len > 0: Port(parseInt(url.port))
             elif secure: Port(443)
             else: Port(80)
  let socket = await dial(url.hostname, port, buffered = false)
  if secure:
    when defined(ssl):
      let context = newContext(verifyMode = CVerifyPeer)
      context.wrapConnectedSocket(socket, handshakeAsClient, url.hostname)
    else:
      socket.close()
      raise httpFailure("https needs a build with -d:ssl")
  return socket

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
  let lines = head.split("\c\L")
  let status = lines[0].split(' ', maxsplit = 2)
  if status.len < 2 or not status[0].startsWith("HTTP/"):
    raise httpFailure("not an HTTP response: " & lines[0][0 ..< min(lines[0].len, 60)])
  try:
    r.code = HttpCode(parseInt(status[1]))
  except ValueError:
    raise httpFailure("bad HTTP status line: " & lines[0][0 ..< min(lines[0].len, 60)])
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
  else:
    r.mode = bmUntilClose
  r.finished = r.mode == bmNone or (r.mode == bmLength and r.remaining == 0)

proc requestOnce(url: string, httpMethod: HttpMethod, headers: HttpHeaders,
                 body: string): Future[WireResponse] {.async.} =
  let target = parseUri(url)
  let response = WireResponse()
  try:
    response.socket = await connect(target)
  except McpTransportError:
    raise
  except CatchableError as e:
    raise httpFailure("cannot connect to " & url & ": " & e.msg)
  try:
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
      let data = await response.socket.recv(ReadSize)
      if data.len == 0:
        raise httpFailure("connection to " & url & " closed before the response")
      head.add data
    response.parseHead(head)
    response.chooseBodyMode(httpMethod)
  except CatchableError as e:
    response.socket.close()
    if e of McpTransportError:
      raise
    raise httpFailure("request to " & url & " failed: " & e.msg)
  return response

proc close*(r: WireResponse) =
  ## Drop the connection; a body not read to its end is abandoned.
  r.finished = true
  if not r.socket.isClosed:
    r.socket.close()

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
              body = ""): Future[WireResponse] {.async.} =
  ## Send the request and read the response head. The body is read with
  ## `readSome` / `readAll`. Redirects to the same server are followed (up
  ## to `MaxRedirects`); one to another server is an error, so that
  ## credentials in `headers` do not travel there. Raises McpTransportError
  ## when the server cannot be reached or does not answer in HTTP.
  var current = url
  for hop in 0 .. MaxRedirects:
    let response = await requestOnce(current, httpMethod, headers, body)
    let location = response.headers.getOrDefault("Location")
    if not isRedirect(response.code, httpMethod) or location.len == 0:
      return response
    let next = combine(parseUri(current), parseUri(location))
    response.close()
    if not sameOrigin(parseUri(current), next):
      raise httpFailure(current & " redirects to another server, " & $next)
    current = $next
  raise httpFailure("more than " & $MaxRedirects & " redirects from " & url)


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
        try:
          r.remaining = parseHexInt(sizeText)
        except ValueError:
          raise httpFailure("bad chunk size: " & sizeText[0 ..< min(sizeText.len, 20)])
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
      if input[i] == '\n':
        r.chunk = csSizeLine
      inc i
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
      try:
        data = await r.socket.recv(ReadSize)
      except OSError as e:
        r.close()
        raise httpFailure("reading the response failed: " & e.msg)
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
  ## The whole body. Raises McpTransportError past `maxSize` bytes.
  while true:
    let part = await r.readSome()
    if part.len == 0:
      break
    result.add part
    if result.len > maxSize:
      r.close()
      raise httpFailure("response body exceeds " & $maxSize & " bytes")
