## Cursor-based pagination of the list methods (tools/list, resources/list,
## resources/templates/list, prompts/list), the same in every version.

import std/[asyncdispatch, base64, json, options, strutils]
import ./errors

type
  McpPage* = object
    items*: seq[JsonNode]
    nextCursor*: Option[string]
      ## None on the last page.

  ListHandler* = proc(cursor: Option[string]): Future[McpPage] {.async.}
    ## The page that follows `cursor`, or the first page when there is none.
    ## Raise `newInvalidCursor()` for a cursor this handler did not issue.

  ListAll* = proc(): Future[seq[JsonNode]] {.async.}

const CursorPrefix = "offset:"

func encodeCursor(offset: int): string =
  base64.encode(CursorPrefix & $offset)

func decodeCursor(cursor: string, itemCount: int): Option[int] =
  ## The offset a cursor of `encodeCursor` names, when it lies inside a list
  ## of `itemCount` items.
  var text: string
  try:
    text = base64.decode(cursor)
  except ValueError:
    return none(int)
  if not text.startsWith(CursorPrefix):
    return none(int)
  var offset: int
  try:
    offset = parseInt(text[CursorPrefix.len .. ^1])
  except ValueError:
    return none(int)
  if offset < 1 or offset >= itemCount:
    return none(int)
  some(offset)

proc pageOf*(items: seq[JsonNode], cursor: Option[string],
             pageSize: int): McpPage {.raises: [McpRequestError].} =
  ## The page of `items` after `cursor`. A `pageSize` of 0 puts everything on
  ## one page, so no cursor can be valid.
  var start = 0
  if cursor.isSome:
    let offset = if pageSize > 0: decodeCursor(cursor.get, items.len) else: none(int)
    if offset.isNone:
      raise newInvalidCursor()
    start = offset.get
  let stop = if pageSize > 0: min(start + pageSize, items.len) else: items.len
  result.items = items[start ..< stop]
  if stop < items.len:
    result.nextCursor = some(encodeCursor(stop))

proc pagedList*(all: ListAll, pageSize: int): ListHandler =
  ## A list handler that cuts the list `all` returns into pages of
  ## `pageSize` items, calling `all` again for each page.
  result = proc(cursor: Option[string]): Future[McpPage] {.async.} =
    return pageOf(await all(), cursor, pageSize)
