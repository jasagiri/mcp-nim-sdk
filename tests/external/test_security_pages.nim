## A server that always has another page must not keep a client reading, and
## growing its list, for ever.

import std/[asyncdispatch, options, strutils, unittest]
import client/content
import client/client except McpRequestError

suite "security: following nextCursor":
  test "Given a server that makes up a new cursor for every page, when all pages are read, then it is a protocol error after the limit":
    var fetched = 0
    let fetch = proc(cursor: Option[string]): Future[tuple[items: seq[int], next: Option[string]]] {.async.} =
      inc fetched
      return (items: @[fetched], next: some("page-" & $fetched))
    expect McpProtocolError:
      discard waitFor allPages[int]("tools/list", fetch, maxPages = 5)
    check fetched == 5

  test "Given a server that repeats a cursor, when all pages are read, then it is a protocol error at the repeat, not at the limit":
    var fetched = 0
    let fetch = proc(cursor: Option[string]): Future[tuple[items: seq[int], next: Option[string]]] {.async.} =
      inc fetched
      return (items: @[fetched], next: some("same"))
    var message = ""
    try:
      discard waitFor allPages[int]("tools/list", fetch)
    except McpProtocolError as e:
      message = e.msg
    check "repeated cursor 'same'" in message
    check fetched == 2

  test "Given a server whose last page is the limit, when all pages are read, then every item is returned":
    var fetched = 0
    let fetch = proc(cursor: Option[string]): Future[tuple[items: seq[int], next: Option[string]]] {.async.} =
      inc fetched
      return (items: @[fetched], next: if fetched < 5: some("page-" & $fetched) else: none(string))
    check waitFor(allPages[int]("tools/list", fetch, maxPages = 5)) == @[1, 2, 3, 4, 5]

  test "Given the default limit, when a server has 1000 pages, then they are read":
    var fetched = 0
    let fetch = proc(cursor: Option[string]): Future[tuple[items: seq[int], next: Option[string]]] {.async.} =
      inc fetched
      return (items: @[fetched], next: if fetched < MaxListPages: some("p" & $fetched) else: none(string))
    check waitFor(allPages[int]("tools/list", fetch)).len == MaxListPages
