## What a server sends can make a read fail, never the client
## (specs/security.feature, MCP-SEC-WIRE-23). Each case was found by fuzzing
## (tests/fuzz: httpResponse, httpChunked, clientAnswers) and raised a Defect.

import std/[unittest, asyncdispatch, asyncnet, json, nativesockets, strutils]
import mcp

type Peer = ref object
  socket: AsyncSocket
  port: int
  answer: string

proc startPeer(answer: string): Peer =
  ## A server that reads a request head and answers it with `answer` as it is.
  let peer = Peer(socket: newAsyncSocket(buffered = false), answer: answer)
  peer.socket.setSockOpt(OptReuseAddr, true)
  peer.socket.bindAddr(Port(0), "127.0.0.1")
  peer.socket.listen()
  peer.port = peer.socket.getLocalAddr()[1].int
  proc acceptLoop() {.async.} =
    while true:
      let client = await peer.socket.accept()
      proc serve() {.async.} =
        var received = ""
        while not received.contains("\c\L\c\L"):
          let data = await client.recv(4096)
          if data.len == 0:
            break
          received.add data
        await client.send(peer.answer)
        client.close()
      asyncCheck serve()
  asyncCheck acceptLoop()
  peer

proc notifyThrough(answer: string) =
  ## Sends a notification over Streamable HTTP to a server that answers it
  ## with `answer`, as a client does; the transport reads the whole answer.
  let peer = startPeer(answer)
  let t = newStreamableHttpTransport("http://127.0.0.1:" & $peer.port & "/")
  waitFor t.sendNotification(newJsonRpcNotification("notifications/roots/list_changed",
                                                    newJObject()))

const Message = """{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"x"}}"""

proc chunked(data: string): string =
  ## A 202 answer whose body is one chunk declared as long as `Message`,
  ## holding `data`, then the last chunk.
  "HTTP/1.1 202 Accepted\c\LTransfer-Encoding: chunked\c\L\c\L" &
    toHex(Message.len).strip(trailing = false, chars = {'0'}) & "\c\L" & data & "\c\L0\c\L\c\L"

suite "what a server sends can make a read fail, never the client":

  test "Given a status code above 599, when the answer head is read, then the request fails":
    expect McpTransportError:
      notifyThrough("HTTP/1.1 2049 Odd\c\LContent-Length: 0\c\L\c\L")

  test "Given a negative status code, when the answer head is read, then the request fails":
    expect McpTransportError:
      notifyThrough("HTTP/1.1 -5 Odd\c\LContent-Length: 0\c\L\c\L")

  test "Given a chunk size that does not fit in an integer, when the answer body is read, then the request fails":
    expect McpTransportError:
      notifyThrough("HTTP/1.1 200 OK\c\LTransfer-Encoding: chunked\c\L\c\L" &
                   "ffffffffffffffff\c\Lx\c\L0\c\L\c\L")

  test "Given bytes between a chunk's data and its line end, when the answer body is read, then the request fails":
    expect McpTransportError:
      notifyThrough(chunked(Message & "XX"))

  test "Given a well-formed chunked answer, when it is read, then the notification is delivered":
    notifyThrough(chunked(Message))

  test "Given an item that is not an object, when its icons are read, then it is a shape error":
    expect McpShapeError:
      discard iconsOf(%(-1))
    expect McpShapeError:
      discard iconsOf(%*["icons"])
