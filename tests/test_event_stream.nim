## Server-sent events: reading a stream that arrives in arbitrary chunks,
## and writing events.

import std/[unittest, options]
import transport/event_stream

proc feedAll(chunks: varargs[string]): seq[SseEvent] =
  var parser = initSseParser()
  for chunk in chunks:
    result.add parser.feed(chunk)

suite "event stream: reading":

  test "Given a retry field, when read, then the parser reports the delay, and ignores a value that is not digits":
    var parser = initSseParser()
    check parser.retryMs.isNone
    discard parser.feed("retry: 1500\n\n")
    check parser.retryMs == some(1500)
    discard parser.feed("retry: soon\n\n")
    check parser.retryMs == some(1500)
    discard parser.feed("retry: 20\ndata: x\n\n")
    check parser.retryMs == some(20)

  test "Given one event, when read, then its data is returned":
    let events = feedAll("data: {\"a\":1}\n\n")
    check events.len == 1
    check events[0].data == "{\"a\":1}"
    check events[0].event == ""
    check events[0].id == ""

  test "Given several data lines, when read, then they are joined with newlines":
    let events = feedAll("data: line1\ndata: line2\ndata: line3\n\n")
    check events[0].data == "line1\nline2\nline3"

  test "Given two events, when read, then both are returned in order":
    let events = feedAll("data: first\n\ndata: second\n\n")
    check events.len == 2
    check events[0].data == "first"
    check events[1].data == "second"

  test "Given CRLF or CR line endings, when read, then lines end the same way as with LF":
    check feedAll("data: a\r\ndata: b\r\n\r\n")[0].data == "a\nb"
    check feedAll("data: a\rdata: b\r\r")[0].data == "a\nb"

  test "Given an event split across chunks at every position, when read, then the same event is returned":
    let stream = "event: message\r\nid: 7\r\ndata: {\"jsonrpc\":\"2.0\"}\r\n\r\n"
    for cut in 1 ..< stream.len:
      let events = feedAll(stream[0 ..< cut], stream[cut .. ^1])
      check events.len == 1
      check events[0].event == "message"
      check events[0].id == "7"
      check events[0].data == "{\"jsonrpc\":\"2.0\"}"

  test "Given a stream fed one byte at a time, when read, then every event is returned once":
    var parser = initSseParser()
    var events: seq[SseEvent] = @[]
    for c in "data: a\r\n\r\ndata: b\n\n":
      events.add parser.feed($c)
    check events.len == 2
    check events[0].data == "a"
    check events[1].data == "b"

  test "Given comment lines, when read, then they produce no event and do not end one":
    let events = feedAll(": keep-alive\n\n: another\ndata: x\n: inside\n\n")
    check events.len == 1
    check events[0].data == "x"

  test "Given a field value, when read, then exactly one leading space is removed":
    check feedAll("data:no-space\n\n")[0].data == "no-space"
    check feedAll("data:  two spaces\n\n")[0].data == " two spaces"

  test "Given a line without a colon, when read, then it is a field with an empty value":
    let events = feedAll("data\n\n")
    check events.len == 1
    check events[0].data == ""

  test "Given an event with no data line, when read, then no event is returned":
    check feedAll("event: ping\nid: 1\n\n").len == 0

  test "Given an id, when a later event has none, then the later event reports the last id seen":
    let events = feedAll("id: 41\ndata: a\n\ndata: b\n\n")
    check events[0].id == "41"
    check events[1].id == "41"

  test "Given an event type, when a later event has none, then the later event has no type":
    let events = feedAll("event: custom\ndata: a\n\ndata: b\n\n")
    check events[0].event == "custom"
    check events[1].event == ""

  test "Given an unknown field, when read, then it is ignored":
    let events = feedAll("retry: 3000\nfoo: bar\ndata: x\n\n")
    check events.len == 1
    check events[0].data == "x"

  test "Given a stream that ends inside an event, when read, then the unfinished event is not returned":
    check feedAll("data: complete\n\ndata: unfinished\n").len == 1

  test "Given a byte order mark at the start, when read, then it is not part of the first field name":
    check feedAll("\xEF\xBB\xBFdata: x\n\n")[0].data == "x"

suite "event stream: writing":

  test "Given data, when formatted, then it is one data line and a blank line":
    check formatSseEvent("{\"a\":1}") == "data: {\"a\":1}\n\n"

  test "Given data with newlines, when formatted, then each line is its own data line":
    check formatSseEvent("a\nb\r\nc") == "data: a\ndata: b\ndata: c\n\n"

  test "Given an event type and id, when formatted, then they precede the data":
    check formatSseEvent("x", event = "message", id = "7") ==
      "event: message\nid: 7\ndata: x\n\n"

  test "Given any formatted event, when read back, then the same data, type and id are returned":
    for data in ["x", "a\nb", "", " leading space", "{\"k\":\"v\"}"]:
      let events = feedAll(formatSseEvent(data, event = "message", id = "9"))
      check events.len == 1
      check events[0].data == data
      check events[0].event == "message"
      check events[0].id == "9"

  test "Given a comment, when formatted, then it is a comment line that yields no event":
    check formatSseComment("keep-alive") == ": keep-alive\n\n"
    check feedAll(formatSseComment("keep-alive")).len == 0
