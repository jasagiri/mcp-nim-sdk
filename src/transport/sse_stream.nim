## The server side of an SSE response: a bounded buffer of events that
## outlives the connection carrying it, and the loop that writes it out.
##
## Keeping the events apart from the connection is what makes a stream
## resumable: a client that lost its connection asks for the events after
## the last one it saw, and a fresh connection continues the same stream.
## It is also how a server finds out that a client went away: the loop
## watches the socket while it waits for the next event.

import std/[asyncdispatch, asyncnet, asynchttpserver, deques, httpcore,
            options, strutils]
import ./event_stream

const
  DefaultMaxStreamEvents* = 1024
    ## Events a stream remembers for resumption; the oldest are dropped
    ## beyond this.
  DefaultKeepAliveMs* = 15_000

type
  StoredEvent = object
    seqNo: int
    event: string
    data: string

  SseStream* = ref object
    id*: string
      ## Names the stream in the ids of its events, so that a `Last-Event-ID`
      ## leads back to it. Must not contain '-'.
    emitIds*: bool
      ## Whether events carry an `id:` field. The 2024-11-05 transport has none.
    events: Deque[StoredEvent]
    nextSeq: int
    maxEvents: int
    finished: bool
    changed: Future[void]
    attachment: int
    written: int

  SseEnd* = enum
    seDrained     ## the stream is finished and every event was written
    seClientGone  ## the peer closed the connection
    seReplaced    ## a newer connection took the stream over

proc newSseStream*(id: string, maxEvents = DefaultMaxStreamEvents,
                   emitIds = true): SseStream =
  SseStream(id: id, emitIds: emitIds, events: initDeque[StoredEvent](),
            nextSeq: 1, maxEvents: maxEvents,
            changed: newFuture[void]("SseStream.changed"))

func isFinished*(s: SseStream): bool = s.finished
func lastSeq*(s: SseStream): int = s.nextSeq - 1
func writtenUpTo*(s: SseStream): int =
  ## The newest event any connection has written; a connection that opens
  ## without `Last-Event-ID` continues after it.
  s.written

proc wake(s: SseStream) =
  let previous = s.changed
  s.changed = newFuture[void]("SseStream.changed")
  previous.complete()

proc push*(s: SseStream, data: string, event = ""): bool =
  ## Append an event; false when the stream is finished and takes no more.
  if s.finished:
    return false
  s.events.addLast StoredEvent(seqNo: s.nextSeq, event: event, data: data)
  inc s.nextSeq
  while s.events.len > s.maxEvents:
    discard s.events.popFirst()
  s.wake()
  true

proc finish*(s: SseStream) =
  ## No more events will come; connections end once they have written the rest.
  if not s.finished:
    s.finished = true
    s.wake()

func eventId*(s: SseStream, seqNo: int): string =
  s.id & "-" & $seqNo

func parseEventId*(text: string): Option[tuple[streamId: string, seqNo: int]] =
  ## The inverse of `eventId`.
  let dash = text.rfind('-')
  if dash <= 0 or dash == text.high:
    return none(tuple[streamId: string, seqNo: int])
  try:
    some((text[0 ..< dash], parseInt(text[dash + 1 .. ^1])))
  except ValueError:
    none(tuple[streamId: string, seqNo: int])

func canResumeAfter*(s: SseStream, seqNo: int): bool =
  ## Whether every event after `seqNo` is still remembered.
  let oldest = if s.events.len > 0: s.events[0].seqNo else: s.nextSeq
  seqNo >= oldest - 1 and seqNo < s.nextSeq

proc armWatch(client: AsyncSocket, gone: Future[void]) {.gcsafe.} =
  let read = client.recv(1)
  read.addCallback(proc() {.closure, gcsafe.} =
    if gone.finished:
      return
    if read.failed or read.read().len == 0:
      gone.complete()
    else:
      armWatch(client, gone))

proc watchDisconnect*(client: AsyncSocket): Future[void] =
  ## Completes when the peer closes the connection. The request has been
  ## read in full by then, so anything arriving afterwards is not for us.
  let gone = newFuture[void]("watchDisconnect")
  armWatch(client, gone)
  gone

proc statusLine(code: HttpCode): string =
  "HTTP/1.1 " & $code & "\c\L"

proc writeHead*(req: Request, code: HttpCode, headers: HttpHeaders): Future[void] =
  ## The head of a response whose body has no length: it ends when the
  ## connection closes.
  var msg = statusLine(code)
  for name, value in headers:
    msg.add name & ": " & value & "\c\L"
  msg.add "Connection: close\c\L\c\L"
  req.client.send(msg)

proc serveStream*(req: Request, stream: SseStream, afterSeq: int,
                  headers: HttpHeaders, gone: Future[void],
                  keepAliveMs = DefaultKeepAliveMs): Future[SseEnd] {.async.} =
  ## Answer `req` with `stream`: the events after `afterSeq`, then each new
  ## one, until the stream is finished, the peer leaves, or another
  ## connection attaches to the stream. Closes the connection.
  ##
  ## `headers` should carry the security headers; the content type and
  ## cache control of an event stream are added here. `gone` is the
  ## `watchDisconnect` of this connection: a connection must be watched once
  ## only, as each watcher consumes what the peer sends.
  inc stream.attachment
  let mine = stream.attachment
  stream.wake()  # a connection already serving the stream notices and leaves
  headers["Content-Type"] = "text/event-stream"
  headers["Cache-Control"] = "no-cache"
  headers["X-Accel-Buffering"] = "no"  # a proxy must not hold events back
  var cursor = afterSeq
  var idle = sleepAsync(keepAliveMs)
  result = seDrained
  try:
    await req.writeHead(Http200, headers)
    while true:
      var batch = ""
      var last = cursor
      for stored in stream.events:
        if stored.seqNo > cursor:
          batch.add formatSseEvent(stored.data, stored.event,
            if stream.emitIds: stream.eventId(stored.seqNo) else: "")
          last = stored.seqNo
      if batch.len > 0:
        await req.client.send(batch)
        cursor = last
        stream.written = max(stream.written, last)
      if stream.attachment != mine:
        result = seReplaced
        break
      if stream.finished and cursor >= stream.lastSeq:
        break
      if gone.finished:
        result = seClientGone
        break
      await (stream.changed or gone or idle)
      if idle.finished:
        idle = sleepAsync(keepAliveMs)
        if not gone.finished:
          await req.client.send(formatSseComment("keep-alive"))
  except OSError, IOError:
    # The write failed because the peer is gone.
    result = seClientGone
  finally:
    req.client.close()
