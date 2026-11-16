## `subscriptions/listen` on the client (2026-07-28): open a stream of the
## change notifications this client wants, in place of `resources/subscribe`
## and the GET stream of earlier versions.
##
##   let subscription = await client.listen(SubscriptionFilter(
##     toolsListChanged: true, resourceSubscriptions: @["file:///project/config.json"]))
##   client.onToolsListChanged = proc() = echo "tools changed"
##   subscription.onNotification = proc(methodName: string, params: JsonNode) = ...
##   await subscription.ended        # or: await subscription.cancel()
##
## Notifications of a stream reach the callbacks the client has for them
## (`onToolsListChanged`, `onResourceUpdated`, ...) and the stream's own
## `onNotification`. The server holds nothing across a lost connection, so
## after `sbLost` the caller listens again if it still wants the stream; no
## stream is re-opened behind the caller's back.

import std/[asyncdispatch, json, options, tables]
import uuids
import ./client
import ./cancel_token
import ./deadline_watch
import ../transport/first_of
import ../protocol/features
import ../protocol/lifecycle
import ../protocol/modern
import ../protocol/subscriptions
import ../protocol/trace_context
import ../protocol/types

export subscriptions

proc cancel*(subscription: McpSubscription, reason = ""): Future[void] {.async.} =
  ## Stop listening: stdio sends `notifications/cancelled`, Streamable HTTP
  ## closes the stream. Nothing happens for a stream that has ended.
  if subscription.endedBy.isSome:
    return
  let client = subscription.owner
  client.endSubscription(subscription.id, sbCancelled)
  await client.abandon(subscription.id, ListenMethod, reason)

proc unsupported*(subscription: McpSubscription): SubscriptionFilter =
  ## What was asked for and the server did not agree to; empty until the
  ## server has acknowledged.
  if subscription.acknowledged.isNone:
    return
  let honored = subscription.acknowledged.get
  let requested = subscription.requested
  result.toolsListChanged = requested.toolsListChanged and not honored.toolsListChanged
  result.promptsListChanged = requested.promptsListChanged and not honored.promptsListChanged
  result.resourcesListChanged = requested.resourcesListChanged and not honored.resourcesListChanged
  for uri in requested.resourceSubscriptions:
    if uri notin honored.resourceSubscriptions:
      result.resourceSubscriptions.add uri
  for id in requested.taskIds:
    if id notin honored.taskIds:
      result.taskIds.add id

proc listen*(client: McpClient, filter: SubscriptionFilter,
             options: McpRequestOptions = McpRequestOptions()): Future[McpSubscription] {.async.} =
  ## Open a stream for the notifications in `filter` and wait for the
  ## server's acknowledgment, which says which of them it will deliver (see
  ## `unsupported`). `options.timeoutMs` bounds that wait and
  ## `options.cancel` can abandon it. Raises McpUnsupportedError, sending
  ## nothing, when the connection is not 2026-07-28; McpRequestError when the
  ## server rejects the request; McpProtocolError for an acknowledgment that
  ## is not one; McpConnectionClosedError when the stream ends first.
  client.requireFeature(ftSubscriptionsListen, ListenMethod)
  if not options.cancel.isNil and options.cancel.isCancelled:
    raise newException(McpCancelledError, ListenMethod & ": cancelled before it was sent")
  let problem = options.traceContext.validate
  if problem.isSome:
    raise newException(ValueError, ListenMethod & ": " & problem.get)
  let id = $genUUID()
  let subscription = McpSubscription(
    id: id, requested: filter, owner: client,
    acknowledgement: newFuture[void]("McpClient.listen.acknowledgement"),
    ended: newFuture[void]("McpClient.listen.ended"))
  # Registered before the request goes out: the acknowledgment may be the
  # first thing back.
  client.subscriptions[id] = subscription
  let params = withRequestMeta(
    withTraceContext(%*{"notifications": filter.toJson()}, options.traceContext),
    requestMeta(client.negotiatedVersion.get, client.clientInfo, client.capabilities.toJson()))
  var started: tuple[id: string, response: Future[JsonRpcResponse]]
  try:
    started = await client.startRequest(ListenMethod, params, id)
  except CatchableError:
    client.subscriptions.del(id)
    raise
  started.response.addCallback(proc() =
    # The stream's end: a response is the server's doing, a failure is the
    # connection's.
    if started.response.failed:
      discard started.response.readError()
      client.endSubscription(id, sbLost)
      return
    let response = started.response.read
    if response.error.isSome:
      subscription.failure = response.error
      client.endSubscription(id, sbFailed)
    else:
      client.endSubscription(id, sbGraceful))

  let timeoutMs = options.timeoutMs.get(client.requestTimeoutMs)
  let deadline = client.deadlines.start(timeoutMs)
  let cancelled = if options.cancel.isNil: newFuture[void]("McpClient.listen.noCancel")
                  else: options.cancel.watchCancellation()
  try:
    await firstOf(subscription.acknowledgement, subscription.ended, deadline.due, cancelled)
  finally:
    client.deadlines.release(deadline)
    if not options.cancel.isNil:
      options.cancel.unwatchCancellation(cancelled)
  if subscription.acknowledgement.finished:
    if subscription.problem.isSome:
      await subscription.cancel("malformed acknowledgment")
      raise newException(McpProtocolError,
        AcknowledgedMethod & ": " & subscription.problem.get)
    return subscription
  if subscription.ended.finished:
    if subscription.failure.isSome:
      let error = subscription.failure.get
      var failure = newException(McpRequestError, ListenMethod & ": " & error.message)
      failure.code = error.code
      failure.data = error.data
      raise failure
    raise newException(McpConnectionClosedError,
      ListenMethod & ": the stream ended before the server acknowledged it")
  await subscription.cancel(if cancelled.finished: options.cancel.cancelReason else: "no acknowledgment")
  if cancelled.finished:
    raise newException(McpCancelledError, ListenMethod & ": cancelled")
  raise newException(McpTimeoutError,
    ListenMethod & ": no acknowledgment within " & $timeoutMs & " ms")
