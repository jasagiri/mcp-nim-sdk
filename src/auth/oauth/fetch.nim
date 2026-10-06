## The HTTP requests an OAuth client makes to metadata, registration and
## token endpoints: bounded in time and size, never redirected, only to URLs
## that pass `checkFetchUrl`, and only to an address the policy allows (the
## host is resolved and the connection goes to the address that was judged).
## They go over `transport/http_wire`, so the TLS certificate has to be valid
## for the host of the URL.

import std/[asyncdispatch, httpcore, json, options, strutils]
import ./errors
import ./urls
import ../../transport/guarded_wire
import ../../transport/http_wire as wire

type
  HttpReply* = object
    code*: int
    headers*: HttpHeaders
    body*: string

  JsonReply* = object
    code*: int
    document*: Option[JsonNode]
      ## Present when the body of a success response is a JSON object.

type Connection = ref object
  response: WireResponse
    ## The request in flight, so that a timeout can close its connection.

proc exchange(httpMethod: HttpMethod, url, what: string, policy: FetchPolicy, body: string,
              headers: HttpHeaders, open: Connection): Future[HttpReply] {.async.} =
  let response = await guardedRequest(
    url, httpMethod, policy.destinationPolicy, policy.resolver, headers, body,
    connected = proc(connection: WireResponse) {.closure, gcsafe.} =
      open.response = connection,
    followRedirects = false, connectTimeoutMs = policy.timeoutMs)
  defer: response.close()
  result.code = response.code.int
  result.headers = response.headers
  result.body = await response.readAll(policy.maxBodySize)

proc httpExchange*(httpMethod: HttpMethod, url: string, policy: FetchPolicy, what: string,
                   body = "", headers: seq[(string, string)] = @[]): Future[HttpReply] {.async.} =
  ## One request. Redirects are not followed: an endpoint that moves is
  ## reported, not chased to a host nobody vetted. The host is resolved here
  ## and the connection goes to an address the policy allows, whatever the
  ## URL's text looks like; a host the policy refuses is an OAuthSecurityError.
  checkFetchUrl(url, policy, what)
  let sent = newHttpHeaders(headers)
  if not sent.hasKey("User-Agent"):
    sent["User-Agent"] = "mcp-nim-sdk"
  let open = Connection()
  let pending = exchange(httpMethod, url, what, policy, body, sent, open)
  try:
    let finished = await withTimeout(pending, policy.timeoutMs)
    if not finished:
      if not open.response.isNil:
        open.response.close()
      # The abandoned request fails when its connection closes. The caller
      # learns about the timeout; the diagnostic below says what became of it.
      pending.addCallback(proc() {.gcsafe.} =
        if pending.failed:
          stderr.writeLine("[oauth] abandoned request to " & url & " ended: " &
                           pending.readError().msg))
      raise newException(OAuthError, what & " " & url & " timed out after " &
                                     $policy.timeoutMs & " ms")
    result = pending.read()
  except OAuthError:
    raise
  except AddressNotAllowed as e:
    raise newException(OAuthSecurityError, what & " " & e.msg)
  except CatchableError as e:
    raise newException(OAuthError, what & " " & url & " failed: " & e.msg)
  # 304 answers a conditional request; it moves nothing.
  if result.code in 300 .. 399 and result.code != 304:
    raise newException(OAuthError, what & " " & url & " redirected (HTTP " &
                                   $result.code & "); redirects are not followed")

proc getJson*(url: string, policy: FetchPolicy, what: string,
              headers: seq[(string, string)] = @[]): Future[JsonReply] {.async.} =
  ## GET a JSON document. Non-success statuses are returned, not raised:
  ## discovery treats a 404 as "try the next URL".
  let reply = await httpExchange(HttpGet, url, policy, what,
                                 headers = headers & @[("Accept", "application/json")])
  result.code = reply.code
  if reply.code in 200 .. 299:
    try:
      let parsed = parseJson(reply.body)
      if parsed.kind == JObject:
        result.document = some(parsed)
    except CatchableError:
      result.document = none(JsonNode)

proc postForm*(url: string, fields: openArray[(string, string)], policy: FetchPolicy,
               what: string, headers: seq[(string, string)] = @[]): Future[HttpReply] =
  httpExchange(HttpPost, url, policy, what, body = formEncode(fields),
               headers = headers & @[("Content-Type", "application/x-www-form-urlencoded"),
                                      ("Accept", "application/json")])

proc postJson*(url: string, document: JsonNode, policy: FetchPolicy,
               what: string): Future[HttpReply] =
  httpExchange(HttpPost, url, policy, what, body = $document,
               headers = @{"Content-Type": "application/json",
                           "Accept": "application/json"})
