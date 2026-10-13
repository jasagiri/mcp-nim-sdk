## A client transport for a URL that may belong to a server of either HTTP
## transport.
##
## As the specification's backwards-compatibility guidance has it: POST the
## first message with Streamable HTTP. If the server refuses with an HTTP 4xx
## status (405 Method Not Allowed, 404 Not Found), the URL is that of a
## server of the 2024-11-05 HTTP+SSE transport: open its event stream with
## GET and use that transport from then on. Any other failure, such as a
## server that cannot be reached, is raised and decides nothing.

import std/[asyncdispatch, httpcore, json]
import ./transport
import ./http
import ./sse_legacy
export sse_legacy  # the type of the `legacy` field, and the HTTP+SSE client by itself
import ../protocol/types

type
  HttpChoice* = enum
    hcUndecided, hcStreamable, hcSseLegacy

  AutoHttpTransport* = ref object of McpTransport
    url*: string
    headers*: HttpHeaders
      ## Sent with every request by whichever transport is chosen.
    streamable*: StreamableHttpTransport
    legacy*: SseLegacyTransport
    chosen*: HttpChoice
    decided: Future[void]

proc newAutoHttpTransport*(url: string): AutoHttpTransport =
  let headers = newHttpHeaders()
  let streamable = newStreamableHttpTransport(url)
  let legacy = newSseLegacyTransport(url)
  streamable.headers = headers
  legacy.headers = headers
  AutoHttpTransport(kind: mtkStreamable, url: url, headers: headers,
                    streamable: streamable, legacy: legacy, chosen: hcUndecided,
                    decided: newFuture[void]("AutoHttpTransport.decided"))

proc choose(t: AutoHttpTransport, choice: HttpChoice) =
  t.chosen = choice
  t.decided.complete()

template sendFirst(t: AutoHttpTransport, viaStreamable, viaLegacy: untyped) =
  ## Send through the transport that is chosen; when none is yet, try
  ## Streamable HTTP and fall back as described above.
  case t.chosen
  of hcStreamable:
    await viaStreamable
  of hcSseLegacy:
    await viaLegacy
  of hcUndecided:
    var refused = false
    try:
      await viaStreamable
    except McpTransportError as e:
      if e.code notin 400 .. 499:
        raise
      refused = true
    if refused:
      t.choose(hcSseLegacy)
      await viaLegacy
    else:
      t.choose(hcStreamable)

method sendRequest*(t: AutoHttpTransport, request: JsonRpcRequest): Future[void] {.async.} =
  # The wrapped transport reports a lost request; this one has the handler.
  t.streamable.onRequestLost = t.onRequestLost
  sendFirst(t, t.streamable.sendRequest(request), t.legacy.sendRequest(request))

method sendNotification*(t: AutoHttpTransport, notification: JsonRpcNotification): Future[void] {.async.} =
  sendFirst(t, t.streamable.sendNotification(notification),
            t.legacy.sendNotification(notification))

method sendResponse*(t: AutoHttpTransport, response: JsonRpcResponse): Future[void] {.async.} =
  sendFirst(t, t.streamable.sendResponse(response), t.legacy.sendResponse(response))

method receiveMessage*(t: AutoHttpTransport): Future[JsonNode] {.async.} =
  await t.decided
  case t.chosen
  of hcSseLegacy:
    return await t.legacy.receiveMessage()
  else:
    return await t.streamable.receiveMessage()

method protocolVersionNegotiated*(t: AutoHttpTransport, version: McpProtocolVersion) =
  t.streamable.protocolVersionNegotiated(version)

method close*(t: AutoHttpTransport): Future[void] {.async.} =
  if not t.decided.finished:
    t.decided.fail(newException(McpTransportError, "transport is closed"))
  await t.streamable.close()
  await t.legacy.close()
