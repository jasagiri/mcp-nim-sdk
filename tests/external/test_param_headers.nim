## x-mcp-header (2026-07-28): which tool declarations are valid, how call
## arguments become Mcp-Param-* headers, and how a server checks them.
##
## Expectations follow server/tools "x-mcp-header" and
## basic/transports/streamable-http "Custom Headers from Tool Parameters".

import std/[unittest, asyncdispatch, httpclient, json, options, strutils]
import std/os
import protocol/types
import protocol/modern
import transport/http_server
import server/server

proc schema(properties: JsonNode): JsonNode =
  %*{"type": "object", "properties": properties}

const SpeaksModern = isModern(DefaultProtocolVersion)

template modernOnly(body: untyped) =
  ## Parameter headers exist from 2026-07-28 on; a build whose default is
  ## older has no server that checks them.
  when SpeaksModern:
    body
  else:
    skip()

type Reply = tuple[code: HttpCode, body: string]

proc startServerWith(inputSchema: JsonNode): string =
  ## A server on 127.0.0.1 that lists one tool, "t", with this `inputSchema`
  ## (none when nil), and answers its calls.
  var tool = %*{"name": "t"}
  if not inputSchema.isNil:
    tool["inputSchema"] = inputSchema
  let transport = newHttpServerTransport(port = 0)
  transport.listen()
  asyncCheck transport.serve()
  let server = newMcpServer(McpServerInfo(name: "ExampleServer", version: "1.0.0"),
    capabilities = McpServerCapabilities(tools: some(McpToolsCapability())))
  let listTools: typeof(McpToolHandlers().listHandler.get) =
    proc(): Future[seq[JsonNode]] {.async.} =
      return @[tool]
  let callTool: typeof(McpToolHandlers().callHandler.get) =
    proc(name: string, arguments: JsonNode): Future[JsonNode] {.async.} =
      return %*{"content": [{"type": "text", "text": name}], "isError": false}
  server.setToolHandlers(McpToolHandlers(
    listHandler: some(listTools), callHandler: some(callTool)))
  waitFor server.attachTransport(transport)
  "http://127.0.0.1:" & $transport.port & "/mcp"

proc postJson(url: string, body: JsonNode, headers: openArray[(string, string)]): Reply =
  let http = newAsyncHttpClient()
  defer: http.close()
  let response = waitFor http.request(url, HttpPost, $body, newHttpHeaders(headers))
  (response.code, waitFor response.body)

proc modernMeta(): JsonNode =
  %*{"io.modelcontextprotocol/protocolVersion": "2026-07-28",
     "io.modelcontextprotocol/clientInfo": {"name": "ExampleClient", "version": "1.0.0"},
     "io.modelcontextprotocol/clientCapabilities": {}}

proc isListed(url: string): bool =
  ## Whether the server's tools/list publishes the tool "t".
  let reply = postJson(url, %*{"jsonrpc": "2.0", "id": 1, "method": "tools/list",
                               "params": {"_meta": modernMeta()}},
                       {"Content-Type": "application/json",
                        "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"})
  check reply.code == Http200
  for tool in parseJson(reply.body)["result"]["tools"]:
    if tool["name"].getStr() == "t":
      return true

proc isPublished(inputSchema: JsonNode): bool =
  isListed(startServerWith(inputSchema))

proc callOf(url: string, arguments: JsonNode,
            received: openArray[(string, string)]): Reply =
  ## A tools/call of "t" carrying exactly these `Mcp-Param-*` headers.
  var headers = @[("Content-Type", "application/json"),
                  ("MCP-Protocol-Version", "2026-07-28"),
                  ("Mcp-Method", "tools/call"), ("Mcp-Name", "t")]
  headers.add received
  postJson(url, %*{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                   "params": {"_meta": modernMeta(), "name": "t", "arguments": arguments}},
           headers)

proc accepts(url: string, arguments: JsonNode,
             received: openArray[(string, string)]): bool =
  callOf(url, arguments, received).code == Http200

proc rejectsAsMismatch(url: string, arguments: JsonNode,
                       received: openArray[(string, string)]): bool =
  let reply = callOf(url, arguments, received)
  reply.code == Http400 and parseJson(reply.body){"error", "code"}.getInt() == ErrHeaderMismatch

let sqlSchema = schema(%*{
  "region": {"type": "string", "x-mcp-header": "Region"},
  "query": {"type": "string"}})


suite "x-mcp-header: invalid declarations":

  proc invalid(properties: JsonNode): bool =
    not isPublished(schema(properties))

  test "Given an empty name, when declarations are read, then the tool is invalid":
    modernOnly:
      check invalid(%*{"a": {"type": "string", "x-mcp-header": ""}})

  test "Given a name that is not a token, when declarations are read, then the tool is invalid":
    modernOnly:
      check invalid(%*{"a": {"type": "string", "x-mcp-header": "Bad Name"}})
      check invalid(%*{"a": {"type": "string", "x-mcp-header": "Bad:Name"}})
      check invalid(%*{"a": {"type": "string", "x-mcp-header": "Bad\r\nName"}})
      check invalid(%*{"a": {"type": "string", "x-mcp-header": "Naïve"}})

  test "Given a name that is not a string, when declarations are read, then the tool is invalid":
    modernOnly:
      check invalid(%*{"a": {"type": "string", "x-mcp-header": 7}})
      check invalid(%*{"a": {"type": "string", "x-mcp-header": ["A"]}})

  test "Given two names that differ only in case, when declarations are read, then the tool is invalid":
    modernOnly:
      check invalid(%*{
        "a": {"type": "string", "x-mcp-header": "Region"},
        "b": {"type": "string", "x-mcp-header": "REGION"}})

  test "Given a number property, when declarations are read, then the tool is invalid":
    modernOnly:
      check invalid(%*{"a": {"type": "number", "x-mcp-header": "A"}})

  test "Given an object or array property, when declarations are read, then the tool is invalid":
    modernOnly:
      check invalid(%*{"a": {"type": "object", "x-mcp-header": "A"}})
      check invalid(%*{"a": {"type": "array", "x-mcp-header": "A"}})

  test "Given an annotated property with no type, when declarations are read, then the tool is invalid":
    modernOnly:
      check invalid(%*{"a": {"x-mcp-header": "A"}})

  test "Given an annotation on the schema root, when declarations are read, then the tool is invalid":
    modernOnly:
      check not isPublished(%*{"type": "object", "x-mcp-header": "A"})

  test "Given an annotation under items, when declarations are read, then the tool is invalid":
    modernOnly:
      check invalid(%*{"list": {"type": "array", "items": {"type": "string", "x-mcp-header": "A"}}})

  test "Given an annotation under composition, conditional or $ref keywords, when declarations are read, then the tool is invalid":
    modernOnly:
      for keyword in ["oneOf", "anyOf", "allOf"]:
        check invalid(%*{"a": {keyword: [{"type": "string", "x-mcp-header": "A"}]}})
      check invalid(%*{"a": {"not": {"type": "string", "x-mcp-header": "A"}}})
      check invalid(%*{"a": {"if": {"type": "string", "x-mcp-header": "A"}}})
      check invalid(%*{"a": {"then": {"type": "string", "x-mcp-header": "A"}}})
      check invalid(%*{"a": {"else": {"type": "string", "x-mcp-header": "A"}}})
      let viaRef = %*{"type": "object", "properties": {"a": {"$ref": "#/$defs/p"}},
                      "$defs": {"p": {"type": "string", "x-mcp-header": "A"}}}
      check not isPublished(viaRef)

  test "Given a property whose schema is the boolean true, when declarations are read, then the tool stays valid and the annotated property is still checked":
    modernOnly:
      let url = startServerWith(schema(%*{
        "anything": true,
        "region": {"type": "string", "x-mcp-header": "Region"}}))
      check isListed(url)
      check rejectsAsMismatch(url, %*{"region": "us-west1"}, [])


suite "x-mcp-header: server validation":


  test "Given a body number written with a fraction part, when checked, then it agrees with the same integer in the header":
    modernOnly:
      let url = startServerWith(schema(%*{"n": {"type": "integer", "x-mcp-header": "N"}}))
      check accepts(url, parseJson("""{"n": 42.0}"""), [("Mcp-Param-N", "42")])
      check rejectsAsMismatch(url, parseJson("""{"n": 42.0}"""), [("Mcp-Param-N", "43")])

  test "Given an object or array argument, when checked, then no header value agrees with it":
    modernOnly:
      let url = startServerWith(sqlSchema)
      for body in [%*{"region": ["x"]}, %*{"region": {"x": 1}}]:
        check rejectsAsMismatch(url, body, [("Mcp-Param-Region", "x")])

  test "Given a boolean argument, when checked, then the header true or false agrees with it and the other does not":
    modernOnly:
      let url = startServerWith(schema(%*{"flag": {"type": "boolean", "x-mcp-header": "Flag"}}))
      check accepts(url, %*{"flag": true}, [("Mcp-Param-Flag", "true")])
      check accepts(url, %*{"flag": false}, [("Mcp-Param-Flag", "false")])
      check rejectsAsMismatch(url, %*{"flag": true}, [("Mcp-Param-Flag", "false")])

  test "Given an integer argument, when the header is not a number, then the answer is 400 header mismatch":
    modernOnly:
      let url = startServerWith(schema(%*{"n": {"type": "integer", "x-mcp-header": "N"}}))
      check rejectsAsMismatch(url, %*{"n": 42}, [("Mcp-Param-N", "forty-two")])

  test "Given a string argument with a comma, when the header carries it plain, then the answer is 200":
    modernOnly:
      # A comma is visible ASCII, so a client sends the value as it is (not Base64).
      let url = startServerWith(sqlSchema)
      check accepts(url, %*{"region": "us-west1,eu-west1"}, [("Mcp-Param-Region", "us-west1,eu-west1")])
      check accepts(url, %*{"region": "a, b"}, [("Mcp-Param-Region", "a, b")])

  test "Given a header sent twice, when one of the two differs from the body, then the answer is 400 header mismatch":
    modernOnly:
      let url = startServerWith(sqlSchema)
      check rejectsAsMismatch(url, %*{"region": "us-west1"},
                              [("Mcp-Param-Region", "us-west1"), ("Mcp-Param-Region", "eu-west1")])


suite "x-mcp-header: tool declarations seen through the public entries":

  proc loggedWhile(body: proc()): string =
    ## Everything the code under test wrote to stderr.
    let path = getTempDir() / "mcp-param-headers-" & $getCurrentProcessId() & ".log"
    let saved = stderr
    stderr = open(path, fmWrite)
    try:
      body()
    finally:
      stderr.close()
      stderr = saved
    result = readFile(path)
    removeFile(path)

  proc reasonFor(inputSchema: JsonNode): string =
    ## What a server says when its tools/list leaves out the tool "t": the
    ## text of its stderr.
    let url = startServerWith(inputSchema)
    result = loggedWhile(proc() = check not isListed(url))

  test "Given items, additionalProperties, anyOf and a property named x-mcp-header with one annotated property, when the tool is listed and called, then it is valid and only the annotated property needs a header":
    modernOnly:
      let url = startServerWith(schema(%*{
        "list": {"type": "array", "items": {"type": "string"}},
        "free": {"type": "object", "additionalProperties": {"type": "integer"}},
        "pick": {"anyOf": [{"type": "string"}, {"type": "integer"}]},
        "inner": {"type": "object", "properties": {"x-mcp-header": {"type": "string"}}},
        "id": {"type": "string", "x-mcp-header": "Id"}}))
      check isListed(url)
      let arguments = %*{"list": ["x"], "free": {"k": 1}, "pick": "p",
                         "inner": {"x-mcp-header": "v"}, "id": "abc"}
      check accepts(url, arguments, [("Mcp-Param-Id", "abc")])
      check rejectsAsMismatch(url, arguments, @[])
      check rejectsAsMismatch(url, arguments, [("Mcp-Param-Id", "abd")])

  test "Given an invalid declaration on a nested property, when the server lists tools, then the reason it logs names that property":
    modernOnly:
      let reason = reasonFor(schema(%*{
        "target": {"type": "object", "properties": {
          "zone": {"type": "number", "x-mcp-header": "Zone"}}}}))
      check "not listing tool 't'" in reason
      check "'target.zone'" in reason

  test "Given an invalid declaration on the schema root, when the server lists tools, then the reason it logs names the schema root":
    modernOnly:
      let reason = reasonFor(%*{"type": "object", "x-mcp-header": "A"})
      check "not listing tool 't'" in reason
      check "the schema root" in reason

  test "Given an empty name, when the server lists tools, then the reason it logs names the property and says the name is not to be empty":
    modernOnly:
      let reason = reasonFor(schema(%*{"a": {"type": "string", "x-mcp-header": ""}}))
      check "'a'" in reason
      check "empty" in reason

  test "Given a name that is not empty but invalid, when the server lists tools, then the reason it logs does not speak of emptiness":
    modernOnly:
      let reason = reasonFor(schema(%*{"a": {"type": "string", "x-mcp-header": "Bad Name"}}))
      check "'a'" in reason
      check "empty" notin reason
