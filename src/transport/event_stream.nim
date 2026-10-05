## Server-sent events (text/event-stream): an incremental reader for a
## stream that arrives in arbitrary chunks, and a writer.

import std/strutils

type
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
    pendingCr: bool       ## the previous chunk ended in CR; a LF may follow
    started: bool         ## past the position where a byte order mark may be

const ByteOrderMark = "\xEF\xBB\xBF"

func initSseParser*(): SseParser {.raises: [].} =
  SseParser()

func takeLine(p: var SseParser, events: var seq[SseEvent]) {.raises: [].} =
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
    return
  if line[0] == ':':
    return

  let colon = line.find(':')
  let name = if colon < 0: line else: line[0 ..< colon]
  var value = if colon < 0: "" else: line[colon + 1 .. ^1]
  if value.len > 0 and value[0] == ' ':
    value = value[1 .. ^1]

  case name
  of "data":
    p.data.add value
    p.hasData = true
  of "event":
    p.event = value
  of "id":
    if '\0' notin value:
      p.lastId = value
  else:
    discard

func feed*(p: var SseParser, chunk: string): seq[SseEvent] {.raises: [].} =
  ## The events completed by `chunk`. Lines may end in LF, CR or CRLF, and a
  ## chunk may end anywhere, including between a CR and its LF.
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
