## Cursor pagination of the four list methods, in every version.

import std/[unittest, asyncdispatch, json, options]
import ./server_harness

proc items(prefix: string, count: int): seq[JsonNode] =
  for i in 1 .. count:
    result.add %*{"name": prefix & $i, "uri": "file:///" & prefix & $i,
                  "uriTemplate": "file:///" & prefix & $i & "/{x}"}

proc pagedServer(pageSize: int): McpServer =
  result = newServer(McpServerCapabilities(
    tools: some(McpToolsCapability()),
    resources: some(McpResourcesCapability()),
    prompts: some(McpPromptsCapability())))
  proc source(prefix: string, count: int): ListAll =
    proc(): Future[seq[JsonNode]] {.async.} = return items(prefix, count)
  result.onToolsList(pagedList(source("tool", 5), pageSize))
  result.onResourcesList(pagedList(source("res", 5), pageSize))
  result.onResourceTemplatesList(pagedList(source("tpl", 5), pageSize))
  result.onPromptsList(pagedList(source("prompt", 5), pageSize))

const Lists = [
  ("tools/list", "tools"), ("resources/list", "resources"),
  ("resources/templates/list", "resourceTemplates"), ("prompts/list", "prompts")]

suite "pageOf":

  test "Given 5 items and a page size of 2, when the pages are followed, then every item comes once and the last page has no cursor":
    let all = items("x", 5)
    var cursor = none(string)
    var seen: seq[JsonNode]
    var pages = 0
    while true:
      let page = pageOf(all, cursor, 2)
      seen.add page.items
      inc pages
      if page.nextCursor.isNone:
        break
      cursor = page.nextCursor
    check seen == all
    check pages == 3

  test "Given a page size of 1, when the pages are followed, then the cursor of the first page leads to the second item":
    let all = items("x", 3)
    let first = pageOf(all, none(string), 1)
    check first.nextCursor.isSome
    check pageOf(all, first.nextCursor, 1).items == @[all[1]]

  test "Given a page size of 0, when the list is paged, then everything is on one page without a cursor":
    let page = pageOf(items("x", 5), none(string), 0)
    check page.items.len == 5
    check page.nextCursor.isNone

  test "Given a cursor nobody issued, when the list is paged, then the cursor is invalid params":
    for bad in ["", "not base64 !!", "aGVsbG8=", "b2Zmc2V0Ond0Zg==", "b2Zmc2V0OjA=", "b2Zmc2V0OjUw", "b2Zmc2V0OjU="]:
      # hello / offset:wtf / offset:0 / offset:50 / offset:5 (the end itself: no page follows it)
      var code = 0
      try:
        discard pageOf(items("x", 5), some(bad), 2)
      except McpRequestError as e:
        code = e.code
      check code == -32602

  test "Given a cursor that is not the padded base64 the server writes, when the list is paged, then the cursor is invalid params":
    # The first two made std/base64.decode of Nim 2.2.8 read past the end of
    # its input (nim-lang/Nim#25530, an IndexDefect). The rest it decodes to
    # "offset:1": a cursor of this server but for the white space or the pad.
    for bad in ["\rN0x", "\rp1d", " b2Zmc2V0OjE=", "b2Zmc2V0OjE=\n", "b2Zm c2V0OjE=", "b2Zmc2V0OjE"]:
      var code = 0
      try:
        discard pageOf(items("x", 5), some(bad), 2)
      except McpRequestError as e:
        code = e.code
      check code == -32602

  test "Given a page size of 0, when any cursor is given, then it is invalid params":
    expect McpRequestError:
      discard pageOf(items("x", 5), some("b2Zmc2V0OjI="), 0)

suite "list methods on the wire (every version)":

  test "Given a paged list, when a client follows nextCursor, then it sees every item and the last page has no nextCursor":
    for v in SupportedProtocolVersions:
      for (methodName, key) in Lists:
        let server = pagedServer(2)
        let peer = server.connect(server.attach(), v)
        var cursor = none(string)
        var names: seq[string]
        var pages = 0
        while true:
          let params = if cursor.isSome: %*{"cursor": cursor.get} else: newJObject()
          let reply = peer.ask(methodName, params)
          check reply["result"][key].len <= 2
          for item in reply["result"][key]:
            names.add item["name"].getStr()
          inc pages
          if not reply["result"].hasKey("nextCursor"):
            break
          cursor = some(reply["result"]["nextCursor"].getStr())
        check names.len == 5
        check pages == 3

  test "Given an unpaged list, when a client lists, then there is no nextCursor":
    for v in SupportedProtocolVersions:
      let server = pagedServer(0)
      let peer = server.connect(server.attach(), v)
      let reply = peer.ask("tools/list")
      check reply["result"]["tools"].len == 5
      check not reply["result"].hasKey("nextCursor")

  test "Given a cursor the server did not issue, when a client lists, then the error is invalid params":
    for v in SupportedProtocolVersions:
      for (methodName, _) in Lists:
        let server = pagedServer(2)
        let peer = server.connect(server.attach(), v)
        check peer.ask(methodName, %*{"cursor": "bogus"}).errorCode == -32602

  test "Given a cursor that is not base64, when a client lists, then the error is invalid params and the server goes on answering":
    for v in SupportedProtocolVersions:
      let server = pagedServer(2)
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/list", %*{"cursor": "\rN0x"}).errorCode == -32602
      check peer.ask("tools/list")["result"]["tools"].len == 2

  test "Given a cursor that is not a string, when a client lists, then the error is invalid params":
    for v in SupportedProtocolVersions:
      let server = pagedServer(2)
      let peer = server.connect(server.attach(), v)
      check peer.ask("tools/list", %*{"cursor": 3}).errorCode == -32602
      check peer.ask("tools/list", %*{"cursor": nil}).errorCode == -32602

  test "Given a handler of its own cursors, when a client lists, then its cursor and its invalid-cursor error are used":
    for v in SupportedProtocolVersions:
      let server = pagedServer(2)
      server.onToolsList(proc(cursor: Option[string]): Future[McpPage] {.async.} =
        if cursor.isNone:
          return McpPage(items: @[%*{"name": "a"}], nextCursor: some("after-a"))
        if cursor.get != "after-a":
          raise newInvalidCursor()
        return McpPage(items: @[%*{"name": "b"}]))
      let peer = server.connect(server.attach(), v)
      let first = peer.ask("tools/list")
      check first["result"]["nextCursor"].getStr() == "after-a"
      let second = peer.ask("tools/list", %*{"cursor": "after-a"})
      check second["result"]["tools"][0]["name"].getStr() == "b"
      check not second["result"].hasKey("nextCursor")
      check peer.ask("tools/list", %*{"cursor": "other"}).errorCode == -32602

  test "Given no templates handler, when a client lists templates, then the list is empty":
    for v in SupportedProtocolVersions:
      let server = newServer(McpServerCapabilities(resources: some(McpResourcesCapability())))
      let peer = server.connect(server.attach(), v)
      check peer.ask("resources/templates/list")["result"]["resourceTemplates"].len == 0

  test "Given no resources capability, when a client lists templates, then the method is not found":
    for v in SupportedProtocolVersions:
      let server = newServer(McpServerCapabilities())
      let peer = server.connect(server.attach(), v)
      check peer.ask("resources/templates/list").errorCode == -32601

  test "Given the handlers of the earlier API, when a client lists, then the whole list is returned":
    let server = newServer(McpServerCapabilities(tools: some(McpToolsCapability())))
    let list: typeof(McpToolHandlers().listHandler.get) =
      proc(): Future[seq[JsonNode]] {.async.} = return items("tool", 3)
    server.setToolHandlers(McpToolHandlers(listHandler: some(list)))
    let peer = server.connect(server.attach(), DefaultProtocolVersion)
    let reply = peer.ask("tools/list")
    check reply["result"]["tools"].len == 3
    check not reply["result"].hasKey("nextCursor")
