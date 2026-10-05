## The HTTP requests an OAuth client makes to metadata, registration and
## token endpoints: bounded in time and size, never redirected, and only to
## URLs that pass `checkFetchUrl`.

import std/[asyncdispatch, httpclient, json, options, strutils]
import ./errors
import ./urls

type
  HttpReply* = object
    code*: int
    headers*: HttpHeaders
    body*: string

  JsonReply* = object
    code*: int
    document*: Option[JsonNode]
      ## Present when the body of a success response is a JSON object.

proc exchange(client: AsyncHttpClient, httpMethod: HttpMethod, url, body: string,
              headers: HttpHeaders, maxBodySize: int): Future[HttpReply] {.async.} =
  let response = await client.request(url, httpMethod, body, headers)
  result.code = response.code.int
  result.headers = response.headers
  while true:
    let (hasData, chunk) = await response.bodyStream.read()
    if not hasData:
      break
    if result.body.len + chunk.len > maxBodySize:
      raise newException(OAuthError, "response from " & url & " exceeds " &
                                     $maxBodySize & " bytes")
    result.body.add chunk

proc httpExchange*(httpMethod: HttpMethod, url: string, policy: FetchPolicy, what: string,
                   body = "", headers: seq[(string, string)] = @[]): Future[HttpReply] {.async.} =
  ## One request. Redirects are not followed: an endpoint that moves is
  ## reported, not chased to a host nobody vetted.
  checkFetchUrl(url, policy, what)
  let client = newAsyncHttpClient(userAgent = "mcp-nim-sdk", maxRedirects = 0)
  let pending = exchange(client, httpMethod, url, body, newHttpHeaders(headers),
                         policy.maxBodySize)
  try:
    let finished = await withTimeout(pending, policy.timeoutMs)
    if not finished:
      client.close()
      # The abandoned request fails when its socket closes. The caller
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
  except CatchableError as e:
    raise newException(OAuthError, what & " " & url & " failed: " & e.msg)
  finally:
    client.close()
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
