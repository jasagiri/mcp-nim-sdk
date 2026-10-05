## Roots: the client tells servers which parts of the filesystem they may
## work in. The server asks with roots/list (before 2026-07-28).

import asyncdispatch, json, options
import ./client
import ../protocol/types
import ../protocol/features

type
  McpRoot* = object
    uri*: string  ## a file:// URI
    name*: Option[string]

  McpRootsProvider* = proc(): Future[seq[McpRoot]] {.closure.}

proc setRootsProvider*(client: McpClient, provider: McpRootsProvider,
                       listChanged: bool = true) =
  ## Declare the roots capability and answer roots/list from `provider`.
  ## `listChanged` states that the client will call `notifyRootsListChanged`
  ## when the roots change. Call before connect().
  client.requireNotConnected("the roots provider")
  client.capabilities.roots = some(McpRootsCapability(listChanged: listChanged))
  client.registerRequestHandler("roots/list",
    proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
      let roots = await provider()
      let list = newJArray()
      for root in roots:
        let item = %*{"uri": root.uri}
        if root.name.isSome: item["name"] = %root.name.get
        list.add item
      return newJsonRpcResponse(request.id, %*{"roots": list}))

proc notifyRootsListChanged*(client: McpClient) {.async.} =
  ## Tell the server to ask for the roots again.
  client.requireFeature(ftRootsListChanged, "notifications/roots/list_changed")
  if client.capabilities.roots.isNone or not client.capabilities.roots.get.listChanged:
    raise newException(McpUnsupportedError,
      "notifications/roots/list_changed: this client did not declare roots.listChanged")
  await client.sendNotification("notifications/roots/list_changed", newJObject())
