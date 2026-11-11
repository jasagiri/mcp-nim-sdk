## JSON-RPC messages are UTF-8 (basic/transports). A string that is not UTF-8
## is never written as such: a request or a notification is not sent, and a
## response, which is owed, is sent as an internal error.

import std/[unittest, asyncdispatch, asyncnet, json, nativesockets, net, streams, strutils, unicode, os]
import mcp

const
  NotUtf8 = ["a\xFFb", "\xE3\x81", "\xC0\x80", "\xED\xA0\x80", "\xF8\x88\x80\x80\x80",
             "\xE0\x80\xA0", "\xF0\x80\x80\xA0", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80"]
    ## A byte no character has, a character cut short, an overlong form, a
    ## surrogate, and a form longer than four bytes; overlong forms of three
    ## and of four bytes, and two code points above U+10FFFF (RFC 3629).
  Utf8 = ["", "ascii", "日本語", "é", "\xF0\x9F\x98\x80", "\xED\x9F\xBF", "\xEE\x80\x80"]
    ## The last two are U+D7FF and U+E000, the characters on either side of
    ## the surrogates.

proc refusal(sending: Future[void]): string =
  ## The message a send is refused with; "" when it is not refused.
  try:
    waitFor sending
  except McpTransportError as e:
    return e.msg

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-utf8-refused-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

suite "strings that are not UTF-8, on stdio":

  test "Given a string that is not UTF-8, when a request or a notification holds it as a value or as a member name, then it is not sent and nothing is written":
    for text in NotUtf8:
      checkpoint text.escape
      let output = newStringStream()
      let transport = newStdioTransport(newStringStream(""), output)
      check "UTF-8" in refusal(transport.sendNotification(newJsonRpcNotification("x", %*{"text": text})))
      check "UTF-8" in refusal(transport.sendRequest(newJsonRpcRequest("r1", "x", %*{"list": [1, {"deep": text}]})))
      let named = newJObject()
      named[text] = %1
      check "UTF-8" in refusal(transport.sendNotification(newJsonRpcNotification("x", named)))
      check output.data == ""

  test "Given strings that are UTF-8, when a message holds them, then it is sent as it is":
    for text in Utf8:
      checkpoint text.escape
      let output = newStringStream()
      let transport = newStdioTransport(newStringStream(""), output)
      check refusal(transport.sendNotification(newJsonRpcNotification("x", %*{"text": text}))) == ""
      check validateUtf8(output.data) == -1
      check parseJson(output.data.strip())["params"]["text"].getStr() == text

  test "Given a result that holds a string that is not UTF-8, when the response is sent, then the peer gets an internal error under the same id and what is written is UTF-8":
    for text in NotUtf8:
      checkpoint text.escape
      let output = newStringStream()
      let transport = newStdioTransport(newStringStream(""), output)
      check refusal(transport.sendResponse(newJsonRpcResponse("r7", %*{"text": text}))) == ""
      check validateUtf8(output.data) == -1
      let written = parseJson(output.data.strip())
      check written["id"].getStr() == "r7"
      check written["error"]["code"].getInt() == -32603
      check not written.hasKey("result")

  test "Given a response whose id is a string that is not UTF-8, when it is sent, then the peer gets an internal error with a null id and what is written is UTF-8":
    for text in NotUtf8:
      checkpoint text.escape
      let output = newStringStream()
      let transport = newStdioTransport(newStringStream(""), output)
      check refusal(transport.sendResponse(newJsonRpcResponse(text, %*{"ok": true}))) == ""
      check validateUtf8(output.data) == -1
      let written = parseJson(output.data.strip())
      check written["id"].kind == JNull
      check written["error"]["code"].getInt() == -32603
      check not written.hasKey("result")

  test "Given a response that holds a string that is not UTF-8, when it is sent as an internal error, then one line is logged and the bytes that are not UTF-8 are not in it":
    for text in NotUtf8:
      checkpoint text.escape
      for response in [newJsonRpcResponse("r7", %*{"text": text}),
                       newJsonRpcResponse(text, %*{"ok": true})]:
        let transport = newStdioTransport(newStringStream(""), newStringStream())
        let logged = loggedWhile(proc() =
          check refusal(transport.sendResponse(response)) == "")
        check logged.count('\n') == 1
        check logged.endsWith("\n")
        check validateUtf8(logged) == -1
        check text notin logged

suite "strings that are not UTF-8, over HTTP":

  test "Given a string that is not UTF-8, when a client posts a request that holds it, then the request is refused and nothing is posted":
    let listener = newAsyncSocket(buffered = false)
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let port = listener.getLocalAddr()[1].int
    var connections = 0
    proc serve() {.async.} =
      while true:
        let client = await listener.accept()
        inc connections
        client.close()
    asyncCheck serve()
    for text in NotUtf8:
      checkpoint text.escape
      let transport = newStreamableHttpTransport("http://127.0.0.1:" & $port & "/mcp")
      check "UTF-8" in refusal(transport.sendRequest(newJsonRpcRequest("r1", "echo", %*{"text": text})))
      waitFor transport.close()
    check connections == 0
