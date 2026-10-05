## Test helper: a response read as it arrives, so that what a server says
## during a request can be told apart from what it says at the end.

import std/[asyncdispatch, httpcore, json, options, deques]
import transport/event_stream
import transport/http_wire as wire

type Events* = ref object
  response*: WireResponse
  parser: SseParser
  queued: Deque[SseEvent]
  ended: bool

proc openAsync*(url: string, httpMethod: HttpMethod, body: string,
                headers: seq[(string, string)]): Future[Events] {.async.} =
  ## Like `open`, for a response whose headers come only with its first event.
  let allHeaders = newHttpHeaders({"Accept": "application/json, text/event-stream",
                                   "Content-Type": "application/json"})
  for (name, value) in headers:
    allHeaders[name] = value
  return Events(response: await wire.request(url, httpMethod, allHeaders, body),
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

