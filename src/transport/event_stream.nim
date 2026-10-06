## Server-sent events (text/event-stream): an incremental reader for a
## stream that arrives in arbitrary chunks, and a writer.

import std/[strutils, options]

const
  DefaultSseLimitBytes* = 16 * 1024 * 1024
    ## The default of both limits of a parser: as much as a transport accepts
    ## for one message (`DefaultMaxResponseSize`), since a message is one
    ## event and may be one line. A transport passes its own
    ## `maxResponseSize`.

type
  SseLimitError* = object of CatchableError
    ## A line or an event grew past its limit. The parser is not usable after
    ## it: what it holds is a part of something that has no end.

  SseEvent* = object
    event*: string  ## the event type; empty when the event names none
    data*: string   ## the data lines joined with "\n"
    id*: string     ## the last event id seen on the stream so far

  SseParser* = object
    line: string          ## the current, still unterminated line
    data: seq[string]     ## data lines of the event being read
    hasData: bool
    event: string
    lastId: string
    retry: Option[int]    ## the newest valid retry field, in milliseconds
    pendingCr: bool       ## the previous chunk ended in CR; a LF may follow
    started: bool         ## past the position where a byte order mark may be
    maxLineBytes: int
    maxEventBytes: int
    eventBytes: int       ## what the event being read holds so far

const ByteOrderMark = "\xEF\xBB\xBF"

func initSseParser*(maxLineBytes = DefaultSseLimitBytes,
                    maxEventBytes = DefaultSseLimitBytes): SseParser {.raises: [].} =
  ## `feed` raises SseLimitError for a line longer than `maxLineBytes`
  ## (decided before the line ends: a server that never sends a line break
  ## must not make the client buffer without end) and for an event whose
  ## data, event and id fields together pass `maxEventBytes` (decided before
  ## the blank line that would end it).
  SseParser(maxLineBytes: maxLineBytes, maxEventBytes: maxEventBytes)

func takeLine(p: var SseParser, events: var seq[SseEvent]) {.raises: [SseLimitError].} =
  ## Interpret the finished line: a blank line ends an event.
  var line = move(p.line)
  p.line = ""
  if not p.started:
    p.started = true
    if line.startsWith(ByteOrderMark):
      line = line[ByteOrderMark.len .. ^1]

  if line.len == 0:
    if p.hasData:
      events.add SseEvent(event: p.event, data: p.data.join("\n"), id: p.lastId)
    p.data.setLen(0)
    p.hasData = false
    p.event = ""
    p.eventBytes = 0
    return
  if line[0] == ':':
    return

  let colon = line.find(':')
  let name = if colon < 0: line else: line[0 ..< colon]
  var value = if colon < 0: "" else: line[colon + 1 .. ^1]
  if value.len > 0 and value[0] == ' ':
    value = value[1 .. ^1]

  if name in ["data", "event", "id"]:
    p.eventBytes += value.len + 1
    if p.eventBytes > p.maxEventBytes:
      raise newException(SseLimitError,
        "an event of the stream is longer than " & $p.maxEventBytes & " bytes")
  case name
  of "data":
    p.data.add value
    p.hasData = true
  of "event":
    p.event = value
  of "id":
    if '\0' notin value:
      p.lastId = value
  of "retry":
    # Nine digits cover any delay worth waiting for and cannot overflow.
    if value.len in 1 .. 9 and value.allCharsInSet(Digits):
      var delay = 0
      for c in value:
        delay = delay * 10 + (ord(c) - ord('0'))
      p.retry = some(delay)
  else:
    discard

func retryMs*(p: SseParser): Option[int] {.raises: [].} =
  ## The reconnection delay the server asked for, if it did.
  p.retry

func feed*(p: var SseParser, chunk: string): seq[SseEvent] {.raises: [SseLimitError].} =
  ## The events completed by `chunk`. Lines may end in LF, CR or CRLF, and a
  ## chunk may end anywhere, including between a CR and its LF. Raises
  ## SseLimitError past a limit of `initSseParser`.
  for c in chunk:
    if p.pendingCr:
      p.pendingCr = false
      if c == '\n':
        continue
    case c
    of '\n':
      p.takeLine(result)
    of '\r':
      p.takeLine(result)
      p.pendingCr = true
    else:
      if p.line.len >= p.maxLineBytes:
        raise newException(SseLimitError,
          "a line of the stream is longer than " & $p.maxLineBytes & " bytes")
      p.line.add c

func formatSseEvent*(data: string, event = "", id = ""): string {.raises: [].} =
  if event.len > 0:
    result.add "event: " & event & "\n"
  if id.len > 0:
    result.add "id: " & id & "\n"
  for line in data.splitLines():
    result.add "data: " & line & "\n"
  result.add "\n"

func formatSseComment*(text: string): string {.raises: [].} =
  ": " & text & "\n\n"
