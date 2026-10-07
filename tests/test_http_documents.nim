## Fixed documents the Streamable HTTP server transport serves at paths of
## their own (what an extension publishes for discovery): content type,
## validators, preflight, the methods allowed, and that the MCP endpoint and
## the authorization hook are untouched.

import std/[unittest, asyncdispatch, httpclient, options, strutils, tables]
import transport/http_server
import transport/auth_hook

proc served(): HttpServerTransport =
  result = newHttpServerTransport(port = 0)
  result.documents["/mcp/note"] = HttpDocument(
    contentType: "application/vnd.example+json", body: "{\"a\":1}", etag: "\"v1\"",
    headers: @[("Cache-Control", "public, max-age=3600"),
               ("Access-Control-Allow-Origin", "*")])
  result.listen()
  asyncCheck result.serve()

proc call(t: HttpServerTransport, httpMethod: HttpMethod, path: string,
          headers: seq[(string, string)] = @[]): tuple[code: int, headers: HttpHeaders, body: string] =
  let http = newAsyncHttpClient(maxRedirects = 0)
  defer: http.close()
  let response = waitFor http.request("http://127.0.0.1:" & $t.port & path, httpMethod,
                                      headers = newHttpHeaders(headers))
  result = (code: response.code.int, headers: response.headers, body: waitFor response.body)

suite "documents served by the HTTP server transport":

  test "Given a document at a path, when a client GETs it, then the body comes with its type, validator and headers":
    let t = served()
    defer: waitFor t.close()
    let answer = t.call(HttpGet, "/mcp/note")
    check answer.code == 200
    check answer.body == "{\"a\":1}"
    check answer.headers["Content-Type"] == "application/vnd.example+json"
    check answer.headers["ETag"] == "\"v1\""
    check answer.headers["Cache-Control"] == "public, max-age=3600"
    check answer.headers["Access-Control-Allow-Origin"] == "*"
    check answer.headers["X-Content-Type-Options"] == "nosniff"

  test "Given a client that holds the document's ETag, when it GETs again, then the answer is 304 without a body":
    let t = served()
    defer: waitFor t.close()
    for tag in ["\"v1\"", "W/\"v1\"", "\"old\", \"v1\"", "*"]:
      checkpoint tag
      let answer = t.call(HttpGet, "/mcp/note", @[("If-None-Match", tag)])
      check answer.code == 304
      check answer.body == ""
      check answer.headers["ETag"] == "\"v1\""
    check t.call(HttpGet, "/mcp/note", @[("If-None-Match", "\"stale\"")]).code == 200

  test "Given a document, when a client sends HEAD or a preflight, then the headers come without a body":
    let t = served()
    defer: waitFor t.close()
    let head = t.call(HttpHead, "/mcp/note")
    check head.code == 200 and head.body == ""
    check head.headers["ETag"] == "\"v1\""
    let preflight = t.call(HttpOptions, "/mcp/note")
    check preflight.code == 204
    check preflight.headers["Access-Control-Allow-Origin"] == "*"

  test "Given a document, when a client POSTs or DELETEs it, then the answer is 405 naming the allowed methods":
    let t = served()
    defer: waitFor t.close()
    for httpMethod in [HttpPost, HttpDelete, HttpPut]:
      let answer = t.call(httpMethod, "/mcp/note")
      check answer.code == 405
      check answer.headers["Allow"] == "GET, HEAD, OPTIONS"

  test "Given no document at a path, when a client asks for it, then the answer is 404":
    let t = served()
    defer: waitFor t.close()
    check t.call(HttpGet, "/mcp/other").code == 404
    check t.call(HttpGet, "/mcp/note/").code == 404

  test "Given an authorization hook that demands a token on the MCP path only, when a client GETs a document, then it is served":
    let t = served()
    defer: waitFor t.close()
    t.auth = HttpServerAuth(
      intercept: proc(httpMethod, path: string, authorization: Option[string]):
                     Future[Option[HttpServerAuthResponse]] {.closure, gcsafe, async.} =
        if path == "/mcp":
          return some(HttpServerAuthResponse(code: 401))
        return none(HttpServerAuthResponse))
    check t.call(HttpGet, "/mcp/note").code == 200
    check t.call(HttpPost, "/mcp").code == 401

  test "Given a transport without documents, when a client asks for any path but the MCP ones, then the answer is 404":
    let t = newHttpServerTransport(port = 0)
    t.listen()
    asyncCheck t.serve()
    defer: waitFor t.close()
    check t.documents.len == 0
    check t.call(HttpGet, "/mcp/server-card").code == 404

suite "documents served by the HTTP server transport (mutation review, g2f-hs-c)":

  test "Given a document without an ETag, when a client GETs it with If-None-Match, then it is served whole and no ETag is sent":
    # No validator, nothing to match: a conditional GET of such a document
    # is an ordinary GET.
    let t = newHttpServerTransport(port = 0)
    t.documents["/mcp/plain"] = HttpDocument(contentType: "text/plain", body: "plain")
    t.listen()
    asyncCheck t.serve()
    defer: waitFor t.close()
    let conditional = t.call(HttpGet, "/mcp/plain", @[("If-None-Match", "*")])
    check conditional.code == 200
    check conditional.body == "plain"
    check not conditional.headers.hasKey("ETag")
    let unconditional = t.call(HttpGet, "/mcp/plain")
    check unconditional.code == 200
    check not unconditional.headers.hasKey("ETag")
