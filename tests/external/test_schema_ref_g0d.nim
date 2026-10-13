## A `$ref` that leads out of the schema document is never fetched: the
## schema is reported as one that cannot be checked. The only address these
## tests use is a listener of their own on 127.0.0.1, which must not be
## connected to.

import std/[unittest, asyncdispatch, asyncnet, json]
import mcp

proc listen(): tuple[socket: AsyncSocket, port: int] =
  let socket = newAsyncSocket()
  socket.setSockOpt(OptReuseAddr, true)
  socket.bindAddr(Port(0), "127.0.0.1")
  socket.listen()
  (socket: socket, port: socket.getLocalAddr()[1].int)

suite "a $ref that leaves the document":

  test "Given a $ref to a network address, when an instance is validated, then the schema is reported and nothing connects to the address":
    let (listener, port) = listen()
    let address = "127.0.0.1:" & $port
    let references = [
      "http://" & address & "/schema.json",
      "https://" & address & "/schema.json",
      "//" & address & "/schema.json",
      "http://" & address & "/schema.json#/definitions/x"]
    for reference in references:
      let schemas = [
        %*{"$ref": reference},
        %*{"type": "object", "properties": {"a": {"$ref": reference}}},
        %*{"allOf": [{"$ref": reference}]}]
      for schema in schemas:
        expect UnsupportedKeywordError:
          discard validate(schema, %*{"a": 1})
    let connection = listener.accept()
    check not waitFor withTimeout(connection, 150)
    listener.close()

  test "Given a $ref to a file or a relative document, when an instance is validated, then the schema is reported":
    for reference in ["file:///etc/hosts", "other.json", "other.json#/definitions/x"]:
      expect UnsupportedKeywordError:
        discard validate(%*{"$ref": reference}, %*{"a": 1})

  test "Given a $ref into its own document, when an instance is validated, then it is followed":
    let schema = %*{"$defs": {"n": {"type": "integer"}},
                    "properties": {"a": {"$ref": "#/$defs/n"}}}
    check validate(schema, %*{"a": 1}).len == 0
    check validate(schema, %*{"a": "x"}).len == 1
