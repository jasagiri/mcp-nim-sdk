## The subscriptions of `subscriptions/listen` (2026-07-28) a server is
## serving: who asked for what, and the signal that ends one.
##
## Kept apart from `McpServer` so that the server only holds the registry;
## the serving of the request and the delivery of notifications are in
## `server.nim`.

import std/[asyncdispatch, json, tables]
import ../protocol/subscriptions

type
  Subscription* = ref object
    ## One open `subscriptions/listen` request.
    session*: string
    requestId*: string
      ## The id the transport knows the request by.
    idNode*: JsonNode
      ## The id as the client wrote it; notifications repeat it as the
      ## subscription id.
    filter*: SubscriptionFilter
      ## What the server agreed to honor.
    closed*: Future[void]
      ## Completes when the server tears the subscription down.
    tornDown*: bool

  SubscriptionRegistry* = object
    entries: Table[string, Subscription]

func entryKey(session, requestId: string): string =
  session & '\x00' & requestId

proc add*(registry: var SubscriptionRegistry, subscription: Subscription) =
  registry.entries[entryKey(subscription.session, subscription.requestId)] = subscription

proc remove*(registry: var SubscriptionRegistry, subscription: Subscription) =
  registry.entries.del(entryKey(subscription.session, subscription.requestId))

func count*(registry: SubscriptionRegistry): int =
  registry.entries.len

func all*(registry: SubscriptionRegistry): seq[Subscription] =
  for subscription in registry.entries.values:
    result.add subscription

func receiving*(registry: SubscriptionRegistry, methodName: string,
                params: JsonNode): seq[Subscription] =
  ## The subscriptions that receive this notification.
  for subscription in registry.entries.values:
    if subscription.filter.wants(methodName, params):
      result.add subscription
