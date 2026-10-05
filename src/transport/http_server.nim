## Server-side HTTP transport for MCP.
##
## Listens on `host:port` and accepts JSON-RPC 2.0 POSTs at `path`
## (default `/mcp`). Each POST is parked, handed to `McpServer` through
## the existing `receiveMessage` / `sendResponse` pipeline, and the
## matching response is written back to the originating HTTP connection.
##
## This is the missing counterpart to `transport/http.nim::StreamableHttpTransport`,
## which is a *client-side* transport (it POSTs requests to a remote
## server). `HttpServerTransport` makes `McpServer` reachable from a
## remote client over HTTP, which is the deployment shape used by
## services.
##
## Concurrent POSTs are supported: `pendingResponses` keys response
## futures by the JSON-RPC id so request/response interleaving is fine.
## JSON-RPC notifications cannot be addressed back to a specific HTTP
## client without a streaming channel; `sendNotification` is therefore a
## no-op for now (a future SSE bridge could implement it).

import std/[asyncdispatch, asynchttpserver, httpcore, json, tables,
             deques, options]
import ./transport
import ../protocol/types

type
  HttpServerTransport* = ref object of McpTransport
    server*:          AsyncHttpServer
    host*:            string
    port*:            int
    path*:            string
    requestQueue:     Deque[JsonNode]
    receiveWaiters:   Deque[Future[JsonNode]]
    pendingResponses: Table[string, Future[JsonRpcResponse]]
    started*:         bool

proc newHttpServerTransport*(host: string = "127.0.0.1",
                             port: int = 9011,
                             path: string = "/mcp"): HttpServerTransport =
  result = HttpServerTransport(
    kind:             mtkHttp,
    server:           newAsyncHttpServer(),
    host:             host,
    port:             port,
    path:             path,
    requestQueue:     initDeque[JsonNode](),
    receiveWaiters:   initDeque[Future[JsonNode]](),
    pendingResponses: initTable[string, Future[JsonRpcResponse]](),
    started:          false,
  )

method receiveMessage*(t: HttpServerTransport): Future[JsonNode] {.async.} =
  if t.requestQueue.len > 0:
    return t.requestQueue.popFirst()
  let fut = newFuture[JsonNode]("HttpServerTransport.receiveMessage")
  t.receiveWaiters.addLast(fut)
  return await fut

method sendResponse*(t: HttpServerTransport,
                    response: JsonRpcResponse): Future[void] {.async.} =
  if not t.pendingResponses.hasKey(response.id):
    return
  let fut = t.pendingResponses[response.id]
  t.pendingResponses.del(response.id)
  fut.complete(response)

method sendNotification*(t: HttpServerTransport,
                        notification: JsonRpcNotification): Future[void] {.async.} =
  ## Without a streaming channel back to a specific HTTP client,
  ## server-to-client notifications can't be delivered. No-op for now.
  discard

method sendRequest*(t: HttpServerTransport,
                   request: JsonRpcRequest): Future[void] {.async.} =
  raise newException(McpTransportError,
                     "HttpServerTransport.sendRequest is not supported")

method close*(t: HttpServerTransport): Future[void] {.async.} =
  t.started = false
  t.server.close()

proc start*(t: HttpServerTransport): Future[void] {.async.} =
  ## Bind asynchttpserver and begin serving. The returned future completes
  ## when the underlying server stops.
  proc requestHandler(req: Request) {.async, gcsafe.} =
    {.cast(gcsafe).}:
      if req.url.path != t.path:
        await req.respond(Http404, "")
        return
      if req.reqMethod != HttpPost:
        await req.respond(Http405, "Method not allowed")
        return
      var rpc: JsonNode
      try:
        rpc = parseJson(req.body)
      except CatchableError, Exception:
        await req.respond(Http400, "Invalid JSON")
        return
      if rpc.isNil or rpc.kind != JObject:
        await req.respond(Http400, "Request must be a JSON object")
        return
      # mcp-nim-sdk's decodeRequest reads id as a string; coerce here so
      # numeric ids from the wire (1, 2, 3, ...) survive the round-trip.
      let idNode = rpc.getOrDefault("id")
      let idStr =
        if idNode.isNil: ""
        elif idNode.kind == JString: idNode.getStr()
        elif idNode.kind == JInt: $idNode.getInt()
        else: $idNode
      rpc["id"] = %idStr
      let respFut = newFuture[JsonRpcResponse](
        "HttpServerTransport.respondFor[" & idStr & "]")
      t.pendingResponses[idStr] = respFut
      if t.receiveWaiters.len > 0:
        let waiter = t.receiveWaiters.popFirst()
        waiter.complete(rpc)
      else:
        t.requestQueue.addLast(rpc)
      let resp = await respFut
      let respBody = encodeMessage(resp)
      let headers = newHttpHeaders({"Content-Type": "application/json"})
      await req.respond(Http200, respBody, headers)
  t.started = true
  await t.server.serve(Port(t.port), requestHandler, t.host)
