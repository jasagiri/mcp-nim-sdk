## Test helper: a response read as it arrives, so that what a server says
## during a request can be told apart from what it says at the end.
##
## It speaks plain HTTP/1.1 over `std/asyncnet`, not through the client of the
## SDK, so that a server is judged by a reader that shares no code with it.

import std/[asyncdispatch, asyncnet, httpcore, json, options, deques, strutils, uri]
import transport/event_stream

const
  ConnectLimitMs = 30_000
  HeadLimitMs = 30_000
  MaxHeadSize = 64 * 1024
  ReadSize = 16 * 1024

type
  BodyMode = enum
    bmNone, bmLength, bmChunked, bmUntilClose

  ChunkState = enum
    csSizeLine, csData, csDataEnd, csTrailers, csDone

  EventsResponse* = ref object
    ## The head of a response and a body that is read part by part.
    code*: HttpCode
    headers*: HttpHeaders
    socket: AsyncSocket
    buffer: string      ## bytes received, not yet taken as body
    mode: BodyMode
    remaining: int      ## bytes left of a Content-Length body or of a chunk
    chunk: ChunkState
    finished: bool

  Events* = ref object
    response*: EventsResponse
    parser: SseParser
    queued: Deque[SseEvent]
    ended: bool

proc close*(r: EventsResponse) =
  ## Drop the connection; a body not read to its end is abandoned.
  r.finished = true
  if not r.socket.isClosed:
    r.socket.close()

proc requestText(url: Uri, httpMethod: HttpMethod, headers: HttpHeaders,
                 body: string): string =
  let target = (if url.path.len > 0: url.path else: "/") &
               (if url.query.len > 0: "?" & url.query else: "")
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

proc readHead(socket: AsyncSocket): Future[(string, string)] {.async.} =
  ## The head up to the blank line, and the bytes that came after it.
  var received = ""
  while true:
    let blank = received.find("\c\L\c\L")
    if blank >= 0:
      return (received[0 ..< blank], received[blank + 4 .. ^1])
    if received.len > MaxHeadSize:
      raise newException(IOError, "the response head is longer than " & $MaxHeadSize & " bytes")
    let part = await socket.recv(ReadSize)
    if part.len == 0:
      raise newException(IOError, "the connection ended inside the response head")
    received.add part

proc parseHead(r: EventsResponse, head: string) =
  let lines = head.split("\c\L")
  let status = lines[0].split(' ', maxsplit = 2)
  if status.len < 2 or not status[0].startsWith("HTTP/"):
    raise newException(IOError, "not an HTTP response: " & lines[0])
  r.code = HttpCode(parseInt(status[1]))
  r.headers = newHttpHeaders()
  for line in lines[1 .. ^1]:
    let colon = line.find(':')
    if colon > 0:
      r.headers.add(line[0 ..< colon].strip(), line[colon + 1 .. ^1].strip())

proc chooseBodyMode(r: EventsResponse, httpMethod: HttpMethod) =
  let code = r.code.int
  if httpMethod == HttpHead or code < 200 or code in [204, 304]:
    r.mode = bmNone
  elif "chunked" in r.headers.getOrDefault("Transfer-Encoding").toLowerAscii():
    r.mode = bmChunked
  elif r.headers.hasKey("Content-Length"):
    r.mode = bmLength
    r.remaining = parseInt(r.headers["Content-Length"])
  else:
    r.mode = bmUntilClose
  r.finished = r.mode == bmNone or (r.mode == bmLength and r.remaining == 0)

proc requestEvents(url: string, httpMethod: HttpMethod, headers: HttpHeaders,
                   body: string): Future[EventsResponse] {.async.} =
  let target = parseUri(url)
  let port = if target.port.len > 0: Port(parseInt(target.port)) else: Port(80)
  let response = EventsResponse(socket: newAsyncSocket(buffered = false))
  try:
    doAssert await withTimeout(response.socket.connect(target.hostname, port), ConnectLimitMs),
      "no connection to " & url & " within " & $ConnectLimitMs & " ms"
    await response.socket.send(requestText(target, httpMethod, headers, body))
    let reading = readHead(response.socket)
    doAssert await withTimeout(reading, HeadLimitMs),
      "no response head from " & url & " within " & $HeadLimitMs & " ms"
    let (head, rest) = reading.read()
    response.parseHead(head)
    response.buffer = rest
    response.chooseBodyMode(httpMethod)
  except CatchableError, AssertionDefect:
    response.close()
    raise
  return response

proc takeChunked(r: EventsResponse): string =
  ## The body bytes the buffer holds so far, with the chunk framing removed.
  while r.buffer.len > 0 and r.chunk != csDone:
    case r.chunk
    of csSizeLine:
      let eol = r.buffer.find('\n')
      if eol < 0:
        break
      let sizeText = r.buffer[0 ..< eol].strip().split(';')[0].strip()
      r.buffer = r.buffer[eol + 1 .. ^1]
      r.remaining = parseHexInt(sizeText)
      r.chunk = if r.remaining == 0: csTrailers else: csData
    of csData:
      let n = min(r.remaining, r.buffer.len)
      result.add r.buffer[0 ..< n]
      r.buffer = r.buffer[n .. ^1]
      r.remaining -= n
      if r.remaining == 0:
        r.chunk = csDataEnd
    of csDataEnd:
      let eol = r.buffer.find('\n')
      if eol < 0:
        break
      r.buffer = r.buffer[eol + 1 .. ^1]
      r.chunk = csSizeLine
    of csTrailers:
      let eol = r.buffer.find('\n')
      if eol < 0:
        break
      let line = r.buffer[0 ..< eol].strip()
      r.buffer = r.buffer[eol + 1 .. ^1]
      if line.len == 0:
        r.chunk = csDone
    of csDone:
      discard

proc readSome*(r: EventsResponse): Future[string] {.async.} =
  ## The next part of the body, as soon as any of it has arrived; "" once the
  ## body has ended.
  while not r.finished:
    case r.mode
    of bmNone:
      r.finished = true
    of bmLength:
      if r.buffer.len == 0:
        r.buffer = await r.socket.recv(ReadSize)
        if r.buffer.len == 0:
          r.close()
          raise newException(IOError, "the connection ended before the whole body arrived")
      let n = min(r.remaining, r.buffer.len)
      result = r.buffer[0 ..< n]
      r.buffer = r.buffer[n .. ^1]
      r.remaining -= n
      if r.remaining == 0:
        r.close()
      return
    of bmUntilClose:
      if r.buffer.len == 0:
        r.buffer = await r.socket.recv(ReadSize)
      if r.buffer.len == 0:
        r.close()
      else:
        result = move(r.buffer)
        r.buffer = ""
        return
    of bmChunked:
      let decoded = r.takeChunked()
      if r.chunk == csDone:
        r.close()
      if decoded.len > 0:
        return decoded
      if not r.finished:
        let part = await r.socket.recv(ReadSize)
        if part.len == 0:
          r.close()
          raise newException(IOError, "the connection ended before the last chunk")
        r.buffer.add part
  return ""

proc readAll*(r: EventsResponse, maxSize: int): Future[string] {.async.} =
  ## The whole body; fails past `maxSize` bytes.
  while true:
    let part = await r.readSome()
    if part.len == 0:
      break
    result.add part
    if result.len > maxSize:
      r.close()
      raise newException(IOError, "response body exceeds " & $maxSize & " bytes")

proc openAsync*(url: string, httpMethod: HttpMethod, body: string,
                headers: seq[(string, string)]): Future[Events] {.async.} =
  ## Like `open`, for a response whose headers come only with its first event.
  let allHeaders = newHttpHeaders({"Accept": "application/json, text/event-stream",
                                   "Content-Type": "application/json"})
  for (name, value) in headers:
    allHeaders[name] = value
  return Events(response: await requestEvents(url, httpMethod, allHeaders, body),
                parser: initSseParser())

proc open*(url: string, httpMethod: HttpMethod, body: string,
          headers: openArray[(string, string)]): Events =
  waitFor openAsync(url, httpMethod, body, @headers)

proc code*(e: Events): HttpCode = e.response.code
proc contentType*(e: Events): string = e.response.headers.getOrDefault("Content-Type")

proc next*(e: Events, timeoutMs = 3000): Option[SseEvent] =
  ## The next event, or none when the stream ended. A stream that stays
  ## silent for `timeoutMs` fails the test.
  while e.queued.len == 0 and not e.ended:
    let read = e.response.readSome()
    doAssert waitFor withTimeout(read, timeoutMs), "no event within " & $timeoutMs & " ms"
    let chunk = read.read()
    if chunk.len == 0:
      e.ended = true
    else:
      for event in e.parser.feed(chunk):
        e.queued.addLast event
  if e.queued.len > 0:
    some(e.queued.popFirst())
  else:
    none(SseEvent)

proc messages*(e: Events): seq[JsonNode] =
  ## Every message until the stream ends; empty-data events are skipped.
  while true:
    let event = e.next()
    if event.isNone:
      break
    if event.get.data.len > 0:
      result.add parseJson(event.get.data)

proc close*(e: Events) = e.response.close()
